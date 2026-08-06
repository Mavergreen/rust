#!/bin/bash
#
# Bootstrap a native macOS 10.9 Rust toolchain (rustc + cargo 1.95.0) from source,
# compiled by the in-repo clang-22 toolchain. Self-contained and reproducible.
#
# Rust dropped 10.9 support long ago: the official prebuilt rustc calls APIs that do
# not exist on 10.9 (os_unfair_lock, clock_gettime, getentropy, _availability_version_
# check, ...), so it will not even load here. This script gets around that in three steps:
#
#   1. build the vendored 10.9 back-fill polyfill as a *dylib*;
#   2. make the official prebuilt rustc 1.95.0 RUN on 10.9 by injecting that dylib with
#      DYLD_INSERT_LIBRARIES + DYLD_FORCE_FLAT_NAMESPACE=1 -- used ONLY as the stage0;
#   3. use that stage0 to compile Rust 1.95.0 from source with clang-22, which links the
#      polyfill statically -- so the resulting toolchain runs on 10.9 with NO injection
#      (a proper, self-contained 10.9 Rust). Its LLVM is built from the bundled source,
#      since the official CI LLVM likewise cannot run on 10.9.
#
# Prereqs: the clang-22 toolchain (scripts/build.sh) and the vendored ./polyfill.
#
#   ./rust.sh         build everything (idempotent; skips finished steps)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
ARCHIVES="$ROOT/archives"; BUILD="$ROOT/build/rust"; POLY="$ROOT/polyfill"
CLANG="$ROOT/toolchains/clang-22"
CMAKEBIN="$ROOT/toolchains/cmake-new/bin"; TOOLSBIN="$ROOT/toolchains/tools/bin"
HOST="x86_64-apple-darwin"; RUST_VER="1.95.0"
PREFIX="$ROOT/toolchains/rust-$RUST_VER"            # final native toolchain install prefix
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
PYTHON="$(command -v python3 || echo /usr/local/bin/python3)"
mkdir -p "$ARCHIVES" "$BUILD"

msg()   { printf '\n=== %s ===\n' "$*"; }
fetch() { [ -f "$2" ] && return 0; echo "  fetch $1"; curl -fL --retry 3 -o "$2.tmp" "$1"; mv "$2.tmp" "$2"; }

DYLIB="$BUILD/libMavericksLegacySupport.dylib"
DIST="$BUILD/rust-$RUST_VER-$HOST"     # extracted prebuilt (installer layout)
STAGE0="$BUILD/stage0"                 # injection-wrapped stage0 (bin/rustc, bin/cargo)
SRC="$BUILD/rustc-$RUST_VER-src"       # extracted source tree

require() {
  [ -x "$CLANG/bin/clang" ] || { echo "ERROR: clang-22 missing -- run scripts/build.sh first" >&2; exit 1; }
  [ -f "$POLY/lib/libMavericksLegacySupport.a" ] || { echo "ERROR: polyfill missing at ${POLY#$ROOT/}" >&2; exit 1; }
}

# 1. polyfill dylib for stage0 injection. --no-default-config: clang.cfg would otherwise auto-link
#    the same archive again (duplicate symbols). -all_load makes the dylib EXPORT every back-fill
#    symbol so flat-namespace lookup can satisfy the prebuilt rustc's missing-on-10.9 references.
build_dylib() {
  [ -f "$DYLIB" ] && return 0
  msg "polyfill dylib (10.9 back-fill, for stage0 injection)"
  "$CLANG/bin/clang" --no-default-config -dynamiclib -mmacosx-version-min=10.9 \
    -Wl,-all_load "$POLY/lib/libMavericksLegacySupport.a" \
    -framework CoreFoundation -framework Security -framework CoreServices -lobjc \
    -install_name '@rpath/libMavericksLegacySupport.dylib' -o "$DYLIB"
}

# 2. official prebuilt rustc/cargo 1.95.0 -> stage0, wrapped so it runs on 10.9 via injection.
#    Only the prebuilt stage0 needs DYLD; everything this script BUILDS links the polyfill and
#    runs natively.
fetch_stage0() {
  [ -x "$STAGE0/bin/rustc" ] && [ -x "$STAGE0/bin/cargo" ] && return 0
  msg "stage0: prebuilt rustc/cargo $RUST_VER (run via polyfill injection)"
  fetch "https://static.rust-lang.org/dist/rust-$RUST_VER-$HOST.tar.xz" "$ARCHIVES/rust-$RUST_VER-$HOST.tar.xz"
  rm -rf "$DIST"; tar -xf "$ARCHIVES/rust-$RUST_VER-$HOST.tar.xz" -C "$BUILD"
  # merge the rust-std component into the rustc sysroot so stage0 rustc can actually compile
  cp -R "$DIST/rust-std-$HOST/lib/rustlib/$HOST" "$DIST/rustc/lib/rustlib/"
  mkdir -p "$STAGE0/bin"
  cat > "$STAGE0/bin/rustc" <<EOF
#!/bin/sh
export DYLD_INSERT_LIBRARIES="$DYLIB"
export DYLD_FORCE_FLAT_NAMESPACE=1
exec "$DIST/rustc/bin/rustc" "\$@"
EOF
  cat > "$STAGE0/bin/cargo" <<EOF
#!/bin/sh
export DYLD_INSERT_LIBRARIES="$DYLIB"
export DYLD_FORCE_FLAT_NAMESPACE=1
exec "$DIST/cargo/bin/cargo" "\$@"
EOF
  chmod +x "$STAGE0/bin/rustc" "$STAGE0/bin/cargo"
}

# 3. Rust source (self-contained: bundles llvm-project + vendored crates).
fetch_src() {
  [ -f "$SRC/x.py" ] && return 0
  msg "Rust $RUST_VER source"
  fetch "https://static.rust-lang.org/dist/rustc-$RUST_VER-src.tar.xz" "$ARCHIVES/rustc-$RUST_VER-src.tar.xz"
  rm -rf "$SRC"; tar -xf "$ARCHIVES/rustc-$RUST_VER-src.tar.xz" -C "$BUILD"
}

# 4. bootstrap config: stage0 = the injected prebuilt; all C/C++/link via clang-22 so the polyfill
#    is baked into every artifact; LLVM built from the bundled source (CI LLVM cannot run on 10.9).
#    local-rebuild=true because stage0 is the same version (1.95.0) we are building.
write_config() {
  cat > "$SRC/bootstrap.toml" <<EOF
[build]
rustc = "$STAGE0/bin/rustc"
cargo = "$STAGE0/bin/cargo"
python = "$PYTHON"
docs = false
extended = true
tools = ["cargo", "rustdoc"]
local-rebuild = true
submodules = false
vendor = true
sanitizers = false
profiler = false

# cargo's C deps vs 10.9:
#  - vendored-openssl: 10.9's system OpenSSL is 0.9.8 (far too old), so build OpenSSL from the
#    vendored openssl-src with clang-22 (offline).
#  - curl/force-system-lib-on-osx: cargo wants libcurl with http2, which 10.9's system libcurl
#    lacks, so curl-sys would build libcurl from source -- but that needs zlib >= 1.2.5.2 and 10.9
#    ships 1.2.5 (no z_const). Use the system libcurl instead (how cargo normally links curl on macOS).
[build.tool.cargo]
features = ["vendored-openssl", "curl/force-system-lib-on-osx"]

[install]
prefix = "$PREFIX"
sysconfdir = "etc"

[rust]
channel = "stable"

[llvm]
download-ci-llvm = false
ninja = true
targets = "X86"

[target.$HOST]
cc = "$CLANG/bin/clang"
cxx = "$CLANG/bin/clang++"
ar = "$CLANG/bin/llvm-ar"
ranlib = "$CLANG/bin/llvm-ranlib"
linker = "$CLANG/bin/clang++"
EOF
}

# 5. build + install. CARGO_TARGET_..._LINKER makes even the early bootstrap binary link with
#    clang-22 (polyfill) so it runs on 10.9; PATH supplies cmake>=3.20 + ninja for the LLVM build.
build_rust() {
  [ -x "$PREFIX/bin/rustc" ] && [ -x "$PREFIX/bin/cargo" ] && [ -x "$PREFIX/bin/rustdoc" ] && return 0
  fetch_stage0; fetch_src; write_config
  msg "build + install Rust $RUST_VER (x.py install; LLVM from source via clang-22)"
  ( cd "$SRC" && PATH="$CLANG/bin:$CMAKEBIN:$TOOLSBIN:$PATH" \
      CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER="$CLANG/bin/clang++" \
      "$PYTHON" x.py install -j "$JOBS" )
}

# 6. relocatability (like the clang toolchains): clang-22 records an ABSOLUTE rpath into
#    toolchains/clang-22/lib (from its auto-applied config) so the rust binaries can find clang-22's
#    libc++/libc++abi/libunwind at build time. Bundle those three dylibs into the rust prefix and
#    rewrite every Mach-O's repo-absolute rpath to a @loader_path-relative one pointing at the
#    bundled libs, so the toolchain carries its own runtime libs and contains no absolute repo path.
relocate() {
  [ -x "$PREFIX/bin/rustc" ] || { echo "ERROR: build Rust first" >&2; exit 1; }
  msg "relocatability: bundle libc++/libc++abi/libunwind + rewrite rpaths"
  # system install_name_tool, NOT clang-22's llvm-install-name-tool: the latter crashes standalone
  # (operator delete __ZdlPv -- its own libc++ doesn't re-export libc++abi), which is exactly the
  # rpath dependency we are here to remove. The 10.9 system tool handles -delete_rpath/-add_rpath.
  local NT="/usr/bin/install_name_tool" d
  # bundle the runtime dylibs (real files + their version symlinks) next to the rust libs
  for d in libc++.1.0.dylib libc++abi.1.0.dylib libunwind.1.0.dylib; do cp -f "$CLANG/lib/$d" "$PREFIX/lib/$d"; done
  ( cd "$PREFIX/lib"
    ln -sf libc++.1.0.dylib libc++.1.dylib;       ln -sf libc++.1.dylib libc++.dylib
    ln -sf libc++abi.1.0.dylib libc++abi.1.dylib; ln -sf libc++abi.1.dylib libc++abi.dylib
    ln -sf libunwind.1.0.dylib libunwind.1.dylib; ln -sf libunwind.1.dylib libunwind.dylib )
  # rewrite each Mach-O: drop any repo-absolute rpath, add a @loader_path-relative one -> PREFIX/lib
  local f rp rel
  while IFS= read -r f; do
    file "$f" 2>/dev/null | grep -q Mach-O || continue
    otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}' | while IFS= read -r rp; do
      case "$rp" in "$ROOT"/*) "$NT" -delete_rpath "$rp" "$f" 2>/dev/null || true ;; esac
    done
    rel="$("$PYTHON" -c "import os;print(os.path.relpath('$PREFIX/lib', os.path.dirname('$f')))")"
    [ "$rel" = "." ] && rel="@loader_path" || rel="@loader_path/$rel"
    otool -l "$f" 2>/dev/null | grep -qF " $rel" || "$NT" -add_rpath "$rel" "$f" 2>/dev/null || true
  done < <(find "$PREFIX/bin" "$PREFIX/lib" -type f 2>/dev/null)
}

# 7. out-of-box linking: Rust hard-clamps x86_64-apple-darwin to a 10.12 deployment target (it
#    ignores a lower MACOSX_DEPLOYMENT_TARGET), so the precompiled std references 10.12 symbols
#    (clock_gettime, ...) that 10.9's libSystem lacks -- a default `cc` link of e.g. any std::time
#    program would fail with "undefined _clock_gettime". Bundle the polyfill archive INTO the
#    toolchain and wrap rustc so every link adds it (+ the frameworks its members may pull). Then
#    `rustc foo.rs` / `cargo build` work out of the box with the system linker, and the toolchain
#    stays self-contained and relocatable (the wrapper resolves the archive relative to itself, so
#    it needs neither clang-22 nor any absolute path).
wrap_rustc() {
  # already wrapped? (bin/rustc is the shell wrapper, not the Mach-O compiler). Re-check this way --
  # not just rustc.bin's existence -- because a re-run of x.py install reinstalls the real bin/rustc.
  [ "$(head -c2 "$PREFIX/bin/rustc" 2>/dev/null)" = '#!' ] && return 0
  msg "wrap rustc: bundle polyfill + auto-link it (out-of-box 10.9 binaries)"
  cp -f "$POLY/lib/libMavericksLegacySupport.a" "$PREFIX/lib/rustlib/$HOST/lib/libMavericksLegacySupport.a"
  mv "$PREFIX/bin/rustc" "$PREFIX/bin/rustc.bin"
  cat > "$PREFIX/bin/rustc" <<'EOF'
#!/bin/sh
# Link the bundled 10.9 back-fill polyfill so std's 10.12 API references (clock_gettime, ...) resolve
# on 10.9 with any linker, including the system cc. Path is relative to this wrapper -> relocatable.
S="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)"
P="$S/../lib/rustlib/x86_64-apple-darwin/lib/libMavericksLegacySupport.a"
exec "$S/rustc.bin" \
  -C link-arg="$P" \
  -C link-arg=-framework -C link-arg=CoreFoundation \
  -C link-arg=-framework -C link-arg=Security \
  -C link-arg=-lobjc "$@"
EOF
  chmod +x "$PREFIX/bin/rustc"
}

# audit: fail if any Mach-O still hardcodes an absolute repo path (dep / install-name / rpath)
check_reloc() {
  msg "relocatability audit"; local f n=0 bad=0 hits
  while IFS= read -r f; do
    file "$f" 2>/dev/null | grep -q Mach-O || continue; n=$((n+1))
    hits="$(printf '%s\n%s\n%s\n' \
      "$(otool -L "$f" 2>/dev/null | tail -n +2)" "$(otool -D "$f" 2>/dev/null | tail -n +2)" \
      "$(otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}')" | grep -F "$ROOT" || true)"
    [ -n "$hits" ] && { bad=$((bad+1)); echo "FAIL ${f#$ROOT/}"; echo "$hits" | sed "s#$ROOT#<REPO>#g;s/^/    /"; }
  done < <(find "$PREFIX/bin" "$PREFIX/lib" -type f 2>/dev/null)
  echo "checked $n Mach-O under ${PREFIX#$ROOT/}: $bad with absolute repo paths"; [ "$bad" -eq 0 ]
}

case "${1:-all}" in
  all)   require; build_dylib; fetch_stage0; fetch_src; build_rust; relocate; wrap_rustc; check_reloc
         msg "DONE -- native 10.9 rustc:"; "$PREFIX/bin/rustc" --version ;;
  reloc) relocate; wrap_rustc; check_reloc ;;
  check) check_reloc ;;
  *) echo "usage: $0 [all|reloc|check]"; exit 1 ;;
esac
