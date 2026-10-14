#!/bin/sh
# platform: host-agnostic
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
W="$ROOT/.github/workflows/release.yml"
fail() { echo "FAIL $1"; exit 1; }
[ -f "$W" ] || { echo "no release.yml -- skipping"; exit 77; }
! grep -q 'pull_request_target' "$W" || fail "pull_request_target would hand a fork PR this repo's secrets"
awk '/^permissions:/{p=1; next} p && /^[^ ]/{p=0} p' "$W" | grep -qx '  contents: read' \
  || fail "top-level permissions must be contents: read; only publish writes (the build jobs run hours of third-party build code)"
awk '/^  publish:/{p=1; next} p && /^  [a-z]/{p=0} p' "$W" | grep -q 'contents: write' || fail "publish must declare its own contents: write"
nco="$(grep -c 'uses: actions/checkout@' "$W")"
npc="$(grep -c 'persist-credentials: false' "$W")"
[ "$nco" = "$npc" ] || fail "every checkout needs persist-credentials: false ($nco checkouts, $npc without persisted credentials)"
grep -A1 'name: Save ccache' "$W" | grep -q 'if: \${{ always()' \
  || fail "the ccache save must run under always(): a job-level timeout is a cancellation, and !cancelled() skips the save"
awk '/^  publish:/{p=1; next} p && /^  [a-z]/{p=0} p' "$W" | grep -q 'needs:.*vm-test' \
  || fail "publish must wait for vm-test: no 10.9 runner builds this, so the native pkg is proven on real 10.9 before it ships"
vm="$(awk '/^  vm-test:/{p=1; next} p && /^  [a-z]/{p=0} p' "$W")"
printf '%s\n' "$vm" | grep -q 'packages: write' || fail "vm-test needs packages: write to cache the mavericks-vm image"
printf '%s\n' "$vm" | grep -q 'check-release-on-10.9.sh' || fail "vm-test must run build/check-release-on-10.9.sh against the built pkg"
echo "OK workflow-invariants-test"
