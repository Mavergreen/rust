# platform: host-agnostic
: "${REPO_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
export REPO_ROOT
MAVERICKS_ROOT="$REPO_ROOT"; export MAVERICKS_ROOT
. "$REPO_ROOT/build/lib.sh"

export MAVERICKS_UPSTREAM_FILE="$REPO_ROOT/UPSTREAM_VERSION"
[ -f "$MAVERICKS_UPSTREAM_FILE" ] || { echo "versions.sh: no UPSTREAM_VERSION at repo root" >&2; exit 1; }
export RUST_VERSION="$(upstream_version)"

if [ -f "$REPO_ROOT/VERSION" ]; then
  export PKG_VERSION="$(cat "$REPO_ROOT/VERSION")"
else
  export PKG_VERSION="$(sh "$REPO_ROOT/build/version.sh" auto | sed -n 's/^FULL=//p')"
fi

export RUST_SRC_URL="https://static.rust-lang.org/dist/rustc-${RUST_VERSION}-src.tar.xz"
export RUST_SRC_SHA_URL="${RUST_SRC_URL}.sha256"

export CLANG_PIN_FILE="$REPO_ROOT/components/clang/version"
export MLS_PIN_FILE="$REPO_ROOT/components/legacy-support/version"
MLS_VERSION="$(tr -d ' \t\n' < "$MLS_PIN_FILE")"; export MLS_VERSION
[ -n "$MLS_VERSION" ] || { echo "versions.sh: empty $MLS_PIN_FILE" >&2; exit 1; }

export TARGET_TRIPLE="x86_64-apple-darwin"
export MACOS_MIN="10.9"
export NATIVE_SHORT="rust"
export CROSS_SHORT="rust-cross"
export NATIVE_PREFIX="/usr/local/mavergreen/$NATIVE_SHORT"
export CROSS_PREFIX="/usr/local/mavergreen/$CROSS_SHORT"
export NATIVE_IDENTIFIER="dev.mavergreen.rust.rust"
export CROSS_IDENTIFIER="dev.mavergreen.rust.rust-cross"

export WORK_ROOT="${MAVERICKS_WORK:-$HOME/.cache/mavergreen-rust}"
export CROSS_STAGE_ROOT="$WORK_ROOT/work-cross/stage"
export NATIVE_STAGE_ROOT="$WORK_ROOT/work-native/stage"
case "${RUST_VARIANT:-}" in
  cross|native) export WORK="$WORK_ROOT/work-$RUST_VARIANT" ;;
  "") unset WORK ;;
  *) echo "versions.sh: RUST_VARIANT must be cross or native (got '$RUST_VARIANT')" >&2; exit 1 ;;
esac
