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
targets = "X86"
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

# wrap_rustc_cross <installed_prefix>
# Bundle the polyfill into the toolchain and replace bin/rustc with a /bin/sh wrapper that adds the
# 10.9 back-fill link-args ONLY when the invocation targets x86_64-apple-darwin. The real compiler
# moves to rustc.bin. Idempotent (skips if bin/rustc is already the shell wrapper). The polyfill .a
# must already be copied to <prefix>/lib/rustlib/<target>/lib/libMacportsLegacySupport.a.
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
    -C link-arg="\$P" \\
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
