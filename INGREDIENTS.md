# Build ingredients

Everything baked into the shipped cross `.pkg`, where it is pinned, and how a change reaches a release.
The *own upstream* is Rust; an ingredient is anything else the artifact is built with.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| Rust source (own upstream) | `UPSTREAM_VERSION` | ⏳ Plan 3: `github-tags` on `rust-lang/rust` | tag-only publish cuts `<ver>-mavericks.1` |
| clang-22 cross toolchain | `components/clang/version` | ⏳ Plan 3: `github-releases` on `ModernMavericks/clang` | repackage → `-mavericks.(N+1)` |
| macports-legacy-support shim (prebuilt) | `MLS_VERSION # mavericks-legacysupport` in `build/versions.sh` | ⏳ Plan 3: shared preset marker customManager | repackage |
| MacOSX10.9 SDK | `shipyard@v1` (`fetch_sdk.sh`, used by the compat-guard smoke) | ✅ github-actions tracks the `@v1` tag | moving tag |

Not ingredients: `build/*.sh` and `native-bootstrap/rust.sh` are this repo's own recipe — a change
there is a deliberate `local_release` repackage, not Renovate-driven.

## Single upstream — why no `lines/`

Rust is one fast-moving upstream whose users always want latest; there are no concurrently-supported
lines users pin independently (unlike LLVM majors or Go minors). So a single bare `UPSTREAM_VERSION`,
not a `lines/<id>/` tree.

## Rust source verification

Verified against `static.rust-lang.org`'s published `.sha256` for the pinned version (upstream
publishes checksums → no hand-maintained hash; a Renovate bump only moves the ref). Fail closed if the
`.sha256` is absent.

## Build-time tools: cmake + ninja (and the intended migration)

The cross build needs `cmake` (≥3.20) and `ninja` to build Rust's bundled LLVM from source. These are
**build-time tools**, not baked into the shipped `.pkg`, so they are not tracked as artifact
ingredients — matching the sibling `mavericks-clang`, which also builds LLVM from source.

Today they come from whatever the runner provides. On the current Tahoe builder that is **pkgsrc
`/opt/pkg`**. A pkgsrc `cmake` bakes `/opt/pkg` into `find_library` results (libzstd/libxml2/libedit),
which would ship as absolute paths and fail `tests/relocatable-test.sh`; the build guards against this
in `build/lib-rust.sh`'s `[llvm] build-config` (`CMAKE_IGNORE_PREFIX_PATH=/opt/pkg;…` + those optional
deps `OFF` + `libzstd = false`), exactly as clang's cross build does.

**Intended direction:** the family plans its own `mavericks-ninja` (checkout exists, not yet released)
and `mavericks-cmake` (not started) products. When those ship, this repo — and clang — should consume
them as pinned, Renovate-tracked ingredients (like `components/clang/version`), and the
`CMAKE_IGNORE_PREFIX_PATH` guard becomes defense-in-depth rather than load-bearing. Recorded here so the
switch is a tracked decision, not a silent one.

## Deferred to later plans

- **Native variant** (Plan 2): the x86_64/10.9 toolchain via Rosetta on the arm64 runner, with
  `native-bootstrap/rust.sh` as the documented fallback (see the design spec's Rosetta-sunset ladder).
- **Sparkle updaters + CC-BY icon, `release.yml`, artifact conformance, Renovate, `family-conventions.yml`**
  (Plan 3).
