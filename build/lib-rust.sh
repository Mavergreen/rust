#!/bin/sh
# Sourced helpers for the rust build. Requires versions.sh already sourced (RUST_VERSION, TARGET_TRIPLE,
# WORK, MACOS_MIN). Callers pass the clang-22 prefix, the polyfill .a, the src tree, and the DESTDIR
# staging prefix.

# write_bootstrap_toml <src> <prefix> <clangdir>
# prefix is the FINAL install prefix (CROSS_PREFIX); DESTDIR handles staging at package time.
write_bootstrap_toml() {
  _src="$1"; _prefix="$2"; _clang="$3"; _py="$(command -v python3 || echo /usr/local/bin/python3)"
  cat > "$_src/bootstrap.toml" <<EOF
[build]
python = "$_py"
docs = false
extended = true
tools = ["cargo", "rustdoc"]
submodules = false
vendor = true
sanitizers = false
profiler = false
# NOTE: no [build] rustc/cargo -> x.py downloads its own pinned stage0 (arm64, runs natively on the
# runner). No DYLD injection: that trick in native-bootstrap/rust.sh exists only for a build ON 10.9.

[build.tool.cargo]
# 10.9's system OpenSSL 0.9.8 is too old -> build vendored OpenSSL with clang-22 (offline).
# 10.9's zlib 1.2.5 lacks z_const so curl-sys cannot build libcurl from source -> use system libcurl.
features = ["vendored-openssl", "curl/force-system-lib-on-osx"]

[install]
prefix = "$_prefix"
sysconfdir = "etc"

[rust]
channel = "stable"

[llvm]
download-ci-llvm = false
ninja = true
# BOTH backends, not just the 10.9 target's. X86 is what we cross-COMPILE FOR; AArch64 is what this
# toolchain RUNS ON, and --host aarch64-apple-darwin means stage1/stage2 rustc must codegen for arm64
# (its own std, build scripts, proc macros). Setting this key at all overrides bootstrap's default
# target list, so omitting AArch64 silently drops it: llvm-config reported "X86 AVR M68k CSKY Xtensa"
# and stage1 rustc ICE'd on --print=deployment-target with
# "could not create LLVM TargetMachine for triple: arm64-apple-macosx11.0.0".
targets = "AArch64;X86"
# Keep pkgsrc /opt/pkg (and any other package-manager prefix) OUT of the LLVM build. On a pkgsrc box
# cmake/ninja themselves come from /opt/pkg, and pkgsrc's cmake bakes /opt/pkg into find_library
# results (libzstd/libxml2/libedit) -- which would ship as absolute paths and fail
# tests/relocatable-test.sh. Mirror mavericks-clang's cross build (CMAKE_IGNORE_PREFIX_PATH + the
# optional deps OFF). libzstd is rust bootstrap's own knob; the rest go through build-config.
libzstd = false
build-config = { CMAKE_IGNORE_PREFIX_PATH = "/opt/pkg;/opt/homebrew;/usr/local;/opt/local;/sw", LLVM_ENABLE_ZSTD = "OFF", LLVM_ENABLE_LIBXML2 = "OFF", LLVM_ENABLE_LIBEDIT = "OFF" }

[target.$TARGET_TRIPLE]
cc = "$_clang/bin/clang"
cxx = "$_clang/bin/clang++"
ar = "$_clang/bin/llvm-ar"
ranlib = "$_clang/bin/llvm-ranlib"
linker = "$_clang/bin/clang++"
EOF
}

# augment_shim <poly_a> <clangdir>
# Add our 10.9 CCRandomGenerateBytes polyfill to the fetched legacy-support archive, then install that
# archive as the one clang-22 auto-links. Two jobs, deliberately in one place:
#
#   1. std does not link for 10.9 without CCRandomGenerateBytes (10.10+; see build/polyfill-ccrandom.c).
#      Adding it to the .a rather than passing a stray .o keeps ONE answer to "what backfills 10.9",
#      and makes the eventual move upstream a deletion rather than a redesign.
#   2. It makes MLS_VERSION actually authoritative. clang-22's .pkg bundles its OWN copy of the shim,
#      and clang.cfg names that copy (<CFGDIR>/../lib/libMacportsLegacySupport.a) -- so until now the
#      bundled copy, NOT the pinned one, is what every target link resolved against. The two are
#      byte-identical today (sha256 3a9142ce78f87d25..., 43152 bytes), so this changes nothing
#      immediately; it closes the drift hazard where bumping MLS_VERSION would silently have no
#      effect on the toolchain we ship.
#
# Idempotent: fetch-legacy-support.sh rm -rf's and re-extracts a pristine .a each run, and `ar r`
# replaces an existing member anyway. Compiling via clang-22 (not the host clang) is what makes the
# object x86_64/10.9 -- its clang.cfg supplies the target, the min-version and the 10.9 SDK.
augment_shim() {
  _poly="$1"; _clang="$2"
  _obj="$(dirname "$_poly")/polyfill-ccrandom.o"
  "$_clang/bin/clang" -c -o "$_obj" "$REPO_ROOT/build/polyfill-ccrandom.c"
  "$_clang/bin/llvm-ar" r "$_poly" "$_obj"
  # Fail loudly here rather than 30 minutes later at the std link.
  nm -g "$_poly" 2>/dev/null | grep -q ' T _CCRandomGenerateBytes$' \
    || { echo "FATAL: polyfill did not define _CCRandomGenerateBytes in $_poly" >&2; exit 1; }
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

# --- NATIVE variant (Plan 2): host==target==x86_64-apple-darwin, runs on real 10.9 -----------------

# write_bootstrap_toml_native <src> <prefix> <clangdir>
# Single-triple x86_64/10.9 build (run under Rosetta on an arm64 builder, or natively on 10.9). Unlike
# the cross config, clang-22 is the CORRECT host compiler too (it defaults to x86_64/10.9), and no
# AArch64 LLVM backend is needed (host==target==x86_64). No [build] rustc/cargo -> x.py downloads the
# pinned x86_64 stage0 (Rosetta runs it). Same /opt/pkg guard as the cross build.
write_bootstrap_toml_native() {
  _src="$1"; _prefix="$2"; _clang="$3"; _py="$(command -v python3 || echo /usr/local/bin/python3)"
  cat > "$_src/bootstrap.toml" <<EOF
[build]
build = "x86_64-apple-darwin"
host = ["x86_64-apple-darwin"]
target = ["x86_64-apple-darwin"]
python = "$_py"
docs = false
extended = true
tools = ["cargo", "rustdoc"]
submodules = false
vendor = true
sanitizers = false
profiler = false

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
targets = "X86"
libzstd = false
build-config = { CMAKE_IGNORE_PREFIX_PATH = "/opt/pkg;/opt/homebrew;/usr/local;/opt/local;/sw", LLVM_ENABLE_ZSTD = "OFF", LLVM_ENABLE_LIBXML2 = "OFF", LLVM_ENABLE_LIBEDIT = "OFF" }

[target.x86_64-apple-darwin]
cc = "$_clang/bin/clang"
cxx = "$_clang/bin/clang++"
ar = "$_clang/bin/llvm-ar"
ranlib = "$_clang/bin/llvm-ranlib"
linker = "$_clang/bin/clang++"
EOF
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
