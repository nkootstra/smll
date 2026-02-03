#!/usr/bin/env bash
# Absolute metrics for smll v0.2: binary size, compression ratio, latency.
# Emits plain Markdown.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

zig build release >/dev/null
BIN="zig-out/release/smll"

if ! [ -x "$BIN" ]; then
    echo "error: $BIN not found" >&2
    exit 1
fi

size_bytes() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

wc_words() {
    # POSIX wc -w; trim leading whitespace
    wc -w < "$1" | tr -d ' '
}

percent() {
    awk -v b="$1" -v a="$2" 'BEGIN { if (b == 0) print "0.0"; else printf "%.1f", 100*(b-a)/b }'
}

median_ms() {
    local bin="$1"
    local fixture="$2"
    if command -v hyperfine >/dev/null; then
        hyperfine --warmup 3 --runs 50 --shell=none --export-json /tmp/smll_hf.json \
            "$bin < $fixture" >/dev/null 2>&1 || return 1
        python3 -c "import json; d=json.load(open('/tmp/smll_hf.json')); print(f\"{d['results'][0]['median']*1000:.2f}\")"
    else
        python3 - "$bin" "$fixture" <<'PY'
import sys, subprocess, time
bin, fixture = sys.argv[1], sys.argv[2]
data = open(fixture, 'rb').read()
samples = []
for _ in range(5):
    subprocess.run([bin], input=data, stdout=subprocess.DEVNULL)
for _ in range(30):
    t0 = time.monotonic_ns()
    subprocess.run([bin], input=data, stdout=subprocess.DEVNULL)
    samples.append(time.monotonic_ns() - t0)
samples.sort()
print(f"{samples[len(samples)//2]/1e6:.2f}")
PY
    fi
}

echo "# smll v0.2 — absolute metrics"
echo
echo "## Binary size"
echo
size=$(size_bytes "$BIN")
echo "- stripped: ${size} bytes"

echo
echo "## Compression (wc -w)"
echo
echo "| fixture | input words | output words | reduction |"
echo "|---|---:|---:|---:|"
for fixture in tests/fixtures/*.txt; do
    before=$(wc_words "$fixture")
    after=$("$BIN" < "$fixture" | wc -w | tr -d ' ')
    ratio=$(percent "$before" "$after")
    echo "| $(basename "$fixture") | $before | $after | ${ratio}% |"
done

echo
echo "## Latency (median)"
echo
echo "| fixture | median |"
echo "|---|---:|"
for fixture in tests/fixtures/*.txt; do
    ms=$(median_ms "$BIN" "$fixture")
    echo "| $(basename "$fixture") | ${ms} ms |"
done
