# mavericks-rust

An unofficial community build of **Rust for Mavericks** — a Rust toolchain that runs on
modern Apple-Silicon macOS and targets **Mac OS X 10.9 (Mavericks)**. Not affiliated with
the Rust project or the Rust Foundation.

`cargo build --target x86_64-apple-darwin` produces a working x86_64 10.9 binary with the
legacy-support polyfill linked — no extra flags.

## Layout
- `build/` — the CI cross-build (runs on a modern arm64 runner).
- `native-bootstrap/rust.sh` — Wowfunhappy's on-10.9 bootstrap, kept for the native build
  phase; not used by CI.
