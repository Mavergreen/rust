#!/bin/sh
# platform: host-agnostic
#   usage: linux-pin-test.sh     build/pin-linux-clang.sh writes components/clang22/linux-sha256 only from bytes it
#          verified against the pinned release's SHA256SUMS, only for the version this checkout pins, and fill
#          answers only when components/clang22/version moved and the digest is stale
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $1"; exit 1; }
t="$(mktemp -d "${TMPDIR:-/tmp}/rust-linux-pin.XXXXXX")"; trap 'rm -rf "$t"' EXIT INT TERM
V=22.1.8-mavericks.99
mkdir -p "$t/repo" "$t/rel/Mavergreen/clang-22/releases/download/$V"
cp -R "$ROOT/build" "$ROOT/components" "$t/repo/"; cp "$ROOT/UPSTREAM_VERSION" "$t/repo/"
asset="clang22-$V-linux-x86_64.tar.gz"
rel="$t/rel/Mavergreen/clang-22/releases/download/$V"
printf fixture > "$rel/$asset"
sha="$(shasum -a 256 "$rel/$asset" | awk '{ print $1 }')"
printf '%s  %s\n' "$sha" "$asset" > "$rel/SHA256SUMS"
export MAVERGREEN_RELEASES="file://$t/rel" MAVERICKS_WORK="$t/work"
P="$t/repo/build/pin-linux-clang.sh"
( cd "$t/repo" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -q -m base && git branch -q base )
out="$(sh "$P" fill base)" && [ -z "$out" ] || fail "fill must succeed and print nothing when components/clang22/version did not move"
printf '%s\n' "$V" > "$t/repo/components/clang22/version"
( cd "$t/repo" && git -c user.name=t -c user.email=t@t commit -q -am bump )
[ "$(sh "$P" values)" = "$V $sha" ] || fail "values must print the version and its verified digest"
[ "$(sh "$P" fill base)" = "$V $sha" ] || fail "fill must print the new pin when the version moved and the digest is stale"
sh "$P" apply "$V" "$sha"
[ "$(cat "$t/repo/components/clang22/linux-sha256")" = "$sha  $asset" ] || fail "apply must write the SHA256SUMS line for $asset"
( cd "$t/repo" && git -c user.name=t -c user.email=t@t commit -q -am pin )
out="$(sh "$P" fill base)" && [ -z "$out" ] || fail "fill must succeed and print nothing once the digest is current"
if sh "$P" apply 22.1.8-mavericks.98 "$sha" 2>/dev/null; then fail "apply must refuse a version this checkout does not pin"; fi
if sh "$P" apply "$V" nothex 2>/dev/null; then fail "apply must refuse a value that is not a SHA-256"; fi
rm -rf "$t/work"
printf '%064d  %s\n' 0 "$asset" > "$rel/SHA256SUMS"
if sh "$P" values >/dev/null 2>&1; then fail "values must refuse a digest the release's bytes do not match"; fi
echo "PASS: linux-pin"
