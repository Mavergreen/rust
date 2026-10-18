#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
fail() { echo "FAIL $1"; exit 1; }
S="$ROOT/build/check-release-on-10.9.sh"
t="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/check-c22.XXXXXX")" && pwd)"; trap 'rm -rf "$t"' EXIT
funcs="$t/funcs.sh"
for f in clang22 uninstall_clang22; do sed -n "/^$f() {/,/^}/p" "$S"; done > "$funcs"
grep -q '^uninstall_clang22() {' "$funcs" || fail "check-release-on-10.9.sh must define clang22 and uninstall_clang22"

scenario() {  # scenario NAME PREINSTALLED CLANG_INSTALL_RC -> prints the sudo log
  crc=$3; MG="$t/$1/mg"; w="$t/$1/w"; mkdir -p "$MG/bin" "$w"; LOG="$t/$1/log"; : > "$LOG"
  for p in $2; do mkdir -p "$MG/$p"; done
  (
    MAVERICKS_CHECK_PREFIX="$MG"; C22="$MG/clang22"; ROOT="$ROOT"; GHLOG="$t/$1/gh"
    curl() { echo "https://github.com/Mavergreen/longboat/releases/tag/19990101.1"; }
    gh_pkg() { echo "$*" >> "$GHLOG"; echo "$w/$1.pkg"; }
    sudo() {
      echo "$*" >> "$LOG"
      case "$*" in
        "installer -pkg $w/longboat.pkg -target /") mkdir -p "$MG/longboat" ;;
        "$MG/bin/longboat install 10.9") mkdir -p "$MG/sdk109" ;;
        "installer -pkg $w/clang-22.pkg -target /")
          [ "$crc" = 0 ] || return 1; mkdir -p "$C22/bin" "$C22/SDKs/MacOSX10.9.sdk"; : > "$C22/bin/clang++"; chmod +x "$C22/bin/clang++" ;;
      esac
    }
    . "$funcs"
    ( clang22 ) >/dev/null 2>&1 || :
    ( uninstall_clang22 ) >/dev/null 2>&1 || :
  )
  grep 'uninstall' "$LOG" | sed 's|.*uninstall ||' | tr '\n' ' '
}

got="$(scenario fresh "" 0)"
[ "$got" = "clang22 sdk109 longboat " ] || fail "a fresh box: the run removes everything it installed, got '$got'"
lbv="$(tr -d ' \t\n' < "$ROOT/components/longboat/version")"
grep -qx "longboat $lbv longboat-$lbv.pkg" "$t/fresh/gh" \
  || fail "Longboat comes from the pin in components/longboat/version, never whatever release is newest (asked for: $(grep longboat "$t/fresh/gh"))"
got="$(scenario haslb "longboat sdk109" 0)"
[ "$got" = "clang22 " ] || fail "Longboat and sdk109 the user already had must survive the check, got '$got'"
grep -q 'installer -pkg .*longboat' "$t/haslb/log" && fail "an installed Longboat must not be reinstalled"
got="$(scenario c22fails "" 1)"
[ "$got" = "sdk109 longboat " ] || fail "a failed clang22 install still cleans up the Longboat and sdk109 this run installed, got '$got'"
echo "OK check-release-clang22-test"
