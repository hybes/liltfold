# Third-party notices

## Project source and artwork

Liltfold's original source and `assets/Liltfold.png` are offered under the
[MIT licence](LICENSE). The logo is AI-generated raster artwork; its generation
prompt and provenance are recorded in [assets/LOGO.md](assets/LOGO.md).

## Rust and system frameworks

Rust dependency versions are pinned in `Cargo.lock`. Their licences remain in
force; use `cargo metadata --locked --format-version 1` to inspect them.
Apple's AppKit, SwiftUI, ImageIO, AVKit and AVFoundation are system frameworks
and are not copied into this repository.

## Codec bundles

No FFmpeg, WebP or other codec binary is committed or released by this repository.
The local build script copies the builder's installed tools and their dynamic
libraries into `dist/Liltfold.app`, adjusts their load paths and ad-hoc signs them.
Liltfold invokes these tools as child processes.

The first local build used FFmpeg 9.0.2 with GPL components (including x264/x265),
under GPL v3 or later, and libwebp under its BSD-style licence. Other build
environments can use different versions/configurations and therefore different
applicable notices:

- [FFmpeg source](https://ffmpeg.org/download.html) and [licensing guidance](https://ffmpeg.org/legal.html).
- [libwebp source and licence](https://chromium.googlesource.com/webm/libwebp/).

The build collects a component manifest, Homebrew recipes/receipts and available
licence files in `Contents/Resources/Licenses`. These records identify what was
bundled; **they are not a substitute for corresponding source**. Before publishing
a compiled bundle, provide the exact corresponding source, patches, build
instructions and notices required by the licences of its codec components and
dependencies. The MIT licence for Liltfold does not relicense those components.

## Documentation photographs

The checked-in browsing screenshots contain sample photographs downloaded from
Unsplash. Those photographs retain their authors' rights and are used under the
[Unsplash licence](https://unsplash.com/license), not the project's MIT licence.
The [source URL list](docs/screenshots/photo-sources.json) records each photograph
used in the original local test collection. Only the application screenshots are
included; the original photographs and local exports are excluded from Git.

`tools/make_fixtures.py` generates original synthetic test patterns and tones
locally. It does not download or require the documentation photographs.
