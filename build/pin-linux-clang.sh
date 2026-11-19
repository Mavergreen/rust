#!/bin/sh
# platform: host-agnostic
#   usage: pin-linux-clang.sh values | apply VERSION SHA256 | fill BASE_REF     values: prints the pinned clang22 version and its Linux archive digest, after verifying the archive against the release's SHA256SUMS. apply: writes components/clang22/linux-sha256 for this checkout's version only. fill: when components/clang22/version moved since BASE_REF and the digest is stale, prints values; else nothing
set -eu
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_ROOT/build/versions.sh"
. "$REPO_ROOT/build/msc.sh"
. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
CLANG22_VERSION="$(tr -d ' \t\n' < "$CLANG_PIN_FILE")"
case "$CLANG22_VERSION" in ''|*[!a-zA-Z0-9._-]*) echo 'invalid clang22 version' >&2; exit 2 ;; esac
asset="clang22-$CLANG22_VERSION-linux-x86_64.tar.gz"
pin="$REPO_ROOT/components/clang22/linux-sha256"
valid_sha() { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 64 ]; }
values() {
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/linux-host.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
  base="${MAVERGREEN_RELEASES:-https://github.com}/Mavergreen/clang-22/releases/download/$CLANG22_VERSION"
  shipyard_curl "$base/SHA256SUMS" "$tmp/sums"
  sha="$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset { print $1 }' "$tmp/sums")"
  valid_sha "$sha" || { echo "missing/invalid digest for $asset" >&2; exit 1; }
  shipyard_fetch_verified "$base/$asset" "$sha" "$WORK_ROOT/linux-pin/$CLANG22_VERSION" "$asset"
  printf '%s %s\n' "$CLANG22_VERSION" "$sha"
}
case "${1:-}" in
  values) [ $# -eq 1 ] || exit 2; values ;;
  apply)
    [ $# -eq 3 ] && [ "$2" = "$CLANG22_VERSION" ] && valid_sha "$3" || { echo 'pin version/digest does not match checkout' >&2; exit 2; }
    printf '%s  %s\n' "$3" "$asset" > "$pin" ;;
  fill)
    [ $# -eq 2 ] || exit 2
    base="$(git -C "$REPO_ROOT" merge-base "$2" HEAD)"
    changes="$(git -C "$REPO_ROOT" diff "$base" HEAD -- components/clang22/version)"
    [ -n "$changes" ] || exit 0
    new="$(values)"; hash=${new#* }
    [ ! -f "$pin" ] || [ "$(cat "$pin")" != "$hash  $asset" ] || exit 0
    printf '%s\n' "$new" ;;
  *) echo 'usage: pin-linux-clang.sh values | apply VERSION SHA256 | fill BASE_REF' >&2; exit 2 ;;
esac
