#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TARGET_TRIPLE=x86_64-apple-darwin; MACOS_MIN=10.9; REPO_ROOT="$ROOT"; NATIVE_PREFIX=/usr/local/mavergreen/rust
export TARGET_TRIPLE MACOS_MIN REPO_ROOT NATIVE_PREFIX
. "$ROOT/build/lib-rust.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/recaulk-fw.XXXXXX")"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }
s0="$(sed -n 's/.*-force_load,"\$RECAULK_A"\(.*\)/\1/p' "$ROOT/build/fetch-stage0.sh" | grep -o -- '-framework [A-Za-z]*' | awk '{print $2}' | sort | tr '\n' ' ')"
mkdir -p "$t/p/bin"; printf 'binary' > "$t/p/bin/rustc"; chmod +x "$t/p/bin/rustc"
wrap_linking_tool "$t/p" rustc always
wr="$(sed -n 's/.*link-arg=-framework -C link-arg=\([A-Za-z]*\).*/\1/p' "$t/p/bin/rustc" | sort | tr '\n' ' ')"
[ -n "$s0" ] && [ -n "$wr" ] || fail "could not read the framework lists (stage0: '$s0', wrapper: '$wr')"
for site in "stage0:$s0" "wrapper:$wr"; do
  case " ${site#*:}" in *" ApplicationServices "*) : ;;
    *) fail "${site%%:*} force-loads librecaulk.a without ApplicationServices: Recaulk's CGColorCreateSRGB back-fill calls CoreGraphics, under ApplicationServices on 10.9 (frameworks: ${site#*:})" ;;
  esac
done
[ "$s0" = "$wr" ] || fail "the stage0 link and the wrapper force-load the same librecaulk.a, so they need the same frameworks (stage0: $s0; wrapper: $wr)"
C=/usr/local/mavergreen/clang22; R=/usr/local/mavergreen/recaulk
rv="$(awk '/<key>version<\/key>/ { getline; sub(/.*<string>/, ""); sub(/<\/string>.*/, ""); print; exit }' "$R/mavergreen.plist" 2>/dev/null)" || rv=""
if [ -x "$C/bin/clang" ] && [ -d "$C/SDKs/MacOSX10.9.sdk" ] && [ "$rv" = "$(tr -d ' \t\n' < "$ROOT/components/recaulk/version")" ]; then
  fw=""; for f in $s0; do fw="$fw -framework $f"; done
  "$C/bin/clang" --no-default-config -dynamiclib -mmacosx-version-min=10.9 -Wl,-force_load,"$R/lib/librecaulk.a" \
    $fw -lobjc -lc++abi -o "$t/all.dylib" 2> "$t/err" \
    || { cat "$t/err"; fail "force-loading the pinned librecaulk.a with these frameworks leaves symbols undefined"; }
  echo "(linked all of the pinned librecaulk.a $rv with: $s0)"
else
  echo "(no installed clang22 with its SDK and Recaulk at the pin: checked the framework lists only)"
fi
echo "OK recaulk-frameworks-test"
