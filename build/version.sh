#!/bin/sh
# Thin wrapper: the logic lives in shipyard (scripts/version.sh) so it cannot drift between repos.
# Every call site -- tests/version-test.sh, build/versions.sh, the release workflow, and a plain
# `sh build/version.sh auto` -- keeps working through this. Rust is a SINGLE upstream (no lines/): the
# pin is the repo-root UPSTREAM_VERSION.
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$SELF/.." && pwd)"; export MAVERICKS_ROOT
MAVERICKS_UPSTREAM_FILE="$MAVERICKS_ROOT/UPSTREAM_VERSION"; export MAVERICKS_UPSTREAM_FILE
[ -f "$MAVERICKS_UPSTREAM_FILE" ] || { echo "version.sh: no UPSTREAM_VERSION at repo root" >&2; exit 1; }
. "$SELF/msc.sh"
exec sh "$SHIPYARD/version.sh" "$@"
