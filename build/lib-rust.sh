#!/bin/sh
# Sourced helpers for the rust build. Requires versions.sh already sourced (RUST_VERSION, TARGET_TRIPLE,
# WORK, MACOS_MIN). Callers pass the clang-22 prefix, the polyfill .a, the src tree, and the DESTDIR
# staging prefix.

write_bootstrap_toml() {
  _src="$1"; _prefix="$2"; _build="$3"; _host="$4"; _clang="$5"; _stage0="${6:-}"
  _py="$(command -v python3 || echo /opt/pkg/bin/python3)"
  _cm="${SHIPYARD_CMAKE:-$(command -v shipyard-cmake || echo /usr/local/mavergreen/bin/shipyard-cmake)}"
  if [ "$_host" = "$TARGET_TRIPLE" ]; then _targets="\"$TARGET_TRIPLE\""; else _targets="\"$_host\", \"$TARGET_TRIPLE\""; fi
  case "$_build$_host" in *aarch64*) _llvm_targets="AArch64;X86" ;; *) _llvm_targets="X86" ;; esac
  {
    printf '[build]\nbuild = "%s"\nhost = ["%s"]\ntarget = [%s]\n' "$_build" "$_host" "$_targets"
    if [ -n "$_stage0" ]; then
      printf 'rustc = "%s/bin/rustc"\ncargo = "%s/bin/cargo"\nlocal-rebuild = true\n' "$_stage0" "$_stage0"
    fi
    cat <<EOF
python = "$_py"
cmake = "$_cm"
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

write_x86_cmake_toolchain() {
  printf 'set(CMAKE_OSX_SYSROOT "%s")\nset(CMAKE_OSX_DEPLOYMENT_TARGET "%s")\nset(CMAKE_OSX_ARCHITECTURES "x86_64")\n' \
    "$2" "$MACOS_MIN" > "$1"
}

# augment_shim <poly_a> <clangdir>
# Compile EVERY build/polyfill-*.c into the fetched legacy-support archive, then install that archive as
# the one clang-22 auto-links. Each polyfill-*.c back-fills 10.9-missing symbols the family authors
# itself (ccrandom: std's entropy source; dispatch: dispatch2 symbols ctrlc links but never calls). Two
# jobs, deliberately in one place:
#
#   1. std/rustc do not link for 10.9 without these (see each build/polyfill-*.c header). Adding them to
#      the .a rather than passing stray .o's keeps ONE answer to "what backfills 10.9", and makes the
#      eventual move to mavericks-compat a deletion rather than a redesign.
#   2. It makes MLS_VERSION authoritative. clang-22's .pkg bundles its OWN shim copy, and clang.cfg names
#      that copy (<CFGDIR>/../lib/libMacportsLegacySupport.a) -- so without this, the bundled copy (not
#      the pinned one) is what every target link resolves against. Overwriting it closes that drift.
#
# Adding a new back-fill = drop a new build/polyfill-*.c; no code change here. Idempotent:
# fetch-legacy-support.sh re-extracts a pristine .a each run and `ar r` replaces members. Compiling via
# clang-22 (not the host clang) is what makes each object x86_64/10.9 (its clang.cfg supplies target,
# min-version, SDK). Fails loudly BEFORE a ~50-min build's link if a load-bearing symbol is missing.
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

# wrap_rustc_cross <installed_prefix>
# Bundle the polyfill into the toolchain and replace bin/rustc with a /bin/sh wrapper that adds the
# 10.9 back-fill link-args ONLY when the invocation targets x86_64-apple-darwin. The real compiler
# moves to rustc.bin. Idempotent (skips if bin/rustc is already the shell wrapper). The polyfill .a
# must already be copied to <prefix>/lib/rustlib/<target>/lib/libMacportsLegacySupport.a.
#
# Two of the link-args are subtler than they look, and BOTH are required to cross-link on a modern
# host. Naming the archive alone (the original form) is not enough:
#
#   -Wl,-force_load  A plain archive on the link line contributes only members that resolve a symbol
#                    still undefined WHEN THE LINKER REACHES IT. rustc emits -lSystem *before* our
#                    -C link-args, so on a modern host libSystem -- which HAS clock_gettime since
#                    10.12 -- already satisfied it and the archive was never consulted: the symbol
#                    stayed an UNDEFINED IMPORT of a function absent from real 10.9. (Building ON 10.9
#                    hides this, because there libSystem genuinely lacks the symbol and the archive
#                    does get pulled -- which is why the rule inherited from native-bootstrap/rust.sh
#                    looked correct.) force_load pulls the members unconditionally, so they are
#                    DEFINED in the output and the compat guard's REQUIRE_DEFINED check passes.
#   -mmacosx-version-min  rustc hard-clamps x86_64-apple-darwin to a 10.12 deployment target
#                    (os_minimum_deployment_target: MacOs => (10,12,0), then version.max(min) -- so
#                    MACOSX_DEPLOYMENT_TARGET cannot lower it) and passes -mmacosx-version-min=10.12.0
#                    to the linker driver. Ours lands after rustc's, and last wins, so the output gets
#                    LC_VERSION_MIN_MACOSX 10.9 as assert_binary_compatible.sh requires.
#
# Both are plain link-args, so the wrapper stays relocatable and still needs no clang-22 and no
# absolute path -- the property the design spec asks for.
wrap_rustc_cross() {
  _p="$1"
  [ "$(head -c2 "$_p/bin/rustc" 2>/dev/null)" = '#!' ] && return 0
  mv "$_p/bin/rustc" "$_p/bin/rustc.bin"
  cat > "$_p/bin/rustc" <<EOF
#!/bin/sh
# Auto-link the 10.9 back-fill polyfill so std's post-10.9 API references (clock_gettime, ...) resolve
# on 10.9 with any linker, but ONLY when producing an x86_64-apple-darwin artifact -- an arm64 host
# build script / proc-macro must not pull an x86_64 archive. Path is relative to this wrapper.
S="\$(cd "\$(dirname "\$0")" >/dev/null 2>&1 && pwd)"
P="\$S/../lib/rustlib/$TARGET_TRIPLE/lib/libMacportsLegacySupport.a"
prev=""; wants=0
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

# relocate_prefix <installed_prefix> <clangdir>
# Bundle clang-22's libc++/libc++abi/libunwind into <prefix>/lib and rewrite every Mach-O's repo/clang
# absolute rpath to a @loader_path-relative one -> <prefix>/lib. Uses the SYSTEM install_name_tool
# (llvm-install-name-tool crashes standalone). Ported from native-bootstrap/rust.sh relocate().
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

# wrap_rustc_native <installed_prefix>
# The native variant's only target IS its host (x86_64/10.9), so EVERY link is the 10.9 target -- auto
# force_load the polyfill and clamp min-version UNCONDITIONALLY (the cross wrapper gates on --target
# because it also builds arm64 host artifacts; native has no other target). Same force_load + min-version
# reasoning as wrap_rustc_cross. Idempotent.
wrap_rustc_native() {
  _p="$1"
  [ "$(head -c2 "$_p/bin/rustc" 2>/dev/null)" = '#!' ] && return 0
  mv "$_p/bin/rustc" "$_p/bin/rustc.bin"
  cat > "$_p/bin/rustc" <<EOF
#!/bin/sh
# Native 10.9 rustc: host==target==x86_64/10.9, so link the 10.9 back-fill polyfill on every link.
S="\$(cd "\$(dirname "\$0")" >/dev/null 2>&1 && pwd)"
P="\$S/../lib/rustlib/$TARGET_TRIPLE/lib/libMacportsLegacySupport.a"
if [ -f "\$P" ]; then
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
