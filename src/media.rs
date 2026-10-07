use crate::model::{Info, Kind, Media};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    ffi::{CString, c_char},
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::OnceLock,
    thread,
    time::{Duration, Instant},
};

#[repr(C)]
#[derive(Default)]
pub struct NativeInfo {
    pub width: u32,
    pub height: u32,
    pub frames: u32,
}
pub type NativeImage =
    unsafe extern "C" fn(*const c_char, *const c_char, u32, *const c_char, *mut NativeInfo) -> i32;
pub static IMAGE: OnceLock<NativeImage> = OnceLock::new();

#[derive(Clone)]
pub struct Backend {
    pub tools: PathBuf,
    pub cache: PathBuf,
}
#[derive(Serialize, Deserialize)]
pub struct Cached {
    pub info: Info,
    pub waveform: Vec<f32>,
}

impl Backend {
    pub fn tool(&self, name: &str) -> PathBuf {
        self.tools.join(name)
    }
    pub fn key(&self, m: &Media, size: u32) -> String {
        format!(
            "{:x}",
            Sha256::digest(format!("v4:{}:{:?}:{size}", m.path.display(), m.stamp).as_bytes())
        )
    }
    pub fn run(
        &self,
        name: &str,
        args: &[String],
        cancelled: &dyn Fn() -> bool,
        timeout: Option<Duration>,
    ) -> io::Result<Vec<u8>> {
        let out = tempfile::tempfile()?;
        let err = tempfile::tempfile()?;
        let mut child = Command::new(self.tool(name))
            .args(args)
            .stdin(Stdio::null())
            .stdout(out.try_clone()?)
            .stderr(err.try_clone()?)
            .spawn()
            .map_err(|e| io::Error::other(format!("Could not start bundled {name}: {e}")))?;
        let start = Instant::now();
        let status = loop {
            if cancelled() || timeout.is_some_and(|t| start.elapsed() > t) {
                let _ = child.kill();
                let _ = child.wait();
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    if cancelled() {
                        "Cancelled"
                    } else {
                        "Media decoder timed out"
                    },
                ));
            }
            if let Some(status) = child.try_wait()? {
                break status;
            }
            thread::sleep(Duration::from_millis(20));
        };
        use std::io::{Seek, SeekFrom};
        if !status.success() {
            let mut err = err;
            err.seek(SeekFrom::Start(0))?;
            let mut text = String::new();
            err.take(12_000).read_to_string(&mut text)?;
            return Err(io::Error::other(if text.trim().is_empty() {
                format!("{name} failed ({status})")
            } else {
                text.trim().to_owned()
            }));
        }
        let mut out = out;
        out.seek(SeekFrom::Start(0))?;
        let mut bytes = vec![];
        out.take(2 * 1024 * 1024).read_to_end(&mut bytes)?;
        Ok(bytes)
    }
    pub fn probe(&self, path: &Path, cancelled: &dyn Fn() -> bool) -> io::Result<Info> {
        let bytes = self.run(
            "ffprobe",
            &strings(&[
                "-v",
                "error",
                "-show_streams",
                "-show_format",
                "-of",
                "json",
                &path.to_string_lossy(),
            ]),
            cancelled,
            Some(Duration::from_secs(20)),
        )?;
        let data: Value = serde_json::from_slice(&bytes)?;
        let streams = data["streams"]
            .as_array()
            .ok_or_else(|| io::Error::other("No readable media streams"))?;
        let video = streams.iter().find(|s| s["codec_type"] == "video");
        let audio = streams.iter().find(|s| s["codec_type"] == "audio");
        if video.is_none() && audio.is_none() {
            return Err(io::Error::other("No supported media streams"));
        }
        let mut info = Info::default();
        if let Some(v) = video {
            info.width = v["width"].as_u64().unwrap_or(0) as u32;
            info.height = v["height"].as_u64().unwrap_or(0) as u32;
            info.codec = v["codec_name"].as_str().unwrap_or("").into();
            info.frames = v["nb_frames"]
                .as_str()
                .and_then(|s| s.parse().ok())
                .unwrap_or(1);
            info.colour = v["color_transfer"].as_str().unwrap_or("").into();
            if v["side_data_list"].as_array().is_some_and(|a| {
                a.iter()
                    .any(|x| x["rotation"].as_i64().unwrap_or(0).abs() % 180 == 90)
            }) {
                std::mem::swap(&mut info.width, &mut info.height);
            }
        }
        if let Some(a) = audio {
            info.audio = true;
            info.sample_rate = a["sample_rate"]
                .as_str()
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            info.channels = a["channels"].as_u64().unwrap_or(0) as u32;
            if video.is_none() {
                info.codec = a["codec_name"].as_str().unwrap_or("").into();
            }
        }
        info.duration = data["format"]["duration"]
            .as_str()
            .and_then(|s| s.parse::<f64>().ok())
            .filter(|v| v.is_finite())
            .unwrap_or(0.0);
        info.title = data["format"]["tags"]["title"]
            .as_str()
            .unwrap_or("")
            .into();
        info.artist = data["format"]["tags"]["artist"]
            .as_str()
            .unwrap_or("")
            .into();
        Ok(info)
    }
    pub fn native_image(
        &self,
        source: &Path,
        destination: &Path,
        size: u32,
        options: &Value,
    ) -> io::Result<Info> {
        let callback = IMAGE
            .get()
            .ok_or_else(|| io::Error::other("Native image service unavailable"))?;
        let src = CString::new(source.to_string_lossy().as_bytes())?;
        let dst = CString::new(destination.to_string_lossy().as_bytes())?;
        let opts = CString::new(options.to_string())?;
        let mut info = NativeInfo::default();
        // SAFETY: all pointers remain alive for the synchronous callback; it writes only NativeInfo.
        let status =
            unsafe { callback(src.as_ptr(), dst.as_ptr(), size, opts.as_ptr(), &mut info) };
        if status != 0 {
            return Err(io::Error::other(
                "ImageIO could not decode this image. It may be corrupt or unsupported.",
            ));
        }
        Ok(Info {
            width: info.width,
            height: info.height,
            frames: info.frames,
            ..Info::default()
        })
    }
    pub fn thumbnail(
        &self,
        m: &Media,
        size: u32,
        cancelled: &dyn Fn() -> bool,
    ) -> io::Result<(Option<PathBuf>, Cached)> {
        let key = self.key(m, size);
        let dest = self.cache.join(format!("{key}.png"));
        let meta = self.cache.join(format!("{key}.json"));
        if let Ok(bytes) = fs::read(&meta)
            && let Ok(cached) = serde_json::from_slice(&bytes)
            && (dest.exists() || m.kind == Kind::Audio)
        {
            return Ok((dest.exists().then_some(dest), cached));
        }
        if m.kind == Kind::Other {
            return Err(io::Error::other(
                "Unsupported format · originals can still be copied",
            ));
        }
        let mut waveform = vec![];
        let info = if m.kind == Kind::Image {
            match self.native_image(
                &m.path,
                &dest,
                size,
                &json!({"format":"png","thumbnail":true}),
            ) {
                Ok(info) => info,
                Err(_) => {
                    let info = self.probe(&m.path, cancelled)?;
                    self.poster(&m.path, &dest, size, cancelled)?;
                    info
                }
            }
        } else {
            let info = if m.info.duration > 0.0 {
                m.info.clone()
            } else {
                self.probe(&m.path, cancelled)?
            };
            if m.kind == Kind::Video {
                self.poster(&m.path, &dest, size, cancelled)?;
            } else {
                waveform = self.waveform(&m.path, cancelled)?;
            }
            info
        };
        if cancelled() {
            let _ = fs::remove_file(&dest);
            return Err(io::Error::new(io::ErrorKind::Interrupted, "Cancelled"));
        }
        let cached = Cached { info, waveform };
        let _ = fs::write(meta, serde_json::to_vec(&cached)?);
        Ok((dest.exists().then_some(dest), cached))
    }
    fn poster(
        &self,
        path: &Path,
        dest: &Path,
        size: u32,
        cancelled: &dyn Fn() -> bool,
    ) -> io::Result<()> {
        self.run(
            "ffmpeg",
            &strings(&[
                "-nostdin",
                "-v",
                "error",
                "-y",
                "-threads",
                "1",
                "-i",
                &path.to_string_lossy(),
                "-frames:v",
                "1",
                "-vf",
                &format!("scale={size}:{size}:force_original_aspect_ratio=decrease"),
                "-threads",
                "1",
                "-update",
                "1",
                &dest.to_string_lossy(),
            ]),
            cancelled,
            Some(Duration::from_secs(30)),
        )?;
        Ok(())
    }
    fn waveform(&self, path: &Path, cancelled: &dyn Fn() -> bool) -> io::Result<Vec<f32>> {
        let raw = tempfile::NamedTempFile::new_in(&self.cache)?;
        self.run(
            "ffmpeg",
            &strings(&[
                "-nostdin",
                "-v",
                "error",
                "-y",
                "-threads",
                "1",
                "-i",
                &path.to_string_lossy(),
                "-vn",
                "-ac",
                "1",
                "-ar",
                "8000",
                "-f",
                "f32le",
                &raw.path().to_string_lossy(),
            ]),
            cancelled,
            Some(Duration::from_secs(90)),
        )?;
        let mut peaks = vec![0.0_f32; 128];
        let mut input = fs::File::open(raw.path())?;
        let samples = (input.metadata()?.len() / 4).max(128) as f64;
        let mut bytes = [0u8; 4096];
        let mut index = 0;
        loop {
            if cancelled() {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "Cancelled"));
            }
            let n = input.read(&mut bytes)?;
            if n == 0 {
                break;
            }
            for chunk in bytes[..n].as_chunks::<4>().0 {
                let sample = f32::from_le_bytes(*chunk).abs();
                let bin = ((index as f64 / samples) * 128.0) as usize;
                if bin < 128 && sample.is_finite() {
                    peaks[bin] = peaks[bin].max(sample);
                }
                index += 1;
            }
        }
        let max = peaks.iter().copied().fold(0.01_f32, f32::max);
        for p in &mut peaks {
            *p = (*p / max).sqrt();
        }
        Ok(peaks)
    }
    pub fn preview(&self, m: &Media, cancelled: &dyn Fn() -> bool) -> io::Result<PathBuf> {
        if !m.path.exists() {
            return Err(io::Error::other(
                "This file is missing. Reconnect its drive or refresh the collection.",
            ));
        }
        match m.kind {
            Kind::Image => {
                let dest = self
                    .cache
                    .join(format!("{}-preview.png", self.key(m, 4096)));
                if !dest.exists()
                    && self
                        .native_image(
                            &m.path,
                            &dest,
                            4096,
                            &json!({"format":"png","thumbnail":true}),
                        )
                        .is_err()
                {
                    self.poster(&m.path, &dest, 4096, cancelled)?;
                }
                Ok(dest)
            }
            Kind::Video | Kind::Audio => {
                let ext = m
                    .path
                    .extension()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_lowercase();
                if matches!(
                    ext.as_str(),
                    "mp4"
                        | "mov"
                        | "m4v"
                        | "mp3"
                        | "m4a"
                        | "wav"
                        | "aif"
                        | "aiff"
                        | "flac"
                        | "aac"
                        | "caf"
                ) {
                    return Ok(m.path.clone());
                }
                let dest = self.cache.join(format!(
                    "{}-playback.{}",
                    self.key(m, 0),
                    if m.kind == Kind::Video { "mp4" } else { "m4a" }
                ));
                if !dest.exists() {
                    let tmp = tempfile::Builder::new()
                        .prefix(".liltfold-")
                        .suffix(if m.kind == Kind::Video {
                            ".mp4"
                        } else {
                            ".m4a"
                        })
                        .tempfile_in(&self.cache)?;
                    let mut args = strings(&[
                        "-nostdin",
                        "-v",
                        "error",
                        "-y",
                        "-threads",
                        "2",
                        "-i",
                        &m.path.to_string_lossy(),
                    ]);
                    if m.kind == Kind::Video {
                        args.extend(strings(&[
                            "-vf",
                            "scale='min(1920,iw)':-2",
                            "-c:v",
                            "h264_videotoolbox",
                            "-b:v",
                            "6000k",
                            "-pix_fmt",
                            "yuv420p",
                        ]));
                    } else {
                        args.push("-vn".into());
                    }
                    args.extend(strings(&[
                        "-c:a",
                        "aac",
                        "-b:a",
                        "192k",
                        "-movflags",
                        "+faststart",
                        &tmp.path().to_string_lossy(),
                    ]));
                    self.run("ffmpeg", &args, cancelled, None)?;
                    tmp.persist(&dest).map_err(|e| e.error)?;
                }
                Ok(dest)
            }
            Kind::Other => Err(io::Error::other(
                "No preview is available for this format. You can copy the original.",
            )),
        }
    }
    pub fn prune_cache(&self) {
        // ponytail: a 768 MiB disk budget, approximate age eviction; use indexed LRU if cache contention appears.
        if let Ok(dir) = fs::read_dir(&self.cache) {
            let mut files: Vec<_> = dir
                .flatten()
                .filter_map(|e| {
                    let m = e.metadata().ok()?;
                    (m.is_file() && e.file_name() != "preferences.json")
                        .then(|| (m.modified().ok(), m.len(), e.path()))
                })
                .collect();
            let mut size: u64 = files.iter().map(|x| x.1).sum();
            files.sort_by_key(|x| x.0);
            for (_, len, path) in files {
                if size <= 768 * 1024 * 1024 {
                    break;
                }
                if fs::remove_file(path).is_ok() {
                    size = size.saturating_sub(len);
                }
            }
        }
    }
}
pub fn strings(s: &[&str]) -> Vec<String> {
    s.iter().map(|s| (*s).to_owned()).collect()
}
