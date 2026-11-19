#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
MAVERICKS_ROOT="$ROOT"; export MAVERICKS_ROOT
. "$ROOT/build/lib.sh"
t="$(mktemp -d "${TMPDIR:-/tmp}/build-jobs.XXXXXX")"; trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL $1"; exit 1; }
unset MAVERICKS_JOBS
mkdir -p "$t/linux" "$t/mac"
printf '#!/bin/sh\necho "sysctl: cannot stat /proc/sys/hw/$2" >&2\nexit 255\n' > "$t/linux/sysctl"
printf '#!/bin/sh\ncase "$1" in _NPROCESSORS_ONLN) echo 4 ;; _PHYS_PAGES) echo 4194304 ;; PAGESIZE) echo 4096 ;; *) exit 1 ;; esac\n' > "$t/linux/getconf"
printf '#!/bin/sh\ncase "$2" in hw.ncpu) echo 8 ;; hw.memsize) echo 17179869184 ;; *) exit 1 ;; esac\n' > "$t/mac/sysctl"
chmod +x "$t/linux/sysctl" "$t/linux/getconf" "$t/mac/sysctl"
got="$(PATH="$t/linux:$PATH" mavericks_build_jobs)"
[ "$got" = 4 ] || fail "a 4-CPU 16 GB Linux runner (no hw.* sysctl) builds with 4 jobs, from getconf (got $got)"
got="$(PATH="$t/mac:$PATH" mavericks_build_jobs)"
[ "$got" = 5 ] || fail "an 8-CPU 16 GB Mac builds with 5 jobs, one per 3 GB (got $got)"
got="$(MAVERICKS_JOBS=3 mavericks_build_jobs)"
[ "$got" = 3 ] || fail "MAVERICKS_JOBS overrides (got $got)"
echo "OK build-jobs-test"
