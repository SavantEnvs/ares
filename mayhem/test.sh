#!/usr/bin/env bash
#
# mayhem/test.sh — RUN ares' own i8080 CPU conformance suite (built by mayhem/build.sh as /mayhem/i8080-test).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# ares ships a CP/M-based 8080 CPU exerciser harness (tests/i8080) that runs four well-known diagnostic
# programs on the emulated i8080 core and prints their results. Each check below asserts one result.
BIN="$SRC/i8080-test"
[ -x "$BIN" ] || { echo "missing $BIN — mayhem/build.sh should have built it" >&2; emit_ctrf "i8080" 0 1 0; exit 1; }

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
(cd "$SRC/tests/i8080" && timeout 900 "$BIN") > "$OUT" 2>&1
rc=$?

passed=0; failed=0
check() { # <description> <condition-exit-status>
  if [ "$2" -eq 0 ]; then passed=$((passed+1)); echo "ok   - $1"; else failed=$((failed+1)); echo "FAIL - $1"; fi
}

check "runner exited 0" "$rc"
grep -aq "CPU TESTS OK" "$OUT";                           check "CPUTEST.COM: CPU TESTS OK" $?
grep -aq "CPU IS OPERATIONAL" "$OUT";                     check "TST8080.COM: CPU IS OPERATIONAL" $?
grep -aq "8080 Preliminary tests complete" "$OUT";        check "8080PRE.COM: preliminary tests complete" $?
grep -aq "Tests complete" "$OUT";                           check "8080EXM.COM: Tests complete" $?
[ "$(grep -ac '^----Completed test: ' "$OUT")" -eq 4 ];   check "all four programs ran to completion" $?
# 8080EXM prints one `PASS! crc is:<crc>` line per instruction group; the crcs are the known-good values
# for a real 8080 (from the original exerciser), so any wrong flag/result changes a line to ERROR.
[ "$(grep -ac 'PASS! crc is:' "$OUT")" -eq 25 ];          check "8080EXM.COM: 25 instruction groups pass" $?
! grep -aq "ERROR" "$OUT";                                check "8080EXM.COM: no ERROR lines" $?
grep -aq "<inr,dcr> b\.* *PASS! crc is:83ed1345" "$OUT";  check "8080EXM.COM: inr/dcr b crc matches 83ed1345" $?
grep -aq "lhld nnnn\.* *PASS! crc is:a9c3d5cb" "$OUT";    check "8080EXM.COM: lhld crc matches a9c3d5cb" $?

[ "$failed" -eq 0 ] || sed -n '1,60p' "$OUT"
emit_ctrf "ares-i8080" "$passed" "$failed" 0
