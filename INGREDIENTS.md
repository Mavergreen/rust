# Build ingredients

Everything baked into the shipped `rust` and `rust-cross` `.pkg`s, where it is pinned, and how a
change reaches a release. The *own upstream* is Rust; an ingredient is anything else the artifacts are
built with.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| Rust source (own upstream) | `UPSTREAM_VERSION` | ✅ `github-releases` on `rust-lang/rust` | cuts `<ver>-mavericks.1` |
| clang-22 (cross pkg for modern hosts, native pkg on 10.9) | `components/clang/version` | ✅ `github-releases` on `Mavergreen/clang-22`, `-mavericks.N` versioning | repackage → `-mavericks.(N+1)` |
| Recaulk (prebuilt `librecaulk.a`, the 10.9 back-fills) | `components/recaulk/version` | ✅ shipyard preset manager → `github-releases` on `Mavergreen/recaulk` | repackage |
| GNU make (builds cargo's vendored OpenSSL) | `components/make/version` | ✅ `github-releases` on `Mavergreen/make`, `-mavericks.N` versioning | repackage |
| MacOSX10.9 SDK (x86_64) | shipyard `fetch_sdk.sh` (pinned by hash) | ✅ moves with shipyard `@v1` | moving tag |
| MacOSX11.3 SDK (the cross pkg's arm64 half) | shipyard `fetch_sdk.sh --arch arm64` (pinned by hash) | ✅ moves with shipyard `@v1` | moving tag |

## Check-only pins

Pinned so the release check is reproducible, but nothing shipped is built with them, so a bump
neither repackages nor appears in the declared state.

| Tool | Pinned in | Renovate | Used by |
|---|---|---|---|
| Longboat (installs the 10.9 SDK that clang22 needs) | `components/longboat/version` | ✅ `github-releases` on `Mavergreen/longboat` | `build/check-release-on-10.9.sh`, on a box without clang22 |

## How the back-fill reaches a 10.9 binary

rustc links Recaulk's `librecaulk.a` into every x86_64 binary it links, one of two ways:

- **A linker that already links it**: Mavergreen clang22's `clang++`, `22.1.1-mavericks.7` or
  later. The rustc wrapper asks the linker what it links (`-###`), sees `librecaulk.a`, and adds only
  `-mmacosx-version-min=10.9`. The linker's own configuration supplies the archive, the frameworks
  and the 10.9 SDK, which the wrapper also hands rustc as `SDKROOT` unless one is set.
- **Any other linker** (`cc`, named explicitly): the wrapper force-loads the `librecaulk.a` that
  ships in `lib/rustlib/x86_64-apple-darwin/lib/`, with the frameworks it needs.

## The default linker: clang22, a runtime dependency of the native pkg

On 10.9 the native pkg's `rustc` and `clippy-driver` link with clang22's `clang++` unless a linker is
named (`-C linker=…`, however it arrives: `CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER`, cargo config,
`RUSTFLAGS`, an `@argfile`) or a linker flavour is (`-C linker-flavor=…`, which lets rustc pick the
linker). Without the Command Line Tools, 10.9's `cc` is the `xcode-select` stub,
and no family toolchain may need them (shipyard vision area 18 B). Naming `cc` still works where they
are installed (area 18 D).

- The wrapper finds clang22 next to rust, never on `PATH`: rust's own `deps/clang22/` first, then the
  shared `clang22/` beside rust's prefix, then the installed `/usr/local/mavergreen/clang22`. The
  last is for a rust that was unpacked rather than installed, as fd's and rg's builds unpack their
  pinned toolchain on a developer's 10.9 machine: nothing is beside it, and installing the pin would
  replace the developer's own rust.
- With no clang22 there, or one older than `22.1.1-mavericks.7` (it links the retired
  macports-legacy-support archive and would fail with duplicate symbols), rustc stops and names both
  remedies: install or update clang22, or name a linker. A call that links nothing (`rustc -vV`,
  `--version`, cargo's `--print` probes) needs no clang22 and passes through untouched, so cargo
  itself keeps working and a named linker reaches every compile.
- So clang22 is a **tool** dependency of the native pkg: its preinstall refuses a box without clang22
  installed (`stage_product.sh --requires clang22`). It isn't pinned: any clang22 at or after that
  floor works, and the Recaulk check catches an older one. rust-cross has no such dependency.

rustc and cargo themselves are linked through clang-22 with this repo's pinned Recaulk, which the
build copies over clang-22's own, so `recaulk=` in `build-info-*.txt` is true of every binary.

## Build-time tools (not ingredients)

- **python3** runs `x.py`, Rust's own build driver. On 10.9 it comes from pkgsrc (`/opt/pkg`); see the
  deviation below.
- **ninja** comes from pkgsrc on both build hosts. **Exit:** switch to the family's own when
  `mavergreen-ninja` ships.
- **CMake** is `shipyard-cmake`. Bootstrap 1.95 has no `[build] cmake` key, so `cmake_shim_dir` puts a
  `cmake -> shipyard-cmake` link first on `PATH` for `x.py`.
- A pkgsrc toolchain on the build host must never leak into the product. The guards are
  `CMAKE_IGNORE_PREFIX_PATH` plus optional LLVM deps off, and `PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig`
  for cargo's `*-sys` crates. `build/verify-relocatable.sh` fails the build if anything leaks anyway.

## Build equivalence (native, cross-hosted vs on 10.9)

The two ways of building the native toolchain ship the same files (same `build-info-native.txt`, same
payload list once crate-hash suffixes are normalized), but not the same bytes. Crate hashes differ with
the stage0 and build triple, and the cross-hosted build's LLVM also has the AArch64 backend, because its
build triple is aarch64 and bootstrap's `[llvm] targets` covers every LLVM it builds. The on-box
build's LLVM is X86 only.

## Single upstream — why no `lines/`

Rust is one fast-moving upstream whose users always want latest; there are no concurrently-supported
lines users pin independently (unlike LLVM majors or Go minors). So a single bare `UPSTREAM_VERSION`.

## Rust source verification

Verified against `static.rust-lang.org`'s published `.sha256` for the pinned version (upstream
publishes checksums → no hand-maintained hash; a Renovate bump only moves the ref). Fail closed if the
`.sha256` is absent. The on-10.9 stage0 (the official x86_64 prebuilt of the same version) is verified
the same way.

## Declared state

- upstream: UPSTREAM_VERSION
- clang: components/clang/version
- recaulk: components/recaulk/version
- make: components/make/version

## Conformance deviations

- python3: x.py, Rust's own build driver, is Python; a native 10.9 build takes python3 from pkgsrc. No alternative exists upstream.
- sdk-pin:usr/local/mavergreen/*/lib/rustlib/*/lib/*.rlib: rustc-emitted objects record no SDK, and rustc clamps every x86_64-apple-darwin object to minos 10.12 (os_minimum_deployment_target). These rlibs are link inputs, not installed executables: every x86_64 link goes through bin/rustc, which passes -mmacosx-version-min=10.9, and the compat guard plus the real-10.9 runs check the linked output. Only patching rustc's target spec would change them.
- floor:rust-cross-*.pkg: the cross toolchain runs on macOS 11 and later and only targets 10.9, so its archive's install floor is 11.0, not 10.9.5.
- bare-curl:build/check-release-on-10.9.sh: it runs from a bare checkout on a 10.9 box, the family VM included, where shipyard isn't installed, so it downloads the pkg, SHA256SUMS and Longboat with 10.9's own curl rather than shipyard_curl. Exit: the VM job puts shipyard's scripts into the guest.
