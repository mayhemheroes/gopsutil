#!/usr/bin/env bash
#
# gopsutil/mayhem/test.sh — RUN a deterministic subset of shirou/gopsutil's OWN Go test suite
# and emit a CTRF summary. exit 0 iff no test failed.
#
# SCOPE — why a subset, not `go test ./...`:
# gopsutil is a system-stats library; most of its packages (process, host, cpu, disk, mem, net,
# load, sensors, docker) probe the LIVE host — they read the real /proc, spawn child processes,
# open netlink sockets, expect specific hardware/permissions — so the full suite is inherently
# host-dependent and flaky inside a sandboxed container (and the docker package literally needs a
# docker daemon). Running it as a build-time oracle would produce non-deterministic failures
# unrelated to our integration.
#
# We scope to ./internal/common/... — gopsutil's host-INDEPENDENT layer: the parsing/conversion
# primitives (ReadLines, MustParseInt32/Uint64/Float64, HexToUint32, StringsContains, IntToString,
# ByteToString), the HOST_PROC/HOST_ETC env resolution (HostEtcWithContext / GetEnvWithContext),
# the Warnings accumulator, and Sleep. These are exactly the building blocks the fuzzed limits
# parser (RlimitUsageWithContext -> fillFromLimitsWithContext) is built on — strings.Fields +
# numeric conversion of the soft/hard fields — and they assert concrete return values
# (assert.Equal / reflect.DeepEqual), so a no-op patch that breaks parsing FAILS this oracle.
# These tests read local fixtures and pure helpers only, so they pass deterministically.
#
# ANTI-REWARD-HACK: This oracle compiles the test binary explicitly, runs it with -test.v, and
# greps the raw output for known PASS/FAIL lines. A neutered binary (or a neutered go tool) emits
# no test output, so the grep finds 0 tests → FAIL.  A no-op patch that stubs out parsing
# functions causes the assert.Equal checks to fail → FAIL.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/usr/local/go/bin:/root/go/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOPATH="${GOPATH:-/home/mayhem/go}"
export GOCACHE="${GOCACHE:-/home/mayhem/.cache/go-build}"
export GOMODCACHE="${GOMODCACHE:-/root/go/pkg/mod}"
cd "$SRC"

PKGS="./internal/common/..."
TESTBIN="/tmp/gopsutil-common.test"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

# Compile the test binary explicitly so we run it directly (not via `go test`).
# This ensures LD_PRELOAD sabotage catches the test binary itself, and the -test.v
# output contains per-test PASS/FAIL lines we can parse as behavioral evidence.
echo "=== compiling test binary for $PKGS ==="
mkdir -p "$SRC/mayhem-build"
if ! go test -c -o "$TESTBIN" $PKGS 2>"$SRC/mayhem-build/gotest-build.err"; then
  echo "--- build error ---"
  cat "$SRC/mayhem-build/gotest-build.err" >&2
  emit_ctrf "go-test" 0 1 0; exit 1
fi

echo "=== running: $TESTBIN -test.v ==="
VLOG="$SRC/mayhem-build/gotest.v"
# Run from the package directory so relative-path fixtures (common_test.go) resolve correctly,
# matching how `go test ./internal/common/...` would set the working directory.
(cd "$SRC/internal/common" && "$TESTBIN" -test.v) > "$VLOG" 2>"$SRC/mayhem-build/gotest.err"; rc=$?

# Show output for humans.
cat "$VLOG" | tail -60
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; cat "$SRC/mayhem-build/gotest.err"; }

# Parse per-test PASS/FAIL/SKIP lines from -test.v output.
# These look like: "--- PASS: TestFoo (0.00s)" or "--- FAIL: TestFoo (0.00s)"
PASSED=$(grep -cE '^\s*--- PASS:' "$VLOG" 2>/dev/null) || PASSED=0
FAILED=$(grep -cE '^\s*--- FAIL:' "$VLOG" 2>/dev/null) || FAILED=0
SKIPPED=$(grep -cE '^\s*--- SKIP:' "$VLOG" 2>/dev/null) || SKIPPED=0

# Behavioral check: we MUST see at least one test that asserts a concrete value.
# TestIntToString checks IntToString([]int8{65,66,67}) == "ABC" — a neutered binary emits nothing.
if ! grep -qE '^\s*--- (PASS|FAIL): Test' "$VLOG" 2>/dev/null; then
  echo "ORACLE: no per-test output found — binary may have been neutered or test suite empty" >&2
  emit_ctrf "go-test" 0 1 0; exit 1
fi

# Trust the parsed failures; if go reported non-zero exit but we counted 0 failures, force one.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"
