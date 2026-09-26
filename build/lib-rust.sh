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
    if [ "${MAVERICKS_USE_CCACHE:-}" = 1 ]; then printf 'ccache = true\n'; fi
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
    # platform: 10.9's system OpenSSL is 0.9.8, older than cargo's openssl crate accepts
    # platform: 10.9's zlib is 1.2.5, which lacks z_const; curl-sys needs it to build libcurl from source
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
    if [ -n "${ARM64_LINKER:-}" ]; then
      printf '\n[target.aarch64-apple-darwin]\nlinker = "%s"\n' "$ARM64_LINKER"
    fi
  } > "$_src/bootstrap.toml"
}

# spec: docs/superpowers/handoffs/plan3a-ledger.md, the Task 3 cmake ruling -- bootstrap 1.95
#       has no [build] cmake key; its sanity check and the cmake crate run `cmake` from PATH ($CMAKE)
cmake_shim_dir() {
  _cm="${SHIPYARD_CMAKE:-$(command -v shipyard-cmake || echo /usr/local/mavergreen/bin/shipyard-cmake)}"
  [ -x "$_cm" ] || { echo "FATAL: no shipyard-cmake at $_cm" >&2; return 1; }
  mkdir -p "$1"; ln -sfn "$_cm" "$1/cmake"; printf '%s\n' "$1"
}

write_cmake_toolchain() {
  printf 'set(CMAKE_OSX_SYSROOT "%s")\nset(CMAKE_OSX_DEPLOYMENT_TARGET "%s")\nset(CMAKE_OSX_ARCHITECTURES "%s")\n' \
    "$2" "$3" "$4" > "$1"
}

write_x86_cmake_toolchain() { write_cmake_toolchain "$1" "$2" "$MACOS_MIN" x86_64; }

write_pinned_cc() {
  printf '#!/bin/sh\nexec /usr/bin/clang -isysroot "%s" "$@"\n' "$2" > "$1"
  chmod +x "$1"
}

# platform: clang-22's clang.cfg auto-links <CFGDIR>/../lib/libMacportsLegacySupport.a, a copy
#           bundled in its pkg
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

# platform: rustc puts -lSystem before -C link-args, and a modern SDK's libSystem exports clock_gettime
# platform: rustc clamps x86_64-apple-darwin to 10.12 and passes -mmacosx-version-min=10.12.0 to
#           the linker driver; the last -mmacosx-version-min on the line wins
wrap_linking_tool() {
  _p="$1"; _tool="$2"; _mode="$3"
  [ "$(head -c2 "$_p/bin/$_tool" 2>/dev/null)" = '#!' ] && return 0
  mv "$_p/bin/$_tool" "$_p/bin/$_tool.bin"
  if [ "$_mode" = always ]; then _wants=1; else _wants=0; fi
  if [ "$_tool" = rustc ]; then _passthru=0; else _passthru=1; fi
  cat > "$_p/bin/$_tool" <<EOF
#!/bin/sh
self="\$0"
while [ -h "\$self" ]; do
  link="\$(readlink "\$self")"
  case "\$link" in /*) self="\$link" ;; *) self="\$(dirname "\$self")/\$link" ;; esac
done
S="\$(cd -P "\$(dirname "\$self")" >/dev/null 2>&1 && pwd)"
P="\$S/../lib/rustlib/$TARGET_TRIPLE/lib/libMacportsLegacySupport.a"
wants=$_wants
prev=""
for a in "\$@"; do
  [ "\$prev" = "--target" ] && [ "\$a" = "$TARGET_TRIPLE" ] && wants=1
  case "\$a" in --target="$TARGET_TRIPLE") wants=1 ;; esac
  prev="\$a"
done
if [ "\$wants" = 1 ] && [ ! -f "\$P" ]; then
  echo "$_tool: \$P is missing; without it a 10.9 binary would link post-10.9 symbols" >&2; exit 1
fi
if [ "\$wants" = 1 ]; then
  if [ $_passthru = 1 ] && [ "\$#" -gt 0 ]; then
    case "\$1" in rustc|*/rustc|*/rustc.bin)
      first="\$1"; shift
      exec "\$S/$_tool.bin" "\$first" \\
        -C link-arg=-Wl,-force_load,"\$P" \\
        -C link-arg=-mmacosx-version-min=$MACOS_MIN \\
        -C link-arg=-framework -C link-arg=CoreFoundation \\
        -C link-arg=-framework -C link-arg=Security \\
        -C link-arg=-lobjc "\$@" ;;
    esac
  fi
  exec "\$S/$_tool.bin" \\
    -C link-arg=-Wl,-force_load,"\$P" \\
    -C link-arg=-mmacosx-version-min=$MACOS_MIN \\
    -C link-arg=-framework -C link-arg=CoreFoundation \\
    -C link-arg=-framework -C link-arg=Security \\
    -C link-arg=-lobjc "\$@"
fi
exec "\$S/$_tool.bin" "\$@"
EOF
  chmod +x "$_p/bin/$_tool"
}

wrap_rustc() { wrap_linking_tool "$1" rustc "$2"; }

# platform: llvm-install-name-tool crashes when run standalone; /usr/bin/install_name_tool does not
loader_rel() {
  _sub="$(dirname "$2")"; _sub="${_sub#"$1"/}"
  _n=1; _r="$_sub"
  while :; do case "$_r" in */*) _r="${_r#*/}"; _n=$((_n+1)) ;; *) break ;; esac; done
  _u=""; _i=0
  case "$_sub" in
    lib) echo @loader_path ;;
    lib/*) while [ "$_i" -lt $((_n-1)) ]; do _u="$_u/.."; _i=$((_i+1)); done; echo "@loader_path$_u" ;;
    *) while [ "$_i" -lt "$_n" ]; do _u="$_u../"; _i=$((_i+1)); done; echo "@loader_path/${_u}lib" ;;
  esac
}

relocate_prefix() {
  _p="$1"; _clang="$2"; NT="/usr/bin/install_name_tool"
  find "$_p/bin" "$_p/lib" -type f 2>/dev/null | while IFS= read -r f; do
    file "$f" 2>/dev/null | grep -q Mach-O || continue
    otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}' | while IFS= read -r rp; do
      case "$rp" in "$_clang"/*|"$WORK"/*) "$NT" -delete_rpath "$rp" "$f" 2>/dev/null || true ;; esac
    done
    rel="$(loader_rel "$_p" "$f")"
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

# spec: docs/superpowers/handoffs/plan3a-ledger.md, the Task 10 proof 2 ruling -- a cross-hosted
#       install leaves rustc's own proc-macro dylibs in lib/; nothing links them
prune_proc_macro_dylibs() {
  for _d in "$1"/lib/*.dylib; do
    [ -f "$_d" ] && [ ! -h "$_d" ] || continue
    nm -gU "$_d" 2>/dev/null | grep -q '__rustc_proc_macro_decls_' && rm -f "$_d"
  done
  return 0
}

stage_stamp() {
  printf 'variant=%s\nrust=%s\nclang=%s\nlegacy_support=%s\n' \
    "$1" "$RUST_VERSION" "$(tr -d ' \t\n' < "$CLANG_PIN_FILE")" "$MLS_VERSION"
  for _f in "$REPO_ROOT/build/lib-rust.sh" "$REPO_ROOT/build/build-$1.sh" "$REPO_ROOT"/build/polyfill-*.c; do
    printf '%s %s\n' "$(shasum -a 256 "$_f" | awk '{print $1}')" "${_f#"$REPO_ROOT"/}"
  done
}

stage_is_current() {
  [ -f "$1" ] && [ "$(cat "$1")" = "$(stage_stamp "$2")" ]
}

# platform: 10.9's lipo has -info but not -archs
guard_prefix() {
  _gd="$(mktemp -d "${TMPDIR:-/tmp}/guard.XXXXXX")"
  find "$1/bin" "$1/lib" -type f -perm -u+x | while IFS= read -r _f; do
    case "$(file "$_f")" in *Mach-O*executable*|*Mach-O*"dynamically linked shared library"*) : ;; *) continue ;; esac
    _a="$(lipo -info "$_f" 2>/dev/null | sed -n 's/.*architecture: //p; s/.* are: //p')"
    printf '%s\n' "$_f" >> "$_gd/$(printf '%s' "$_a" | tr ' ' '+')"
  done
  [ -n "$(ls "$_gd")" ] || { echo "FATAL: no Mach-O under $1 -- nothing guarded" >&2; rm -rf "$_gd"; return 1; }
  _rc=0
  for _l in "$_gd"/*; do
    tr '\n' '\0' < "$_l" | MAVERICKS_ALLOW_ARCHS="$(basename "$_l" | tr '+' ' ')" \
      xargs -0 sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" || _rc=1
  done
  rm -rf "$_gd"; return $_rc
}
