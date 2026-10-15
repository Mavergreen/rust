#!/bin/sh
# platform: macOS-only -- installer, pkgutil and the installed toolchain; meant for real 10.9
#   usage: check-release-on-10.9.sh <version>
#          Run ON Mac OS X 10.9 after a release: downloads and verifies rust-<version>.pkg, installs it,
#          exercises the toolchain the way a user would, uninstalls it. One PASS/FAIL line per step;
#          exit 1 if any step failed. MAVERICKS_RELEASE_BASE overrides where the pkg and SHA256SUMS
#          come from (default: the version's GitHub release), e.g. file:///path for a rehearsal.
# spec: docs/superpowers/specs/2026-09-25-rust-plan3b-release-design.md decision 4
set -u
V="${1:-}"
[ -n "$V" ] || { echo "usage: check-release-on-10.9.sh <version>   (e.g. 1.95.0-mavericks.1)" >&2; exit 2; }
os="${MAVERICKS_CHECK_OS:-$(sw_vers -productVersion 2>/dev/null)}"
case "$os" in 10.9|10.9.*) : ;; *) echo "check-release-on-10.9.sh: run this on Mac OS X 10.9 (this is $os)" >&2; exit 2 ;; esac
base="${MAVERICKS_RELEASE_BASE:-https://github.com/Mavergreen/rust/releases/download/$V}"
w="$(mktemp -d "${TMPDIR:-/tmp}/rust-release-check.XXXXXX")"
bad=0; skips=0
step() {
  name="$1"; shift
  if ( "$@" ) > "$w/$name.log" 2>&1; then echo "PASS $name"; else
    echo "FAIL $name (log: $w/$name.log)"; tail -n 20 "$w/$name.log" | sed 's/^/    /'; bad=1
  fi
}
# platform: without the Command Line Tools xcode-select has no developer directory and /usr/bin/cc is
#           10.9's stub, which exists either way
has_clt() { xcode-select -p >/dev/null 2>&1; }
# spec: INGREDIENTS.md "The default linker" -- a step that needs the Command Line Tools runs
#       only where they are installed: shipyard vision area 18 D tests the CLT path on the maintainer's
#       box, not gated, and the family VM never has them (area 18 E)
cstep() {
  if has_clt; then step "$@"; else
    echo "SKIP $1 (no Command Line Tools: covered on the maintainer's 10.9 box (area 18 D))"; skips=$((skips + 1))
  fi
}
summary() {
  _s=""; [ "$skips" = 0 ] || _s=", $skips SKIPPED for want of the Command Line Tools"
  if [ "$bad" = 0 ]; then echo "ALL PASS $V$_s"; else echo "SOME FAILED $V$_s -- fix forward in the next -mavericks.N"; return 1; fi
}
# platform: runs from a bare checkout on a 10.9 box, the family VM included, where shipyard need not
#           be installed, so it downloads with 10.9's own curl rather than shipyard_curl
fetch() {
  curl -fsSL -o "$w/rust-$V.pkg" "$base/rust-$V.pkg" || return 1
  curl -fsSL -o "$w/SHA256SUMS" "$base/SHA256SUMS" || return 1
  n="$(grep -c " rust-$V.pkg\$" "$w/SHA256SUMS")"
  [ "$n" = 1 ] || { echo "rust-$V.pkg is listed $n times in SHA256SUMS"; return 1; }
  ( cd "$w" && grep " rust-$V.pkg\$" SHA256SUMS | shasum -a 256 -c - )
}
install_pkg() { sudo installer -pkg "$w/rust-$V.pkg" -target / && /usr/local/bin/mavergreen check; }
# platform: /usr/local/mavergreen/bin reaches PATH only through a login shell's paths.d
L() { /bin/zsh -lc "$1"; }
versions() { L 'rustc --version && cargo --version && cargo clippy --version && cargo fmt --version'; }
write_smoke() {
  printf '%s\n' 'use std::collections::HashMap; use std::time::SystemTime;' \
    'fn main() { let mut m = HashMap::new(); m.insert("mavericks", 109); let _ = SystemTime::now();' \
    '  let n = std::thread::spawn(|| 42).join().unwrap(); println!("smoke {:?} {}", m.get("mavericks"), n); }' > "$w/smoke.rs"
}
stress() {
  write_smoke && L "cd '$w' && rustc smoke.rs -o smoke" && [ "$("$w/smoke")" = 'smoke Some(109) 42' ]
}
explicit_cc() {
  write_smoke && L "cd '$w' && rustc -C linker=cc smoke.rs -o smoke-cc" && [ "$("$w/smoke-cc")" = 'smoke Some(109) 42' ]
}
crates_io() { L "cd '$w' && cargo new -q dep && cd dep && cargo add -q itoa@1 && cargo build -q"; }
write_ws() {
  mkdir -p "$w/ws/app/src" "$w/ws/pm/src"
  printf '[workspace]\nmembers = ["app", "pm"]\nresolver = "2"\n' > "$w/ws/Cargo.toml"
  printf '[package]\nname = "pm"\nversion = "0.1.0"\nedition = "2021"\n[lib]\nproc-macro = true\n' > "$w/ws/pm/Cargo.toml"
  printf '%s\n' 'use proc_macro::TokenStream;' '#[proc_macro]' \
    'pub fn answer(_: TokenStream) -> TokenStream { let m: std::collections::HashMap<u8, u8> = std::collections::HashMap::new(); let _ = std::time::Instant::now(); format!("{}", 42 + m.len()).parse().unwrap() }' \
    > "$w/ws/pm/src/lib.rs"
  printf '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\npm = { path = "../pm" }\n[lib]\nname = "app_doc"\npath = "src/lib.rs"\n' > "$w/ws/app/Cargo.toml"
  printf '%s\n' 'fn main() { let m: std::collections::HashMap<u8, u8> = std::collections::HashMap::new(); let _ = std::time::Instant::now(); println!("cargo:rustc-env=BUILT={}", m.len()); }' > "$w/ws/app/build.rs"
  printf '%s\n' 'fn main() { println!("{} {}", pm::answer!(), env!("BUILT")); }' > "$w/ws/app/src/main.rs"
  printf '%s\n' '/// ```' '/// assert_eq!(app_doc::seven(), 7);' '/// ```' \
    'pub fn seven() -> u8 { let _m: std::collections::HashMap<u8, u8> = std::collections::HashMap::new(); let _ = std::time::Instant::now(); 7 }' \
    > "$w/ws/app/src/lib.rs"
}
clippy_ws() {
  write_ws && L "cd '$w/ws' && cargo clippy -q && cargo build -q && [ \"\$(./target/debug/app)\" = '42 0' ] && cargo test -q --doc -p app"
}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MG="${MAVERICKS_CHECK_PREFIX:-/usr/local/mavergreen}"
C22="$MG/clang22"
gh_pkg() {
  _repo="$1"; _tag="$2"; shift 2
  _rb="https://github.com/Mavergreen/$_repo/releases/download/$_tag"
  curl -fsSL -o "$w/$_repo-SHA256SUMS" "$_rb/SHA256SUMS" || return 1
  for _a in "$@"; do
    grep -q " $_a\$" "$w/$_repo-SHA256SUMS" || continue
    curl -fsSL -o "$w/$_a" "$_rb/$_a" || return 1
    ( cd "$w" && grep " $_a\$" "$_repo-SHA256SUMS" | shasum -a 256 -c - ) >&2 || return 1
    echo "$w/$_a"; return 0
  done
  echo "none of $* is listed in $_rb/SHA256SUMS" >&2; return 1
}
clang22() {
  if [ -x "$C22/bin/clang++" ]; then
    [ -d "$C22/SDKs/MacOSX10.9.sdk" ] && return 0
    echo "clang22 is installed without its 10.9 SDK: run sudo longboat install 10.9"; return 1
  fi
  if [ ! -d "$MG/longboat" ]; then
    lb_tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/Mavergreen/longboat/releases/latest)"
    lb_tag="${lb_tag##*/}"
    lb="$(gh_pkg longboat "$lb_tag" "longboat-$lb_tag.pkg")" || return 1
    sudo installer -pkg "$lb" -target / || return 1
    : > "$w/installed-longboat"
  fi
  if [ ! -d "$MG/sdk109" ]; then
    sudo "$MG/bin/longboat" install 10.9 || return 1
    : > "$w/installed-sdk109"
  fi
  ct="$(tr -d ' \t\n' < "$ROOT/components/clang/version")"
  cp="$(gh_pkg clang-22 "$ct" "mavericks-clang-22-native-$ct.pkg" "clang-22-native-$ct.pkg")" || return 1
  sudo installer -pkg "$cp" -target / || return 1
  : > "$w/installed-clang22"
  [ -x "$C22/bin/clang++" ] && [ -d "$C22/SDKs/MacOSX10.9.sdk" ]
}
# spec: INGREDIENTS.md "How the back-fill reaches a 10.9 binary" -- with no SDKROOT, the wrapper hands
#       rustc an explicit clang22's own 10.9 SDK, which minos-sdk then requires
link_clang22() {
  write_smoke && L "cd '$w' && rm -rf c22 && cargo new -q c22 && cp '$w/smoke.rs' c22/src/main.rs && cd c22 && unset SDKROOT && CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER='$C22/bin/clang++' cargo build -q" \
    && [ "$("$w/c22/target/debug/c22")" = 'smoke Some(109) 42' ]
}
link_clang22_build_rs() {
  write_ws && L "cd '$w/ws' && cargo clean -q && unset SDKROOT && CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER='$C22/bin/clang++' cargo build -q" \
    && [ "$("$w/ws/target/debug/app")" = '42 0' ]
}
minos_sdk() {
  set -- "$w/smoke" "$w/c22/target/debug/c22" "$w/ws/target/debug/app"
  ! has_clt || [ ! -f "$w/smoke-cc" ] || set -- "$w/smoke-cc" "$@"
  for b in "$@"; do
    [ -f "$b" ] || { echo "$b was never built"; return 1; }
    vm="$("$C22/bin/llvm-otool" -l "$b" | awk '/LC_VERSION_MIN_MACOSX/{p=1} p&&/version/{v=$2} p&&/sdk/{print v, $2; exit}')"
    [ "$vm" = "10.9 10.9" ] || { echo "$b records minos/sdk '$vm', not '10.9 10.9'"; return 1; }
  done
}
uninstall_clang22() {
  _rc=0
  for _p in clang22 sdk109 longboat; do
    [ -f "$w/installed-$_p" ] || continue
    sudo /usr/local/bin/mavergreen uninstall "$_p" || _rc=1
  done
  return "$_rc"
}
uninstall() {
  sudo /usr/local/bin/mavergreen uninstall rust || return 1
  [ ! -e /usr/local/mavergreen/rust ] || return 1
  if pkgutil --pkgs | grep -qx dev.mavergreen.rust.rust; then return 1; fi
}
step fetch-and-verify fetch
[ "$bad" = 0 ] || { echo "SOME FAILED $V -- not installing a pkg that did not verify"; exit 1; }
step clang22 clang22
step install install_pkg
step versions versions
step stress-program stress
step crates-io crates_io
step clippy-proc-macro-build-rs-doctest clippy_ws
step link-clang22 link_clang22
step link-clang22-build-rs link_clang22_build_rs
cstep explicit-cc explicit_cc
step minos-sdk minos_sdk
step uninstall uninstall
step uninstall-clang22 uninstall_clang22
summary || exit 1
