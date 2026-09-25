#!/bin/sh
# platform: macOS-only -- relocate_prefix runs otool and install_name_tool
#   usage: . build/lib-rust.sh   (after build/versions.sh; needs TARGET_TRIPLE, MACOS_MIN, WORK)

write_bootstrap_toml() {
  _src="$1"; _prefix="$2"; _build="$3"; _host="$4"; _clang="$5"; _stage0="${6:-}"
  _py="$(command -v python3 || echo /opt/pkg/bin/python3)"
  if [ "$_host" = "$TARGET_TRIPLE" ]; then _targets="\"$TARGET_TRIPLE\""; else _targets="\"$_host\", \"$TARGET_TRIPLE\""; fi
  case "$_build$_host" in *aarch64*) _llvm_targets="AArch64;X86" ;; *) _llvm_targets="X86" ;; esac
  {
    printf '[build]\nbuild = "%s"\nhost = ["%s"]\ntarget = [%s]\n' "$_build" "$_host" "$_targets"
    if [ -n "$_stage0" ]; then
      printf 'rustc = "%s/bin/rustc"\ncargo = "%s/bin/cargo"\nlocal-rebuild = true\n' "$_stage0" "$_stage0"
    fi
    cat <<EOF
python = "$_py"
docs = false
extended = true
tools = ["cargo", "rustdoc", "clippy", "rustfmt"]
submodules = false
vendor = true
sanitizers = false
profiler = false

EOF
    # platform: 10.9's system OpenSSL is 0.9.8, too old for cargo, so openssl-src is vendored
    # platform: 10.9's zlib 1.2.5 lacks z_const, so curl-sys cannot build libcurl; use the system one
    cat <<EOF
[build.tool.cargo]
features = ["vendored-openssl", "curl/force-system-lib-on-osx"]

[install]
prefix = "$_prefix"
sysconfdir = "etc"

[rust]
channel = "stable"

[llvm]
download-ci-llvm = false
ninja = true
targets = "$_llvm_targets"
libzstd = false
build-config = { CMAKE_IGNORE_PREFIX_PATH = "/opt/pkg;/opt/homebrew;/usr/local;/opt/local;/sw", LLVM_ENABLE_ZSTD = "OFF", LLVM_ENABLE_LIBXML2 = "OFF", LLVM_ENABLE_LIBEDIT = "OFF" }

[target.$TARGET_TRIPLE]
cc = "$_clang/bin/clang"
cxx = "$_clang/bin/clang++"
ar = "$_clang/bin/llvm-ar"
ranlib = "$_clang/bin/llvm-ranlib"
linker = "$_clang/bin/clang++"
EOF
  } > "$_src/bootstrap.toml"
}

# spec: docs/superpowers/plans/2026-09-25-rust-plan3a-conformance.md Task 3 ruling -- bootstrap 1.95
#       has no [build] cmake key; its sanity check and the cmake crate run `cmake` from PATH ($CMAKE)
cmake_shim_dir() {
  _cm="${SHIPYARD_CMAKE:-$(command -v shipyard-cmake || echo /usr/local/mavergreen/bin/shipyard-cmake)}"
  [ -x "$_cm" ] || { echo "FATAL: no shipyard-cmake at $_cm" >&2; return 1; }
  mkdir -p "$1"; ln -sfn "$_cm" "$1/cmake"; printf '%s\n' "$1"
}

write_x86_cmake_toolchain() {
  printf 'set(CMAKE_OSX_SYSROOT "%s")\nset(CMAKE_OSX_DEPLOYMENT_TARGET "%s")\nset(CMAKE_OSX_ARCHITECTURES "x86_64")\n' \
    "$2" "$MACOS_MIN" > "$1"
}

# platform: clang-22's clang.cfg auto-links <CFGDIR>/../lib/libMacportsLegacySupport.a, its own
#           bundled copy, so the pinned shim must overwrite it or every link resolves the bundled one
augment_shim() {
  _poly="$1"; _clang="$2"
  for _src in "$REPO_ROOT"/build/polyfill-*.c; do
    _obj="$(dirname "$_poly")/$(basename "$_src" .c).o"
    "$_clang/bin/clang" -c -o "$_obj" "$_src"
    "$_clang/bin/llvm-ar" r "$_poly" "$_obj"
  done
  for _sym in _CCRandomGenerateBytes _dispatch_workloop_create; do
    nm -g "$_poly" 2>/dev/null | grep -q " T $_sym\$" \
      || { echo "FATAL: polyfill did not define $_sym in $_poly" >&2; exit 1; }
  done
  cp -f "$_poly" "$_clang/lib/libMacportsLegacySupport.a"
}

# platform: rustc puts -lSystem before -C link-args, so on a modern SDK libSystem resolves
#           clock_gettime first unless the shim archive is force_loaded
# platform: rustc clamps x86_64-apple-darwin to 10.12 and passes -mmacosx-version-min=10.12.0 to
#           the linker driver; the last -mmacosx-version-min on the line wins
wrap_rustc() {
  _p="$1"; _mode="$2"
  [ "$(head -c2 "$_p/bin/rustc" 2>/dev/null)" = '#!' ] && return 0
  mv "$_p/bin/rustc" "$_p/bin/rustc.bin"
  if [ "$_mode" = always ]; then _wants=1; else _wants=0; fi
  cat > "$_p/bin/rustc" <<EOF
#!/bin/sh
self="\$0"
while [ -h "\$self" ]; do
  link="\$(readlink "\$self")"
  case "\$link" in /*) self="\$link" ;; *) self="\$(dirname "\$self")/\$link" ;; esac
done
S="\$(cd "\$(dirname "\$self")" >/dev/null 2>&1 && pwd)"
P="\$S/../lib/rustlib/$TARGET_TRIPLE/lib/libMacportsLegacySupport.a"
wants=$_wants
prev=""
for a in "\$@"; do
  [ "\$prev" = "--target" ] && [ "\$a" = "$TARGET_TRIPLE" ] && wants=1
  case "\$a" in --target="$TARGET_TRIPLE") wants=1 ;; esac
  prev="\$a"
done
if [ "\$wants" = 1 ] && [ -f "\$P" ]; then
  exec "\$S/rustc.bin" \\
    -C link-arg=-Wl,-force_load,"\$P" \\
    -C link-arg=-mmacosx-version-min=$MACOS_MIN \\
    -C link-arg=-framework -C link-arg=CoreFoundation \\
    -C link-arg=-framework -C link-arg=Security \\
    -C link-arg=-lobjc "\$@"
fi
exec "\$S/rustc.bin" "\$@"
EOF
  chmod +x "$_p/bin/rustc"
}

# platform: llvm-install-name-tool crashes when run standalone; /usr/bin/install_name_tool does not
relocate_prefix() {
  _p="$1"; _clang="$2"; NT="/usr/bin/install_name_tool"
  for d in libc++.1.0.dylib libc++abi.1.0.dylib libunwind.1.0.dylib; do
    [ -f "$_clang/lib/$d" ] && cp -f "$_clang/lib/$d" "$_p/lib/$d"
  done
  ( cd "$_p/lib"
    ln -sf libc++.1.0.dylib libc++.1.dylib;       ln -sf libc++.1.dylib libc++.dylib
    ln -sf libc++abi.1.0.dylib libc++abi.1.dylib; ln -sf libc++abi.1.dylib libc++abi.dylib
    ln -sf libunwind.1.0.dylib libunwind.1.dylib; ln -sf libunwind.1.dylib libunwind.dylib ) 2>/dev/null || true
  _py="$(command -v python3 || echo /usr/local/bin/python3)"
  find "$_p/bin" "$_p/lib" -type f 2>/dev/null | while IFS= read -r f; do
    file "$f" 2>/dev/null | grep -q Mach-O || continue
    otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}' | while IFS= read -r rp; do
      case "$rp" in "$_clang"/*|"$WORK"/*) "$NT" -delete_rpath "$rp" "$f" 2>/dev/null || true ;; esac
    done
    rel="$("$_py" -c "import os,sys;print(os.path.relpath('$_p/lib', os.path.dirname(sys.argv[1])))" "$f")"
    [ "$rel" = "." ] && rel="@loader_path" || rel="@loader_path/$rel"
    otool -l "$f" 2>/dev/null | grep -qF " $rel" || "$NT" -add_rpath "$rel" "$f" 2>/dev/null || true
  done
}

staged_complete() {
  for _t in rustc cargo rustdoc clippy-driver cargo-clippy rustfmt cargo-fmt; do
    [ -x "$1/bin/$_t" ] || return 1
  done
}

write_stage0_wrappers() {
  mkdir -p "$1/bin"
  for _b in rustc cargo; do
    printf '#!/bin/sh\nexport DYLD_INSERT_LIBRARIES="%s/libMavericksLegacySupport.dylib"\nexport DYLD_FORCE_FLAT_NAMESPACE=1\nexec "%s/%s/bin/%s" "$@"\n' \
      "$1" "$2" "$_b" "$_b" > "$1/bin/$_b"
    chmod +x "$1/bin/$_b"
  done
}
