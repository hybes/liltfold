use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    fs,
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Image,
    Video,
    Audio,
    Other,
}

impl Kind {
    pub fn of(path: &Path) -> Self {
        match path
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_lowercase()
            .as_str()
        {
            "jpg" | "jpeg" | "png" | "heic" | "heif" | "webp" | "tif" | "tiff" | "gif" | "bmp"
            | "avif" | "dng" | "cr2" | "cr3" | "nef" | "arw" | "orf" | "rw2" | "raf" | "pef"
            | "exr" => Self::Image,
            "mp4" | "mov" | "webm" | "mkv" | "m4v" | "avi" | "mts" | "m2ts" | "mpg" | "mpeg"
            | "3gp" => Self::Video,
            "mp3" | "m4a" | "wav" | "flac" | "aif" | "aiff" | "aac" | "ogg" | "opus" | "wma"
            | "caf" => Self::Audio,
            _ => Self::Other,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Stamp {
    pub size: u64,
    pub modified: u128,
    pub inode: u64,
    pub device: u64,
}
impl Stamp {
    pub fn read(path: &Path) -> std::io::Result<Self> {
        use std::os::unix::fs::MetadataExt;
        let m = fs::metadata(path)?;
        Ok(Self {
            size: m.len(),
            modified: m
                .modified()?
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos(),
            inode: m.ino(),
            device: m.dev(),
        })
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Info {
    pub width: u32,
    pub height: u32,
    pub duration: f64,
    pub codec: String,
    pub audio: bool,
    pub frames: u32,
    pub sample_rate: u32,
    pub channels: u32,
    pub colour: String,
    pub title: String,
    pub artist: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Media {
    pub id: usize,
    pub path: PathBuf,
    pub root: PathBuf,
    pub name: String,
    pub kind: Kind,
    pub size: u64,
    pub modified: f64,
    #[serde(skip)]
    pub stamp: Stamp,
    pub info: Info,
    pub thumbnail: Option<PathBuf>,
    pub waveform: Vec<f32>,
    pub error: Option<String>,
    pub group: Option<String>,
    pub copies: usize,
}
impl Media {
    pub fn new(path: PathBuf, root: PathBuf, id: usize) -> std::io::Result<Self> {
        let stamp = Stamp::read(&path)?;
        Ok(Self {
            id,
            name: path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into(),
            kind: Kind::of(&path),
            size: stamp.size,
            modified: stamp.modified as f64 / 1e9,
            stamp,
            path,
            root,
            info: Info::default(),
            thumbnail: None,
            waveform: vec![],
            error: None,
            group: None,
            copies: 1,
        })
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct View {
    pub filter: String,
    pub query: String,
    pub sort: String,
    pub duplicates: String,
}
impl Default for View {
    fn default() -> Self {
        Self {
            filter: "all".into(),
            query: String::new(),
            sort: "name".into(),
            duplicates: "all".into(),
        }
    }
}
pub fn matching(
    items: &[Media],
    view: &View,
    representatives: &HashMap<String, usize>,
) -> Vec<usize> {
    let query = view.query.to_lowercase();
    let mut ids: Vec<_> = items
        .iter()
        .filter(|m| {
            (view.filter == "all"
                || matches!(
                    (view.filter.as_str(), m.kind),
                    ("image", Kind::Image)
                        | ("video", Kind::Video)
                        | ("audio", Kind::Audio)
                        | ("other", Kind::Other)
                ))
                && m.name.to_lowercase().contains(&query)
                && (view.duplicates != "only" || m.copies > 1)
                && (view.duplicates != "hide"
                    || m.group
                        .as_ref()
                        .is_none_or(|g| representatives.get(g).is_none_or(|id| *id == m.id)))
        })
        .map(|m| m.id)
        .collect();
    ids.sort_by(|a, b| {
        let (a, b) = (&items[*a], &items[*b]);
        let order = match view.sort.as_str() {
            "date" => b.modified.total_cmp(&a.modified),
            "size" => b.size.cmp(&a.size),
            "type" => format!("{:?}", a.kind).cmp(&format!("{:?}", b.kind)),
            _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
        };
        order.then_with(|| a.path.cmp(&b.path))
    });
    ids
}
pub fn scope(
    items: &[Media],
    view: &View,
    reps: &HashMap<String, usize>,
    selected: &HashSet<usize>,
    all: bool,
) -> Vec<Media> {
    if all {
        matching(items, view, reps)
            .into_iter()
            .map(|i| items[i].clone())
            .collect()
    } else {
        let mut result: Vec<_> = items
            .iter()
            .filter(|m| selected.contains(&m.id))
            .cloned()
            .collect();
        result.sort_by(|a, b| a.path.cmp(&b.path));
        result
    }
}
