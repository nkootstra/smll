#!/usr/bin/env bash
set -euo pipefail

REQUIRED="0.15.2"
ACTUAL="$(zig version)"

if [ "$ACTUAL" != "$REQUIRED" ]; then
    echo "error: zig $REQUIRED required; found $ACTUAL" >&2
    exit 1
fi
