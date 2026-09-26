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
bad=0
step() {
  name="$1"; shift
  if ( "$@" ) > "$w/$name.log" 2>&1; then echo "PASS $name"; else echo "FAIL $name (log: $w/$name.log)"; bad=1; fi
}
fetch() {
  curl -fsSL -o "$w/rust-$V.pkg" "$base/rust-$V.pkg" && curl -fsSL -o "$w/SHA256SUMS" "$base/SHA256SUMS" &&
    ( cd "$w" && grep " rust-$V.pkg\$" SHA256SUMS | shasum -a 256 -c - )
}
install_pkg() { sudo installer -pkg "$w/rust-$V.pkg" -target / && /usr/local/bin/mavergreen check; }
# platform: /usr/local/mavergreen/bin reaches PATH only through a login shell's paths.d
L() { /bin/zsh -lc "$1"; }
versions() { L 'rustc --version && cargo --version && cargo clippy --version && cargo fmt --version'; }
stress() {
  printf '%s\n' 'use std::collections::HashMap; use std::time::SystemTime;' \
    'fn main() { let mut m = HashMap::new(); m.insert("mavericks", 109); let _ = SystemTime::now();' \
    '  let n = std::thread::spawn(|| 42).join().unwrap(); println!("smoke {:?} {}", m.get("mavericks"), n); }' > "$w/smoke.rs"
  L "cd '$w' && rustc smoke.rs -o smoke" && [ "$("$w/smoke")" = 'smoke Some(109) 42' ]
}
crates_io() { L "cd '$w' && cargo new -q dep && cd dep && cargo add -q itoa@1 && cargo build -q"; }
clippy_ws() {
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
  L "cd '$w/ws' && cargo clippy -q && cargo build -q && [ \"\$(./target/debug/app)\" = '42 0' ] && cargo test -q --doc -p app"
}
uninstall() {
  sudo /usr/local/bin/mavergreen uninstall rust || return 1
  [ ! -e /usr/local/mavergreen/rust ] || return 1
  if pkgutil --pkgs | grep -qx dev.mavergreen.rust.rust; then return 1; fi
}
step fetch-and-verify fetch
step install install_pkg
step versions versions
step stress-program stress
step crates-io crates_io
step clippy-proc-macro-build-rs-doctest clippy_ws
step uninstall uninstall
if [ "$bad" = 0 ]; then echo "ALL PASS $V"; else echo "SOME FAILED $V -- fix forward in the next -mavericks.N"; exit 1; fi
