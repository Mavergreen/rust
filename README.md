# Rust for Mavericks

**This README has not been read or edited by a human yet.** Until it has, this project cannot cut its first release.

A Rust toolchain for **Mac OS X 10.9 (Mavericks)**, as an unofficial community build, not affiliated
with the Rust project. It is a Mavergreen product: `rustc`, `cargo`, `rustdoc`, `cargo clippy` and
`cargo fmt`, with the 10.9 back-fills linked in, so a plain `cargo build` produces a binary that runs
on 10.9.

## Two packages, one per kind of Mac

| Package | Runs on | Installs to |
|---|---|---|
| `rust-<version>.pkg` | Mac OS X 10.9.5 and later on Intel (including modern macOS on Intel) | `/usr/local/mavergreen/rust` |
| `rust-cross-<version>.pkg` | macOS 11 and later on Apple Silicon | `/usr/local/mavergreen/rust-cross` |

Both produce x86_64 binaries for 10.9. The cross package is arm64-only, so Installer refuses it on an
Intel Mac; on Apple Silicon, use the cross package (the native one would ask for Rosetta).
With the cross package, set `SDKROOT` to a Mac OS X 10.9 SDK to link against it rather than the
running macOS's SDK; that is how this project's own builds and tests link.

After installing, open a new terminal: `/usr/local/mavergreen/bin` is on every login shell's `PATH`
through `/etc/paths.d/mavergreen`, and `rustc`, `cargo` and friends are linked there. Tools that
don't run a login shell (IDEs, launchd jobs) should use `/usr/local/mavergreen/bin/cargo` by path. A
Sparkle updater keeps the package current. `mavergreen uninstall rust` (or `rust-cross`) removes
everything the package installed.

## Building it

- `build/build-cross.sh`: the cross toolchain, on an Apple Silicon Mac.
- `build/build-native.sh`: the 10.9 toolchain. On an Apple Silicon Mac it cross-hosts the build (no
  Rosetta); on Mac OS X 10.9 itself it builds natively from the same recipe.
- `build/package-cross-pkg.sh`, `build/package-native-pkg.sh`: the packages, into `dist/`.
- `tests/`: run with shipyard's `run-repo-tests.sh`.

Builds need the shipyard package (for `shipyard-cmake` and its scripts), plus python3 and ninja on
`PATH`. Heavy build output goes to `~/.cache/mavergreen-rust`, never into the source tree.
`INGREDIENTS.md` lists everything that goes into the packages.

## After each release

CI can prove that nothing post-10.9 is linked, but no CI runner can run 10.9. So after each release,
on a Mac OS X 10.9 machine:

```sh
sh build/check-release-on-10.9.sh <version>     # e.g. 1.95.0-mavericks.1
```

It downloads and verifies that release's native pkg, installs it, builds and runs programs the way a
user would (including a crates.io dependency and `cargo clippy` on a crate with a proc-macro and a
build script), and uninstalls it. Anything it finds is fixed forward in the next `-mavericks.N`.
