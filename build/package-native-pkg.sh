#!/bin/sh
# platform: host-agnostic
set -eu
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export REPO_ROOT
. "$REPO_ROOT/build/package-lib.sh"; package_variant native
