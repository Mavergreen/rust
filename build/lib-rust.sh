#!/bin/sh
# platform: host-agnostic
#   usage: . build/lib-rust.sh   (after build/versions.sh; needs TARGET_TRIPLE, MACOS_MIN, WORK)

write_bootstrap_toml() {
  _src="$1"; _prefix="$2"; _build="$3"; _host="$4"; _clang="$5"; _stage0="${6:-}"
  _py="$(command -v python3 || echo /opt/pkg/bin/python3)"
  if [ "$_host" = "$TARGET_TRIPLE" ]; then _targets="\"$TARGET_TRIPLE\""; else _targets="\"$_host\", \"$TARGET_TRIPLE\""; fi
  case "$_build$_host" in *aarch64*) _llvm_targets="AArch64;X86" ;; *) _llvm_targets="X86" ;; esac
  # platform: bootstrap runs ccache as CMake's compiler launcher, and ccache cannot use LLVM 22's
  #           precompiled headers (built without -fno-pch-timestamp), so on Linux CI nothing caches
  _bcx=""; [ "$_build" != x86_64-unknown-linux-gnu ] || _bcx=', CMAKE_DISABLE_PRECOMPILE_HEADERS = "ON"'
  if [ -n "${ARM64_CC:-}" ] && [ -z "${ARM64_CXX:-}" ]; then
    echo "FATAL: ARM64_CC compiles C for aarch64-apple-darwin, and ARM64_CXX, its C++, is unset" >&2
    return 1
  fi
  if [ "$_build" = x86_64-unknown-linux-gnu ] && { [ -z "${LINUX_HOST_CC:-}" ] || [ -z "${LINUX_HOST_CXX:-}" ]; }; then
    echo "FATAL: a Linux build triple compiles with LINUX_HOST_CC and LINUX_HOST_CXX (linux_host_compilers), and one is unset" >&2
    return 1
  fi
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
    # platform: built on 10.9 itself, bootstrap's own build scripts compile and link at the 10.9 floor
    #           with stage0, the unpatched prebuilt, whose minimum is 10.12 (patch 0003 lowers only
    #           ours); rustc and clang++ warn about it, and bootstrap denies warnings; revisit when
    #           stage0 is a rustc whose x86_64 macOS minimum is 10.9
    if [ "$_build" = "$TARGET_TRIPLE" ]; then printf 'deny-warnings = false\n'; fi
    # platform: the source tarball's dist profile compresses debuginfo with zlib, which bootstrap
    #           applies to non-Apple targets only, and clang22's ld.lld has no zlib
    if [ "$_build" = x86_64-unknown-linux-gnu ]; then printf 'compress-debuginfo = "off"\n'; fi
    cat <<EOF
channel = "stable"

[llvm]
download-ci-llvm = false
ninja = true
targets = "$_llvm_targets"
libzstd = false
build-config = { CMAKE_IGNORE_PREFIX_PATH = "/opt/pkg;/opt/homebrew;/usr/local;/opt/local;/sw", LLVM_ENABLE_ZSTD = "OFF", LLVM_ENABLE_LIBXML2 = "OFF", LLVM_ENABLE_LIBEDIT = "OFF"$_bcx }
EOF
    # platform: rustc_llvm links a Linux LLVM with -lstdc++, the runner's, unless use-libcxx; the build
    #           triple's c++ then resolves -lc++ to the host libc++ it compiled LLVM against
    if [ "$_build" = x86_64-unknown-linux-gnu ]; then printf 'use-libcxx = true\n'; fi
    cat <<EOF

[target.$TARGET_TRIPLE]
cc = "$_clang/bin/clang"
cxx = "$_clang/bin/clang++"
ar = "$_clang/bin/llvm-ar"
ranlib = "$_clang/bin/llvm-ranlib"
linker = "$_clang/bin/clang++"
EOF
    # platform: rustc's x86_64-apple-darwin default is 10.9 (patch 0003), but stage0's is 10.12 and a
    #           MACOSX_DEPLOYMENT_TARGET set higher would raise a link; since 22.1.8-mavericks.8
    #           clang-22's cfgs let a later version win, and a -C link-arg comes after rustc's own
    printf 'rustflags = ["-Clink-arg=-mmacosx-version-min=%s"]\n' "$MACOS_MIN"
    if [ "$_build" = x86_64-unknown-linux-gnu ]; then
      printf '\n[target.x86_64-unknown-linux-gnu]\ncc = "%s"\ncxx = "%s"\nar = "%s/bin/llvm-ar"\nranlib = "%s/bin/llvm-ranlib"\nlinker = "%s"\n' \
        "$LINUX_HOST_CC" "$LINUX_HOST_CXX" "$_clang" "$_clang" "$LINUX_HOST_CXX"
    fi
    if [ -n "${ARM64_LINKER:-}" ]; then
      printf '\n[target.aarch64-apple-darwin]\n'
      if [ -n "${ARM64_CC:-}" ]; then
        printf 'cc = "%s"\ncxx = "%s"\nar = "%s/bin/llvm-ar"\nranlib = "%s/bin/llvm-ranlib"\n' \
          "$ARM64_CC" "$ARM64_CXX" "$_clang" "$_clang"
      fi
      printf 'linker = "%s"\n' "$ARM64_LINKER"
    fi
  } > "$_src/bootstrap.toml"
}

# platform: clang22's Linux archive ships a libc++ for Darwin targets only, so a Linux build triple's C++
#           links shipyard's host libc++, built by clang22 from the llvm-project release clang22 is, and
#           with the libgcc runtime that libc++abi was built for
# platform: clang targets core2 for x86_64 macOS and plain x86-64 for Linux; the build triple compiles for
#           core2, so no code path keys on the build machine's CPU (nodejs-24 R3)
# platform: a flag only a link reads draws -Wunused-command-line-argument from a compile, and CMake's
#           flag checks read that warning as a missing flag; a query (--version, -print-*) links nothing
# platform: a Linux build exports SDKROOT for rustc's Apple links (pin_linux_build_sdk), and the build
#           triple's C and C++ must not see the 10.9 SDK
# platform: with llvm.use-libcxx rustc_llvm links -lc++, which must find the host libc++.a
# platform: rustc links with -nodefaultlibs, which leaves -rtlib and --unwindlib unused, and bootstrap
#           denies the linker warning (linker_messages)
_print_link_scan() {
  printf 'link=yes\nfor a do case "$a" in -c|-E|-S|-M|-MM|-fsyntax-only|--version|-dumpversion|-dumpmachine|-print-*) link=no ;; esac; done\n'
}

_write_linux_host_compiler() {
  {
    printf '#!/bin/sh\nunset SDKROOT\n'
    _print_link_scan
    printf '[ "$link" = no ] || exec %s %s -fuse-ld=lld -rtlib=libgcc --unwindlib=libgcc -Wno-unused-command-line-argument %s "$@" %s\n' "$2" "$3" "$4" "$5"
    printf 'exec %s %s "$@"\n' "$2" "$3"
  } > "$1"
  chmod +x "$1"
}

linux_host_compilers() {
  [ "$(uname -s)" = Linux ] || return 0
  _lcxx="$(sh "$SHIPYARD_SCRIPTS/fetch_host_libcxx.sh" "$CLANG_PIN_DIR" "$1")" \
    || { echo "FATAL: fetch_host_libcxx.sh gave no host libc++ for $1" >&2; return 1; }
  for _f in lib/libc++.a lib/libc++abi.a include/c++/v1/__config_site; do
    [ -f "$_lcxx/$_f" ] || { echo "FATAL: the host libc++ at $_lcxx has no $_f" >&2; return 1; }
  done
  _d4="--no-default-config --target=x86_64-unknown-linux-gnu -march=core2"
  mkdir -p "$WORK/linux-host"
  _write_linux_host_compiler "$WORK/linux-host/cc" "'$1/bin/clang'" "$_d4" "" ""
  _write_linux_host_compiler "$WORK/linux-host/c++" "'$1/bin/clang++'" "$_d4 -nostdinc++ -isystem '$_lcxx/include/c++/v1'" \
    "-nostdlib++ -L'$_lcxx/lib'" "'$_lcxx/lib/libc++.a' '$_lcxx/lib/libc++abi.a' -lpthread"
  LINUX_HOST_CC="$WORK/linux-host/cc"; LINUX_HOST_CXX="$WORK/linux-host/c++"; export LINUX_HOST_CC LINUX_HOST_CXX
}

# spec: docs/superpowers/handoffs/plan3a-ledger.md, the Task 3 cmake ruling -- bootstrap 1.95
#       has no [build] cmake key; its sanity check and the cmake crate run `cmake` from PATH ($CMAKE)
# platform: shipyard-cmake is a Mac pkg; on Linux the runner's cmake configures, and build-info records it
cmake_shim_dir() {
  if [ "$(uname -s)" = Linux ]; then
    _cm="$(command -v cmake)" || { echo "FATAL: no cmake on PATH" >&2; return 1; }
  else
    _cm="${SHIPYARD_CMAKE:-$(command -v shipyard-cmake || echo /usr/local/mavergreen/bin/shipyard-cmake)}"
  fi
  [ -x "$_cm" ] || { echo "FATAL: no shipyard-cmake at $_cm" >&2; return 1; }
  mkdir -p "$1"; ln -sfn "$_cm" "$1/cmake"; printf '%s\n' "$1"
}

# spec: .superpowers/plans/2026-10-24-macos-runner-exit/06-rust-and-codex-cli.md Task 7 (shipyard) --
#       shipyard's toolchain file pins arm64's 11.3 SDK and 11.0 floor
# platform: MavericksToolchain.cmake finds clang22's Mach-O tools beside the compiler, which here is a
#           wrapper, so CMake would take PATH's, and a Linux runner's strip is GNU strip
write_arm64_cmake_toolchain() {
  [ -f "$2" ] || { echo "FATAL: no MavericksToolchain.cmake at $2" >&2; return 1; }
  {
    printf 'set(CMAKE_OSX_ARCHITECTURES "arm64")\n'
    for _p in INSTALL_NAME_TOOL=llvm-install-name-tool STRIP=llvm-strip NM=llvm-nm; do
      printf 'set(CMAKE_%s "%s/bin/%s" CACHE FILEPATH "clang22'"'"'s %s, which reads Mach-O")\n' "${_p%%=*}" "$3" "${_p#*=}" "${_p#*=}"
    done
    printf 'include("%s")\n' "$2"
  } > "$1"
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

# platform: with no SDKROOT rustc runs xcrun for every Apple link's SDK, and a Linux host has no xcrun;
#           rustc reads SDKROOT only for an Apple target, and the build triple's cc and c++ drop it
# platform: cargo splits target rustflags on spaces
pin_linux_build_sdk() {
  [ "$1" = x86_64-unknown-linux-gnu ] || return 0
  case "$2" in *" "*) echo "FATAL: the SDK path '$2' has a space, which cargo would split in target rustflags" >&2; return 1 ;; esac
  SDKROOT="$2"
  CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS="-C link-arg=-isysroot -C link-arg=$2"
  CFLAGS_x86_64_apple_darwin="-isysroot $2 -mmacosx-version-min=$MACOS_MIN"
  CXXFLAGS_x86_64_apple_darwin="$CFLAGS_x86_64_apple_darwin"
  export SDKROOT CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS CFLAGS_x86_64_apple_darwin CXXFLAGS_x86_64_apple_darwin
}

# platform: clang-22's clang.cfg looks for <bin>/../SDKs/MacOSX10.9.sdk; its pkg ships SDKs as a link
#           into Longboat's sdk109, which dangles in a prefix copied out of the pkg
populate_clang_sdk() {
  [ -h "$1/SDKs" ] && rm -f "$1/SDKs"
  mkdir -p "$1/SDKs"; ln -sfn "$2" "$1/SDKs/MacOSX10.9.sdk"
}

# spec: .superpowers/plans/2026-10-24-macos-runner-exit/06-rust-and-codex-cli.md D5 (shipyard) --
#       arm64 Darwin compiles and links run clang22 with no cfg, whose own is for x86_64 10.9
# platform: rustc passes -isysroot with $SDKROOT's SDK (the 10.9 one on a Linux build) or xcrun's, and
#           the last -isysroot wins, so the pinned 11.3 SDK and arm64 target follow the caller's arguments
# platform: clang22's own libc++ headers come before the SDK's, and are libc++ 22's, whose inline code calls
#           what macOS 11's libc++.dylib lacks; C++ reads the SDK's, as Apple's clang does
write_pinned_cc() {
  _pf="--no-default-config --target=arm64-apple-macos11.0"
  _lw=""
  if [ "${4:-clang}" = clang++ ]; then
    _pf="$_pf -nostdinc++ -isystem '$2/usr/include/c++/v1'"; _lw=" -Wno-unused-command-line-argument"
  fi
  {
    printf '#!/bin/sh\n'
    _print_link_scan
    printf '[ "$link" = no ] || exec %s "$@" %s -fuse-ld=lld%s -isysroot %s\n' "'$3/bin/${4:-clang}'" "$_pf" "$_lw" "'$2'"
    printf 'exec %s "$@" %s -isysroot %s\n' "'$3/bin/${4:-clang}'" "$_pf" "'$2'"
  } > "$1"
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
# platform: a Linux runner's own make is GNU make 4; the family's make is a Mac pkg
fetch_make() {
  if [ "$(uname -s)" = Linux ]; then
    _mk="$(command -v make)" || { echo "FATAL: no make on PATH" >&2; return 1; }
    case "$("$_mk" --version 2>/dev/null | sed -n 1p)" in
      "GNU Make 4."*) dirname "$_mk"; return 0 ;;
      *) echo "FATAL: $_mk is not GNU Make 4 (cargo's vendored OpenSSL needs it)" >&2; return 1 ;;
    esac
  fi
  _mk="$(sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" make "$MAKE_VERSION" "$WORK/make")" || return 1
  [ -x "$_mk/bin/make" ] || { echo "FATAL: make $MAKE_VERSION has no bin/make" >&2; return 1; }
  printf '%s\n' "$_mk/bin"
}

# platform: fetch_clang22.sh can answer with an installed clang22 or a cache other products share, and
#           the build writes rust's Recaulk and the 10.9 SDK link into its clang22, so it works on a copy
#           in $WORK, made once per pin
clang_work_copy() {
  _cw="$WORK/clang22-$(tr -d ' \t\n' < "$CLANG_PIN_FILE")"
  if [ ! -x "$_cw/bin/clang" ]; then
    for _old in "$WORK"/clang22-*; do [ "$_old" = "$_cw" ] || rm -rf "$_old"; done
    rm -rf "$_cw" "$_cw.part"; mkdir -p "$WORK"
    cp -pR "$1" "$_cw.part" && mv "$_cw.part" "$_cw" || { rm -rf "$_cw.part"; echo "FATAL: could not copy $1 to $_cw" >&2; return 1; }
  fi
  printf '%s\n' "$_cw"
}

# platform: clang-22's clang.cfg links <CFGDIR>/../lib/librecaulk.a into everything it links, rustc and
#           cargo included; overwriting it keeps build-info's recaulk= true of every shipped binary
install_recaulk_into_clang() { cp -f "$1" "$2/lib/librecaulk.a"; }

# platform: rustc puts -lSystem before -C link-args, and a modern SDK's libSystem exports clock_gettime
# platform: rustc's x86_64-apple-darwin default is 10.9 (patch 0003), and a MACOSX_DEPLOYMENT_TARGET
#           set higher would raise a link; the last -mmacosx-version-min on the line wins
# platform: -force_load takes every member of librecaulk.a, its C++ catch rules among them, and those
#           call 10.9's /usr/lib/libc++abi.dylib
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
optout=0
# platform: rustc stops after printing for every --print request but link-args and native-static-libs
printed() { case "\$1" in link-args|native-static-libs) : ;; *) nolink=1 ;; esac; }
scan() {
  case "\$1" in -V|-vV|-Vv|--version|-h|--help|--explain|--explain=*) nolink=1 ;; --print=*) printed "\${1#--print=}" ;; esac
  [ "\$prev" != "--print" ] || printed "\$1"
  [ "\$prev" = "--target" ] && [ "\$1" = "$TARGET_TRIPLE" ] && wants=1
  case "\$1" in --target="$TARGET_TRIPLE") wants=1 ;; esac
  case "\$prev" in -C|--codegen) case "\$1" in linker=*) linker="\${1#linker=}" ;; esac ;; esac
  case "\$1" in -Clinker=*) linker="\${1#-Clinker=}" ;; --codegen=linker=*) linker="\${1#--codegen=linker=}" ;; esac
  # platform: rustc reads _ and - alike in a -C option's name
  case "\$prev" in -C|--codegen) case "\$1" in linker[-_]flavor=*) flavor=1 ;; esac ;; esac
  case "\$1" in -Clinker[-_]flavor=*|--codegen=linker[-_]flavor=*) flavor=1 ;; esac
  la=""
  case "\$prev" in -C|--codegen) case "\$1" in link[-_]arg=*|link[-_]args=*) la="\$1" ;; esac ;; esac
  case "\$1" in -Clink[-_]arg=*|-Clink[-_]args=*) la="\${1#-C}" ;; --codegen=link[-_]arg=*|--codegen=link[-_]args=*) la="\${1#--codegen=}" ;; esac
  case "\$la" in link_arg=*) la="link-arg=\${la#link_arg=}" ;; link_args=*) la="link-args=\${la#link_args=}" ;; esac
  case "\$la" in
    link-arg=--no-default-config) optout=1 ;;
    link-args=*) set -f; for w in \${la#link-args=}; do [ "\$w" != --no-default-config ] || optout=1; done; set +f ;;
  esac
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
# spec: INGREDIENTS.md "How the back-fill reaches a 10.9 binary" -- --no-default-config on a link
#       means the toolchain adds nothing; the caller supplies linker, SDK, minimum and back-fills
[ "\$wants" = 1 ] && [ "\$optout" = 1 ] && exec "\$S/$_tool.bin" "\$@"
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
  # platform: rustc on a Linux host passes the linker no -isysroot, and clang22's cfg then names its own
  #           SDKs/MacOSX10.9.sdk, which its Linux archive lacks; a gated wrapper hands on the caller's SDKROOT
  if [ $_default = 0 ] && [ -n "\${SDKROOT:-}" ]; then
    set -- -C link-arg=-isysroot -C "link-arg=\$SDKROOT" "\$@"
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
      -C link-arg=-lobjc -C link-arg=-lc++abi "\$@"
  fi
  [ "\$first" = 0 ] || set -- "\$first" "\$@"
fi
exec "\$S/$_tool.bin" "\$@"
EOF
  chmod +x "$_p/bin/$_tool"
}

wrap_rustc() { wrap_linking_tool "$1" rustc "$2"; }

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
# platform: Linux has no Mach-O tools and no /usr/bin/clang, so there clang22's are the only ones
macho_tools() {
  if [ "$(uname -s)" = Linux ]; then
    [ -n "${CLANGDIR:-}" ] || { echo "FATAL: on Linux macho_tools reads clang22's Mach-O tools, and CLANGDIR is unset" >&2; return 1; }
    set -- "$CLANGDIR/bin"
  else
    _pin="$(tr -d ' \t\n' < "${CLANG_PIN_FILE:-/dev/null}" 2>/dev/null)" || _pin=""
    set -- ${CLANGDIR:+"$CLANGDIR/bin"} ${_pin:+"${WORK_ROOT:-/nonexistent}"/work-*/clang22-"$_pin"/bin} \
           /usr/local/mavergreen/clang22/bin
  fi
  _found=""
  for _d do
    [ -x "$_d/llvm-otool" ] || continue
    _found="$_d"
    LIPO="$_d/llvm-lipo"; OTOOL="$_d/llvm-otool"; NM="$_d/llvm-nm"; STRINGS="$_d/llvm-strings"
    INSTALL_NAME_TOOL="$_d/llvm-install-name-tool"
    [ -d "$_d/../SDKs/MacOSX10.9.sdk" ] && MACHO_CC="${MACHO_CC:-$_d/clang}"
    break
  done
  if [ "$(uname -s)" = Linux ]; then
    [ -n "$_found" ] || { echo "FATAL: $CLANGDIR/bin has no llvm-otool" >&2; return 1; }
    MACHO_CC="${MACHO_CC:-$CLANGDIR/bin/clang}"
  else
    LIPO="${LIPO:-lipo}"; OTOOL="${OTOOL:-otool}"; NM="${NM:-nm}"; STRINGS="${STRINGS:-strings}"
    INSTALL_NAME_TOOL="${INSTALL_NAME_TOOL:-install_name_tool}"
    MACHO_CC="${MACHO_CC:-/usr/bin/clang}"
  fi
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

# spec: .superpowers/plans/2026-10-24-macos-runner-exit/06-rust-and-codex-cli.md D7 (shipyard) -- the
#       Linux tarball runs on the family's glibc floor, clang-22's pinned base image
# platform: rustc's LLVM links the host libc++ statically (use-libcxx, linux_host_compilers), so a
#           shipped ELF loads glibc, libgcc_s and rust's own libraries, the last through an $ORIGIN
#           RUNPATH; ld.so searches DT_RPATH before LD_LIBRARY_PATH, so the tarball uses RUNPATH only
audit_linux_elf() {
  _ro="${CLANGDIR:?audit_linux_elf reads ELF with clang22, and CLANGDIR is unset}/bin/llvm-readobj"
  _al="$(mktemp "${TMPDIR:-/tmp}/audit-elf.XXXXXX")"
  find "$1/bin" "$1/lib" -type f 2>/dev/null > "$_al" || true
  _n=0; _bad=0; _or='$ORIGIN'
  while IFS= read -r _f; do
    [ "$(od -An -tx1 -N4 "$_f" 2>/dev/null | tr -d ' \n')" = 7f454c46 ] || continue
    _n=$((_n+1)); _rel="${_f#"$1"/}"
    _dyn="$("$_ro" --dynamic-table "$_f" 2>&1)" || { echo "$_rel: llvm-readobj cannot read it: $_dyn"; _bad=$((_bad+1)); continue; }
    _ok=1
    if printf '%s\n' "$_dyn" | grep -q ' RPATH '; then echo "$_rel has DT_RPATH, which outranks LD_LIBRARY_PATH; it wants RUNPATH"; _ok=0; fi
    _rp="$(printf '%s\n' "$_dyn" | sed -n 's/.* RUNPATH .*\[\(.*\)\]$/\1/p')"
    _oldifs="$IFS"; IFS=:
    for _e in $_rp; do
      case "$_e" in '$ORIGIN'|'$ORIGIN/'*) : ;; *) echo "$_rel: its RUNPATH names $_e, not a path from \$ORIGIN"; _ok=0 ;; esac
    done
    IFS="$_oldifs"
    for _lib in $(printf '%s\n' "$_dyn" | sed -n 's/.* NEEDED .*\[\(.*\)\]$/\1/p'); do
      case " libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libutil.so.1 libgcc_s.so.1 ld-linux-x86-64.so.2 " in
        *" $_lib "*) continue ;;
      esac
      _found=0; IFS=:
      for _e in $_rp; do
        case "$_e" in '$ORIGIN'*) [ ! -f "$(dirname "$_f")${_e#"$_or"}/$_lib" ] || _found=1 ;; esac
      done
      IFS="$_oldifs"
      [ "$_found" = 1 ] || { echo "$_rel needs $_lib, which neither glibc's floor nor its RUNPATH (${_rp:-none}) provides"; _ok=0; }
    done
    [ "$_ok" = 1 ] || _bad=$((_bad+1))
  done < "$_al"
  rm -f "$_al"
  echo "checked $_n ELF under $1: $_bad refused"
  [ "$_n" -gt 0 ] || { echo "no ELF under $1/{bin,lib} -- nothing audited"; return 1; }
  [ "$_bad" -eq 0 ]
}

_tool_version() { command -v "$1" >/dev/null 2>&1 || return 0; "$1" --version 2>&1 | sed -n 1p; }

record_build_tools() {
  # platform: a Mac's bare make and cmake are the Command Line Tools stubs, so a Mac records the pinned ones
  if [ "$(uname -s)" != Linux ] && { [ -z "${MAKE:-}" ] || [ -z "${CMAKE:-}" ]; }; then
    echo "FATAL: on a Mac record_build_tools records \$MAKE and \$CMAKE, and one is unset" >&2; return 1
  fi
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) _bh=x86_64-unknown-linux-gnu ;;
    Darwin/arm64) _bh=aarch64-apple-darwin ;;
    Darwin/x86_64) _bh=x86_64-apple-darwin ;;
    *) _bh="$(uname -sm)" ;;
  esac
  if [ "$(uname -s)" = Linux ]; then _libc="$(getconf GNU_LIBC_VERSION 2>/dev/null)" || _libc=""; else _libc="$(uname -sr)"; fi
  {
    printf 'build-host=%s\n' "$_bh"
    printf 'build-host-cmake=%s\n' "$(_tool_version "${CMAKE:-cmake}")"
    printf 'build-host-ninja=%s\n' "$(_tool_version "${NINJA:-ninja}")"
    printf 'build-host-make=%s\n' "$(_tool_version "${MAKE:-make}")"
    printf 'build-host-libc=%s\n' "$_libc"
    printf 'build-host-python=%s\n' "$(_tool_version python3)"
  } >> "$1"
}

# platform: a Mac has shasum and no sha256sum; a Linux runner has both, a minimal Linux image only sha256sum
_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'
}

stage_stamp() {
  printf 'variant=%s\nrust=%s\nclang=%s\nrecaulk=%s\nmake=%s\n' \
    "$1" "$RUST_VERSION" "$(tr -d ' \t\n' < "$CLANG_PIN_FILE")" "$RECAULK_VERSION" "$MAKE_VERSION"
  for _f in "$REPO_ROOT/build/lib-rust.sh" "$REPO_ROOT/build/build-$1.sh" "$REPO_ROOT"/patches/*.patch; do
    [ -f "$_f" ] || continue
    printf '%s %s\n' "$(_sha256 "$_f")" "${_f#"$REPO_ROOT"/}"
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

# platform: openssl-src stamps libcrypto's "built on" date from SOURCE_DATE_EPOCH, else the clock
export_source_date_epoch() {
  SOURCE_DATE_EPOCH="$(sh "$SHIPYARD_SCRIPTS/source-date-epoch.sh")"; export SOURCE_DATE_EPOCH
}
