#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

clang -fobjc-arc -mmacosx-version-min=14.2 \
    -framework Foundation -framework AppKit -framework CoreAudio \
    -o "$OUT/router-handlers" router-handlers.m
"$OUT/router-handlers"
