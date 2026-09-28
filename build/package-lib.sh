# platform: macOS-only -- ditto, pkgbuild, productbuild
#   usage: . build/package-lib.sh; package_variant native|cross
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
  VER="$(sh "$SHIPYARD_SCRIPTS/resolve-version.sh" "$(sh "$SHIPYARD_SCRIPTS/release-mode.sh")")"
  pr="$WORK/pkgroot"; scr="$WORK/pkg-scripts"; comp="$WORK/$short-component.pkg"
  rm -rf "$pr" "$scr"; mkdir -p "$pr$(dirname "$prefix")" "$REPO_ROOT/dist"
  # platform: macOS stamps an undeletable com.apple.provenance on every file a tracked process
  #           writes, and pkgbuild records it as a ._X member; --noextattr drops only the others
  ditto --norsrc --noextattr --noacl "$sroot$prefix" "$pr$prefix"
  app="$(sh "$REPO_ROOT/build/build-updater.sh" "$v")"
  set -- --stage "$pr" --product "$short" --name "Rust for Mavericks" --group rust \
    --version "$VER" --exclude bin/rustc.bin --exclude bin/clippy-driver.bin --scripts-out "$scr" --updater-app "$app"
  if [ -n "$line" ]; then set -- "$@" --line "$line"; fi
  find "$pr" -name '._*' -delete
  sh "$SHIPYARD_SCRIPTS/stage_product.sh" "$@"
  pkgbuild --root "$pr" --identifier "$id" --version "$VER" --scripts "$scr" --install-location / "$comp"
  out="$REPO_ROOT/dist/$short-$VER.pkg"
  sh "$SHIPYARD_SCRIPTS/set_install_floor.sh" --identifier "$id" \
    --title "Rust for Mavericks $VER$title_tail" --component "$comp" --out "$out" $floor --require-scripts
  rm -f "$comp"
  sh "$SHIPYARD_SCRIPTS/build-info.sh" "$REPO_ROOT/dist/build-info-$v.txt" \
    variant="$v" arch="$arch" prefix="$prefix" pkg="$(basename "$out")" identifier="$id" \
    rust="$RUST_VERSION" clang="$(tr -d ' \t\n' < "$CLANG_PIN_FILE")" legacy_support="$MLS_VERSION" target="$TARGET_TRIPLE"
  echo "built $out"
}
