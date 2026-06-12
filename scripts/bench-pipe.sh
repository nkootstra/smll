#!/usr/bin/env bash
# Pipe-mode throughput guard for smll.
#
# Streams the whole tests/fixtures/large/ corpus through the release binary as a
# single concatenated input and reports MB/s. Concatenating amortizes the fixed
# per-process startup cost (~ms) over ~1 MB of payload, so the headline number
# reflects actual scan throughput rather than fork+exec overhead — which is what
# a regression like an accidental O(n^2) scan would crater.
#
# The floor (FLOOR_MBPS, default 10) is deliberately GENEROUS: it trips only on
# an egregious regression, not on ordinary CI timing noise. This is a smoke
# alarm, not a microbenchmark. The per-fixture table is informational only (its
# timings are startup-dominated for the small fixtures, so no floor is applied
# per-fixture). The whole corpus is measured — nothing is sampled or dropped.
#
# Usage:
#   scripts/bench-pipe.sh            # measure, print Markdown, enforce floor
#   FLOOR_MBPS=20 scripts/bench-pipe.sh
#   RUNS=60 WARMUP=5 scripts/bench-pipe.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FLOOR_MBPS="${FLOOR_MBPS:-10}"
RUNS="${RUNS:-30}"
WARMUP="${WARMUP:-5}"
CORPUS_DIR="tests/fixtures/large"

zig build release >/dev/null
BIN="zig-out/release/smll"
if ! [ -x "$BIN" ]; then
    echo "error: $BIN not found" >&2
    exit 1
fi

shopt -s nullglob
fixtures=("$CORPUS_DIR"/*.txt)
shopt -u nullglob
if [ "${#fixtures[@]}" -eq 0 ]; then
    echo "error: no fixtures in $CORPUS_DIR" >&2
    exit 1
fi

echo "# smll — pipe throughput"
echo
echo "binary: $BIN ($(stat -f%z "$BIN" 2>/dev/null || stat -c%s "$BIN") bytes)"
echo "corpus: ${#fixtures[@]} fixtures in ${CORPUS_DIR}"
echo "runs: ${RUNS} (warmup ${WARMUP}), floor: ${FLOOR_MBPS} MB/s (whole corpus)"
echo

# One python3 invocation does all the timing. Per-fixture rows go to stderr (so
# they stream into the log), and the guarded whole-corpus throughput is the only
# value on stdout, captured below.
throughput=$(python3 - "$BIN" "$RUNS" "$WARMUP" "${fixtures[@]}" <<'PY'
import subprocess, sys, time

binary = sys.argv[1]
runs = int(sys.argv[2])
warmup = int(sys.argv[3])
fixtures = sys.argv[4:]

def median_ns(data):
    for _ in range(warmup):
        subprocess.run([binary], input=data, stdout=subprocess.DEVNULL)
    samples = []
    for _ in range(runs):
        t0 = time.monotonic_ns()
        subprocess.run([binary], input=data, stdout=subprocess.DEVNULL)
        samples.append(time.monotonic_ns() - t0)
    samples.sort()
    return samples[len(samples) // 2]

print("| fixture | bytes | median ms |", file=sys.stderr)
print("|---|---:|---:|", file=sys.stderr)
combined = bytearray()
for path in fixtures:
    data = open(path, "rb").read()
    combined += data
    name = path.rsplit("/", 1)[-1]
    print(f"| {name} | {len(data)} | {median_ns(data)/1e6:.2f} |", file=sys.stderr)

corpus = bytes(combined)
med = median_ns(corpus)
seconds = med / 1e9
mbps = (len(corpus) / 1e6) / seconds if seconds > 0 else float("inf")
print(f"\nwhole corpus: {len(corpus)} bytes, median {med/1e6:.2f} ms",
      file=sys.stderr)
print(f"{mbps:.1f}")
PY
)

echo
echo "throughput: ${throughput} MB/s (floor ${FLOOR_MBPS} MB/s)"

awk -v m="$throughput" -v f="$FLOOR_MBPS" 'BEGIN {
    if (m + 0 < f + 0) {
        printf "::error::pipe throughput %s MB/s below floor %s MB/s\n", m, f
        exit 1
    }
}'
