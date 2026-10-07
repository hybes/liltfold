pub mod discovery;
pub mod duplicates;
pub mod export;
pub mod media;
pub mod model;

use export::{Report, Settings};
use media::{Backend, NativeImage};
use model::{Kind, Media, View};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    ffi::{CStr, CString, c_char},
    fs,
    path::PathBuf,
    sync::{
        Arc, Condvar, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

struct State {
    roots: Vec<PathBuf>,
    items: Vec<Media>,
    selected: HashSet<usize>,
    view: View,
    reps: HashMap<String, usize>,
    scanning: bool,
    issues: Vec<String>,
    duplicate_status: String,
    duplicate_progress: f64,
    revision: u64,
    view_revision: u64,
    dirty: HashSet<usize>,
    report: Report,
    preview: Value,
    excluded: Vec<PathBuf>,
    preferences: Value,
    started: Instant,
    first_preview_ms: Option<u128>,
}
impl State {
    fn touch(&mut self, list: bool) {
        self.revision += 1;
        if list {
            self.view_revision += 1;
        }
    }
}
struct Work {
    id: usize,
    generation: u64,
    epoch: u64,
    size: u32,
}
struct ScanJob {
    roots: Vec<PathBuf>,
    generation: u64,
}
struct Queue {
    inflight: HashSet<(u64, usize)>,
    jobs: VecDeque<Work>,
    wanted: Vec<usize>,
    epoch: u64,
}
pub struct Engine {
    state: Mutex<State>,
    backend: Backend,
    generation: AtomicU64,
    queue: (Mutex<Queue>, Condvar),
    busy: AtomicUsize,
    export_cancel: AtomicBool,
    preview_serial: AtomicU64,
    preview_queue: (Mutex<Option<(Media, u64)>>, Condvar),
    scan_queue: (Mutex<Option<ScanJob>>, Condvar),
    generated: AtomicUsize,
}

fn background_priority() {
    #[cfg(target_os = "macos")]
    unsafe {
        unsafe extern "C" {
            fn pthread_set_qos_class_self_np(class: u32, priority: i32) -> i32;
        }
        pthread_set_qos_class_self_np(0x09, 0);
    }
}
impl Engine {
    pub fn new(backend: Backend) -> Arc<Self> {
        let _ = fs::create_dir_all(&backend.cache);
        let prefs = fs::read(backend.cache.join("preferences.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or(json!({"theme":"system","thumbnail_size":196}));
        let engine = Arc::new(Self {
            state: Mutex::new(State {
                roots: vec![],
                items: vec![],
                selected: HashSet::new(),
                view: View::default(),
                reps: HashMap::new(),
                scanning: false,
                issues: vec![],
                duplicate_status: "Add a folder to begin".into(),
                duplicate_progress: 0.0,
                revision: 1,
                view_revision: 1,
                dirty: HashSet::new(),
                report: Report::default(),
                preview: Value::Null,
                excluded: vec![],
                preferences: prefs,
                started: Instant::now(),
                first_preview_ms: None,
            }),
            backend,
            generation: AtomicU64::new(0),
            queue: (
                Mutex::new(Queue {
                    inflight: HashSet::new(),
                    jobs: VecDeque::new(),
                    wanted: vec![],
                    epoch: 0,
                }),
                Condvar::new(),
            ),
            busy: AtomicUsize::new(0),
            export_cancel: AtomicBool::new(false),
            preview_serial: AtomicU64::new(0),
            preview_queue: (Mutex::new(None), Condvar::new()),
            scan_queue: (Mutex::new(None), Condvar::new()),
            generated: AtomicUsize::new(0),
        });
        for _ in 0..2 {
            let engine = engine.clone();
            thread::spawn(move || engine.thumbnail_worker());
        }
        let e = engine.clone();
        thread::spawn(move || e.preview_worker());
        let e = engine.clone();
        thread::spawn(move || e.scan_worker());
        let e = engine.clone();
        thread::spawn(move || e.watch_visible());
        let e = engine.clone();
        thread::spawn(move || {
            background_priority();
            e.backend.prune_cache();
        });
        engine
    }
    fn scan(self: &Arc<Self>, roots: Vec<PathBuf>) -> Result<(), String> {
        let roots = discovery::normalise_roots(roots).map_err(|e| e.to_string())?;
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        self.preview_serial.fetch_add(1, Ordering::SeqCst);
        {
            let mut q = self.queue.0.lock().unwrap();
            q.jobs.clear();
            q.wanted.clear();
            q.epoch += 1;
        }
        {
            let mut s = self.state.lock().unwrap();
            s.roots = roots.clone();
            s.items.clear();
            s.selected.clear();
            s.reps.clear();
            s.dirty.clear();
            s.issues.clear();
            s.preview = Value::Null;
            s.scanning = true;
            s.duplicate_status = "Waiting for discovery".into();
            s.duplicate_progress = 0.0;
            s.started = Instant::now();
            s.first_preview_ms = None;
            s.touch(true);
        }
        *self.scan_queue.0.lock().unwrap() = Some(ScanJob { roots, generation });
        self.scan_queue.1.notify_one();
        Ok(())
    }
    fn scan_worker(self: Arc<Self>) {
        background_priority();
        loop {
            let ScanJob { roots, generation } = {
                let mut q = self.scan_queue.0.lock().unwrap();
                while q.is_none() {
                    q = self.scan_queue.1.wait(q).unwrap();
                }
                q.take().unwrap()
            };
            let e = &self;
            let mut batch = Vec::with_capacity(64);
            let mut last = Instant::now();
            discovery::discover(
                &roots,
                || e.generation.load(Ordering::Relaxed) != generation,
                |p| {
                    e.state
                        .lock()
                        .unwrap()
                        .excluded
                        .iter()
                        .any(|x| p.starts_with(x))
                },
                |m| {
                    batch.push(m);
                    if batch.len() >= 64 || last.elapsed() > Duration::from_millis(80) {
                        e.append(&mut batch, generation);
                        last = Instant::now();
                    }
                },
                |error| {
                    let mut s = e.state.lock().unwrap();
                    if e.generation.load(Ordering::Relaxed) == generation && s.issues.len() < 200 {
                        s.issues.push(error);
                        s.touch(false);
                    }
                },
            );
            e.append(&mut batch, generation);
            if e.generation.load(Ordering::Relaxed) != generation {
                continue;
            }
            {
                let mut s = e.state.lock().unwrap();
                s.scanning = false;
                s.duplicate_status = "Checking exact duplicates".into();
                s.touch(true);
            }
            e.check_duplicates(generation);
        }
    }
    fn watch_visible(self: Arc<Self>) {
        background_priority();
        loop {
            thread::sleep(Duration::from_secs(2));
            let generation = self.generation.load(Ordering::Relaxed);
            let ids = self.queue.0.lock().unwrap().wanted.clone();
            let items: Vec<_> = {
                let s = self.state.lock().unwrap();
                ids.iter()
                    .filter_map(|id| s.items.get(*id).cloned())
                    .collect()
            };
            for mut m in items {
                if self.generation.load(Ordering::Relaxed) != generation {
                    break;
                }
                let changed = match model::Stamp::read(&m.path) {
                    Ok(stamp)
                        if stamp != m.stamp
                            || m.error
                                .as_ref()
                                .is_some_and(|e| e.starts_with("File missing")) =>
                    {
                        m.stamp = stamp.clone();
                        m.size = stamp.size;
                        m.modified = stamp.modified as f64 / 1e9;
                        m.info = model::Info::default();
                        m.thumbnail = None;
                        m.waveform.clear();
                        m.error = None;
                        true
                    }
                    Err(e)
                        if m.error
                            .as_ref()
                            .is_none_or(|e| !e.starts_with("File missing")) =>
                    {
                        m.error = Some(format!("File missing or unreadable: {e}"));
                        m.thumbnail = None;
                        true
                    }
                    _ => false,
                };
                if changed {
                    let mut s = self.state.lock().unwrap();
                    if self.generation.load(Ordering::Relaxed) != generation
                        || m.id >= s.items.len()
                    {
                        break;
                    }
                    if let Some(group) = m.group.take() {
                        for item in &mut s.items {
                            if item.group.as_ref() == Some(&group) {
                                item.group = None;
                                item.copies = 1;
                            }
                        }
                        s.reps.remove(&group);
                    }
                    m.copies = 1;
                    let id = m.id;
                    s.items[id] = m;
                    s.duplicate_status = "Incomplete · source changed; refresh to recheck".into();
                    s.touch(true);
                }
            }
        }
    }
    fn append(&self, batch: &mut Vec<Media>, generation: u64) {
        if self.generation.load(Ordering::Relaxed) != generation {
            batch.clear();
            return;
        }
        let mut s = self.state.lock().unwrap();
        for mut m in batch.drain(..) {
            if s.excluded.iter().any(|p| m.path.starts_with(p)) {
                continue;
            }
            m.id = s.items.len();
            s.items.push(m);
        }
        s.touch(true);
    }
    fn check_duplicates(&self, generation: u64) {
        let items = self.state.lock().unwrap().items.clone();
        let cancelled = || {
            while self.busy.load(Ordering::Relaxed) > 0
                || !self.queue.0.lock().unwrap().jobs.is_empty()
            {
                if self.generation.load(Ordering::Relaxed) != generation {
                    return true;
                }
                thread::sleep(Duration::from_millis(40));
            }
            self.generation.load(Ordering::Relaxed) != generation
        };
        let groups = duplicates::groups(&items, cancelled, |done, total| {
            let mut s = self.state.lock().unwrap();
            s.duplicate_progress = if total > 0 {
                done as f64 / total as f64
            } else {
                1.0
            };
            s.touch(false);
        });
        if self.generation.load(Ordering::Relaxed) != generation {
            return;
        }
        let mut s = self.state.lock().unwrap();
        match groups {
            Ok(groups) => {
                let count = groups.len();
                for group in groups {
                    let key = group[0].to_string();
                    s.reps.insert(key.clone(), group[0]);
                    for id in &group {
                        s.items[*id].group = Some(key.clone());
                        s.items[*id].copies = group.len();
                    }
                }
                s.duplicate_status = format!(
                    "Complete · {count} exact duplicate {}",
                    if count == 1 { "group" } else { "groups" }
                );
                s.duplicate_progress = 1.0;
            }
            Err(e) => s.duplicate_status = format!("Incomplete · {e}"),
        }
        s.touch(true);
    }
    fn thumbnail_worker(self: Arc<Self>) {
        loop {
            let work = {
                let mut q = self.queue.0.lock().unwrap();
                while q.jobs.is_empty() {
                    q = self.queue.1.wait(q).unwrap();
                }
                let work = q.jobs.pop_front().unwrap();
                q.inflight.insert((work.generation, work.id));
                work
            };
            self.process_thumbnail(&work);
            let mut q = self.queue.0.lock().unwrap();
            q.inflight.remove(&(work.generation, work.id));
            if q.epoch != work.epoch
                && self.generation.load(Ordering::Relaxed) == work.generation
                && q.wanted.contains(&work.id)
            {
                let epoch = q.epoch;
                q.jobs.push_back(Work { epoch, ..work });
                self.queue.1.notify_one();
            }
        }
    }
    fn process_thumbnail(&self, work: &Work) {
        if self.generation.load(Ordering::Relaxed) != work.generation {
            return;
        }
        let m = { self.state.lock().unwrap().items.get(work.id).cloned() };
        let Some(mut m) = m else {
            return;
        };
        let cancelled = || {
            self.generation.load(Ordering::Relaxed) != work.generation
                || self.queue.0.lock().unwrap().epoch != work.epoch
        };
        if cancelled() {
            return;
        }
        self.busy.fetch_add(1, Ordering::Relaxed);
        if m.kind == Kind::Audio
            && m.info.duration == 0.0
            && let Ok(info) = self.backend.probe(&m.path, &cancelled)
        {
            m.info = info;
            let mut s = self.state.lock().unwrap();
            if self.generation.load(Ordering::Relaxed) == work.generation && work.id < s.items.len()
            {
                s.items[work.id].info = m.info.clone();
                s.dirty.insert(work.id);
                s.touch(false);
            }
        }
        let result = (|| {
            let stamp = model::Stamp::read(&m.path)?;
            if stamp != m.stamp {
                m.stamp = stamp.clone();
                m.size = stamp.size;
                m.modified = stamp.modified as f64 / 1e9;
                m.group = None;
                m.copies = 1;
            }
            self.backend.thumbnail(&m, work.size, &cancelled)
        })();
        self.busy.fetch_sub(1, Ordering::Relaxed);
        if self
            .generated
            .fetch_add(1, Ordering::Relaxed)
            .is_multiple_of(64)
        {
            self.backend.prune_cache();
        }
        if cancelled() {
            return;
        }
        let mut s = self.state.lock().unwrap();
        if work.id >= s.items.len() {
            return;
        }
        match result {
            Ok((path, cache)) => {
                m.thumbnail = path;
                m.info = cache.info;
                m.waveform = cache.waveform;
                m.error = None;
                if s.first_preview_ms.is_none() {
                    s.first_preview_ms = Some(s.started.elapsed().as_millis());
                }
            }
            Err(e) => {
                m.error = Some(e.to_string());
            }
        }
        s.items[work.id] = m;
        s.dirty.insert(work.id);
        s.touch(false);
    }
    fn preview_worker(self: Arc<Self>) {
        loop {
            let (m, serial) = {
                let mut q = self.preview_queue.0.lock().unwrap();
                while q.is_none() {
                    q = self.preview_queue.1.wait(q).unwrap();
                }
                q.take().unwrap()
            };
            let result = self.backend.preview(&m, &|| {
                self.preview_serial.load(Ordering::Relaxed) != serial
            });
            if self.preview_serial.load(Ordering::Relaxed) != serial {
                continue;
            }
            let mut s = self.state.lock().unwrap();
            s.preview = match result {
                Ok(path) => json!({"id":m.id,"status":"ready","path":path,"item":m}),
                Err(error) => {
                    json!({"id":m.id,"status":"error","error":error.to_string(),"item":m})
                }
            };
            s.touch(false);
        }
    }
    pub fn command(self: &Arc<Self>, v: Value) -> Result<Value, String> {
        let action = v["action"].as_str().ok_or("Missing action")?;
        match action {
            "add_roots" | "refresh" | "remove_root" => {
                let mut roots = self.state.lock().unwrap().roots.clone();
                if action == "add_roots" {
                    roots.extend(
                        v["paths"]
                            .as_array()
                            .ok_or("Missing folders")?
                            .iter()
                            .filter_map(|s| s.as_str().map(PathBuf::from)),
                    );
                }
                if action == "remove_root" {
                    roots.retain(|p| Some(p.to_string_lossy().as_ref()) != v["path"].as_str());
                }
                self.scan(roots)?;
                Ok(json!({}))
            }
            "clear" => {
                self.state.lock().unwrap().excluded.clear();
                self.scan(vec![])?;
                Ok(json!({}))
            }
            "cancel_scan" => {
                self.generation.fetch_add(1, Ordering::SeqCst);
                let mut s = self.state.lock().unwrap();
                s.scanning = false;
                s.duplicate_status = "Incomplete · discovery stopped".into();
                s.touch(false);
                Ok(json!({}))
            }
            "view" => {
                let view: View =
                    serde_json::from_value(v["view"].clone()).map_err(|e| e.to_string())?;
                let mut s = self.state.lock().unwrap();
                s.view = view;
                s.touch(true);
                Ok(json!({}))
            }
            "selection" => {
                let mut s = self.state.lock().unwrap();
                s.selected = v["ids"]
                    .as_array()
                    .ok_or("Missing selection")?
                    .iter()
                    .filter_map(|v| v.as_u64().map(|n| n as usize))
                    .filter(|id| *id < s.items.len())
                    .collect();
                s.touch(false);
                Ok(json!({}))
            }
            "select_all" => {
                let mut s = self.state.lock().unwrap();
                let ids = model::matching(&s.items, &s.view, &s.reps);
                s.selected.extend(ids);
                s.touch(false);
                Ok(json!({}))
            }
            "deselect_all" => {
                let mut s = self.state.lock().unwrap();
                s.selected.clear();
                s.touch(false);
                Ok(json!({}))
            }
            "representative" => {
                let id = v["id"].as_u64().ok_or("Missing item")? as usize;
                let mut s = self.state.lock().unwrap();
                let group = s
                    .items
                    .get(id)
                    .and_then(|m| m.group.clone())
                    .ok_or("No duplicate group")?;
                s.reps.insert(group, id);
                s.touch(true);
                Ok(json!({}))
            }
            "duplicates" => {
                let s = self.state.lock().unwrap();
                let id = v["id"].as_u64().ok_or("Missing item")? as usize;
                let m = s.items.get(id).ok_or("Item no longer available")?;
                Ok(json!(
                        s.items
                            .iter()
                            .filter(|item| item.id == id
                                || (m.group.is_some() && m.group == item.group))
                            .collect::<Vec<_>>()
                    ))
            }
            "thumbnails" => {
                let ids: Vec<usize> = v["ids"]
                    .as_array()
                    .ok_or("Missing viewport")?
                    .iter()
                    .filter_map(|v| v.as_u64().map(|n| n as usize))
                    .take(180)
                    .collect();
                let s = self.state.lock().unwrap();
                let mut q = self.queue.0.lock().unwrap();
                if q.wanted != ids {
                    q.wanted = ids.clone();
                    q.epoch += 1;
                    q.jobs.clear();
                }
                let epoch = q.epoch;
                let generation = self.generation.load(Ordering::Relaxed);
                let queued: HashSet<_> = q.jobs.iter().map(|w| w.id).collect();
                for id in ids {
                    if let Some(m) = s.items.get(id)
                        && m.thumbnail.is_none()
                        && m.waveform.is_empty()
                        && m.error.is_none()
                        && !queued.contains(&id)
                        && !q.inflight.contains(&(generation, id))
                    {
                        q.jobs.push_back(Work {
                            id,
                            generation,
                            epoch,
                            size: 512,
                        });
                    }
                }
                self.queue.1.notify_all();
                Ok(json!({}))
            }
            "preview" => {
                let id = v["id"].as_u64().ok_or("Missing item")? as usize;
                let mut s = self.state.lock().unwrap();
                let m = s.items.get(id).cloned().ok_or("Item no longer available")?;
                let serial = self.preview_serial.fetch_add(1, Ordering::SeqCst) + 1;
                s.preview = json!({"id":id,"status":"loading","item":m});
                s.touch(false);
                *self.preview_queue.0.lock().unwrap() = Some((m, serial));
                self.preview_queue.1.notify_one();
                Ok(json!({}))
            }
            "close_preview" => {
                self.preview_serial.fetch_add(1, Ordering::SeqCst);
                let mut s = self.state.lock().unwrap();
                s.preview = Value::Null;
                s.touch(false);
                Ok(json!({}))
            }
            "export_plan" => {
                let settings: Settings =
                    serde_json::from_value(v["settings"].clone()).map_err(|e| e.to_string())?;
                let s = self.state.lock().unwrap();
                let items = model::scope(
                    &s.items,
                    &s.view,
                    &s.reps,
                    &s.selected,
                    settings.all_matching,
                );
                let included: Vec<_> = items
                    .iter()
                    .filter(|m| settings.format(m.kind) != "exclude")
                    .collect();
                Ok(
                    json!({"count":included.len(),"excluded":items.len()-included.len(),"bytes":included.iter().map(|m|m.size).sum::<u64>(),"images":included.iter().filter(|m|m.kind==Kind::Image).count(),"videos":included.iter().filter(|m|m.kind==Kind::Video).count(),"audio":included.iter().filter(|m|m.kind==Kind::Audio).count(),"other":included.iter().filter(|m|m.kind==Kind::Other).count(),"sample_names":included.iter().take(3).enumerate().map(|(i,m)|export::output_relative(m,&settings,i,&s.roots)).collect::<Vec<_>>()}),
                )
            }
            "export" => {
                let mut settings: Settings =
                    serde_json::from_value(v["settings"].clone()).map_err(|e| e.to_string())?;
                settings.validate().map_err(|e| e.to_string())?;
                let mut s = self.state.lock().unwrap();
                settings.preferred_ids = s.reps.values().copied().collect();
                if s.report.running {
                    return Err("An export is already running".into());
                }
                if (settings.all_matching || settings.conflict == "replace") && s.scanning {
                    return Err(
                        "Wait for discovery to finish before exporting all matching files or replacing files.".into(),
                    );
                }
                let items = model::scope(
                    &s.items,
                    &s.view,
                    &s.reps,
                    &s.selected,
                    settings.all_matching,
                );
                if !items.iter().any(|m| settings.format(m.kind) != "exclude") {
                    return Err(
                        "No files in this export. Select files or change the export scope.".into(),
                    );
                }
                let destination = fs::canonicalize(&settings.destination)
                    .map_err(|e| format!("Choose an available destination folder: {e}"))?;
                if s.roots.iter().any(|root| root.starts_with(&destination)) {
                    return Err("Choose a separate destination or a subfolder. A source root, or a folder containing it, cannot be the export destination.".into());
                }
                // The exclusion is installed before work begins, including during an active recursive scan.
                s.excluded.push(destination);
                let sources = s.items.clone();
                let roots = s.roots.clone();
                s.report = Report {
                    running: true,
                    total: items.len(),
                    stage: "Preparing export".into(),
                    destination: settings.destination.clone(),
                    ..Report::default()
                };
                s.touch(false);
                self.export_cancel.store(false, Ordering::Relaxed);
                let e = self.clone();
                thread::spawn(move || {
                    background_priority();
                    export::execute(
                        &e.backend,
                        &items,
                        &sources,
                        &roots,
                        &settings,
                        &|| e.export_cancel.load(Ordering::Relaxed),
                        |report| {
                            let mut s = e.state.lock().unwrap();
                            s.report = report.clone();
                            s.touch(false);
                        },
                    );
                });
                Ok(json!({}))
            }
            "cancel_export" => {
                self.export_cancel.store(true, Ordering::Relaxed);
                Ok(json!({}))
            }
            "dismiss_report" => {
                let mut s = self.state.lock().unwrap();
                if !s.report.running {
                    s.report = Report::default();
                    s.touch(false);
                }
                Ok(json!({}))
            }
            "preferences" => {
                let mut s = self.state.lock().unwrap();
                s.preferences = v["preferences"].clone();
                let _ = fs::write(
                    self.backend.cache.join("preferences.json"),
                    s.preferences.to_string(),
                );
                s.touch(false);
                Ok(json!({}))
            }
            "poll" => {
                let mut s = self.state.lock().unwrap();
                if v["revision"].as_u64() == Some(s.revision) {
                    return Ok(json!({"unchanged":true}));
                }
                let ids = model::matching(&s.items, &s.view, &s.reps);
                let matching: HashSet<_> = ids.iter().copied().collect();
                let hidden = s
                    .selected
                    .iter()
                    .filter(|id| !matching.contains(id))
                    .count();
                let items = if v["view_revision"].as_u64() != Some(s.view_revision) {
                    Some(
                        ids.iter()
                            .map(|id| s.items[*id].clone())
                            .collect::<Vec<_>>(),
                    )
                } else {
                    None
                };
                let updates: Vec<_> = s.dirty.drain().collect();
                let updates: Vec<_> = updates
                    .iter()
                    .filter_map(|id| s.items.get(*id).cloned())
                    .collect();
                Ok(
                    json!({"revision":s.revision,"view_revision":s.view_revision,"items":items,"updates":updates,"roots":s.roots,"total":s.items.len(),"matching":ids.len(),"selected":s.selected,"hidden_selected":hidden,"scanning":s.scanning,"issues":s.issues,"duplicate_status":s.duplicate_status,"duplicate_progress":s.duplicate_progress,"report":s.report,"preview":s.preview,"preferences":s.preferences,"first_preview_ms":s.first_preview_ms,"elapsed_ms":s.started.elapsed().as_millis(),"counts":[s.items.iter().filter(|m|m.kind==Kind::Image).count(),s.items.iter().filter(|m|m.kind==Kind::Video).count(),s.items.iter().filter(|m|m.kind==Kind::Audio).count(),s.items.iter().filter(|m|m.kind==Kind::Other).count()]}),
                )
            }
            _ => Err(format!("Unknown action: {action}")),
        }
    }
}

static ENGINE: OnceLock<Arc<Engine>> = OnceLock::new();
/// Initialise once from the native main thread. Paths must be live, NUL-terminated UTF-8 strings.
/// # Safety
/// The caller owns the valid strings and callback for the process lifetime.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lilt_init(
    cache: *const c_char,
    tools: *const c_char,
    image: Option<NativeImage>,
) {
    if cache.is_null() || tools.is_null() {
        return;
    }
    if let Some(callback) = image {
        let _ = media::IMAGE.set(callback);
    }
    // SAFETY: the native launcher supplies valid C strings for the duration of the call.
    let (cache, tools) = unsafe {
        (
            CStr::from_ptr(cache).to_string_lossy().into_owned(),
            CStr::from_ptr(tools).to_string_lossy().into_owned(),
        )
    };
    let _ = ENGINE.set(Engine::new(Backend {
        cache: cache.into(),
        tools: tools.into(),
    }));
}
/// # Safety
/// `input` must be a valid NUL-terminated string. Release the returned allocation with `lilt_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lilt_command(input: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| -> Result<Value, String> {
        if input.is_null() {
            return Err("Empty command".into());
        }
        // SAFETY: guaranteed by this function's C ABI contract.
        let bytes = unsafe { CStr::from_ptr(input) }.to_bytes();
        let value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        ENGINE.get().ok_or("Engine not initialised")?.command(value)
    });
    let value = match result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => json!({"error":error}),
        Err(_) => json!({"error":"An internal operation failed. Restart Liltfold if it persists."}),
    };
    CString::new(value.to_string()).unwrap().into_raw()
}
/// # Safety
/// Pass only an unreleased pointer returned by `lilt_command`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lilt_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        unsafe {
            drop(CString::from_raw(pointer));
        }
    }
}
