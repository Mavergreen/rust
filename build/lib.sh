# platform: host-agnostic
: "${MAVERICKS_ROOT:=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd || pwd)}"
export MAVERICKS_ROOT
. "$MAVERICKS_ROOT/build/msc.sh"
. "$SHIPYARD/lib.sh"

# platform: LLVM's heaviest C++ translation units (DAGCombiner, the SelectionDAG family) each peak
#           above 1 GB of compiler memory; on a 16 GB box without swap, -j8 was SIGKILLed ("Killed: 9",
#           nothing else) around 2000 of 4353 objects
mavericks_build_jobs() {
  if [ -n "${MAVERICKS_JOBS:-}" ]; then printf '%s\n' "$MAVERICKS_JOBS"; return 0; fi
  _ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  _memgb="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 8589934592) / 1073741824 ))"
  _memjobs="$(( _memgb / 3 ))"
  [ "$_memjobs" -lt 1 ] && _memjobs=1
  if [ "$_memjobs" -lt "$_ncpu" ]; then printf '%s\n' "$_memjobs"; else printf '%s\n' "$_ncpu"; fi
}
