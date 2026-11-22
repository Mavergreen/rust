#!/bin/sh
# platform: host-agnostic
#   usage: assert-core2.sh PREFIX
#          Proves a staged or installed native rust prefix runs on a Core 2 Mac, function by function.
#          An x86_64-apple-darwin rlib object's function may hold an instruction core2 lacks (SSE4.1 and
#          later) only if its embedded bitcode compiles it for core2 plus such a feature by its own
#          attribute (runtime-detected paths); an object whose bitcode this llvm-dis cannot read, and
#          every Mach-O under bin/ and lib/, may hold one only in a function listed in
#          core2-allowlist.txt (CORE2_ALLOWLIST overrides it), by demangled name without its hash.
#          Prints "core2: N objects, M executables clean", or one "core2: FILE FUNCTION uses MNEMONIC"
#          line per offender and exits 1. A feature every function in an object enables was set for the
#          whole object, so it opts no function in. LLVM_DIS names the llvm-dis to try first, before the
#          prefix's own, the build tree's and clang22's; LLVM_OBJDUMP replaces clang22's llvm-objdump for
#          disassembly. On Linux, CLANGDIR names clang22.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/versions.sh"; . "$HERE/lib-rust.sh"; macho_tools
P="${1:?usage: assert-core2.sh PREFIX}"
B="$(dirname "$OTOOL")"
# platform: std's bitcode is written by rust's own LLVM, which an older llvm-dis cannot read; the prefix
#           ships a matching one under lib/rustlib/<host>/bin, and the build tree has one for its host
DIS=""
for _d in ${LLVM_DIS:+"$LLVM_DIS"} "$P"/lib/rustlib/*/bin/llvm-dis "${WORK_ROOT:-/nonexistent}"/work-*/*/build/*/llvm/bin/llvm-dis \
          "${WORK_ROOT:-/nonexistent}"/work-*/*/build/*/llvm/build/bin/llvm-dis "$B/llvm-dis"; do
  [ -x "$_d" ] && "$_d" --version > /dev/null 2>&1 && { DIS="$_d"; break; }
done
echo "core2: reading bitcode with ${DIS:-no llvm-dis that runs here}" >&2
AL="${CORE2_ALLOWLIST:-$HERE/core2-allowlist.txt}"
SET='^(v.*|pblendvb|pblendw|blendp[sd]|blendvp[sd]|ptest|pmin(sb|sd|uw|ud)|pmax(sb|sd|uw|ud)|pmulld|pmuldq|pextr[bdq]|pinsr[bdq]|round[sp][sd]|dpp[sd]|insertps|extractps|pcmpeqq|pcmpgtq|packusdw|pmov[sz]x(bw|bd|bq|wd|wq|dq)|mpsadbw|phminposuw|movntdqa|crc32[bwlq]?|popcnt[wlq]?|pcmp[ei]str[im]|lzcnt[wlq]?|andn[lq]|bextr[lq]?|blsi[lq]?|blsmsk[lq]?|blsr[lq]?|bzhi[lq]?|pdep[lq]?|pext[lq]?|rorx[lq]?|sarx[lq]?|shlx[lq]?|shrx[lq]?|mulx[lq]?|movbe[wlq]?|adcx[lq]?|adox[lq]?|aes(enc|enclast|dec|declast|imc|keygenassist)|pclmulqdq|sha1(rnds4|nexte|msg1|msg2)|sha256(rnds2|msg1|msg2)|rdrand[wlq]?|rdseed[wlq]?|tzcnt[wlq]?|rdtscp|xgetbv|xsetbv|xsave(c|s|opt)?(64)?|xrstors?(64)?|xbegin|xend|xabort|xtest|(rd|wr)(fs|gs)base[lq]?|clflushopt|clwb|rdpid[lq]?|gf2p8(affineqb|affineinvqb|mulb)|extrq|insertq|movnts[sd])$'
t="$(mktemp -d "${TMPDIR:-/tmp}/assert-core2.XXXXXX")"; trap 'rm -rf "$t"' EXIT
for _x in llvm-objdump llvm-ar llvm-objcopy llvm-cxxfilt; do
  [ -x "$B/$_x" ] || { echo "core2: no $_x in $B (clang22's tools)" >&2; exit 1; }
done
OD="${LLVM_OBJDUMP:-$B/llvm-objdump}"

magic() { od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n'; }
# platform: in a binary stripped of local symbols llvm-objdump credits a private function to the symbol
#           before it; LC_FUNCTION_STARTS still marks where each function begins, so one with no symbol
#           of its own is reported as unnamed, and no allowlisted neighbour covers it
offenders() {
  "$OD" -d --no-show-raw-insn "$1" > "$t/dis" 2> "$t/dis.err" \
    || { echo "core2: llvm-objdump cannot disassemble $1: $(head -1 "$t/dis.err")" >&2; exit 1; }
  awk -v re="$SET" -v sf="${2:-}" '
    function pad(a) { a = sprintf("%16s", a); gsub(/ /, "0", a); return a }
    BEGIN { n = 0; k = 1; if (sf != "") while ((getline l < sf) > 0) if (l ~ /^[0-9a-f]+$/) s[++n] = pad(l) }
    /^[0-9a-f]+ <.*>:$/ { f = $2; sub(/^</, "", f); sub(/>:$/, "", f); fa = pad($1); next }
    /^ *[0-9a-f]+:/ { a = $1; sub(/:$/, "", a); a = pad(a); g = f
      if (n) { while (k < n && s[k + 1] <= a) k++
        if (s[k] <= a && s[k] > fa) { u = s[k]; sub(/^0+/, "", u); g = "unnamed-function@0x" u } }
      sub(/^ *[0-9a-f]+:[ \t]*/, ""); i = 1
      while (i < NF && $i ~ /^(rex64|rex|data16|data32|addr16|addr32|lock|rep|repe|repz|repne|repnz|notrack|xacquire|xrelease|bnd|cs|ds|es|fs|gs|ss|[{](vex|vex2|vex3|evex)[}])$/) i++
      m = $i
      if ((m ~ re || (m == "pextrw" && $NF ~ /[(]/)) && m != "verr" && m != "verw" && !(g in seen)) { seen[g] = 1; print g, m } }' "$t/dis"
}
demangle() { "$B/llvm-cxxfilt" -_ | sed -E 's/^_//; s/ \(\.llvm\.[0-9]+\)$//; s/\.llvm\.[0-9]+$//; s/::h[0-9a-f]{16}$//'; }
opted() {
  awk '
    /^attributes #[0-9]+ = / { g = $2; c = ""; f = ""
      if (match($0, /"target-cpu"="[^"]*"/)) c = substr($0, RSTART + 14, RLENGTH - 15)
      if (match($0, /"target-features"="[^"]*"/)) f = substr($0, RSTART + 19, RLENGTH - 20)
      if ((c == "core2" || c == "x86-64" || c == "generic") && f ~ /(^|,)\+(sse4\.1|sse4\.2|popcnt|avx|avx2|avx512[a-z0-9]*|fma|f16c|bmi|bmi2|lzcnt|aes|pclmul|sha|movbe|adx|rdrnd|rdseed)(,|$)/) ok[g] = 1
      next }
    /^define / { if (!match($0, /@("[^"]*"|[-a-zA-Z$._0-9]+)/)) next
      n = substr($0, RSTART + 1, RLENGTH - 1); gsub(/"/, "", n)
      if (match($0, /\) [^{]*#[0-9]+/)) { a = substr($0, RSTART, RLENGTH); sub(/.*#/, "#", a); fn[n] = a } }
    END { nf = 0; nh = 0; for (n in fn) { nf++; if (fn[n] in ok) nh++ }
      if (nh < nf) for (n in fn) if (fn[n] in ok) print "_" n }' "$1"
}
listed() {
  demangle < "$1" > "$1.d"
  [ -r "$AL" ] || AL=/dev/null
  paste -d ' ' "$1" "$1.d" | awk 'FILENAME == ARGV[1] { a[$0] = 1; next } { d = $0; sub(/^[^ ]* /, "", d); if (d in a) print $1 }' "$AL" -
}
report() {
  awk 'FILENAME == ARGV[1] { a[$1] = 1; next } !($1 in a)' "$3" "$2" > "$t/bad"
  [ -s "$t/bad" ] || return 0
  cut -d' ' -f1 "$t/bad" | demangle > "$t/badd"
  paste -d ' ' "$t/bad" "$t/badd" | while read -r _s m d; do
    echo "core2: $1 $d uses $m${4:+ ($4)}"
  done
  st=1
}

st=0; no=0; ne=0
for r in "$P"/lib/rustlib/x86_64-apple-darwin/lib/*.rlib; do
  [ -f "$r" ] || continue
  rm -rf "$t/x"; mkdir "$t/x"; ( cd "$t/x" && "$B/llvm-ar" x "$r" )
  for o in "$t"/x/*; do
    [ "$(magic "$o")" = cffaedfe ] || continue
    no=$((no + 1))
    offenders "$o" > "$t/off"; [ -s "$t/off" ] || continue
    rule=allowlist
    if "$B/llvm-objcopy" --dump-section __LLVM,__bitcode="$t/bc" "$o" "$t/o.out" 2>/dev/null && [ -s "$t/bc" ] \
       && [ -n "$DIS" ] && "$DIS" "$t/bc" -o "$t/ll" 2>/dev/null; then
      rule=bitcode; opted "$t/ll" > "$t/ok"
    else
      cut -d' ' -f1 "$t/off" > "$t/syms"; listed "$t/syms" > "$t/ok"
    fi
    rm -f "$t/bc" "$t/ll" "$t/o.out"
    report "$r($(basename "$o"))" "$t/off" "$t/ok" "$rule"
  done
done
find "$P/bin" "$P/lib" -type f ! -name '*.rlib' 2>/dev/null | sort > "$t/files"
while IFS= read -r f; do
  case "$(magic "$f")" in cffaedfe|cafebabe) : ;; *) continue ;; esac
  ne=$((ne + 1))
  "$B/llvm-objdump" --macho --function-starts "$f" 2>/dev/null | tail -n +2 > "$t/starts" || : > "$t/starts"
  offenders "$f" "$t/starts" > "$t/off"; [ -s "$t/off" ] || continue
  cut -d' ' -f1 "$t/off" > "$t/syms"; listed "$t/syms" > "$t/ok"
  report "$f" "$t/off" "$t/ok" ""
done < "$t/files"
[ $((no + ne)) -gt 0 ] || { echo "core2: $P holds no x86_64-apple-darwin rlib object and no Mach-O under bin/ or lib/" >&2; exit 1; }
[ "$st" = 0 ] || exit 1
echo "core2: $no objects, $ne executables clean"
