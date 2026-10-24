#!/bin/sh
# platform: macOS-only -- relocate_prefix runs otool and install_name_tool (macho_tools picks clang-22's)
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
EOF
    # platform: built on 10.9 itself, bootstrap's own build scripts compile and link at the 10.9 floor,
    #           below rustc's 10.12; rustc and clang++ warn about it, and bootstrap denies warnings
    if [ "$_build" = "$TARGET_TRIPLE" ]; then printf 'deny-warnings = false\n'; fi
    cat <<EOF
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

# platform: LLVM's configure asks xcrun for libtool and ld64; on 10.9 it finds the Command Line
#           Tools' when they are installed and nothing when they are not, so pin clang-22's
write_x86_cmake_toolchain() {
  write_cmake_toolchain "$1" "$2" "$MACOS_MIN" x86_64
  printf 'set(CMAKE_LIBTOOL "%s/bin/llvm-libtool-darwin")\nset(LD64_EXECUTABLE "%s/bin/ld64.lld")\n' "$3" "$3" >> "$1"
}

# platform: on 10.9 rustc runs xcrun for an SDK on every link and the cc crate runs cc to detect a
#           compiler family; both are Command Line Tools stubs. A cross-hosted build's arm64 build
#           tools need neither the 10.9 SDK nor clang-22, so this pins only an on-box build
pin_onbox_tools() {
  [ "$1" = "$TARGET_TRIPLE" ] || return 0
  SDKROOT="$3"; CC="$2/bin/clang"; CXX="$2/bin/clang++"; export SDKROOT CC CXX
}

# platform: clang-22's clang.cfg looks for <bin>/../SDKs/MacOSX10.9.sdk; its pkg ships SDKs as a link
#           into Longboat's sdk109, which dangles in a prefix copied out of the pkg
populate_clang_sdk() {
  [ -h "$1/SDKs" ] && rm -f "$1/SDKs"
  mkdir -p "$1/SDKs"; ln -sfn "$2" "$1/SDKs/MacOSX10.9.sdk"
}

write_pinned_cc() {
  printf '#!/bin/sh\nexec /usr/bin/clang -isysroot "%s" "$@"\n' "$2" > "$1"
  chmod +x "$1"
}

fetch_recaulk() {
  _rc="$(sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" recaulk "$RECAULK_VERSION" "$WORK/recaulk")" || return 1
  _a="$_rc/lib/librecaulk.a"
  [ -f "$_a" ] || { echo "FATAL: Recaulk $RECAULK_VERSION has no lib/librecaulk.a" >&2; return 1; }
  "${LIPO:-lipo}" -info "$_a" 2>/dev/null | sed -n 's/.*: //p' | grep -qw x86_64 \
    || { echo "FATAL: $_a has no x86_64 slice" >&2; return 1; }
  printf '%s\n' "$_a"
}

# platform: cargo's vendored OpenSSL builds with a bare `make`, which on 10.9 is a Command Line Tools
#           stub; the family's GNU make goes first on x.py's PATH
fetch_make() {
  _mk="$(sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" make "$MAKE_VERSION" "$WORK/make")" || return 1
  [ -x "$_mk/bin/make" ] || { echo "FATAL: make $MAKE_VERSION has no bin/make" >&2; return 1; }
  printf '%s\n' "$_mk/bin"
}

# platform: clang-22's clang.cfg links <CFGDIR>/../lib/librecaulk.a into everything it links, rustc and
#           cargo included; overwriting it keeps build-info's recaulk= true of every shipped binary
install_recaulk_into_clang() { cp -f "$1" "$2/lib/librecaulk.a"; }

# platform: rustc puts -lSystem before -C link-args, and a modern SDK's libSystem exports clock_gettime
# platform: rustc clamps x86_64-apple-darwin to 10.12 and passes -mmacosx-version-min=10.12.0 to
#           the linker driver; the last -mmacosx-version-min on the line wins
wrap_linking_tool() {
  _p="$1"; _tool="$2"; _mode="$3"
  [ "$(head -c2 "$_p/bin/$_tool" 2>/dev/null)" = '#!' ] && return 0
  mv "$_p/bin/$_tool" "$_p/bin/$_tool.bin"
  # spec: INGREDIENTS.md "The default linker" -- only the native pkg (mode always) names a
  #       default linker; rust-cross keeps rustc's own default until the flag day merges the two
  if [ "$_mode" = always ]; then _wants=1; _default=1; else _wants=0; _default=0; fi
  _inst=""; [ $_default = 0 ] || _inst="$(dirname "${NATIVE_PREFIX:?wrap_linking_tool: NATIVE_PREFIX is unset}")"
  if [ "$_tool" = rustc ]; then _passthru=0; else _passthru=1; fi
  cat > "$_p/bin/$_tool" <<EOF
#!/bin/sh
self="\$0"
while [ -h "\$self" ]; do
  link="\$(readlink "\$self")"
  case "\$link" in /*) self="\$link" ;; *) self="\$(dirname "\$self")/\$link" ;; esac
done
S="\$(cd -P "\$(dirname "\$self")" >/dev/null 2>&1 && pwd)"
P="\$S/../lib/rustlib/$TARGET_TRIPLE/lib/librecaulk.a"
wants=$_wants
prev=""
linker=""
flavor=0
nolink=0
# platform: rustc stops after printing for every --print request but link-args and native-static-libs
printed() { case "\$1" in link-args|native-static-libs) : ;; *) nolink=1 ;; esac; }
scan() {
  case "\$1" in -V|-vV|-Vv|--version|-h|--help|--explain|--explain=*) nolink=1 ;; --print=*) printed "\${1#--print=}" ;; esac
  [ "\$prev" != "--print" ] || printed "\$1"
  [ "\$prev" = "--target" ] && [ "\$1" = "$TARGET_TRIPLE" ] && wants=1
  case "\$1" in --target="$TARGET_TRIPLE") wants=1 ;; esac
  case "\$prev" in -C|--codegen) case "\$1" in linker=*) linker="\${1#linker=}" ;; esac ;; esac
  case "\$1" in -Clinker=*) linker="\${1#-Clinker=}" ;; --codegen=linker=*) linker="\${1#--codegen=linker=}" ;; esac
  case "\$prev" in -C|--codegen) case "\$1" in linker-flavor=*) flavor=1 ;; esac ;; esac
  case "\$1" in -Clinker-flavor=*|--codegen=linker-flavor=*) flavor=1 ;; esac
  prev="\$1"
}
# platform: cargo retries rustc with one @argfile (an argument per line) when argv exceeds ARG_MAX
for a in "\$@"; do
  case "\$a" in
    @*) if [ -f "\${a#@}" ]; then while IFS= read -r l || [ -n "\$l" ]; do scan "\$l"; done < "\${a#@}"; else scan "\$a"; fi ;;
    *) scan "\$a" ;;
  esac
done
# spec: INGREDIENTS.md "The default linker" -- cargo runs rustc -vV (and --print probes) with no linker
#       named, so a call that links nothing needs no clang22 and gets nothing added
[ "\$nolink" = 0 ] || wants=0
if [ "\$wants" = 1 ] && [ ! -f "\$P" ]; then
  echo "$_tool: \$P is missing; without it a 10.9 binary would link post-10.9 symbols" >&2; exit 1
fi
named=0
# platform: on 10.9 without the Command Line Tools rustc's default linker, cc, is the xcode-select stub
# spec: INGREDIENTS.md "The default linker" -- clang22 is found next to rust (its own
#       deps/ first, then the shared sibling), then installed (an unpacked rust has neither beside
#       it), never by PATH, and its absence is an error, not cc
if [ "\$wants" = 1 ] && [ $_default = 1 ] && [ -z "\$linker" ] && [ "\$flavor" = 0 ]; then
  R="\$(cd -P "\$S/.." >/dev/null 2>&1 && pwd)"
  sib="\$(dirname "\$R")/clang22/bin/clang++"
  inst="$_inst/clang22/bin/clang++"
  [ "\$inst" != "\$sib" ] || inst=""
  for c in "\$R/deps/clang22/bin/clang++" "\$sib" "\${inst:-\$sib}"; do
    [ -x "\$c" ] && { linker="\$c"; named=1; break; }
  done
  if [ "\$named" = 0 ]; then
    if [ -n "\$inst" ]; then where="\$R/deps/clang22/bin/clang++, \$sib and \$inst"; else where="\$R/deps/clang22/bin/clang++ and \$sib"; fi
    echo "$_tool: no clang22 next to rust or installed (looked in \$where); install clang22, or name a linker (-C linker=cc) to use the Command Line Tools" >&2
    exit 1
  fi
fi
if [ "\$wants" = 1 ]; then
  defer=0
  # platform: a clang driver that loads a .cfg reports the config's link inputs under -###, so the
  #           linker itself says whether it already links librecaulk.a (Mavergreen clang22 does)
  ran=0
  if [ -n "\$linker" ] && probe="\$("\$linker" -### /dev/null </dev/null 2>&1)"; then
    ran=1
    case "\$probe" in */librecaulk.a*) defer=1 ;; esac
  fi
  # spec: INGREDIENTS.md "The default linker" -- an older clang22 links its own back-fill
  #       archive, so force-loading Recaulk beside it fails with duplicate symbols
  if [ "\$named" = 1 ] && [ "\$ran" = 0 ]; then
    echo "$_tool: \$linker fails to run (-###); reinstall clang22, or name a linker (-C linker=cc) to use the Command Line Tools" >&2
    exit 1
  fi
  if [ "\$named" = 1 ] && [ "\$defer" = 0 ]; then
    echo "$_tool: \$linker does not link Recaulk's librecaulk.a (clang22 older than 22.1.1-mavericks.7); update clang22, or name a linker (-C linker=cc) to use the Command Line Tools" >&2
    exit 1
  fi
  first=0
  if [ $_passthru = 1 ] && [ "\$#" -gt 0 ]; then
    case "\$1" in rustc|*/rustc|*/rustc.bin) first="\$1"; shift ;; esac
  fi
  # platform: with no SDKROOT rustc runs xcrun on every link to find an SDK, and without the Command
  #           Line Tools xcrun is 10.9's stub; a clang22 carries its own 10.9 SDK beside its bin/
  if [ $_default = 1 ] && [ "\$defer" = 1 ] && [ -z "\${SDKROOT:-}" ]; then
    case "\$linker" in */*) lp="\$linker" ;; *) lp="\$(command -v "\$linker" 2>/dev/null)" || lp="" ;; esac
    while [ -n "\$lp" ] && [ -h "\$lp" ]; do
      l="\$(readlink "\$lp")"
      case "\$l" in /*) lp="\$l" ;; *) lp="\$(dirname "\$lp")/\$l" ;; esac
    done
    [ -z "\$lp" ] || [ ! -d "\$(dirname "\$lp")/../SDKs/MacOSX10.9.sdk" ] || { SDKROOT="\$(dirname "\$lp")/../SDKs/MacOSX10.9.sdk"; export SDKROOT; }
  fi
  if [ "\$named" = 1 ]; then
    set -- -C "linker=\$linker" -C link-arg=-mmacosx-version-min=$MACOS_MIN "\$@"
  elif [ "\$defer" = 1 ]; then
    set -- -C link-arg=-mmacosx-version-min=$MACOS_MIN "\$@"
  else
    set -- -C link-arg=-Wl,-force_load,"\$P" \\
      -C link-arg=-mmacosx-version-min=$MACOS_MIN \\
      -C link-arg=-framework -C link-arg=CoreFoundation \\
      -C link-arg=-framework -C link-arg=Security \\
      -C link-arg=-framework -C link-arg=CoreServices \\
      -C link-arg=-lobjc "\$@"
  fi
  [ "\$first" = 0 ] || set -- "\$first" "\$@"
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
  _p="$1"; _clang="$2"; NT="${INSTALL_NAME_TOOL:-install_name_tool}"
  find "$_p/bin" "$_p/lib" -type f 2>/dev/null | while IFS= read -r f; do
    file "$f" 2>/dev/null | grep -q Mach-O || continue
    "${OTOOL:-otool}" -l "$f" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}' | while IFS= read -r rp; do
      case "$rp" in "$_clang"/*|"$WORK"/*) "$NT" -delete_rpath "$rp" "$f" 2>/dev/null || true ;; esac
    done
    rel="$(loader_rel "$_p" "$f")"
    "${OTOOL:-otool}" -l "$f" 2>/dev/null | grep -qF " $rel" || "$NT" -add_rpath "$rel" "$f" 2>/dev/null || true
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
    printf '#!/bin/sh\nexport DYLD_INSERT_LIBRARIES="%s/librecaulk-stage0.dylib"\nexport DYLD_FORCE_FLAT_NAMESPACE=1\nexec "%s/%s/bin/%s" "$@"\n' \
      "$1" "$2" "$_b" "$_b" > "$1/bin/$_b"
    chmod +x "$1/bin/$_b"
  done
}

# platform: on 10.9 without the Command Line Tools, lipo, otool, nm, strings, install_name_tool and
#           /usr/bin/clang are xcode-select stubs; clang-22 ships llvm- workalikes, and the compat guard
#           reads LIPO, OTOOL, NM and STRINGS. The build's clang-22 comes first, then the installed one;
#           MACHO_CC is a clang-22 only where its 10.9 SDK is in place
macho_tools() {
  _pin="$(tr -d ' \t\n' < "${CLANG_PIN_FILE:-/dev/null}" 2>/dev/null)" || _pin=""
  for _d in ${CLANGDIR:+"$CLANGDIR/bin"} ${_pin:+"${WORK_ROOT:-/nonexistent}"/work-*/clang-*-"$_pin"/bin} \
            /usr/local/mavergreen/clang22/bin; do
    [ -x "$_d/llvm-otool" ] || continue
    LIPO="$_d/llvm-lipo"; OTOOL="$_d/llvm-otool"; NM="$_d/llvm-nm"; STRINGS="$_d/llvm-strings"
    INSTALL_NAME_TOOL="$_d/llvm-install-name-tool"
    [ -d "$_d/../SDKs/MacOSX10.9.sdk" ] && MACHO_CC="${MACHO_CC:-$_d/clang}"
    break
  done
  LIPO="${LIPO:-lipo}"; OTOOL="${OTOOL:-otool}"; NM="${NM:-nm}"; STRINGS="${STRINGS:-strings}"
  INSTALL_NAME_TOOL="${INSTALL_NAME_TOOL:-install_name_tool}"
  MACHO_CC="${MACHO_CC:-/usr/bin/clang}"
  export LIPO OTOOL NM STRINGS INSTALL_NAME_TOOL MACHO_CC
}

# spec: docs/superpowers/handoffs/plan3a-ledger.md, the Task 10 proof 2 ruling -- a cross-hosted
#       install leaves rustc's own proc-macro dylibs in lib/; nothing links them
prune_proc_macro_dylibs() {
  for _d in "$1"/lib/*.dylib; do
    [ -f "$_d" ] && [ ! -h "$_d" ] || continue
    "${NM:-nm}" -gU "$_d" 2>/dev/null | grep -q '__rustc_proc_macro_decls_' && rm -f "$_d"
  done
  return 0
}

stage_stamp() {
  printf 'variant=%s\nrust=%s\nclang=%s\nrecaulk=%s\nmake=%s\n' \
    "$1" "$RUST_VERSION" "$(tr -d ' \t\n' < "$CLANG_PIN_FILE")" "$RECAULK_VERSION" "$MAKE_VERSION"
  for _f in "$REPO_ROOT/build/lib-rust.sh" "$REPO_ROOT/build/build-$1.sh"; do
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
    _t="$(file "$_f")"
    case "$_t" in *Mach-O*executable*|*Mach-O*"dynamically linked shared library"*) : ;; *) continue ;; esac
    _a="$("${LIPO:-lipo}" -info "$_f" 2>"$_gd.err" | sed -n 's/.*architecture: //p; s/.* are: //p' | sed 's/ *$//')"
    [ -n "$_a" ] || { echo "FATAL: ${LIPO:-lipo} -info names no arch for $_t" >&2; cat "$_gd.err" >&2; exit 1; }
    printf '%s\n' "$_f" >> "$_gd/$(printf '%s' "$_a" | tr ' ' '+')"
  done || { rm -rf "$_gd" "$_gd.err"; return 1; }
  rm -f "$_gd.err"
  [ -n "$(ls "$_gd")" ] || { echo "FATAL: no Mach-O under $1 -- nothing guarded" >&2; rm -rf "$_gd"; return 1; }
  _rc=0
  for _l in "$_gd"/*; do
    tr '\n' '\0' < "$_l" | MAVERICKS_ALLOW_ARCHS="$(basename "$_l" | tr '+' ' ')" \
      xargs -0 sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" || _rc=1
  done
  rm -rf "$_gd"; return $_rc
}
