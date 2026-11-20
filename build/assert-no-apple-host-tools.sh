#!/bin/sh
# platform: host-agnostic
#   usage: assert-no-apple-host-tools.sh LOG...
#          Fails if any LOG names xcrun, /usr/bin/clang or pkgutil, printing each such line, or if a
#          LOG is missing. A build or packager log that names none ran none of Apple's host tools.
# spec: .superpowers/plans/2026-10-24-macos-runner-exit/06-rust-and-codex-cli.md "Review Focus" (shipyard) -- rustc's Apple-target links get their SDK and linker from us
set -eu
[ "$#" -gt 0 ] || { echo "usage: assert-no-apple-host-tools.sh LOG..." >&2; exit 2; }
rc=0
for l do
  [ -f "$l" ] || { echo "::error::no log at $l"; rc=1; continue; }
  if hits="$(grep -nE 'xcrun|/usr/bin/clang|pkgutil' "$l")"; then
    printf '%s\n' "$hits" | sed "s|^|$l:|"
    echo "::error::$l names xcrun, /usr/bin/clang or pkgutil"; rc=1
  else
    echo "no xcrun, /usr/bin/clang or pkgutil in $(wc -l < "$l" | tr -d ' ') lines of $l"
  fi
done
exit "$rc"
