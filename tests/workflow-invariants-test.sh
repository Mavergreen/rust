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
A="$ROOT/.github/actions"
for j in build-native build-cross build-linux; do
  body="$(awk -v j="  $j:" '$0 == j {p=1; next} p && /^  [a-z]/{p=0} p' "$W")"
  printf '%s\n' "$body" | grep -q 'uses: ./.github/actions/build-setup' || fail "$j prepares its runner with ./.github/actions/build-setup, the one copy of that setup"
  printf '%s\n' "$body" | grep -q 'uses: ./.github/actions/build-report' || fail "$j reports wall time and disk with ./.github/actions/build-report"
  printf '%s\n' "$body" | grep -q '"$RUNNER_TEMP/end"' || fail "$j's Build step records when it ends, so the wall time it reports leaves out Package"
done
[ "$(grep -c 'usr/share/dotnet' "$W" "$A"/*/action.yml | awk -F: '{n += $2} END {print n}')" = 1 ] \
  || fail "the disk-freeing step is written once, in build-setup"
grep -q 'RUNNER_TEMP/end' "$A/build-report/action.yml" || fail "build-report's wall time ends where Build ended"
python3 -c 'import yaml' > /dev/null 2>&1 || { echo "no PyYAML -- skipping the job-graph checks"; exit 77; }
python3 - "$W" "$ROOT/.github/workflows" <<'PY' || exit 1
import json, os, re, sys, yaml
W, D = sys.argv[1], sys.argv[2]
def fail(m):
    print("FAIL " + m); sys.exit(1)
jobs = yaml.safe_load(open(W))["jobs"]
for f in sorted(os.listdir(D)):
    if not f.endswith(".yml"):
        continue
    for n, j in (yaml.safe_load(open(os.path.join(D, f))) or {}).get("jobs", {}).items():
        runs = json.dumps(j.get("runs-on", "")) + json.dumps((j.get("strategy") or {}).get("matrix", ""))
        if re.search(r"macos-", runs, re.I) and (f, n) != ("release.yml", "modern-smoke"):
            fail("%s:%s runs on macOS; release.yml's modern-smoke is the one macOS job (D9)" % (f, n))
ms = jobs.get("modern-smoke") or fail("release.yml has no modern-smoke job, which runs the rust-cross pkg's arm64 slice (D9)")
"macos-26" == ms.get("runs-on") or fail("modern-smoke runs on macos-26")
"SPARKLE_PRIVATE_KEY" not in json.dumps(ms) or fail("modern-smoke holds no key: its env and secrets never mention SPARKLE_PRIVATE_KEY")
"secrets" not in json.dumps(ms) or fail("modern-smoke reads no secret")
"smoke-target-exec.sh" in json.dumps(ms) or fail("modern-smoke runs tests/smoke-target-exec.sh against the installed rust-cross pkg")
needs = jobs.get("publish", {}).get("needs") or []
for n in ("ver", "collect", "scan", "vm-test", "modern-smoke"):
    n in needs or fail("publish needs %s" % n)
builds = sorted(n for n in jobs if n.startswith("build"))
builds == ["build-cross", "build-linux", "build-native"] or fail("the builds are build-native, build-cross and build-linux, not %s" % builds)
for n in builds:
    jobs[n].get("timeout-minutes") == 355 or fail("%s has timeout-minutes: 355, under the hosted runner's 360" % n)
    "ubuntu" in str(jobs[n].get("runs-on")) or fail("%s runs on ubuntu" % n)
"ubuntu" in str(jobs["collect"].get("runs-on")) or fail("collect runs on ubuntu (D8)")
keys = [s["with"]["key"] for j in jobs.values() for s in j.get("steps", []) if str(s.get("uses", "")).startswith("actions/cache") and "hashFiles" in str((s.get("with") or {}).get("key"))]
len(keys) >= 6 or fail("each build job restores and saves its ccache under a key over the sources (%d keys)" % len(keys))
for k in keys:
    "'!components/longboat/**'" in k or fail("the ccache key excludes components/longboat/**, which renovate bumps for every family release: %s" % k)
main = "github.ref == 'refs/heads/main'"
for n, j in jobs.items():
    uses = str(j.get("uses", ""))
    if re.search(r"(publish|retry)-release\.yml", uses) and main not in str(j.get("if", "")):
        fail("%s writes a release, so it runs only for refs/heads/main: its if needs %s" % (n, main))
    for c in [j.get("if", "")] + [s.get("if", "") for s in j.get("steps", [])]:
        if "outputs.publish == 'yes'" in str(c) and main not in str(c):
            fail("%s: a condition that publishes holds only on refs/heads/main: %s" % (n, c))
    for s in j.get("steps", []):
        if re.search(r"sign_and_appcast|SPARKLE_PRIVATE_KEY", json.dumps(s)) and main not in str(s.get("if", "")):
            fail("%s: the step that signs and writes the appcast runs only for refs/heads/main" % n)
ver = json.dumps(jobs["ver"])
"workflow_dispatch:*)" not in ver or fail("ver lets a workflow_dispatch on any ref publish; only refs/heads/main publishes")
PY
echo "OK workflow-invariants-test"
