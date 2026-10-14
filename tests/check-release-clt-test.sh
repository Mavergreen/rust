#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
fail() { echo "FAIL $1"; exit 1; }
S="$ROOT/build/check-release-on-10.9.sh"
t="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/check-clt.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
funcs="$t/funcs.sh"
for f in step cstep has_clt write_smoke write_ws link_clang22 link_clang22_build_rs minos_sdk summary; do
  grep -q "^$f() {" "$S" || fail "check-release-on-10.9.sh must define $f"
  sed -n "/^$f() {/,/^}/p" "$S" >> "$funcs"
done
grep -q 'xcode-select -p' "$S" || fail "the CLT probe is xcode-select -p"
grep -Eq '\[ -[efx] /usr/bin/cc' "$S" && fail "never test that /usr/bin/cc exists: 10.9's stub always does"

mkdir -p "$t/noclt" "$t/clt"
printf '#!/bin/sh\necho "xcode-select: error: unable to get active developer directory" >&2; exit 2\n' > "$t/noclt/xcode-select"
printf '#!/bin/sh\necho /Library/Developer/CommandLineTools\n' > "$t/clt/xcode-select"
chmod +x "$t/noclt/xcode-select" "$t/clt/xcode-select"

run() {  # run PATHDIR SNIPPET -> the snippet's output, with fresh $w and counters
  w="$t/w.$$.$(date +%s)$RANDOM"; mkdir -p "$w"
  ( PATH="$1:$PATH"; bad=0; skips=0; V=1.99.0-mavericks.2; C22="$t/c22"; . "$funcs"; eval "$2" ) 2>&1
}

out="$(run "$t/noclt" 'boom() { echo first; echo the cause; return 1; }; step boom-step boom')"
case "$out" in *"FAIL boom-step"*"the cause"*) : ;; *) fail "a FAIL prints its log tail, got: $out" ;; esac

out="$(run "$t/noclt" 'ran() { echo RAN; }; cstep needs-cc ran; echo "skips=$skips bad=$bad"')"
[ "$out" = "SKIP needs-cc (no Command Line Tools: /usr/bin/cc is 10.9's stub)
skips=1 bad=0" ] || fail "without the CLT a cc step is a declared SKIP and does not run, got: $out"
out="$(run "$t/clt" 'ran() { :; }; cstep needs-cc ran; echo "skips=$skips"')"
[ "$out" = "PASS needs-cc
skips=0" ] || fail "with the CLT a cc step runs, got: $out"

out="$(run "$t/noclt" 'summary')"
case "$out" in "ALL PASS 1.99.0-mavericks.2"*) : ;; *) fail "no skips, no failures: ALL PASS, got: $out" ;; esac
out="$(run "$t/noclt" 'skips=3; summary')"
case "$out" in *"ALL PASS"*"3 SKIPPED"*) : ;; *) fail "the summary counts the skips, got: $out" ;; esac
set +e; out="$(run "$t/noclt" 'bad=1; skips=2; summary')"; rc=$?; set -e
[ "$rc" != 0 ] || fail "a failure still fails the summary"
case "$out" in *"SOME FAILED"*"2 SKIPPED"*) : ;; *) fail "a failing summary counts the skips too, got: $out" ;; esac

out="$(run "$t/noclt" 'L() { :; }; link_clang22 2>/dev/null || :; [ -f "$w/smoke.rs" ] && echo smoke; link_clang22_build_rs 2>/dev/null || :; [ -f "$w/ws/app/build.rs" ] && echo ws')"
[ "$out" = "smoke
ws" ] || fail "link-clang22 and link-clang22-build-rs write their own sources, got: $out"

mkdir -p "$t/c22/bin"
printf '#!/bin/sh\nprintf "LC_VERSION_MIN_MACOSX\\n version 10.9\\n sdk 10.9\\n"\n' > "$t/c22/bin/llvm-otool"
chmod +x "$t/c22/bin/llvm-otool"
MK='mkdir -p "$w/c22/target/debug" "$w/ws/target/debug"; : > "$w/c22/target/debug/c22"; : > "$w/ws/target/debug/app"'
out="$(run "$t/noclt" "$MK; minos_sdk && echo ok")"
[ "$out" = ok ] || fail "without the CLT minos-sdk checks the clang22 binaries alone, got: $out"
set +e; out="$(run "$t/clt" "$MK; minos_sdk")"; rc=$?; set -e
[ "$rc" != 0 ] || fail "with the CLT minos-sdk requires the cc-linked smoke binary too"
set +e; out="$(run "$t/noclt" 'minos_sdk')"; rc=$?; set -e
[ "$rc" != 0 ] || fail "minos-sdk never passes with no binaries at all"

for st in stress-program crates-io clippy-proc-macro-build-rs-doctest; do
  grep -q "^cstep $st " "$S" || fail "$st links with the default cc, so it is a cstep"
done
for st in clang22 link-clang22 link-clang22-build-rs minos-sdk; do
  grep -q "^step $st " "$S" || fail "$st needs no Command Line Tools, so it always runs as a step"
done

grep -Eq '^- vm-test:build/check-release-on-10\.9\.sh: .*QUEUE #48' "$ROOT/INGREDIENTS.md" \
  || fail "INGREDIENTS.md declares the skip as a conformance deviation whose exit names shipyard QUEUE #48"
echo "OK check-release-clt-test"
