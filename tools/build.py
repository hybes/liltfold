#!/usr/bin/env python3
"""Build a self-contained Apple Silicon app using the installed native toolchain."""
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "dist/Liltfold.app"
CONTENTS = APP / "Contents"

def run(*args, **kwargs):
    subprocess.run(args, check=True, cwd=ROOT, **kwargs)

def dependencies(binary):
    lines = subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]
    return [line.strip().split(" (", 1)[0] for line in lines]

def minimum_macos(binaries):
    """A bundle must require the newest deployment target of all its executables/libraries."""
    versions = [(14, 0, 0)]
    for binary in binaries:
        commands = subprocess.check_output(["otool", "-l", str(binary)], text=True)
        for command in commands.split("Load command "):
            if "cmd LC_BUILD_VERSION\n" in command:
                version = re.search(r"\bminos (\d+(?:\.\d+)+)", command)
            elif "cmd LC_VERSION_MIN_MACOSX\n" in command:
                version = re.search(r"\bversion (\d+(?:\.\d+)+)", command)
            else:
                continue
            if version:
                parts = tuple(map(int, version[1].split(".")))
                versions.append((parts + (0, 0))[:3])
    return ".".join(map(str, max(versions)))

def bundle_tools():
    binaries = CONTENTS / "Resources/bin"
    libraries = CONTENTS / "Frameworks"
    notices = CONTENTS / "Resources/Licenses"
    for folder in (binaries, libraries, notices):
        folder.mkdir(parents=True, exist_ok=True)
    pending = []
    for tool in ("ffmpeg", "ffprobe", "cwebp"):
        source = shutil.which(tool)
        if not source:
            sys.exit(f"Build prerequisite missing: {tool}. Install ffmpeg and webp on the build Mac.")
        pending.append((Path(source).resolve(), binaries / tool))
    seen, packages, manifest = set(), set(), []
    while pending:
        source, target = pending.pop(0)
        if target in seen:
            continue
        seen.add(target)
        shutil.copy2(source, target)
        target.chmod(0o755)
        subprocess.run(["codesign", "--remove-signature", str(target)], capture_output=True)
        changes = []
        for dep in dependencies(source):
            if dep.startswith(("/System/", "/usr/lib/")):
                continue
            if dep.startswith("@"):
                candidates = [source.parent / Path(dep).name, Path("/opt/homebrew/lib") / Path(dep).name]
                resolved = next((p.resolve() for p in candidates if p.exists()), None)
                if resolved is None:
                    sys.exit(f"Cannot resolve {dep} for {source}")
            else:
                resolved = Path(dep).resolve()
            if resolved == source:
                continue
            destination = libraries / resolved.name
            pending.append((resolved, destination))
            relative = "@loader_path/" + ("../../Frameworks/" if target.parent == binaries else "") + resolved.name
            changes.extend(["-change", dep, relative])
        if target.suffix == ".dylib":
            changes.extend(["-id", "@rpath/" + target.name])
        if changes:
            run("install_name_tool", *changes, str(target), stderr=subprocess.DEVNULL)
        manifest.append(f"{target.relative_to(CONTENTS)} ← {source}")
        # Keep the exact package version, build recipe/receipt and licences with the local bundle.
        parts = source.parts
        if "Cellar" in parts:
            index = parts.index("Cellar")
            package = Path(*parts[:index + 3])
            if package not in packages:
                packages.add(package)
                dest = notices / (parts[index + 1] + "-" + parts[index + 2])
                dest.mkdir(exist_ok=True)
                for pattern in ("LICENSE*", "COPYING*", "AUTHORS*", "PATENTS*", "INSTALL_RECEIPT.json", ".brew/*.rb"):
                    for file in package.glob(pattern):
                        if file.is_file():
                            shutil.copy2(file, dest / file.name)
        run("codesign", "--force", "--sign", "-", str(target), stderr=subprocess.DEVNULL)
    (notices / "BUNDLED-COMPONENTS.txt").write_text("\n".join(manifest) + "\n")
    shutil.copy2(ROOT / "THIRD_PARTY.md", notices / "README.md")
    for target in seen:
        external = [dep for dep in dependencies(target) if dep.startswith(("/opt/", "/usr/local/", "/Users/"))]
        if external:
            sys.exit(f"Non-portable runtime dependencies in {target}: {external}")

def main():
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        sys.exit("Build Liltfold on an Apple Silicon Mac.")
    run("cargo", "build", "--release", "--locked")
    for folder in (CONTENTS / "MacOS", CONTENTS / "Resources"):
        folder.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "assets/Liltfold.png", CONTENTS / "Resources/LiltfoldLogo.png")
    test_flags = ["-D", "UI_TESTING", "tests/UITests.swift"] if "--ui-test" in sys.argv else []
    native_minimum = minimum_macos([ROOT / "target/release/libliltfold.a"])
    run("xcrun", "swiftc", "-O", "-swift-version", "5", "-target", f"arm64-apple-macos{native_minimum}", "-parse-as-library", "-import-objc-header", "native/Liltfold.h", *map(str, sorted((ROOT / "native").glob("*.swift"))), *test_flags, "target/release/libliltfold.a", "-framework", "AppKit", "-framework", "SwiftUI", "-framework", "AVKit", "-framework", "AVFoundation", "-framework", "ImageIO", "-framework", "UniformTypeIdentifiers", "-o", str(CONTENTS / "MacOS/Liltfold"))
    if "--ui-only" not in sys.argv or not (CONTENTS / "Resources/bin/ffmpeg").exists():
        bundle_tools()
        iconset = ROOT / ".build/Liltfold.iconset"
        iconset.mkdir(parents=True, exist_ok=True)
        run("xcrun", "swift", "tools/Icon.swift", str(iconset))
        run("iconutil", "-c", "icns", str(iconset), "-o", str(CONTENTS / "Resources/Liltfold.icns"))
    binaries = [CONTENTS / "MacOS/Liltfold", *sorted((CONTENTS / "Resources/bin").iterdir()), *sorted((CONTENTS / "Frameworks").glob("*.dylib"))]
    minimum_os = minimum_macos(binaries)
    info = {"CFBundleName": "Liltfold", "CFBundleDisplayName": "Liltfold", "CFBundleIdentifier": "com.hybes.liltfold", "CFBundleExecutable": "Liltfold", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "LSMinimumSystemVersion": minimum_os, "LSArchitecturePriority": ["arm64"], "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication", "CFBundleIconFile": "Liltfold", "NSHumanReadableCopyright": "Liltfold · local by design", "CFBundleDocumentTypes": [{"CFBundleTypeName": "Folder", "CFBundleTypeRole": "Viewer", "LSItemContentTypes": ["public.folder"]}]}
    with (CONTENTS / "Info.plist").open("wb") as file:
        plistlib.dump(info, file)
    run("codesign", "--force", "--deep", "--sign", "-", str(APP), stderr=subprocess.DEVNULL)
    run("codesign", "--verify", "--deep", "--strict", str(APP))
    print(f"{APP} (Apple Silicon, macOS {minimum_os}+)")

if __name__ == "__main__":
    main()
