#!/bin/sh
# platform: host-agnostic
#   usage: version.sh auto|local       prints FULL=, TAG=, RELEASE= (shipyard's scripts/version.sh)
set -eu
SELF="$(cd "$(dirname "$0")" && pwd)"
MAVERICKS_ROOT="$(cd "$SELF/.." && pwd)"; export MAVERICKS_ROOT
MAVERICKS_UPSTREAM_FILE="$MAVERICKS_ROOT/UPSTREAM_VERSION"; export MAVERICKS_UPSTREAM_FILE
[ -f "$MAVERICKS_UPSTREAM_FILE" ] || { echo "version.sh: no UPSTREAM_VERSION at repo root" >&2; exit 1; }
. "$SELF/msc.sh"
exec sh "$SHIPYARD/version.sh" "$@"
