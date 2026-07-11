#!/usr/bin/env bash
#
# gopsutil/mayhem/build.sh — build shirou/gopsutil's OSS-Fuzz Go fuzz target as a sanitized
# libFuzzer binary, REPLICATING OSS-Fuzz's compile_native_go_fuzzer.
#
# OSS-Fuzz target (projects/gopsutil/build.sh):
#   cp $SRC/fuzz_test.go ./process/
#   printf 'package process\nimport _ "github.com/AdamKorcz/go-118-fuzz-build/testing"\n' > ./process/register.go
#   compile_native_go_fuzzer github.com/shirou/gopsutil/v4/process FuzzTest FuzzTest
# i.e. the NATIVE go fuzz harness `func FuzzTest(f *testing.F)` (mayhem/fuzz_test.go), built with
# `go-118-fuzz-build`, then linked with $LIB_FUZZING_ENGINE.
#
# The harness writes the fuzzed bytes to a /proc-style <pid>/limits file (HOST_PROC=".") and runs
# RlimitUsageWithContext -> fillFromLimitsWithContext, gopsutil's /proc/<pid>/limits text parser
# (strings.Fields + str[len(str)-1] indexing). The fuzzed surface is that limits parser.
#
# We produce:
#   /mayhem/FuzzTest   — OSS-Fuzz target (process.FuzzTest, go-118-fuzz-build, ASan+libFuzzer)
#
# The .a archive carries the Go fuzz code (instrumented by the go-118 builder); we link it
# against the C/C++ libFuzzer engine with clang ($CXX) + ASan, exactly like
# compile_native_go_fuzzer's final `$CXX $CXXFLAGS $LIB_FUZZING_ENGINE $fuzzer.a -o $OUT/$fuzzer`.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
# §6.2 item 10: fuzz binary must carry DWARF < 4. The final clang++ link step compiles a tiny
# C-shim CU with -gdwarf-3, making the first DWARF CU in the ELF be version 3 (what Mayhem
# triage reads). CGO_CFLAGS/CGO_CXXFLAGS propagate into any CGo compilation as well.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS GO_DEBUG_FLAGS

# Go env: non-root build needs writable GOCACHE/GOPATH; reuse the root-populated module cache.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOPATH="${GOPATH:-/home/mayhem/go}"
export GOCACHE="${GOCACHE:-/home/mayhem/.cache/go-build}"
export GOMODCACHE="${GOMODCACHE:-/root/go/pkg/mod}"
mkdir -p "$GOPATH" "$GOCACHE"
# The go-118-fuzz-build tool lives on PATH via /root/go/bin (set in the Dockerfile); make sure it
# is present even if this is run standalone.
export PATH="/usr/local/go/bin:/root/go/bin:$GOPATH/bin:$PATH"

cd "$SRC"
go version

# OSS-Fuzz drops the native harness into the process package and registers the go-118 testing
# shim. Replicate exactly: copy fuzz_test.go into ./process/ and emit ./process/register.go.
cp "$SRC/mayhem/fuzz_test.go" "$SRC/process/fuzz_test.go"
printf 'package process\nimport _ "github.com/AdamKorcz/go-118-fuzz-build/testing"\n' > "$SRC/process/register.go"

# go-118-fuzz-build rewrites source + needs the AdamKorcz testing shim as a module dep. Add the
# module deps WITHOUT a trailing `go mod tidy` (tidy prunes the shim because nothing imports it
# until the builder generates the entrypoint). Order matters: tidy first, then `go get` the shim.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# ── OSS-Fuzz target: process.FuzzTest via go-118-fuzz-build (func FuzzTest(f *testing.F)) ────────
#     Exact replica of `compile_native_go_fuzzer github.com/shirou/gopsutil/v4/process FuzzTest`.
#     go-118-fuzz-build wants the package DIRECTORY containing the harness.
echo "=== building FuzzTest (process.FuzzTest, go-118-fuzz-build) ==="
go-118-fuzz-build -o "$SRC/mayhem-build/FuzzTest.a" -func FuzzTest "$SRC/process"
$CXX $GO_DEBUG_FLAGS $SANITIZER_FLAGS $LIB_FUZZING_ENGINE "$SRC/mayhem-build/FuzzTest.a" -o /mayhem/FuzzTest
echo "built /mayhem/FuzzTest"

echo "build.sh complete:"
ls -la /mayhem/FuzzTest 2>&1 || true
