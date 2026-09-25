# Build ingredients

Everything baked into the shipped `rust` and `rust-cross` `.pkg`s, where it is pinned, and how a
change reaches a release. The *own upstream* is Rust; an ingredient is anything else the artifacts are
built with.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| Rust source (own upstream) | `UPSTREAM_VERSION` | ⏳ Plan 3B: `github-tags` on `rust-lang/rust` | cuts `<ver>-mavericks.1` |
| clang-22 (cross pkg for modern hosts, native pkg on 10.9) | `components/clang/version` | ⏳ Plan 3B: `github-releases` on `Mavergreen/clang-22`, `-mavericks.N` versioning | repackage → `-mavericks.(N+1)` |
| macports-legacy-support shim (prebuilt) | `components/legacy-support/version` | ⏳ Plan 3B: `github-releases` on `Mavergreen/macports-legacy-support`, `-mavericks.N` versioning | repackage |
| MacOSX10.9 SDK | shipyard `fetch_sdk.sh` (pinned by hash) | ✅ moves with shipyard `@v1` | moving tag |

The legacy-support pin is a whole file, not the preset's `# mavericks-legacysupport` marker line,
because `release-state.sh` reads a `path:KEY` entry as a line starting `KEY=`: an `export`ed,
marker-commented assignment cannot be declared.

## Temporary back-fills (with their exit)

`build/polyfill-ccrandom.c` (`CCRandomGenerateBytes`, std's entropy source) and
`build/polyfill-dispatch.c` (four libdispatch symbols that dispatch2 links into rustc and cargo but
never calls) are compiled into the shim by `augment_shim`. Both belong in mavergreen-compat, which
already carries `ccrandom.c`.

**Exit:** when mavergreen-compat publishes a release under the `/usr/local/mavergreen` layout, pin it
here as an ingredient, and delete both files and `augment_shim`'s compile loop. Separately,
`CCRandomGenerateBytes` is to be offered upstream to macports/macports-legacy-support.

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
- legacy-support: components/legacy-support/version

## Conformance deviations

- python3: x.py, Rust's own build driver, is Python; a native 10.9 build takes python3 from pkgsrc. No alternative exists upstream.
- sdk-pin:usr/local/mavergreen/*/lib/rustlib/*/lib/*.rlib: rustc-emitted objects record no SDK, and rustc clamps every x86_64-apple-darwin object to minos 10.12 (os_minimum_deployment_target). These rlibs are link inputs, not installed executables: every x86_64 link goes through bin/rustc, which passes -mmacosx-version-min=10.9, and the compat guard plus the real-10.9 runs check the linked output. Only patching rustc's target spec would change them.
- floor:rust-cross-*.pkg: the cross toolchain runs on macOS 11 and later and only targets 10.9, so its archive's install floor is 11.0, not 10.9.5.
