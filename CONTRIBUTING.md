# Contributing

Small, focused fixes are welcome. For a substantial feature or a change to export
behaviour, open an issue describing the user problem before building it.

## Development

Follow the [build instructions](README.md#build-and-run). The application is for
Apple Silicon macOS; Rust core tests can also run on Linux. Use Rust stable for
formatting and Clippy. The minimum supported Rust version is 1.88.

```sh
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
python3 -m unittest discover -s tests -p 'test_*.py'
```

For Swift changes, run the formatter/linter supplied with Xcode:

```sh
xcrun swift-format lint --strict --recursive native tests/NativeSmoke.swift tests/UITests.swift tools/Icon.swift
python3 tools/build.py --ui-only
```

Run a full build first so the codec bundle exists. If media processing changes,
run the [native conversion tests](README.md#tests). UI changes need inspection
in light/dark appearances and a compact window. Use synthetic or publishable
media in reports; avoid personal files and paths.

## Code layout

| Location | Responsibility |
| --- | --- |
| `src/lib.rs` | Rust application state, commands and worker queues |
| `src/discovery.rs`, `src/model.rs` | Folder traversal, metadata, filtering and scope |
| `src/duplicates.rs` | Exact-content duplicate verification |
| `src/media.rs`, `src/export.rs` | Preview backends and safe exports |
| `native/` | SwiftUI/AppKit presentation and the ImageIO C bridge |
| `tests/` | Core, packaging, codec and native UI checks |
| `tools/` | Local app packaging, icon sizes and synthetic test media |

Keep state and job orchestration in Rust. Reuse native controls and the existing
workers rather than adding a second processing path. Original-file copying must
remain separate from conversion. Preserve source files, cancellation cleanup,
exact duplicate verification and non-destructive conflict defaults.

Add a focused regression test where behaviour changes. In a pull request, explain
the problem, the resulting behaviour and the checks actually run. Include a
screenshot for visible changes. Generated media, build output, caches, signing
material and local screenshots must stay out of commits.

Be respectful and keep discussions about the work. By contributing, you agree
that your contribution can be distributed under this project's MIT licence.
Identify any third-party material and its separate licence explicitly.
