#!/bin/sh
# Single source of truth for every pinned input. Sourced, not executed.
: "${REPO_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
export REPO_ROOT
# Heavy build I/O (a full rustc + LLVM Release build) must live on a LOCAL disk. Default to the local
# cache; override with MAVERICKS_WORK (never under an NFS/shared tree). On CI $HOME/.cache is fine.
export WORK="${MAVERICKS_WORK:-$HOME/.cache/mavericks-rust/work}"

. "$REPO_ROOT/build/lib.sh"

# Own upstream: Rust. Single always-latest upstream (NO lines/). upstream_version() reads
# MAVERICKS_UPSTREAM_FILE; point it at the repo-root pin.
export MAVERICKS_UPSTREAM_FILE="$REPO_ROOT/UPSTREAM_VERSION"
[ -f "$MAVERICKS_UPSTREAM_FILE" ] || { echo "versions.sh: no UPSTREAM_VERSION at repo root" >&2; exit 1; }
export RUST_VERSION="$(upstream_version)"

# Full package version (<upstream>-mavericks.N): written to VERSION by the release workflow and
# gitignored; before a release is cut, fall back to the computed auto version.
if [ -f "$REPO_ROOT/VERSION" ]; then
  export PKG_VERSION="$(cat "$REPO_ROOT/VERSION")"
else
  export PKG_VERSION="$(sh "$REPO_ROOT/build/version.sh" auto | sed -n 's/^FULL=//p')"
fi

# Rust source tarball. Verified against upstream's own published .sha256 (static.rust-lang.org) in
# build/fetch-rust-src.sh -- a checksum upstream publishes for the pinned version makes a Renovate bump
# self-contained (no hand-pasted hash), vouching for bytes before we have seen them.
export RUST_SRC_URL="https://static.rust-lang.org/dist/rustc-${RUST_VERSION}-src.tar.xz"
export RUST_SRC_SHA_URL="${RUST_SRC_URL}.sha256"

# The 10.9 legacy-support shim, fetched PREBUILT from the mavericks-legacysupport release and verified
# against its SHA256SUMS every run. Renovate bumps this via the shared preset's marker customManager.
export MLS_VERSION=1.5.2-mavericks.2   # mavericks-legacysupport

# clang-22 cross toolchain (the C/C++ compiler + linker for Rust's bundled LLVM and as cc/linker).
# Pinned in components/clang/version (see fetch-clang.sh).
export CLANG_PIN_FILE="$REPO_ROOT/components/clang/version"

# The cross variant TARGETS x86_64 Mavericks and RUNS on modern arm64. (native, Plan 2, RUNS on 10.9.)
export TARGET_TRIPLE="x86_64-apple-darwin"     # Rust's triple for 10.9 x86_64 (min set via clang/env)
export MACOS_MIN="10.9"
export NATIVE_PREFIX="/usr/local/mavericks-rust"
export CROSS_PREFIX="/usr/local/mavericks-rust-cross"
export NATIVE_IDENTIFIER="dev.mavergreen.rust.rust"
export CROSS_IDENTIFIER="dev.mavergreen.rust.rust-cross"

# shipyard scripts dir for shell callers (SDK fetch, compat guard, productbuild, build-info).
# Resolve in the family's usual order: override -> user package registry -> sibling checkout.
_mav_shared_scripts() {
  if [ -n "${MAVERICKS_SHARED_SCRIPTS:-}" ] && [ -d "$MAVERICKS_SHARED_SCRIPTS" ]; then
    printf '%s\n' "$MAVERICKS_SHARED_SCRIPTS"; return 0; fi
  for _r in "$HOME/.cmake/packages/MavericksShipyard/"*; do
    [ -f "$_r" ] || continue; _d="$(cat "$_r")/scripts"
    [ -d "$_d" ] && { printf '%s\n' "$_d"; return 0; }; done
  [ -d "$REPO_ROOT/../mavergreen-shipyard/scripts" ] && \
    { printf '%s\n' "$REPO_ROOT/../mavergreen-shipyard/scripts"; return 0; }
  return 1
}
SHIPYARD_SCRIPTS="$(_mav_shared_scripts || true)"; export SHIPYARD_SCRIPTS
