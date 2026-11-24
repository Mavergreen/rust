# platform: host-agnostic
#   usage: . build/package-lib.sh; package_variant native|cross
#          Writes the pkg and build-info-<variant>.txt to PKG_DIR (default dist/).
# spec: INGREDIENTS.md "The default linker" -- the native pkg's rustc links with clang22 by
#       default, so its preinstall refuses a box without clang22 (shipyard vision area 7's tool kind)
variant_requires() { case "$1" in native) echo clang22 ;; esac; }
RUST_MANIFEST_EXCLUDES="bin/rustc.bin bin/clippy-driver.bin"
# spec: .superpowers/QUEUE.md 6 -- install-products.sh reads opt/mavergreen/rust/mavergreen.plist from the
#       Linux tarball instead of fetching the macOS pkg; the tarball installs no updater, so no appcast
write_linux_manifest() {
  _lm="$(mktemp -d "${TMPDIR:-/tmp}/linux-manifest.XXXXXX")"
  set -- "$1" --stage "$_lm" --product rust --name "Rust for Mavericks" --group rust --version "$2"
  for _e in $RUST_MANIFEST_EXCLUDES; do set -- "$@" --exclude "$_e"; done
  for _r in $(variant_requires native); do set -- "$@" --requires "$_r"; done
  _ld="$1"; shift
  sh "$SHIPYARD_SCRIPTS/render-manifest.sh" "$@" >&2 \
    && cp "$_lm/usr/local/mavergreen/rust/mavergreen.plist" "$_ld/mavergreen.plist"
  _rc=$?; rm -rf "$_lm"; return "$_rc"
}
package_variant() {
  v="$1"
  RUST_VARIANT="$v"; export RUST_VARIANT
  . "$REPO_ROOT/build/versions.sh"
  export COPYFILE_DISABLE=1
  case "$v" in
    native) short="$NATIVE_SHORT"; id="$NATIVE_IDENTIFIER"; prefix="$NATIVE_PREFIX"; sroot="$NATIVE_STAGE_ROOT"
            line=""; arch=x86_64; floor="--min-os 10.9.5 --host-arch x86_64"; title_tail="" ;;
    cross)  short="$CROSS_SHORT"; id="$CROSS_IDENTIFIER"; prefix="$CROSS_PREFIX"; sroot="$CROSS_STAGE_ROOT"
            line=cross; arch=arm64; floor="--min-os 11.0 --host-arch arm64"; title_tail=" (cross toolchain for modern macOS)" ;;
    *) echo "package_variant: native|cross (got '$v')" >&2; return 2 ;;
  esac
  . "$REPO_ROOT/build/lib-rust.sh"
  [ -x "$sroot$prefix/bin/rustc.bin" ] || { echo "FATAL: $v not staged at $sroot$prefix" >&2; exit 1; }
  stage_is_current "$WORK/staged.stamp" "$v" \
    || { echo "FATAL: the $v stage is stale or unfinished (no current $WORK/staged.stamp): build-$v.sh again" >&2; exit 1; }
  [ -s "$sroot/build-tools.txt" ] \
    || { echo "FATAL: the $v stage has no $sroot/build-tools.txt recording what built it: build-$v.sh again" >&2; exit 1; }
  VER="$(sh "$SHIPYARD_SCRIPTS/resolve-version.sh" "$(sh "$SHIPYARD_SCRIPTS/release-mode.sh")")"
  pr="$WORK/pkgroot"; scr="$WORK/pkg-scripts"; comp="$WORK/$short-component.pkg"
  dist="${PKG_DIR:-$REPO_ROOT/dist}"
  rm -rf "$pr" "$scr"; mkdir -p "$pr$(dirname "$prefix")" "$dist"
  cp -pR "$sroot$prefix" "$pr$prefix"
  find "$pr" -name '._*' -delete
  app="$(sh "$REPO_ROOT/build/build-updater.sh" "$v")"
  set -- --stage "$pr" --product "$short" --name "Rust for Mavericks" --group rust \
    --version "$VER" --scripts-out "$scr" --updater-app "$app"
  for _e in $RUST_MANIFEST_EXCLUDES; do set -- "$@" --exclude "$_e"; done
  if [ -n "$line" ]; then set -- "$@" --line "$line"; fi
  for _r in $(variant_requires "$v"); do set -- "$@" --requires "$_r"; done
  sh "$SHIPYARD_SCRIPTS/stage_product.sh" "$@"
  sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" --root "$pr" --identifier "$id" --version "$VER" \
    --scripts "$scr" --install-location / --out "$comp" > /dev/null
  out="$dist/$short-$VER.pkg"
  sh "$SHIPYARD_SCRIPTS/set_install_floor.sh" --identifier "$id" \
    --title "Rust for Mavericks $VER$title_tail" --component "$comp" --out "$out" $floor --require-scripts
  rm -f "$comp"
  set -- variant="$v" arch="$arch" prefix="$prefix" pkg="$(basename "$out")" identifier="$id" \
    rust="$RUST_VERSION" clang="$(tr -d ' \t\n' < "$CLANG_PIN_FILE")" recaulk="$RECAULK_VERSION" make="$MAKE_VERSION" target="$TARGET_TRIPLE"
  while IFS= read -r _kv; do set -- "$@" "$_kv"; done < "$sroot/build-tools.txt"
  sh "$SHIPYARD_SCRIPTS/build-info.sh" "$dist/build-info-$v.txt" "$@"
  echo "built $out"
}
