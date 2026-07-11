# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm + libFuzzer + the
# identities + the build-contract ENV. shirou/gopsutil is a pure-Go project, so the base
# (C/C++ only — NO Go toolchain) needs Go added here as a USER root step, then the OSS-Fuzz
# Go fuzzing tooling (go114-fuzz-build / go-118-fuzz-build) that turns the native Go fuzz harness
# into a libFuzzer-instrumented binary linked with $LIB_FUZZING_ENGINE.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t gopsutil-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# NOTE: the OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); the Go fuzz
# binary is built with ASan and links the libFuzzer engine. build.sh handles the Go specifics.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the Go toolchain version. gopsutil's go.mod is `go 1.24.0`; GOTOOLCHAIN=local keeps this
# exact toolchain, so we must pin a Go >= 1.24. 1.24.x builds go114/go-118-fuzz-build and the
# gopsutil module + its own test suite cleanly.
ARG GO_VERSION=1.24.4

# ── Install Go + the OSS-Fuzz Go fuzzing build tools (root step) ──────────────────────────────
# The base image is C/C++-only; replicate OSS-Fuzz base-builder-go's install_go.sh:
#   * official go tarball -> /usr/local/go (PATH'd)
#   * go114-fuzz-build (symlinked as `go-fuzz`)  — builds the LEGACY `func Fuzz([]byte) int` harness
#   * go-118-fuzz-build                          — builds the native `func FuzzX(f *testing.F)` harness
#     (this is what gopsutil's OSS-Fuzz target uses: process.FuzzTest, compile_native_go_fuzzer)
ENV GOROOT=/usr/local/go \
    GOPATH=/root/go \
    GOTOOLCHAIN=local \
    PATH=/usr/local/go/bin:/root/go/bin:/usr/local/bin:/usr/bin:/bin
USER root
RUN repro-sources-list.sh 2>/dev/null || true; \
    apt-get update && apt-get install -yq --no-install-recommends wget ca-certificates git \
    && rm -rf /var/lib/apt/lists/* \
    && wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tgz \
    && tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz \
    && go version \
    && go install github.com/mdempsky/go114-fuzz-build@latest \
    && ln -sf "$GOPATH/bin/go114-fuzz-build" "$GOPATH/bin/go-fuzz" \
    && go install github.com/AdamKorcz/go-118-fuzz-build@latest \
    && ls -la "$GOPATH/bin" \
    && chmod -R a+rX /usr/local/go "$GOPATH" \
    && go clean -cache 2>/dev/null || true
# Let the non-root mayhem user share the module cache + go tools the root step populated.
RUN chmod -R a+rwX /root/go && chmod a+rx /root
USER mayhem

# Non-root mayhem (uid 2000) needs its own writable GOPATH/GOCACHE for the per-commit build.
ENV GOFLAGS=-mod=mod \
    GOPATH=/home/mayhem/go \
    GOCACHE=/home/mayhem/.cache/go-build \
    GOMODCACHE=/root/go/pkg/mod

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run gopsutil's own Go test suite at build time (a failing suite fails the image build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
