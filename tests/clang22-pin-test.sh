#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
fail() { echo "FAIL $1"; exit 1; }
P="$ROOT/components/clang22"
[ -f "$P/version" ] || fail "components/clang22/version is missing: shipyard's fetch_clang22.sh takes a components/clang22 directory"
v="$(cat "$P/version")"
printf '%s\n' "$v" | grep -Eqx '22\.[0-9]+\.[0-9]+-mavericks\.[0-9]+' || fail "components/clang22/version holds '$v', not a clang-22 release tag"
[ -f "$P/linux-sha256" ] || fail "components/clang22/linux-sha256 is missing: fetch_clang22.sh verifies the Linux archive against it"
[ "$(wc -l < "$P/linux-sha256" | tr -d ' ')" = 1 ] || fail "linux-sha256 must be one line, the release's SHA256SUMS line for its Linux archive"
grep -Eqx "[0-9a-f]{64}  clang22-$(printf '%s' "$v" | sed 's/\./\\./g')-linux-x86_64\.tar\.gz" "$P/linux-sha256" \
  || fail "linux-sha256 must be '<sha256>  clang22-$v-linux-x86_64.tar.gz' (got '$(cat "$P/linux-sha256")')"
[ ! -e "$ROOT/components/clang" ] || fail "components/clang must be gone: the pin lives in components/clang22"
grep -qF '"/^components/clang22/version$/"' "$ROOT/.github/renovate.json" || fail "Renovate's clang-22 manager must match /^components/clang22/version$/"
! grep -qF 'components/clang/' "$ROOT/.github/renovate.json" || fail "Renovate still names components/clang/"
sed -n '/^## Declared state/,/^## /p' "$ROOT/INGREDIENTS.md" | grep -qx -- '- clang: components/clang22/version' \
  || fail "INGREDIENTS.md's declared state must name components/clang22/version"
echo "OK clang22-pin-test"
