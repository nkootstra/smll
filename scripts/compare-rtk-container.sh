#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTK_REF="${RTK_REF:-v0.42.1}"
DOCKER="${DOCKER:-docker}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/zig-out/benchmarks}"
TAG_REF="$(printf '%s' "$RTK_REF" | tr -c 'A-Za-z0-9_.-' '-')"
IMAGE="${IMAGE:-smll-vs-rtk:$TAG_REF}"
DOCKERFILE="$REPO_ROOT/benchmarks/smll-vs-rtk/Dockerfile"

if ! command -v "$DOCKER" >/dev/null 2>&1; then
    echo "error: Docker not found. Set DOCKER=/path/to/docker or install Docker." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

"$DOCKER" build \
    --build-arg "RTK_REF=$RTK_REF" \
    -t "$IMAGE" \
    -f "$DOCKERFILE" \
    "$REPO_ROOT/benchmarks/smll-vs-rtk"

"$DOCKER" run --rm --network none \
    -v "$REPO_ROOT:/src:ro" \
    -v "$OUT_DIR:/out" \
    "$IMAGE" \
    bash -lc '
        set -euo pipefail
        export PATH="/opt/bench-venv/bin:/usr/local/bin:/usr/bin:/bin"
        export HOME="/tmp/home"
        export XDG_CONFIG_HOME="/tmp/xdg-config"
        export XDG_DATA_HOME="/tmp/xdg-data"
        export RTK_TELEMETRY_DISABLED=1
        export DO_NOT_TRACK=1
        export SMLL_TEE=0
        export NO_COLOR=1
        export TERM=dumb
        export LC_ALL=C
        export LANG=C

        rm -rf /tmp/smll-work "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
        mkdir -p /tmp/smll-work "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
        tar \
            --exclude="./zig-out" \
            --exclude="./.zig-cache" \
            --exclude="./.git/fsmonitor--daemon.ipc" \
            -C /src -cf - . | tar -C /tmp/smll-work -xf -
        cd /tmp/smll-work

        zig build release >/tmp/smll-release-build.log
        python3 scripts/compare-rtk.py \
            --smll-bin /tmp/smll-work/zig-out/release/smll \
            --rtk-bin /opt/rtk/rtk \
            --require-tokenizer \
            --json /out/smll-vs-rtk.json \
            --markdown /out/smll-vs-rtk.md \
            --outputs-dir /out/smll-vs-rtk-outputs \
            "$@"
    ' smll-vs-rtk "$@"

echo
echo "Wrote benchmark results under:"
echo "  $OUT_DIR/"
echo "Default output paths:"
echo "  $OUT_DIR/smll-vs-rtk.md"
echo "  $OUT_DIR/smll-vs-rtk.json"
echo "  $OUT_DIR/smll-vs-rtk-outputs/"
