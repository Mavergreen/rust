#!/bin/sh
# platform: host-agnostic
#   usage: package-linux.sh
#          Writes the Linux stage as dist/rust-$VER-linux-x86_64.tar.gz, laid out under
#          opt/mavergreen/rust/ for shipyard's fetch_product_tar.sh, and dist/build-info-linux.txt.
#          The archive is reproducible: GNU tar with sorted names, owner 0 and every mtime set to
#          SOURCE_DATE_EPOCH (default: HEAD's commit time), then gzip -n. PKG_DIR replaces dist/.
# spec: .superpowers/plans/2026-10-24-macos-runner-exit/06-rust-and-codex-cli.md D7 (shipyard)
set -eu
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; export REPO_ROOT
RUST_VARIANT=linux; export RUST_VARIANT
. "$REPO_ROOT/build/versions.sh"; . "$REPO_ROOT/build/lib-rust.sh"
P="$LINUX_STAGE_ROOT$LINUX_PREFIX"
[ -x "$P/bin/rustc.bin" ] || { echo "FATAL: the Linux toolchain is not staged at $P" >&2; exit 1; }
stage_is_current "$WORK/staged.stamp" linux \
  || { echo "FATAL: the Linux stage is stale or unfinished (no current $WORK/staged.stamp): build-linux.sh again" >&2; exit 1; }
[ -s "$LINUX_STAGE_ROOT/build-tools.txt" ] \
  || { echo "FATAL: the Linux stage has no $LINUX_STAGE_ROOT/build-tools.txt recording what built it: build-linux.sh again" >&2; exit 1; }
tar --version 2>/dev/null | grep -q 'GNU tar' || { echo "FATAL: package-linux.sh needs GNU tar (--sort, --mtime, --owner)" >&2; exit 1; }
VER="$(sh "$SHIPYARD_SCRIPTS/resolve-version.sh" "$(sh "$SHIPYARD_SCRIPTS/release-mode.sh")")"
: "${SOURCE_DATE_EPOCH:=$(git -C "$REPO_ROOT" log -1 --format=%ct)}"
dist="${PKG_DIR:-$REPO_ROOT/dist}"; mkdir -p "$dist"
name="$NATIVE_SHORT-$VER-linux-x86_64.tar.gz"; out="$dist/$name"
# platform: fetch_product_tar.sh takes regular files, directories and relative symlinks only, so a hard
#           link is archived as the file it names
( cd "$LINUX_STAGE_ROOT" && tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
    --hard-dereference -cf - "${LINUX_PREFIX#/}" ) | gzip -n -9 > "$out.part"
mv "$out.part" "$out"
set -- variant=linux arch=x86_64 host=x86_64-unknown-linux-gnu prefix="$LINUX_PREFIX" tarball="$name" \
  rust="$RUST_VERSION" clang="$(tr -d ' \t\n' < "$CLANG_PIN_FILE")" recaulk="$RECAULK_VERSION" make="$MAKE_VERSION" \
  target="$TARGET_TRIPLE" source-date-epoch="$SOURCE_DATE_EPOCH"
while IFS= read -r _kv; do set -- "$@" "$_kv"; done < "$LINUX_STAGE_ROOT/build-tools.txt"
sh "$SHIPYARD_SCRIPTS/build-info.sh" "$dist/build-info-linux.txt" "$@"
echo "built $out"
