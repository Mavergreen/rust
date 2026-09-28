#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
U="$(tr -d ' \t\n' < "$ROOT/UPSTREAM_VERSION")"

out="$(MAVERICKS_TAGS="" sh "$ROOT/build/version.sh" auto)"
echo "$out" | grep -qx "FULL=$U-mavericks.1" || { echo "FAIL auto/no-tags FULL: $out"; exit 1; }
echo "$out" | grep -qx 'RELEASE=yes'         || { echo "FAIL auto/no-tags RELEASE: $out"; exit 1; }

out="$(MAVERICKS_TAGS="$U-mavericks.1
$U-mavericks.3" sh "$ROOT/build/version.sh" auto)"
echo "$out" | grep -qx "FULL=$U-mavericks.3" || { echo "FAIL auto/tags FULL: $out"; exit 1; }
echo "$out" | grep -qx 'RELEASE=no'          || { echo "FAIL auto/tags RELEASE: $out"; exit 1; }

out="$(MAVERICKS_TAGS="$U-mavericks.3" sh "$ROOT/build/version.sh" local)"
echo "$out" | grep -qx "FULL=$U-mavericks.4" || { echo "FAIL local FULL: $out"; exit 1; }

( . "$ROOT/build/versions.sh"
  [ "$RUST_VERSION" = "$U" ]                      || { echo "FAIL RUST_VERSION=$RUST_VERSION"; exit 1; }
  [ "$TARGET_TRIPLE" = "x86_64-apple-darwin" ]    || { echo "FAIL TARGET_TRIPLE=$TARGET_TRIPLE"; exit 1; }
  [ -n "$MLS_VERSION" ]                           || { echo "FAIL MLS_VERSION empty"; exit 1; }
  case "$RUST_SRC_URL" in *"$RUST_VERSION"*) : ;; *) echo "FAIL RUST_SRC_URL=$RUST_SRC_URL"; exit 1 ;; esac
) || exit 1

( . "$ROOT/build/versions.sh"
  [ "$NATIVE_PREFIX" = /usr/local/mavergreen/rust ]         || { echo "FAIL NATIVE_PREFIX=$NATIVE_PREFIX (spec: Layout and identity)"; exit 1; }
  [ "$CROSS_PREFIX" = /usr/local/mavergreen/rust-cross ]    || { echo "FAIL CROSS_PREFIX=$CROSS_PREFIX"; exit 1; }
  [ "$NATIVE_SHORT" = rust ] && [ "$CROSS_SHORT" = rust-cross ] || { echo "FAIL short names"; exit 1; }
  [ "$MLS_VERSION" = "$(tr -d ' \t\n' < "$ROOT/components/legacy-support/version")" ] \
    || { echo "FAIL MLS_VERSION must come from components/legacy-support/version (release-state reads whole files)"; exit 1; }
  case "$CROSS_STAGE_ROOT" in */work-cross/stage) : ;; *) echo "FAIL CROSS_STAGE_ROOT=$CROSS_STAGE_ROOT"; exit 1 ;; esac
  case "$NATIVE_STAGE_ROOT" in */work-native/stage) : ;; *) echo "FAIL NATIVE_STAGE_ROOT=$NATIVE_STAGE_ROOT"; exit 1 ;; esac
  [ -z "${WORK:-}" ] || { echo "FAIL WORK must be unset without RUST_VARIANT, so no script shares one work dir by accident"; exit 1; }
) || exit 1
( RUST_VARIANT=native; . "$ROOT/build/versions.sh"
  case "$WORK" in */work-native) : ;; *) echo "FAIL WORK=$WORK for RUST_VARIANT=native"; exit 1 ;; esac
) || exit 1
grep -q '^for repo in clang-22 clang; do$' "$ROOT/build/fetch-clang.sh" || { echo "FAIL fetch-clang.sh must try Mavergreen/clang-22 before the pre-rename Mavergreen/clang"; exit 1; }

echo "OK version-test"
