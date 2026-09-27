#!/bin/bash
# Regenerates packaging/AppIcon.icns from packaging/icon-1024.png.
# Run on macOS (needs sips and iconutil).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="packaging/icon-1024.png"
SET="build/icon.iconset"
rm -rf "$SET"
mkdir -p "$SET"

size() { sips -z "$2" "$2" "$SRC" --out "$SET/icon_$1.png" >/dev/null; }
size 16x16 16
size "16x16@2x" 32
size 32x32 32
size "32x32@2x" 64
size 128x128 128
size "128x128@2x" 256
size 256x256 256
size "256x256@2x" 512
size 512x512 512
size "512x512@2x" 1024

iconutil -c icns "$SET" -o packaging/AppIcon.icns
echo "Built packaging/AppIcon.icns"
