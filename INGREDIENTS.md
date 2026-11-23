# Build ingredients

Everything baked into the shipped `rust` and `rust-cross` `.pkg`s and the Linux-hosted
`rust-<v>-linux-x86_64.tar.gz`, where it is pinned, and how a change reaches a release. The *own
upstream* is Rust; an ingredient is anything else the artifacts are built with.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| Rust source (own upstream) | `UPSTREAM_VERSION` | ✅ `github-releases` on `rust-lang/rust` | cuts `<ver>-mavericks.1` |
| clang-22 (shipyard's `fetch_clang22.sh`: the cross pkg on a modern Mac, the native pkg on 10.9, the Linux archive on Linux) | `components/clang22/version`, plus the Linux archive's digest in `components/clang22/linux-sha256` | ✅ `github-releases` on `Mavergreen/clang-22`, `-mavericks.N` versioning; the pins bot (`.github/workflows/pins-bot.yml`) verifies the new release's Linux archive against its `SHA256SUMS` and writes `linux-sha256` on Renovate's branch | repackage → `-mavericks.(N+1)` |
| Recaulk (prebuilt `librecaulk.a`, the 10.9 back-fills) | `components/recaulk/version` | ✅ shipyard preset manager → `github-releases` on `Mavergreen/recaulk` | repackage |
| GNU make (builds cargo's vendored OpenSSL on a Mac) | `components/make/version` | ✅ `github-releases` on `Mavergreen/make`, `-mavericks.N` versioning | repackage |
| Linux host CMake, Ninja and GNU make (configure and drive the Linux-hosted build of the native toolchain and its updater; make also builds cargo's vendored OpenSSL there) | runner-provided (`ubuntu-latest`, ninja from apt's `ninja-build`), unpinned; `build-info-*.txt` records each `--version` (`build-host-cmake`, `build-host-ninja`, `build-host-make`), with the host's libc (`build-host-libc`) and python (`build-host-python`) | ❌ **untrackable**: the runner image provides them, so no pin exists to track. Exit: when shipyard pins cmake, ninja and make for Linux hosts as it pins them for a Mac, take those | none; a runner image update can change them |
| Linux host libc++ and libc++abi (the C++ library of the Linux-hosted build's own compilers and LLVM: shipyard's `fetch_host_libcxx.sh`, static, built by clang22 from the llvm-project source its pin is built from) | `components/clang22/llvm-project` (`LLVM_VERSION SHA256` of `llvm-project-<v>.src.tar.xz`), which must agree with `components/clang22/version` | ❌ **untrackable** by a bot: it must name the LLVM release clang22 is built from, which `fetch_host_libcxx.sh` enforces, so it moves by hand with a clang22 LLVM bump | none: nothing it builds ships. Exit: when clang-22 ships a Linux-host libc++, take it from the pinned archive and drop `llvm-project` |
| clang-22's Linux base image (the build host of the Linux tarball, and its glibc floor: glibc, CMake, Ninja, GNU make and python3 at the versions its `packages.lock` names; the build adds cpio, file and ccache from the same apt snapshot, `build/linux/Dockerfile`) | `build/linux/base-image`, `apt-snapshot` and `packages.lock` in `Mavergreen/clang-22` at the tag `components/clang22/version` names | ✅ moves with the clang22 pin | repackage → `-mavericks.(N+1)` |
| MacOSX10.9 SDK (x86_64) | shipyard `fetch_sdk.sh` (pinned by hash) | ✅ moves with shipyard `@v1` | moving tag |
| MacOSX11.3 SDK (the cross pkg's arm64 half) | shipyard `fetch_sdk.sh --arch arm64` (pinned by hash) | ✅ moves with shipyard `@v1` | moving tag |

## Our patches

`build/fetch-rust-src.sh` applies `patches/*.patch` to the verified source with shipyard's
`apply_patches.sh`, so every host builds the same patched tree, and the stage stamp covers them.
A patch to a vendored crate also has its files' entries in that crate's `.cargo-checksum.json`
rewritten (`build/rehash-vendored.sh`), since cargo refuses a vendored file that does not match.

- `0001-std-macos-main-thread-stack-size-from-rlimit.patch`: on Mac OS X 10.9, libSystem's
  `pthread_get_stacksize_np` reports 512 KiB for the main thread, whose real stack is
  `RLIMIT_STACK` (8 MiB by default). std put its guard page at that 512 KiB mark, so every Rust
  program on 10.9 aborted with "has overflowed its stack" once `main` used more. The patch takes the
  larger of the two. Recaulk carries MacPorts' corrected `pthread_get_stacksize_np`, but rustc names
  `-lSystem` ahead of `librecaulk.a`, so a Rust program takes libSystem's. Exit: drop the patch when
  the Recaulk override reaches every Rust link and `build/check-release-on-10.9.sh`'s
  `main-thread-stack` step passes without it.
- `0002-libgit2-stransport-finish-handshake-after-server-auth.patch`: libgit2 (vendored by
  `libgit2-sys` 0.18.7, libgit2 1.9.6, which cargo links) breaks out of the SecureTransport handshake
  to check the server's certificate, then leaves `SSLWrite` to finish the handshake. Mac OS X 10.9's
  SecureTransport refuses that with `errSecBadReq`, so cargo fetched no HTTPS git dependency on 10.9
  ("SecureTransport error: Bad parameter or invalid state for operation"). The patch calls
  `SSLHandshake` until it completes, as Apple documents. libgit2's main branch has the same code.
  `build/check-release-on-10.9.sh`'s `git-https` step covers it. Exit: drop the patch when the
  libgit2 that cargo vendors finishes the handshake itself.
- `0003-rustc-target-macos-10.9-core2.patch`: rustc 1.99.1's `x86_64-apple-darwin` defaulted to
  deployment target 10.12 and CPU penryn, so std was compiled with SSE4.1 and every Rust program
  could die with SIGILL on a Core 2 (Merom) Mac, which runs 10.9. The patch makes
  `os_minimum_deployment_target` return 10.9 for macOS (arm64 keeps 11.0 through
  `minimum_deployment_target`) and the x86_64 CPU `core2`, so std, the shipped tools and every program
  built with no flags run on every Mac that runs 10.9, and `--print cfg` and `--print
  deployment-target` say so. A caller's own `-C target-cpu` still applies. `tests/target-core2-test.sh`
  and `build/check-release-on-10.9.sh`'s `target-defaults` step cover it. The core2 guarantee is
  checked statically, function by function, by `build/assert-core2.sh` in smoke-native (a function
  may hold SSE4.1 or later only behind its own `#[target_feature]`, or by name in
  `build/core2-allowlist.txt`), because under KVM the 10.9 VM runs newer instructions whatever CPU it
  reports. Exit: upstream rustc lowers
  the x86_64 macOS floor to 10.9 and the CPU to core2 (or the floor rises past the last
  Merom-capable macOS).

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

**`--no-default-config` on a link means the Mavergreen toolchain adds nothing of its own: no target,
SDK, minimum, Recaulk, frameworks or libc++. The caller supplies all of it.** clang22 already does
this, and the rustc and clippy-driver wrappers honour the same flag when it reaches them as a link
argument (`-C link-arg=--no-default-config`, or one word of `-C link-args=`, with `_` or `-` in the
option name as rustc allows, directly or from an `@argfile`) on an x86_64 Mac link. They then run
rustc with the arguments unchanged: no default linker, no clang22 or `librecaulk.a` required, no
`SDKROOT`, and the flag stays on the line for the caller's linker. A plain named linker (`-C linker=cc`) without the flag still gets Recaulk. Revisit
when the family retires `--no-default-config` as its opt-out.

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
- **ninja** comes from pkgsrc on a Mac and from the runner on Linux (see the table above). **Exit:**
  switch to the family's own when `mavergreen-ninja` ships.
- **CMake** is `shipyard-cmake` on a Mac and the runner's `cmake` on Linux. Bootstrap 1.95 has no
  `[build] cmake` key, so `cmake_shim_dir` puts a `cmake` link to it first on `PATH` for `x.py`, and
  `build-info-*.txt` records its `--version` as `build-host-cmake`.
- **The packager and the updater** run on either host: the pkg is written by shipyard's stevedore
  (`build_component_pkg.sh`, `set_install_floor.sh`), and the Sparkle updater is compiled by the pinned
  clang22 for its floor (x86_64 10.9, arm64 11.0), not by Apple's clang.
- A pkgsrc toolchain on the build host must never leak into the product. The guards are
  `CMAKE_IGNORE_PREFIX_PATH` plus optional LLVM deps off, and `PKG_CONFIG_LIBDIR=/usr/lib/pkgconfig`
  for cargo's `*-sys` crates. `build/verify-relocatable.sh` fails the build if anything leaks anyway.

## Build equivalence (native, cross-hosted vs on 10.9)

Measured with shipyard's `build-equivalence.sh` (v1.0.812, 2026-11-22) between CI's Linux-hosted
`build-native` at 54e9cf1 (run 45076950970) and `build-native.sh` run natively on 10.9.5 at the same
commit, built with the same shipyard. The two payloads hold the same paths, and no Mach-O differs in the
dylibs it links, its minos or its SDK. The differences that remain have two causes, both declared under
"Conformance deviations":

- std's crate ID. A Linux-built std's StableCrateId differs from a 10.9-built one, deterministically
  (`fda44cb9000b3d7` against `77dcaaddc7994ba9` in two pairs of builds). Target rustflags are not the
  cause (cargo hashes them only into file names, which the checker normalizes), and neither is
  `rustc -vV`'s `host:` line (cargo leaves it out for target crates). The ID reaches every rlib and
  rmeta, `libstd`, the binaries built against it, the order in which `librustc_driver` mangles
  `dyn … + DynSend + DynSync` and where generics such as `thin_vec::drop_non_singleton` are
  instantiated, so `rustdoc` and `clippy-driver` import different symbols from it (rustc orders both
  by DefPathHash, which derives from the StableCrateId). Once the IDs match, all thirteen of its entries
  are expected to go, the three interface entries included; the checker fails on any that no longer
  excuse anything.
- Function order in LLVM's tools. Same flags, same clang22 configuration, the same `libc++.a` and
  the same CMake check results, yet clang22 hosted on Linux and clang22 hosted on 10.9 emit a
  translation unit's inline functions in a different order, so `__text`, `__cstring` and
  `__unwind_info` are permuted at equal sizes and with identical symbol sets.

Measuring also found three things this repo set, now fixed: OpenSSL's "built on" date (the builds
export SOURCE_DATE_EPOCH), the SDK path in target rustflags (rustc hands the linker SDKROOT), and
manifests naming the staging root and pruned dylibs.

On 10.9, x.py's own `bootstrap` driver is compiled by stage0, whose std is upstream's and takes
libSystem's 512 KiB main-thread stack, so it overflows before the build starts. `build-native.sh`
sets `RUSTFLAGS_BOOTSTRAP` on that path to force-load Recaulk into the driver alone. It is a build
tool, never shipped. Revisit when clang22's `librecaulk-libsystem.a` (ahead of every input) has
shipped and an on-box `bootstrap` shows `pthread_get_stacksize_np` defined without the flag.

## Single upstream — why no `lines/`

Rust is one fast-moving upstream whose users always want latest; there are no concurrently-supported
lines users pin independently (unlike LLVM majors or Go minors). So a single bare `UPSTREAM_VERSION`.

## Rust source verification

Verified against `static.rust-lang.org`'s published `.sha256` for the pinned version (upstream
publishes checksums → no hand-maintained hash; a Renovate bump only moves the ref). Fail closed if the
`.sha256` is absent. The stage0 (the official prebuilt of the same version: x86_64-apple-darwin on
10.9, x86_64-unknown-linux-gnu on Linux) is verified the same way.

## Declared state

- upstream: UPSTREAM_VERSION
- clang: components/clang22/version
- recaulk: components/recaulk/version
- make: components/make/version
- patch-std-main-stack: patches/0001-std-macos-main-thread-stack-size-from-rlimit.patch
- patch-libgit2-stransport: patches/0002-libgit2-stransport-finish-handshake-after-server-auth.patch
- patch-rustc-target: patches/0003-rustc-target-macos-10.9-core2.patch

## Conformance deviations

- python3: x.py, Rust's own build driver, is Python; a native 10.9 build takes python3 from pkgsrc. No alternative exists upstream.
- build-equivalence:usr/local/mavergreen/rust/lib/rustlib/x86_64-apple-darwin/lib/*-H.rlib: std's crate ID differs between a Linux-built and a 10.9-built std ("Build equivalence" above) and reaches every member. Exit: std's StableCrateId matching across build hosts.
- build-equivalence:usr/local/mavergreen/rust/lib/rustlib/x86_64-apple-darwin/lib/*-H.rmeta: the same crate ID, in each crate's metadata. Exit: as above.
- build-equivalence:usr/local/mavergreen/rust/lib/rustlib/x86_64-apple-darwin/lib/libstd-H.dylib: the same crate ID, in its symbols and metadata. Exit: as above.
- build-equivalence:usr/local/mavergreen/rust/lib/rustlib/manifest-rust-std-x86_64-apple-darwin: it lists std's files, whose names carry the crate hashes. Exit: as above.
- build-equivalence:usr/local/mavergreen/rust/lib/rustlib/manifest-rustc: it lists librustc_driver, whose name carries its crate hash. Exit: as above.
- build-equivalence:usr/local/mavergreen/rust/bin/rustc.bin: built against std, so the crate ID reaches its symbol hashes. Exit: as above.
- build-equivalence:usr/local/mavergreen/rust/bin/rustfmt: as rustc.bin. Exit: as above.
- build-equivalence:usr/local/mavergreen/rust/bin/cargo-fmt: as rustc.bin. Exit: as above.
- build-equivalence:usr/local/mavergreen/rust/bin/cargo-clippy: as rustc.bin. Exit: as above.
- build-equivalence:usr/local/mavergreen/rust/bin/cargo: as rustc.bin, and its vendored OpenSSL records its compiler command line ("compiler: ccache … -isysroot <SDK path>"), which names the build host's paths. Exit: as above, and openssl-src recording no build paths.
- build-equivalence-interface:usr/local/mavergreen/rust/lib/librustc_driver-H.dylib: the crate ID orders the auto traits in the v0 mangling of `dyn … + DynSend + DynSync`, so some exported names differ. Exit: as above.
- build-equivalence-interface:usr/local/mavergreen/rust/bin/rustdoc: generics such as `thin_vec::drop_non_singleton` are shared from different crates, so it imports different symbols from librustc_driver. Exit: as above.
- build-equivalence-interface:usr/local/mavergreen/rust/bin/clippy-driver.bin: as rustdoc. Exit: as above.
- build-equivalence:usr/local/mavergreen/rust/lib/rustlib/x86_64-apple-darwin/bin/*: LLVM's tools, which clang22 hosted on Linux and on 10.9 emit with a translation unit's inline functions in a different order. Exit: clang-22 emitting host-independently.
- sdk-pin:usr/local/mavergreen/*/lib/rustlib/*/lib/*.rlib: rustc-emitted objects record no SDK (LC_VERSION_MIN_MACOSX "sdk n/a"); their minimum is 10.9 since patch 0003. These rlibs are link inputs, not installed executables: the linked output records the 10.9 SDK, and the compat guard plus the real-10.9 runs check it. Exit: rustc writing an SDK version into the objects it emits.
- sdk-pin:opt/mavergreen/rust/lib/rustlib/*/lib/*.rlib: the Linux tarball's rlibs, for the same reason: rustc records no SDK in the objects it emits, whose minimum is 10.9 since patch 0003. Exit: as above.
- linux:opt/mavergreen/rust/*: rustc and cargo hosted on x86_64 Linux, targeting Mac OS X 10.9, for builds of 10.9 products on Linux (codex-cli, and the pinned toolchain set Aqua WebKit's Linux build fetches)
- macos-runner:release.yml:modern-smoke: the rust-cross pkg's rustc and cargo are arm64 and run only on Apple Silicon, so this job installs the run's own pkg on a macos-26 runner and has them build 10.9 x86_64 programs before publish; it holds no key, and every build, the packaging and the signing run on Linux; exit: none while rust-cross ships an arm64 slice
- arm64:usr/local/mavergreen/rust-cross/*: rust-cross is the toolchain for building 10.9 x86_64 programs on an Apple Silicon Mac (macOS 11 and later), so its rustc, cargo and tools are arm64; release.yml's modern-smoke runs them on macos-26 before every release. Revisit when the flag day merges native and cross ("The default linker" above)
- floor:rust-cross-*.pkg: the cross toolchain runs on macOS 11 and later and only targets 10.9, so its archive's install floor is 11.0, not 10.9.5.
- bare-curl:build/check-release-on-10.9.sh: it runs from a bare checkout on a 10.9 box, the family VM included, where shipyard isn't installed, so it downloads the pkg, SHA256SUMS and Longboat with 10.9's own curl rather than shipyard_curl. Exit: the VM job puts shipyard's scripts into the guest.
