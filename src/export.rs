use crate::{
    duplicates,
    media::{Backend, strings},
    model::{Kind, Media, Stamp},
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::HashSet,
    fs::{self, File},
    io::{self, Read, Write},
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub originals: bool,
    pub all_matching: bool,
    pub destination: PathBuf,
    pub deduplicate: bool,
    pub preserve_paths: bool,
    pub prefix: String,
    pub sequence: bool,
    pub conflict: String,
    pub image: String,
    pub video: String,
    pub audio: String,
    pub image_quality: u32,
    pub max_dimension: u32,
    pub transparency: String,
    pub metadata: bool,
    pub video_bitrate: u32,
    pub video_crf: u32,
    pub video_height: u32,
    pub frame_rate: u32,
    pub retain_audio: bool,
    pub audio_bitrate: u32,
    pub sample_rate: u32,
    pub channels: u32,
    #[serde(skip)]
    pub preferred_ids: Vec<usize>,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            originals: true,
            all_matching: false,
            destination: PathBuf::new(),
            deduplicate: false,
            preserve_paths: false,
            prefix: "Liltfold".into(),
            sequence: false,
            conflict: "unique".into(),
            image: "webp".into(),
            video: "mp4".into(),
            audio: "original".into(),
            image_quality: 88,
            max_dimension: 0,
            transparency: "preserve".into(),
            metadata: false,
            video_bitrate: 8000,
            video_crf: 25,
            video_height: 0,
            frame_rate: 0,
            retain_audio: true,
            audio_bitrate: 256,
            sample_rate: 0,
            channels: 0,
            preferred_ids: vec![],
        }
    }
}
impl Settings {
    pub fn format(&self, kind: Kind) -> &str {
        if self.originals {
            return "original";
        }
        match kind {
            Kind::Image => &self.image,
            Kind::Video => &self.video,
            Kind::Audio => &self.audio,
            Kind::Other => "original",
        }
    }
    pub fn validate(&self) -> io::Result<()> {
        for (value, choices) in [
            (
                &self.image,
                &["original", "exclude", "webp", "jpeg", "png"][..],
            ),
            (&self.video, &["original", "exclude", "mp4", "webm"][..]),
            (
                &self.audio,
                &["original", "exclude", "mp3", "m4a", "wav", "flac"][..],
            ),
            (&self.conflict, &["skip", "unique", "replace"][..]),
            (&self.transparency, &["preserve", "white", "black"][..]),
        ] {
            if !choices.contains(&value.as_str()) {
                return Err(io::Error::other("Invalid export option"));
            }
        }
        if self.sequence
            && (self.prefix.trim().is_empty()
                || self.prefix.contains(['/', '\\', ':', '\0'])
                || self.prefix == "."
                || self.prefix == "..")
        {
            return Err(io::Error::other(
                "The filename prefix must be a name without slashes or colons.",
            ));
        }
        if !(1..=100).contains(&self.image_quality)
            || self.max_dimension > 32768
            || !(100..=100000).contains(&self.video_bitrate)
            || self.video_crf > 63
            || self.video_height > 8640
            || self.frame_rate > 120
            || !(32..=320).contains(&self.audio_bitrate)
            || ![0, 22050, 44100, 48000, 96000].contains(&self.sample_rate)
            || self.channels > 2
        {
            return Err(io::Error::other(
                "Export settings are outside supported limits.",
            ));
        }
        if !self.originals && self.image == "jpeg" && self.transparency == "preserve" {
            return Err(io::Error::other(
                "JPEG cannot retain transparency. Choose a white or black background.",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Report {
    pub running: bool,
    pub total: usize,
    pub completed: usize,
    pub copied: usize,
    pub converted: usize,
    pub skipped: usize,
    pub failed: usize,
    pub cancelled: bool,
    pub stage: String,
    pub current: String,
    pub destination: PathBuf,
    pub errors: Vec<String>,
    pub outputs: Vec<PathBuf>,
}

pub fn output_relative(m: &Media, settings: &Settings, index: usize, roots: &[PathBuf]) -> PathBuf {
    let format = settings.format(m.kind);
    let extension = if format == "original" {
        m.path
            .extension()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned()
    } else if format == "jpeg" {
        "jpg".into()
    } else {
        format.into()
    };
    let name = if settings.sequence {
        format!(
            "{}-{:04}{}{}",
            settings.prefix.trim(),
            index + 1,
            if extension.is_empty() { "" } else { "." },
            extension
        )
    } else {
        let mut name = PathBuf::from(&m.name);
        if format != "original" {
            name.set_extension(extension);
        }
        name.to_string_lossy().into_owned()
    };
    if !settings.preserve_paths {
        return PathBuf::from(name);
    }
    let relative = m.path.strip_prefix(&m.root).unwrap_or(Path::new(&m.name));
    let parent = relative.parent().unwrap_or(Path::new(""));
    let mut result = PathBuf::new();
    if roots.len() > 1 {
        let label = m.root.file_name().unwrap_or_default().to_string_lossy();
        let same = roots
            .iter()
            .filter(|r| r.file_name() == m.root.file_name())
            .count();
        result.push(if same > 1 {
            format!(
                "{}-{}",
                label,
                roots.iter().position(|r| r == &m.root).unwrap_or(0) + 1
            )
        } else {
            label.into_owned()
        });
    }
    for component in parent.components() {
        if let std::path::Component::Normal(p) = component {
            result.push(p);
        }
    }
    result.push(name);
    result
}

fn cancelled_error() -> io::Error {
    io::Error::new(io::ErrorKind::Interrupted, "Cancelled")
}
pub fn copy_stream(
    source: &Path,
    target: &mut File,
    cancelled: &dyn Fn() -> bool,
) -> io::Result<()> {
    let before = Stamp::read(source)?;
    let mut input = File::open(source)?;
    let mut buffer = [0u8; 128 * 1024];
    loop {
        if cancelled() {
            return Err(cancelled_error());
        }
        let n = input.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        target.write_all(&buffer[..n])?;
    }
    if before != Stamp::read(source)? {
        return Err(io::Error::other(
            "Source changed while copying; incomplete output discarded",
        ));
    }
    target.sync_all()
}

fn convert(
    backend: &Backend,
    m: &Media,
    s: &Settings,
    dest: &Path,
    cancelled: &dyn Fn() -> bool,
) -> io::Result<()> {
    let format = s.format(m.kind);
    if m.kind == Kind::Image {
        let options = json!({"format":if format=="webp"{"png"}else{format},"quality":s.image_quality,"max_dimension":s.max_dimension,"transparency":s.transparency,"metadata":s.metadata,"thumbnail":false});
        let intermediate = tempfile::Builder::new()
            .prefix(".liltfold-")
            .suffix(".png")
            .tempfile_in(dest.parent().unwrap())?;
        let image_dest = if format == "webp" {
            intermediate.path()
        } else {
            dest
        };
        if backend
            .native_image(&m.path, image_dest, s.max_dimension, &options)
            .is_err()
        {
            // Decoder fallback shares the same resize/alpha rules; ImageIO handles HEIC and embedded RAW previews.
            let mut args = strings(&[
                "-nostdin",
                "-v",
                "error",
                "-y",
                "-i",
                &m.path.to_string_lossy(),
                "-frames:v",
                "1",
                "-threads",
                "1",
            ]);
            if s.max_dimension > 0 {
                args.extend(strings(&[
                    "-vf",
                    &format!(
                        "scale='min({},iw)':'min({},ih)':force_original_aspect_ratio=decrease",
                        s.max_dimension, s.max_dimension
                    ),
                ]));
            }
            args.extend(strings(&[
                "-f",
                "image2",
                "-c:v",
                "png",
                &intermediate.path().to_string_lossy(),
            ]));
            backend.run("ffmpeg", &args, cancelled, None)?;
            if format != "webp" {
                backend.native_image(intermediate.path(), dest, s.max_dimension, &options)?;
            }
        }
        if format == "webp" {
            backend.run(
                "cwebp",
                &strings(&[
                    "-quiet",
                    "-q",
                    &s.image_quality.to_string(),
                    "-metadata",
                    if s.metadata { "all" } else { "none" },
                    &image_dest.to_string_lossy(),
                    "-o",
                    &dest.to_string_lossy(),
                ]),
                cancelled,
                None,
            )?;
        }
    } else {
        let mut args = strings(&[
            "-nostdin",
            "-v",
            "error",
            "-y",
            "-threads",
            "2",
            "-i",
            &m.path.to_string_lossy(),
            "-map_metadata",
            if s.metadata { "0" } else { "-1" },
        ]);
        if m.kind == Kind::Video {
            args.extend(strings(&["-map", "0:v:0"]));
            if s.retain_audio {
                args.extend(strings(&["-map", "0:a:0?"]));
            } else {
                args.push("-an".into());
            }
            let height = if s.video_height == 0 {
                16384
            } else {
                s.video_height
            };
            args.extend(strings(&[
                "-vf",
                &format!("scale=-2:'min({height},ih)':force_divisible_by=2,setsar=1"),
                "-pix_fmt",
                "yuv420p",
            ]));
            if s.frame_rate > 0 {
                args.extend(strings(&["-r", &s.frame_rate.to_string()]));
            }
            if format == "mp4" {
                args.extend(strings(&[
                    "-c:v",
                    "h264_videotoolbox",
                    "-allow_sw",
                    "1",
                    "-b:v",
                    &format!("{}k", s.video_bitrate),
                    "-c:a",
                    "aac",
                    "-b:a",
                    "192k",
                    "-movflags",
                    "+faststart",
                    "-f",
                    "mp4",
                ]));
            } else {
                args.extend(strings(&[
                    "-c:v",
                    "libvpx-vp9",
                    "-crf",
                    &s.video_crf.to_string(),
                    "-b:v",
                    "0",
                    "-cpu-used",
                    "4",
                    "-row-mt",
                    "1",
                    "-threads",
                    "2",
                    "-c:a",
                    "libopus",
                    "-b:a",
                    "160k",
                    "-f",
                    "webm",
                ]));
            }
        } else {
            args.extend(strings(&["-vn", "-map", "0:a:0"]));
            match format {
                "mp3" => args.extend(strings(&[
                    "-c:a",
                    "libmp3lame",
                    "-b:a",
                    &format!("{}k", s.audio_bitrate),
                    "-f",
                    "mp3",
                ])),
                "m4a" => args.extend(strings(&[
                    "-c:a",
                    "aac",
                    "-b:a",
                    &format!("{}k", s.audio_bitrate),
                    "-movflags",
                    "+faststart",
                    "-f",
                    "ipod",
                ])),
                "wav" => args.extend(strings(&["-c:a", "pcm_s16le", "-f", "wav"])),
                "flac" => args.extend(strings(&[
                    "-c:a",
                    "flac",
                    "-compression_level",
                    "5",
                    "-f",
                    "flac",
                ])),
                _ => return Err(io::Error::other("Unsupported conversion")),
            }
            if s.sample_rate > 0 {
                args.extend(strings(&["-ar", &s.sample_rate.to_string()]));
            }
            if s.channels > 0 {
                args.extend(strings(&["-ac", &s.channels.to_string()]));
            }
        }
        args.push(dest.to_string_lossy().into());
        backend.run("ffmpeg", &args, cancelled, None)?;
    }
    let info = backend.probe(dest, cancelled)?;
    let expected = match format {
        "webp" => "webp",
        "jpeg" => "mjpeg",
        "png" => "png",
        "mp4" => "h264",
        "webm" => "vp9",
        "mp3" => "mp3",
        "m4a" => "aac",
        "wav" => "pcm_s16le",
        "flac" => "flac",
        _ => "",
    };
    if info.codec != expected {
        return Err(io::Error::other(format!(
            "Output verification failed: expected {expected}, found {}",
            info.codec
        )));
    }
    backend.run(
        "ffmpeg",
        &strings(&[
            "-nostdin",
            "-v",
            "error",
            "-threads",
            "1",
            "-i",
            &dest.to_string_lossy(),
            "-t",
            "0.1",
            "-f",
            "null",
            "-",
        ]),
        cancelled,
        None,
    )?;
    Ok(())
}

fn protected(destination: &Path, sources: &[Media]) -> bool {
    let canonical = fs::canonicalize(destination).ok();
    let stamp = Stamp::read(destination).ok();
    sources.iter().any(|m| {
        canonical.as_ref() == Some(&m.path)
            || stamp
                .as_ref()
                .is_some_and(|s| s.device == m.stamp.device && s.inode == m.stamp.inode)
    })
}
fn unique_path(path: &Path, n: usize) -> PathBuf {
    if n == 0 {
        return path.to_path_buf();
    }
    let stem = path.file_stem().unwrap_or_default().to_string_lossy();
    let ext = path
        .extension()
        .map(|s| format!(".{}", s.to_string_lossy()))
        .unwrap_or_default();
    path.with_file_name(format!("{stem} ({n}){ext}"))
}

pub fn execute(
    backend: &Backend,
    items: &[Media],
    sources: &[Media],
    roots: &[PathBuf],
    s: &Settings,
    cancelled: &dyn Fn() -> bool,
    mut progress: impl FnMut(&Report),
) -> Report {
    let mut report = Report {
        running: true,
        total: items.len(),
        destination: s.destination.clone(),
        stage: "Preparing export".into(),
        ..Report::default()
    };
    let run = (|| -> io::Result<()> {
        s.validate()?;
        let destination = fs::canonicalize(&s.destination)?;
        if !destination.is_dir() {
            return Err(io::Error::other("The destination is not a folder"));
        }
        let mut chosen: Vec<_> = items
            .iter()
            .filter(|m| s.format(m.kind) != "exclude")
            .cloned()
            .collect();
        report.total = chosen.len();
        progress(&report);
        if s.deduplicate {
            report.stage = "Verifying exact duplicates".into();
            progress(&report);
            let groups = duplicates::groups(&chosen, cancelled, |_, _| {})?;
            let excluded: HashSet<_> = groups
                .iter()
                .flat_map(|g| {
                    let keep = g
                        .iter()
                        .find(|id| s.preferred_ids.contains(id))
                        .unwrap_or(&g[0]);
                    g.iter().copied().filter(move |id| id != keep)
                })
                .collect();
            report.skipped += excluded.len();
            report.completed += excluded.len();
            chosen.retain(|m| !excluded.contains(&m.id));
        }
        for (index, m) in chosen.iter().enumerate() {
            if cancelled() {
                return Err(cancelled_error());
            }
            let format = s.format(m.kind);
            report.current = m.name.clone();
            report.stage = if format == "original" {
                "Copying original"
            } else {
                "Converting and verifying"
            }
            .into();
            progress(&report);
            let result = (|| -> io::Result<Option<PathBuf>> {
                if Stamp::read(&m.path)? != m.stamp {
                    return Err(io::Error::other(
                        "Source changed since discovery; refresh before exporting",
                    ));
                }
                let requested = destination.join(output_relative(m, s, index, roots));
                fs::create_dir_all(requested.parent().unwrap())?;
                // Resolve existing directory symlinks before applying source protection and finalisation.
                let parent = fs::canonicalize(requested.parent().unwrap())?;
                if !parent.starts_with(&destination) {
                    return Err(io::Error::other(
                        "A destination subfolder is a symlink outside the chosen destination",
                    ));
                }
                let requested = parent.join(requested.file_name().unwrap());
                if requested.exists() && s.conflict == "skip" {
                    return Ok(None);
                }
                if s.conflict == "replace"
                    && (protected(&requested, sources)
                        || (requested.exists()
                            && roots.iter().any(|root| requested.starts_with(root))))
                {
                    return Err(io::Error::other(
                        "Refused to overwrite an original source file",
                    ));
                }
                let mut temp = tempfile::Builder::new()
                    .prefix(".liltfold-")
                    .suffix(".partial")
                    .tempfile_in(&parent)?;
                if format == "original" {
                    copy_stream(&m.path, temp.as_file_mut(), cancelled)?;
                } else {
                    convert(backend, m, s, temp.path(), cancelled)?;
                    File::open(temp.path())?.sync_all()?;
                }
                if cancelled() {
                    return Err(cancelled_error());
                }
                if Stamp::read(&m.path)? != m.stamp {
                    return Err(io::Error::other(
                        "Source changed during export; output discarded",
                    ));
                }
                if s.conflict == "replace" {
                    if protected(&requested, sources) {
                        return Err(io::Error::other(
                            "Refused to overwrite an original source file",
                        ));
                    }
                    temp.persist(&requested).map_err(|e| e.error)?;
                    return Ok(Some(requested));
                }
                let mut n = 0;
                loop {
                    let target = unique_path(&requested, n);
                    match temp.persist_noclobber(&target) {
                        Ok(_) => return Ok(Some(target)),
                        Err(e) if e.error.kind() == io::ErrorKind::AlreadyExists => {
                            temp = e.file;
                            if s.conflict == "skip" {
                                return Ok(None);
                            }
                            n += 1;
                        }
                        Err(e) => return Err(e.error),
                    }
                    if cancelled() {
                        return Err(cancelled_error());
                    }
                }
            })();
            match result {
                Ok(Some(path)) => {
                    report.outputs.push(path);
                    if format == "original" {
                        report.copied += 1;
                    } else {
                        report.converted += 1;
                    }
                }
                Ok(None) => report.skipped += 1,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => return Err(e),
                Err(e) => {
                    report.failed += 1;
                    report.errors.push(format!("{}: {e}", m.path.display()));
                }
            }
            report.completed += 1;
            progress(&report);
        }
        Ok(())
    })();
    if let Err(e) = run {
        if e.kind() == io::ErrorKind::Interrupted {
            report.cancelled = true;
        } else {
            report.failed += 1;
            report.errors.push(e.to_string());
        }
    }
    report.running = false;
    report.current.clear();
    report.stage = if report.cancelled {
        "Cancelled — completed files kept"
    } else if report.failed > 0 {
        "Finished with errors"
    } else {
        "Export complete"
    }
    .into();
    progress(&report);
    report
}
