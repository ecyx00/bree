#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLE_BYTES="${BREE_DIFF_BENCH_BYTES:-16777216}"
ITERATIONS="${BREE_DIFF_BENCH_ITERATIONS:-20}"
export BREE_DIFF_BENCH_MAX_MANIFEST_P95_US="${BREE_DIFF_BENCH_MAX_MANIFEST_P95_US:-1000}"
export BREE_DIFF_BENCH_MIN_READ_MIBPS="${BREE_DIFF_BENCH_MIN_READ_MIBPS:-500}"
export BREE_DIFF_BENCH_MAX_STREAM_P95_MS="${BREE_DIFF_BENCH_MAX_STREAM_P95_MS:-250}"

"${ROOT}/scripts/run-diff-sidecar-cargo.sh" run \
  --quiet \
  --release \
  --locked \
  --manifest-path "${ROOT}/Native/DiffSidecar/Cargo.toml" \
  --bin bree-diff-sidecar \
  --features benchmark \
  -- benchmark "$SAMPLE_BYTES" "$ITERATIONS"

(
  cd "${ROOT}/webviews"
  BREE_DIFF_BENCH_ITERATIONS="${BREE_DIFF_WEB_BENCH_ITERATIONS:-5}" \
    BREE_DIFF_BENCH_RENDER_APP="${BREE_DIFF_BENCH_RENDER_APP:-1}" \
    bun run benchmark
)
