#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"; export TARGET_TRIPLE MACOS_MIN REPO_ROOT
. "$ROOT/build/lib-rust.sh"
t="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/wrapper.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
NATIVE_PREFIX="$t/nowhere/rust"; export NATIVE_PREFIX
fail() { echo "FAIL $1"; exit 1; }
mk() {
  mkdir -p "$t/$1/bin" "$t/$1/lib/rustlib/$TARGET_TRIPLE/lib"
  # platform: sh runs an exec'd file that has no #! line as a shell script (ENOEXEC fallback)
  printf 'echo "STUB $*"\n' > "$t/$1/bin/rustc"; chmod +x "$t/$1/bin/rustc"
  : > "$t/$1/lib/rustlib/$TARGET_TRIPLE/lib/librecaulk.a"
  wrap_rustc "$t/$1" "$2"
}
stub_linker() {  # stub_linker PATH LIBLINE RC
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "-###" ] && { [ -n "${MARK:-}" ] && : > "$MARK"; echo %s >&2; exit %s; }; done\nexit 0\n' "$2" "$3" > "$1"
  chmod +x "$1"
}
C22="$t/clang22/bin/clang++"
stub_linker "$C22" '"/opt/c/bin/../lib/librecaulk.a"' 0
mk native always; mk cross gated
defaulted() {  # defaulted CASE OUT: no linker was named, so the wrapper named clang22 and deferred
  case "$2" in *"-C linker=$C22 -C link-arg=-mmacosx-version-min=10.9 "*) : ;; *) fail "$1: no linker named, so the native wrapper names clang22 next to rust and defers to it: $2" ;; esac
  case "$2" in *force_load*) fail "$1: clang22 already links librecaulk.a: $2" ;; esac
}

out="$("$t/native/bin/rustc" x.rs)"
[ "$out" = "STUB -C linker=$C22 -C link-arg=-mmacosx-version-min=10.9 x.rs" ] || fail "case 1 direct: $out"

mkdir -p "$t/farm/bin" "$t/elsewhere"
ln -s "../../native/bin/rustc" "$t/farm/bin/rustc"
out="$(cd "$t/elsewhere" && "$t/farm/bin/rustc" x.rs 2>&1)" || true
defaulted "case 2 relative farm link from another cwd: the wrapper must resolve its REAL dir" "$out"

ln -s "$t/farm/bin/rustc" "$t/elsewhere/rustc2"
out="$(cd "$t/elsewhere" && PATH="$t/elsewhere:$PATH" rustc2 x.rs 2>&1)" || true
defaulted "case 3 PATH lookup through a two-link chain" "$out"

out="$("$t/cross/bin/rustc" --target=x86_64-apple-darwin x.rs)"
case "$out" in STUB*force_load*) : ;; *) fail "case 4 gated wrapper must accept --target=<triple>: $out" ;; esac
case "$out" in *linker=*) fail "case 4 rust-cross names no default linker (spec D1 is the native pkg's): $out" ;; esac
out="$("$t/cross/bin/rustc" --target aarch64-apple-darwin x.rs)"
case "$out" in *force_load*) fail "case 5 gated wrapper must not link the x86_64 shim into an arm64 artifact: $out" ;; esac

before="$(cat "$t/native/bin/rustc")"; wrap_rustc "$t/native" always
[ "$before" = "$(cat "$t/native/bin/rustc")" ] || fail "case 6 wrap_rustc must be idempotent"
mkdir -p "$t/cd/bin" "$t/cd/lib/rustlib/$TARGET_TRIPLE/lib"
printf 'echo "STUB $*"\n' > "$t/cd/bin/clippy-driver"; chmod +x "$t/cd/bin/clippy-driver"
: > "$t/cd/lib/rustlib/$TARGET_TRIPLE/lib/librecaulk.a"
wrap_linking_tool "$t/cd" clippy-driver always
[ -x "$t/cd/bin/clippy-driver.bin" ] || fail "case 7 clippy-driver moves to clippy-driver.bin"
out="$("$t/cd/bin/clippy-driver" /somewhere/bin/rustc --crate-type proc-macro x.rs)"
case "$out" in "STUB /somewhere/bin/rustc -C linker=$C22 -C link-arg=-mmacosx-version-min=10.9 "*) : ;; *) fail "case 7 under RUSTC_WORKSPACE_WRAPPER, cargo passes rustc's path first; the back-fill args go after it (cargo clippy on 10.9 left a proc-macro's _clock_gettime undefined): $out" ;; esac
out="$("$t/cd/bin/clippy-driver" x.rs)"
[ "$out" = "STUB -C linker=$C22 -C link-arg=-mmacosx-version-min=10.9 x.rs" ] || fail "case 8 clippy-driver called directly: $out"
out="$("$t/cross/bin/rustc" --target x86_64-apple-darwin x.rs)"
case "$out" in STUB*force_load*) : ;; *) fail "case 9 gated wrapper must accept --target <triple> (space form): $out" ;; esac

mkdir -p "$t/real/bin" "$t/real/lib/rustlib/$TARGET_TRIPLE/lib" "$t/links"
printf 'echo "STUB $*"\n' > "$t/real/bin/rustc"; chmod +x "$t/real/bin/rustc"
: > "$t/real/lib/rustlib/$TARGET_TRIPLE/lib/librecaulk.a"
wrap_rustc "$t/real" always
ln -s "$t/real/bin" "$t/links/bin"
out="$("$t/links/bin/rustc" x.rs)"
defaulted "case 10 a bin/ reached through a directory symlink must resolve physically (cd -P)" "$out"

mkdir -p "$t/noshim/bin"
printf 'echo "STUB $*"\n' > "$t/noshim/bin/rustc"; chmod +x "$t/noshim/bin/rustc"
wrap_rustc "$t/noshim" always
if out="$("$t/noshim/bin/rustc" x.rs 2>&1)"; then fail "case 11 a native rustc with no back-fill shim must fail, not link a binary that dies on 10.9: $out"; fi
case "$out" in *librecaulk.a*) : ;; *) fail "case 11 the error must name the missing shim: $out" ;; esac

mkdir -p "$t/farm2"
stub_linker "$t/lk/clang++" '"/opt/c/bin/../lib/librecaulk.a"' 0
stub_linker "$t/sp ace/clang++" '"/opt/c/bin/../lib/librecaulk.a"' 0
stub_linker "$t/lk/cc-plain" '"/usr/lib/libSystem.dylib"' 0
stub_linker "$t/lk/cc-refuses" '"unknown argument: -###"' 1
ln -s "$t/lk/clang++" "$t/farm2/clang++-22"
D="$t/lk/clang++"
defers() {
  case "$2" in *"-C link-arg=-mmacosx-version-min=10.9"*) : ;; *) fail "$1: a deferred link still needs rustc's 10.12 overridden: $2" ;; esac
  case "$2" in *force_load*|*-framework*|*-lobjc*) fail "$1: a linker that already links librecaulk.a must get no second copy (lld: duplicate symbol): $2" ;; esac
}
out="$("$t/native/bin/rustc" -C linker="$D" x.rs)"; defers "case 12 -C linker=<clang22>" "$out"
out="$("$t/native/bin/rustc" -Clinker="$D" x.rs)"; defers "case 13 -Clinker=<clang22>" "$out"
out="$("$t/native/bin/rustc" -C "linker=$D" x.rs)"; defers "case 13 -C linker=<clang22> as two arguments" "$out"
out="$("$t/native/bin/rustc" -C linker="$t/lk/cc-plain" x.rs)"
case "$out" in *force_load*"-framework -C link-arg=CoreServices"*) : ;; *) fail "case 14 a linker that does not link librecaulk.a gets the force-load and Recaulk's frameworks: $out" ;; esac
out="$("$t/native/bin/rustc" -C linker="$t/lk/cc-refuses" x.rs 2>"$t/err")" || fail "case 15 a linker that rejects -### must not fail the wrapper"
case "$out" in *force_load*) : ;; *) fail "case 15 a linker that rejects -### gets the force-load: $out" ;; esac
[ ! -s "$t/err" ] || fail "case 15 the probe's complaints must not reach the user: $(cat "$t/err")"
out="$(PATH="$t/lk:$PATH" "$t/native/bin/rustc" -C linker=clang++ x.rs)"; defers "case 16 a bare linker name found on PATH" "$out"
out="$("$t/native/bin/rustc" -C linker="$t/sp ace/clang++" x.rs)"; defers "case 17 a linker path with a space" "$out"
out="$("$t/native/bin/rustc" -C linker="$t/farm2/clang++-22" x.rs)"; defers "case 18 a link-farm name for clang22" "$out"
out="$("$t/cd/bin/clippy-driver" /somewhere/bin/rustc -C linker="$D" x.rs)"
case "$out" in "STUB /somewhere/bin/rustc -C link-arg=-mmacosx-version-min=10.9"*) : ;; *) fail "case 19 RUSTC_WORKSPACE_WRAPPER form defers too, args after rustc's path: $out" ;; esac
defers "case 19" "$out"
out="$(MARK="$t/probed" "$t/cross/bin/rustc" --target aarch64-apple-darwin -C linker="$D" x.rs)"
[ "$out" = "STUB --target aarch64-apple-darwin -C linker=$D x.rs" ] || fail "case 20 an arm64 link gets nothing added: $out"
[ ! -e "$t/probed" ] || fail "case 20 the probe must not run for a link that needs no back-fill"
out="$("$t/native/bin/rustc" x.rs)"; defaulted "case 21 no -C linker means clang22, not 10.9's cc stub" "$out"
printf '%s\n' -C "linker=$D" x.rs > "$t/argfile"
out="$("$t/native/bin/rustc" "@$t/argfile")"; defers "case 22 cargo retries rustc with an @argfile when argv is too long" "$out"
printf '%s\n' --target x86_64-apple-darwin x.rs > "$t/argfile2"
out="$("$t/cross/bin/rustc" "@$t/argfile2")"
case "$out" in *force_load*) : ;; *) fail "case 23 a --target inside an @argfile still selects the x86_64 back-fill: $out" ;; esac

one_linker() {  # one_linker CASE OUT: the user's linker, and no second one from the wrapper
  case "$2" in *"$C22"*) fail "$1: a named linker wins; the wrapper adds no clang22: $2" ;; esac
  [ "$(printf '%s\n' "$2" | grep -o 'linker=' | wc -l | tr -d ' ')" = 1 ] || fail "$1: exactly one linker on the line: $2"
}
P="$t/lk/cc-plain"
out="$("$t/native/bin/rustc" -C linker="$P" x.rs)"; one_linker "case 24 -C linker=cc" "$out"
out="$("$t/native/bin/rustc" -Clinker="$P" x.rs)"; one_linker "case 24 -Clinker=" "$out"
out="$("$t/native/bin/rustc" --codegen "linker=$P" x.rs)"; one_linker "case 24 --codegen linker=" "$out"
out="$("$t/native/bin/rustc" --codegen=linker="$P" x.rs)"; one_linker "case 24 --codegen=linker=" "$out"
printf '%s\n' -C "linker=$P" x.rs > "$t/argfile3"
out="$("$t/native/bin/rustc" "@$t/argfile3")"
case "$out" in *linker=*) fail "case 24 a linker inside an @argfile is named; the wrapper adds none: $out" ;; esac
case "$out" in *force_load*) : ;; *) fail "case 24 an explicit cc still gets Recaulk force-loaded: $out" ;; esac

mk withdeps/rust always
stub_linker "$t/withdeps/rust/deps/clang22/bin/clang++" '"/d/lib/librecaulk.a"' 0
stub_linker "$t/withdeps/clang22/bin/clang++" '"/s/lib/librecaulk.a"' 0
out="$("$t/withdeps/rust/bin/rustc" x.rs)"
case "$out" in "STUB -C linker=$t/withdeps/rust/deps/clang22/bin/clang++ "*) : ;; *) fail "case 25 rust's own deps/clang22 wins over the shared one (vision area 7): $out" ;; esac

mk none/rust always
if out="$("$t/none/rust/bin/rustc" x.rs 2>&1)"; then fail "case 26 no clang22 and no linker named must fail, not fall back to 10.9's cc stub: $out"; fi
case "$out" in *STUB*) fail "case 26 the real rustc must not run: $out" ;; esac
case "$out" in "rustc: no clang22 next to rust or installed (looked in $t/none/rust/deps/clang22/bin/clang++, $t/none/clang22/bin/clang++ and $t/nowhere/clang22/bin/clang++); install clang22, or name a linker (-C linker=cc) to use the Command Line Tools") : ;; *) fail "case 26 the message names where it looked and both remedies: $out" ;; esac
out="$("$t/none/rust/bin/rustc" -C linker="$P" x.rs)" || fail "case 26 a named linker needs no clang22"

mk old/rust always
stub_linker "$t/old/clang22/bin/clang++" '"/usr/lib/libSystem.dylib"' 0
if out="$("$t/old/rust/bin/rustc" x.rs 2>&1)"; then fail "case 27 a clang22 that does not link librecaulk.a must not be the default: $out"; fi
case "$out" in *STUB*) fail "case 27 the real rustc must not run: $out" ;; esac
case "$out" in *"$t/old/clang22/bin/clang++"*librecaulk.a*22.1.1-mavericks.7*"-C linker=cc"*) : ;; *) fail "case 27 the message names the clang22, the floor and the remedy: $out" ;; esac
mk broken/rust always
stub_linker "$t/broken/clang22/bin/clang++" '"oops"' 1
if out="$("$t/broken/rust/bin/rustc" x.rs 2>&1)"; then fail "case 28 a default clang22 that fails -### must not be used: $out"; fi
case "$out" in *STUB*) fail "case 28 the real rustc must not run: $out" ;; esac
[ "$out" = "rustc: $t/broken/clang22/bin/clang++ fails to run (-###); reinstall clang22, or name a linker (-C linker=cc) to use the Command Line Tools" ] \
  || fail "case 28 a clang22 that won't run is broken, not old: $out"

out="$("$t/cross/bin/rustc" x.rs)"
case "$out" in *linker=*) fail "case 29 rust-cross with no target adds no linker: $out" ;; esac

mk sdk/rust always
stub_linker "$t/sdk/clang22/bin/clang++" '"/s/lib/librecaulk.a"' 0
mkdir -p "$t/sdk/clang22/SDKs/MacOSX10.9.sdk"
printf 'echo "SDKROOT=${SDKROOT:-unset}"\n' > "$t/sdk/rust/bin/rustc.bin"
out="$(env -u SDKROOT "$t/sdk/rust/bin/rustc" x.rs)"
[ "$out" = "SDKROOT=$t/sdk/clang22/bin/../SDKs/MacOSX10.9.sdk" ] || fail "case 30 linking through clang22, rustc gets clang22's SDK, so it never runs the xcrun stub: $out"
out="$(SDKROOT=/mine "$t/sdk/rust/bin/rustc" x.rs)"
[ "$out" = "SDKROOT=/mine" ] || fail "case 30 a user's SDKROOT wins: $out"
out="$(env -u SDKROOT "$t/sdk/rust/bin/rustc" -C linker="$P" x.rs)"
[ "$out" = "SDKROOT=unset" ] || fail "case 30 a non-clang22 linker gets no SDKROOT from the wrapper: $out"
out="$(env -u SDKROOT "$t/sdk/rust/bin/rustc" -C linker="$t/sdk/clang22/bin/clang++" x.rs)"
[ "$out" = "SDKROOT=$t/sdk/clang22/bin/../SDKs/MacOSX10.9.sdk" ] || fail "case 30 an explicit clang22 gets its SDK too: $out"

for q in -vV -V --version "--print=sysroot" "--print sysroot" "- --crate-name ___ --print=file-names --crate-type bin"; do
  # shellcheck disable=SC2086
  out="$("$t/none/rust/bin/rustc" $q 2>&1)" || fail "case 31 '$q' links nothing, so a missing clang22 must not fail it (cargo runs rustc -vV with no linker): $out"
  [ "$out" = "STUB $q" ] || fail "case 31 '$q' passes through untouched: $out"
done
out="$(MARK="$t/probed31" "$t/native/bin/rustc" -vV)"
[ "$out" = "STUB -vV" ] && [ ! -e "$t/probed31" ] || fail "case 31 rustc -vV names no linker and runs no probe: $out"
if out="$("$t/none/rust/bin/rustc" --print link-args x.rs 2>&1)"; then fail "case 31 --print link-args links, so it still needs clang22: $out"; fi

mk gsdk/rust gated
stub_linker "$t/gsdk/clang22/bin/clang++" '"/s/lib/librecaulk.a"' 0
mkdir -p "$t/gsdk/clang22/SDKs/MacOSX10.9.sdk"
printf 'echo "SDKROOT=${SDKROOT:-unset}"\n' > "$t/gsdk/rust/bin/rustc.bin"
out="$(env -u SDKROOT "$t/gsdk/rust/bin/rustc" --target x86_64-apple-darwin -C linker="$t/gsdk/clang22/bin/clang++" x.rs)"
[ "$out" = "SDKROOT=unset" ] || fail "case 32 rust-cross is unchanged: it sets no SDKROOT: $out"

mkdir -p "$t/farm3/bin"; ln -s "$t/sdk/clang22/bin/clang++" "$t/farm3/bin/clang++"
out="$(env -u SDKROOT "$t/sdk/rust/bin/rustc" -C linker="$t/farm3/bin/clang++" x.rs)"
[ "$out" = "SDKROOT=$t/sdk/clang22/bin/../SDKs/MacOSX10.9.sdk" ] || fail "case 33 a clang22 reached through a link farm still gets its own SDK: $out"
out="$(env -u SDKROOT PATH="$t/farm3/bin:$PATH" "$t/sdk/rust/bin/rustc" -C linker=clang++ x.rs)"
[ "$out" = "SDKROOT=$t/sdk/clang22/bin/../SDKs/MacOSX10.9.sdk" ] || fail "case 33 a farm clang++ found on PATH still gets its own SDK: $out"
for fl in "-C linker-flavor=ld64.lld" "-Clinker-flavor=ld64.lld" "--codegen linker-flavor=ld64.lld"; do
  # shellcheck disable=SC2086
  out="$("$t/none/rust/bin/rustc" $fl x.rs 2>&1)" || fail "case 34 '$fl' chooses the link, so it needs no clang22: $out"
  case "$out" in *"-C linker="*) fail "case 34 '$fl' names a flavour and lets rustc pick its linker; the wrapper adds none: $out" ;; esac
done

NATIVE_PREFIX="$t/inst/rust"
mk unpacked/rust always; mk inst/rust always
NATIVE_PREFIX="$t/nowhere/rust"
stub_linker "$t/inst/clang22/bin/clang++" '"/i/lib/librecaulk.a"' 0
out="$("$t/unpacked/rust/bin/rustc" x.rs)" || fail "case 35 an unpacked rust with no clang22 beside it uses the installed one: $out"
case "$out" in "STUB -C linker=$t/inst/clang22/bin/clang++ -C link-arg=-mmacosx-version-min=10.9 x.rs") : ;; *) fail "case 35 an unpacked rust (fd's and rg's pinned toolchain) links with the installed clang22: $out" ;; esac
stub_linker "$t/unpacked/clang22/bin/clang++" '"/u/lib/librecaulk.a"' 0
out="$("$t/unpacked/rust/bin/rustc" x.rs)"
case "$out" in "STUB -C linker=$t/unpacked/clang22/bin/clang++ "*) : ;; *) fail "case 35 a clang22 next to rust wins over the installed one: $out" ;; esac
rm -rf "$t/inst/clang22"
if out="$("$t/inst/rust/bin/rustc" x.rs 2>&1)"; then fail "case 35 an installed rust with no clang22 must fail: $out"; fi
case "$out" in "rustc: no clang22 next to rust or installed (looked in $t/inst/rust/deps/clang22/bin/clang++ and $t/inst/clang22/bin/clang++); "*) : ;; *) fail "case 35 an installed rust's message names the installed clang22 once: $out" ;; esac
echo "OK wrapper-test"
