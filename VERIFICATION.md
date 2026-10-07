# Local verification — 7 October 2026

Initial local build: `dist/Liltfold.app`, Apple Silicon, locally ad-hoc signed.
This is a historical verification record, not a public binary release.
The release contains the new raster artwork in the header, empty state, export
sheets and Dock icon. No procedural logo remains.

## Actual application checks

The real AppKit/SwiftUI window was exercised with an in-process native test
runner, using the same Rust commands and native views as the production app.
The external desktop-control connector could not start, so this did not use
automated physical mouse gestures. The runner is compiled out of the delivered
production app.

Passed:

- Recursive discovery of 26 mixed files, overlapping-root normalisation, filename
  search, all four media filters, retained hidden selections and duplicate views.
- Opening a native accessible image tile, magnification and exact scroll-position
  restoration after closing its preview.
- AVKit video playback, seeking and volume; audio playback, seeking, duration,
  metadata and a progressively generated waveform.
- Mixed export: image → WebP, video → MP4, audio → unchanged original. The actual
  export sheet and completed report were captured.
- Command-A selecting all 5,000 matches; scrolling to item 4,200 while keeping
  fewer than 60 native collection items instantiated.
- Light/dark appearances at 1220 × 820 logical pixels and compact dark appearance
  at 920 × 660. The `ui-taste` review identified and corrected resize spacing,
  secondary-text contrast, export-summary detail and placeholder icon orientation.
- Original raster artwork inspected in the running header and at 16/32/64-pixel
  icon sizes. Alpha is preserved in the source and generated `.icns` assets.

The native folder picker and Command/Shift-click use standard AppKit controls;
physical drag-and-drop, modifier-click gestures and VoiceOver were not automated
because the desktop-control connector was unavailable.

Evidence: [native UI results](verification/ui-results.json).

## Performance

Hardware: **MacBook Pro, M1 Max, 10 CPU cores, 32 GB RAM**, internal APFS SSD.
macOS **27.0.1**, Rust **1.98.0**, Xcode **27.0** / Swift **6.4**.
Build: Rust `--release` with thin LTO; Swift `-O`; arm64 throughout.

| Dataset and cache state | First rendered preview | App RSS at checkpoint |
| --- | ---: | ---: |
| 26 mixed files, cold thumbnail cache | 352 ms | 151 MB |
| Same mixed collection, cached thumbnails | 218 ms | 220 MB |
| 5,000 JPEGs, cold thumbnail cache | 461 ms | 314 MB |
| Same 5,000 files, cached thumbnails | 282 ms | 336 MB |

These are measured observations, not promises or statistically controlled
benchmarks. Timing starts when the folder scan is requested and ends when the
first decoded thumbnail reaches the native cell's draw method. RSS comes from
`ps` at the checkpoint; it excludes child encoder processes and is not a peak
working-set figure. The cached runs follow playback, exports and other checks in
the same process, which explains their larger resident memory.

The mixed dataset occupies **17,874,549 bytes**: JPEG, PNG, HEIC, WebP, TIFF, GIF,
MP4, MOV, WebM, MP3, M4A, WAV, FLAC, known exact copies, one deliberately corrupt
JPEG and one unsupported text file, across nested folders. The large dataset
contains **5,000 files / 2,144,831,500 bytes**, made from ten photographic JPEGs
copied into 25 folders. It stresses large-catalogue browsing and exact duplicate
work; it is not 5,000 distinct photographs. Filesystem caches were not flushed.
“Cold” means a new empty Liltfold thumbnail cache. Sample photograph source URLs
are retained locally in `docs/screenshots/photo-sources.json`.

Discovery publishes batches while walking the tree; the viewport can request
thumbnails before scanning finishes. Hashing yields to pending visible-preview
work. The local SSD collections finish discovery quickly, so these timings alone
do not establish throughput for disconnected, remote or very slow drives.

## Format and integrity checks

The native integration runner passed **40 real conversions**:

| Input files tested | Outputs verified |
| --- | --- |
| JPEG, PNG, HEIC, WebP, TIFF, GIF | WebP, JPEG, PNG |
| MP4, MOV, WebM | MP4/H.264/AAC, WebM/VP9/Opus |
| MP3, M4A, WAV, FLAC | MP3, M4A/AAC, WAV/PCM, FLAC |

Every output was probed and decoded in full with the bundled tools. Image
dimensions were checked against a 600-pixel maximum. Video resolution, duration
and retained audio were checked; audio outputs were checked for duration,
44.1 kHz sample rate and mono channels. SHA-256 hashes of all input fixtures
remained unchanged. A deliberately corrupt image failed conversion with no
completed-looking output left behind.

Evidence: [conversion results](verification/conversions.json).

Nine Rust tests pass for recursive discovery (including 140 nested directories),
overlapping roots, symlink loops, missing entries, cancellation, content-based
duplicate grouping, representative choice, 5,000-item selection/export scope,
unique/skip/replace conflicts, hard-link/source protection, temporary-file
cleanup, path naming, settings validation and cache invalidation keys.

`cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`, the
Swift formatter/linter, native codec runner and native UI runner completed successfully. Bundle
signatures and Apple Silicon architecture were checked. Bundled FFmpeg also ran
with PATH restricted to `/usr/bin:/bin`; no bundled Mach-O dependency points at
Homebrew or the workspace.

## Screenshots

- [Browsing, dark with the production raster logo](docs/screenshots/browsing-dark.png)
- [Browsing, light](docs/screenshots/browsing-light.png)

The original local preview/export captures included machine-specific source and
output paths. They remain local; the public repository includes the two browsing
captures above and the structured test results.

## Remaining limits

- The original bundled codec build requires **macOS 27+**. New source builds
  derive their minimum macOS version from the native executable and bundled codecs. The app is locally signed,
  not notarised for public distribution.
- Image previews and conversions use the first frame of GIF/multipage images.
  Large image previews are capped at 4096 pixels; full-size exports remain
  available. Conversion uses 8-bit sRGB; animation, HDR and some metadata are
  intentionally not preserved, as the export sheet explains.
- WebM and other non-native playback containers prepare a local compatibility
  preview before AVKit playback. Large files can take time and consume temporary
  cache space. Original-file copying never performs this transformation.
- RAW support depends on the camera formats understood by this Mac's ImageIO
  decoders/embedded previews. No camera RAW fixture was available to verify.
  HDR, unusual multichannel media, disconnected physical drives and remote
  volumes were not comprehensively tested.
- Refresh discovers added/removed files. Visible source changes invalidate
  previews automatically. Destinations inside a source tree are excluded from
  subsequent scans in that collection; exporting directly into a source root or
  its ancestor is refused. Clearing the collection clears those exclusions.
- Duplicate checks are exact-content checks only. No perceptual similarity,
  source-file deletion, library import or cloud processing is included.
