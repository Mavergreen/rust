#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"; export TARGET_TRIPLE MACOS_MIN REPO_ROOT
. "$ROOT/build/lib-rust.sh"
t="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/wrapper.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }
mk() {
  mkdir -p "$t/$1/bin" "$t/$1/lib/rustlib/$TARGET_TRIPLE/lib"
  # platform: sh runs an exec'd file that has no #! line as a shell script (ENOEXEC fallback)
  printf 'echo "STUB $*"\n' > "$t/$1/bin/rustc"; chmod +x "$t/$1/bin/rustc"
  : > "$t/$1/lib/rustlib/$TARGET_TRIPLE/lib/libMacportsLegacySupport.a"
  wrap_rustc "$t/$1" "$2"
}
mk native always; mk cross gated

out="$("$t/native/bin/rustc" x.rs)"
case "$out" in "STUB -C link-arg=-Wl,-force_load,$t/native/bin/../lib/rustlib/$TARGET_TRIPLE/lib/libMacportsLegacySupport.a"*) : ;; *) fail "case 1 direct: $out" ;; esac

mkdir -p "$t/farm/bin" "$t/elsewhere"
ln -s "../../native/bin/rustc" "$t/farm/bin/rustc"
out="$(cd "$t/elsewhere" && "$t/farm/bin/rustc" x.rs 2>&1)" || true
case "$out" in STUB*force_load*"$t/native/bin/../lib/"*) : ;; *) fail "case 2 relative farm link from another cwd: the wrapper must resolve its REAL dir: $out" ;; esac

ln -s "$t/farm/bin/rustc" "$t/elsewhere/rustc2"
out="$(cd "$t/elsewhere" && PATH="$t/elsewhere:$PATH" rustc2 x.rs 2>&1)" || true
case "$out" in STUB*force_load*"$t/native/bin/../lib/"*) : ;; *) fail "case 3 PATH lookup through a two-link chain: $out" ;; esac

out="$("$t/cross/bin/rustc" --target=x86_64-apple-darwin x.rs)"
case "$out" in STUB*force_load*) : ;; *) fail "case 4 gated wrapper must accept --target=<triple>: $out" ;; esac
out="$("$t/cross/bin/rustc" --target aarch64-apple-darwin x.rs)"
case "$out" in *force_load*) fail "case 5 gated wrapper must not link the x86_64 shim into an arm64 artifact: $out" ;; esac

before="$(cat "$t/native/bin/rustc")"; wrap_rustc "$t/native" always
[ "$before" = "$(cat "$t/native/bin/rustc")" ] || fail "case 6 wrap_rustc must be idempotent"
mkdir -p "$t/cd/bin" "$t/cd/lib/rustlib/$TARGET_TRIPLE/lib"
printf 'echo "STUB $*"\n' > "$t/cd/bin/clippy-driver"; chmod +x "$t/cd/bin/clippy-driver"
: > "$t/cd/lib/rustlib/$TARGET_TRIPLE/lib/libMacportsLegacySupport.a"
wrap_linking_tool "$t/cd" clippy-driver always
[ -x "$t/cd/bin/clippy-driver.bin" ] || fail "case 7 clippy-driver moves to clippy-driver.bin"
out="$("$t/cd/bin/clippy-driver" /somewhere/bin/rustc --crate-type proc-macro x.rs)"
case "$out" in "STUB /somewhere/bin/rustc -C link-arg=-Wl,-force_load,"*) : ;; *) fail "case 7 under RUSTC_WORKSPACE_WRAPPER, cargo passes rustc's path first; the back-fill args go after it (cargo clippy on 10.9 left a proc-macro's _clock_gettime undefined): $out" ;; esac
out="$("$t/cd/bin/clippy-driver" x.rs)"
case "$out" in "STUB -C link-arg=-Wl,-force_load,"*) : ;; *) fail "case 8 clippy-driver called directly: $out" ;; esac
out="$("$t/cross/bin/rustc" --target x86_64-apple-darwin x.rs)"
case "$out" in STUB*force_load*) : ;; *) fail "case 9 gated wrapper must accept --target <triple> (space form): $out" ;; esac

mkdir -p "$t/real/bin" "$t/real/lib/rustlib/$TARGET_TRIPLE/lib" "$t/links"
printf 'echo "STUB $*"\n' > "$t/real/bin/rustc"; chmod +x "$t/real/bin/rustc"
: > "$t/real/lib/rustlib/$TARGET_TRIPLE/lib/libMacportsLegacySupport.a"
wrap_rustc "$t/real" always
ln -s "$t/real/bin" "$t/links/bin"
out="$("$t/links/bin/rustc" x.rs)"
case "$out" in STUB*force_load*"$t/real/bin/../lib/"*) : ;; *) fail "case 10 a bin/ reached through a directory symlink must resolve physically (cd -P): $out" ;; esac

mkdir -p "$t/noshim/bin"
printf 'echo "STUB $*"\n' > "$t/noshim/bin/rustc"; chmod +x "$t/noshim/bin/rustc"
wrap_rustc "$t/noshim" always
if out="$("$t/noshim/bin/rustc" x.rs 2>&1)"; then fail "case 11 a native rustc with no back-fill shim must fail, not link a binary that dies on 10.9: $out"; fi
case "$out" in *libMacportsLegacySupport.a*) : ;; *) fail "case 11 the error must name the missing shim: $out" ;; esac
echo "OK wrapper-test"
