use liltfold::{
    discovery, duplicates,
    export::{self, Settings},
    media::Backend,
    model::{self, Kind, Media, View},
};
use std::{
    collections::{HashMap, HashSet},
    fs,
    path::Path,
    sync::atomic::{AtomicUsize, Ordering},
};
use tempfile::TempDir;

fn item(path: &Path, id: usize) -> Media {
    Media::new(path.into(), path.parent().unwrap().into(), id).unwrap()
}
fn write(path: &Path, bytes: &[u8]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, bytes).unwrap();
}
fn backend(dir: &TempDir) -> Backend {
    Backend {
        tools: "/does-not-exist".into(),
        cache: dir.path().join("cache"),
    }
}

#[test]
fn discovery_recurses_without_a_depth_cap_and_deduplicates_overlapping_roots() {
    let dir = TempDir::new().unwrap();
    let root = dir.path().join("root");
    let nested = root.join("one/two/three");
    write(&nested.join("photo.JPG"), b"image");
    write(&root.join("unknown.xyz"), b"other");
    let mut deep = root.clone();
    for _ in 0..140 {
        deep.push("x");
    }
    write(&deep.join("deep.flac"), b"audio");
    std::os::unix::fs::symlink(&root, nested.join("loop")).unwrap();
    std::os::unix::fs::symlink(nested.join("photo.JPG"), root.join("alias.jpg")).unwrap();
    let roots =
        discovery::normalise_roots(vec![root.clone(), nested.clone(), root.clone()]).unwrap();
    assert_eq!(roots, vec![fs::canonicalize(root).unwrap()]);
    let mut files = vec![];
    let mut issues = vec![];
    discovery::discover(
        &roots,
        || false,
        |_| false,
        |m| files.push(m),
        |e| issues.push(e),
    );
    assert_eq!(files.len(), 3);
    assert!(issues.is_empty());
    assert!(files.iter().any(|m| m.kind == Kind::Other));
    assert!(files.iter().any(|m| m.name == "deep.flac"));
    let nested = fs::canonicalize(nested).unwrap();
    let mut excluded = vec![];
    discovery::discover(
        &roots,
        || false,
        |p| p.starts_with(&nested),
        |m| excluded.push(m),
        |_| {},
    );
    assert_eq!(excluded.len(), 2);
}

#[test]
fn discovery_reports_unreadable_paths_and_cancels() {
    let dir = TempDir::new().unwrap();
    write(&dir.path().join("a.png"), b"image");
    std::os::unix::fs::symlink(dir.path().join("missing"), dir.path().join("broken")).unwrap();
    let mut issues = vec![];
    discovery::discover(
        &[dir.path().into()],
        || false,
        |_| false,
        |_| {},
        |e| issues.push(e),
    );
    assert_eq!(issues.len(), 1);
    let mut count = 0;
    discovery::discover(
        &[dir.path().into()],
        || true,
        |_| false,
        |_| count += 1,
        |_| {},
    );
    assert_eq!(count, 0);
}

#[test]
fn duplicate_groups_require_identical_bytes_and_survive_renames() {
    let dir = TempDir::new().unwrap();
    let a = dir.path().join("z.jpg");
    let b = dir.path().join("a.png");
    let c = dir.path().join("same-size.jpg");
    let mut data = vec![5u8; 300_000];
    write(&a, &data);
    write(&b, &data);
    data[150_000] = 6;
    write(&c, &data);
    let items = vec![item(&a, 0), item(&b, 1), item(&c, 2)];
    let groups = duplicates::groups(&items, || false, |_, _| {}).unwrap();
    assert_eq!(groups, vec![vec![1, 0]]);
    assert_eq!(
        duplicates::hash_file(&a, || true).unwrap_err().kind(),
        std::io::ErrorKind::Interrupted
    );
    fs::write(&a, b"changed").unwrap();
    assert!(duplicates::groups(&items, || false, |_, _| {}).is_err());
}

#[test]
fn selection_and_scope_include_offscreen_and_hidden_selected_files() {
    let dir = TempDir::new().unwrap();
    let mut items = vec![];
    for id in 0..5000 {
        let p = dir
            .path()
            .join(format!("{id}.{}", if id % 2 == 0 { "jpg" } else { "mp3" }));
        write(&p, b"x");
        items.push(item(&p, id));
    }
    let view = View {
        filter: "image".into(),
        ..View::default()
    };
    let selected = HashSet::from([0, 1, 4999]);
    let reps = HashMap::new();
    assert_eq!(model::matching(&items, &view, &reps).len(), 2500);
    assert_eq!(
        model::scope(&items, &view, &reps, &selected, false).len(),
        3
    );
    assert_eq!(
        model::scope(&items, &view, &reps, &selected, true).len(),
        2500
    );
    items[0].copies = 2;
    items[0].group = Some("group".into());
    items[2].copies = 2;
    items[2].group = Some("group".into());
    let reps = HashMap::from([("group".into(), 2)]);
    let hide = View {
        duplicates: "hide".into(),
        ..view.clone()
    };
    let ids = model::matching(&items, &hide, &reps);
    assert!(!ids.contains(&0));
    assert!(ids.contains(&2));
    let only = View {
        duplicates: "only".into(),
        ..view
    };
    assert_eq!(model::matching(&items, &only, &reps).len(), 2);
}

#[test]
fn safe_export_handles_duplicate_names_skip_replace_and_preserves_originals() {
    let dir = TempDir::new().unwrap();
    let a = dir.path().join("source/a/same.jpg");
    let b = dir.path().join("source/b/same.jpg");
    write(&a, b"first original");
    write(&b, b"second original");
    let items = vec![item(&a, 0), item(&b, 1)];
    let out = dir.path().join("out");
    fs::create_dir(&out).unwrap();
    let mut settings = Settings {
        destination: out.clone(),
        ..Settings::default()
    };
    let report = export::execute(
        &backend(&dir),
        &items,
        &items,
        &[],
        &settings,
        &|| false,
        |_| {},
    );
    assert_eq!((report.copied, report.failed), (2, 0));
    assert_eq!(fs::read(out.join("same.jpg")).unwrap(), b"first original");
    assert_eq!(
        fs::read(out.join("same (1).jpg")).unwrap(),
        b"second original"
    );
    settings.conflict = "skip".into();
    let report = export::execute(
        &backend(&dir),
        &items,
        &items,
        &[],
        &settings,
        &|| false,
        |_| {},
    );
    assert_eq!(report.skipped, 2);
    settings.conflict = "replace".into();
    settings.destination = a.parent().unwrap().into();
    let report = export::execute(
        &backend(&dir),
        &items,
        &items,
        &[],
        &settings,
        &|| false,
        |_| {},
    );
    assert_eq!(report.failed, 2);
    assert_eq!(fs::read(&a).unwrap(), b"first original");
    assert_eq!(fs::read(&b).unwrap(), b"second original");
    let link = out.join("same.jpg");
    fs::remove_file(&link).unwrap();
    fs::hard_link(&a, &link).unwrap();
    settings.destination = out;
    let report = export::execute(
        &backend(&dir),
        &items[..1],
        &items,
        &[],
        &settings,
        &|| false,
        |_| {},
    );
    assert_eq!(report.failed, 1);
    assert_eq!(fs::read(a).unwrap(), b"first original");
}

#[test]
fn cancellation_discards_partial_files_and_keeps_sources() {
    let dir = TempDir::new().unwrap();
    let source = dir.path().join("source/large.mov");
    write(&source, b"x");
    fs::OpenOptions::new()
        .write(true)
        .open(&source)
        .unwrap()
        .set_len(16 * 1024 * 1024)
        .unwrap();
    let m = item(&source, 0);
    let out = dir.path().join("out");
    fs::create_dir(&out).unwrap();
    let ticks = AtomicUsize::new(0);
    let settings = Settings {
        destination: out.clone(),
        ..Settings::default()
    };
    let report = export::execute(
        &backend(&dir),
        std::slice::from_ref(&m),
        std::slice::from_ref(&m),
        &[],
        &settings,
        &|| ticks.fetch_add(1, Ordering::Relaxed) > 4,
        |_| {},
    );
    assert!(report.cancelled);
    assert_eq!(fs::read_dir(out).unwrap().count(), 0);
    assert_eq!(fs::metadata(source).unwrap().len(), 16 * 1024 * 1024);
}

#[test]
fn deduplicated_export_verifies_contents_before_writing() {
    let dir = TempDir::new().unwrap();
    let a = dir.path().join("a.png");
    let b = dir.path().join("b.png");
    write(&a, b"identical bytes");
    write(&b, b"identical bytes");
    let items = vec![item(&a, 0), item(&b, 1)];
    let out = dir.path().join("out");
    fs::create_dir(&out).unwrap();
    let settings = Settings {
        destination: out.clone(),
        deduplicate: true,
        preferred_ids: vec![1],
        ..Settings::default()
    };
    let report = export::execute(
        &backend(&dir),
        &items,
        &items,
        &[],
        &settings,
        &|| false,
        |_| {},
    );
    assert_eq!((report.copied, report.skipped, report.failed), (1, 1, 0));
    assert!(
        out.join("b.png").exists(),
        "The chosen representative is exported"
    );
    fs::remove_file(&b).unwrap();
    let report = export::execute(
        &backend(&dir),
        &items,
        &items,
        &[],
        &settings,
        &|| false,
        |_| {},
    );
    assert_eq!(report.copied, 0);
    assert_eq!(report.failed, 1);
}

#[test]
fn paths_naming_and_settings_are_validated() {
    let dir = TempDir::new().unwrap();
    let root = dir.path().join("root");
    let file = root.join("nested/one.jpg");
    write(&file, b"x");
    let mut m = item(&file, 0);
    m.root = root.clone();
    let mut settings = Settings {
        originals: false,
        image: "png".into(),
        sequence: true,
        prefix: "Trip".into(),
        preserve_paths: true,
        ..Settings::default()
    };
    assert_eq!(
        export::output_relative(&m, &settings, 11, &[root]).to_string_lossy(),
        "nested/Trip-0012.png"
    );
    settings.prefix = "../escape".into();
    assert!(settings.validate().is_err());
    settings.prefix = "Trip".into();
    settings.image = "exe".into();
    assert!(settings.validate().is_err());
}

#[test]
fn cache_keys_change_when_the_source_changes() {
    let dir = TempDir::new().unwrap();
    let p = dir.path().join("one.png");
    write(&p, b"before");
    let backend = backend(&dir);
    let first = backend.key(&item(&p, 0), 512);
    write(&p, b"after");
    assert_ne!(first, backend.key(&item(&p, 0), 512));
    assert_ne!(
        backend.key(&item(&p, 0), 256),
        backend.key(&item(&p, 0), 512)
    );
}
