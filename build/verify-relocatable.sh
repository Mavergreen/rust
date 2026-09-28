#!/bin/sh
# platform: macOS-only -- otool reads Mach-O load commands
#   usage: verify-relocatable.sh <prefix>
#          Fails if any Mach-O under <prefix>/{bin,lib} names an absolute dependency, install name
#          or rpath outside @-relative paths, /usr/lib, /System, and the two product prefixes. It is
#          an allowlist: a build-host package manager (/opt/pkg, /opt/homebrew) baked in by CMake is
#          caught as surely as the build's own scratch dir.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"
P="${1:?usage: verify-relocatable.sh <prefix>}"
[ -n "$NATIVE_PREFIX" ] && [ -n "$CROSS_PREFIX" ] || { echo "FATAL: empty product prefix would allow every absolute path" >&2; exit 1; }
n=0; bad=0
tmp="$(mktemp "${TMPDIR:-/tmp}/verify-relocatable.XXXXXX")"
find "$P/bin" "$P/lib" -type f 2>/dev/null > "$tmp" || true
[ -s "$tmp" ] || { echo "FATAL: no files under $P/{bin,lib} -- nothing audited" >&2; exit 1; }
while IFS= read -r f; do
  desc="$(file "$f" 2>/dev/null)"
  # platform: `file` calls a fat static archive "Mach-O universal binary ... ar archive", and
  #           `otool -L` on an archive prints one "/path/lib.a(member.o):" line per member
  case "$desc" in
    *"ar archive"*) continue ;;
    *Mach-O*executable*|*Mach-O*"shared library"*|*Mach-O*bundle*) : ;;
    *) continue ;;
  esac
  n=$((n+1))
  paths="$(printf '%s\n%s\n%s\n' \
    "$(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}')" \
    "$(otool -D "$f" 2>/dev/null | tail -n +2)" \
    "$(otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}')")"
  hits=""
  for p in $paths; do
    case "$p" in
      @*|"") continue ;;
      /usr/lib/*|/System/*) continue ;;
      "$NATIVE_PREFIX"/*|"$CROSS_PREFIX"/*) continue ;;
      /*) hits="$hits$p
" ;;
    esac
  done
  if [ -n "$hits" ]; then
    bad=$((bad+1))
    echo "FAIL ${f#"$P"/}"
    printf '%s' "$hits" | sed "s#$WORK_ROOT#<WORK_ROOT>#g;s/^/    /"
  fi
done < "$tmp"
rm -f "$tmp"
echo "checked $n Mach-O under $P: $bad with unshippable absolute paths"
[ "$bad" -eq 0 ]
