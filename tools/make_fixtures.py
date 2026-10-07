#!/usr/bin/env python3
"""Generate original synthetic media for the existing native tests, without downloads."""
import argparse
from pathlib import Path
import shutil
import subprocess


def run(*args):
    subprocess.run(list(map(str, args)), check=True, stdout=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(".build/fixtures"))
    parser.add_argument("--large", action="store_true", help="Also create a 5,000-file collection")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error(f"{output} is not empty; choose a new output folder")
    for tool in ("ffmpeg", "cwebp", "sips"):
        if not shutil.which(tool):
            parser.error(f"Missing {tool}; run on macOS with ffmpeg and webp installed")

    root = output / "Field collection"
    still = root / "01 · Still"
    motion = root / "02 · Motion"
    sound = root / "03 · Sound"
    variations = root / "04 · Variations"
    for folder in (still / "Coast", still / "Highlands", motion, sound, variations):
        folder.mkdir(parents=True, exist_ok=True)

    images = []
    for i in range(10):
        image = still / ("Coast" if i % 2 == 0 else "Highlands") / f"{i + 1:02d} - Colour field {i + 1:02d}.jpg"
        run("ffmpeg", "-v", "error", "-nostdin", "-f", "lavfi", "-i",
            "testsrc2=size=960x640:rate=1", "-vf", f"hue=h={i * 31}",
            "-frames:v", "1", "-q:v", "2", "-threads", "1", image)
        images.append(image)
    for fmt in ("png", "tiff", "heic"):
        run("sips", "-s", "format", fmt, images[0], "--out", variations / f"Colour field.{fmt}")
    run("cwebp", "-quiet", images[0], "-o", variations / "Colour field.webp")
    run("ffmpeg", "-v", "error", "-nostdin", "-f", "lavfi", "-i",
        "testsrc2=size=480x320:rate=8", "-t", "1", "-threads", "1", variations / "Colour study.gif")
    shutil.copy2(images[0], variations / "Colour field - another copy.jpg")
    shutil.copy2(images[3], variations / images[3].name)

    video = motion / "Colour in motion.mp4"
    run("ffmpeg", "-v", "error", "-nostdin", "-f", "lavfi", "-i",
        "testsrc2=size=960x540:rate=24", "-f", "lavfi", "-i",
        "sine=frequency=220:sample_rate=48000", "-t", "4", "-c:v", "libx264",
        "-preset", "ultrafast", "-threads", "2", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", video)
    run("ffmpeg", "-v", "error", "-nostdin", "-i", video, "-c", "copy", motion / "Colour in motion.mov")
    run("ffmpeg", "-v", "error", "-nostdin", "-i", video, "-c:v", "libvpx-vp9",
        "-b:v", "0", "-crf", "35", "-cpu-used", "6", "-threads", "2",
        "-c:a", "libopus", motion / "Colour in motion.webm")

    wav = sound / "Room tone.wav"
    run("ffmpeg", "-v", "error", "-nostdin", "-f", "lavfi", "-i",
        "sine=frequency=330:sample_rate=48000", "-t", "8", "-af",
        "afade=t=in:d=1,afade=t=out:st=6:d=2,tremolo=f=0.7:d=0.8", "-ac", "2", wav)
    for ext, codec in (("mp3", "libmp3lame"), ("m4a", "aac"), ("flac", "flac")):
        run("ffmpeg", "-v", "error", "-nostdin", "-i", wav, "-c:a", codec,
            "-metadata", "title=Synthetic test tone", sound / f"Room tone.{ext}")
    (variations / "Unreadable photograph.jpg").write_bytes(b"Deliberately corrupt JPEG fixture.\n")
    (variations / "Field notes.txt").write_text("Unsupported-format fixture; original copying remains available.\n")
    if args.large:
        for i in range(5000):
            target = output / "Large collection" / f"Set {i // 200:02d}" / f"Field study {i:05d}.jpg"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(images[i % len(images)], target)
    print(f"Created 26 synthetic fixtures in {root}")


if __name__ == "__main__":
    main()
