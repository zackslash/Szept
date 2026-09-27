#!/bin/bash
# Builds the release binary and wraps it in an ad hoc signed Szept.app.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Szept.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swift build -c release
cp .build/release/Szept "$APP/Contents/MacOS/Szept"
cp packaging/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"
echo "Built $APP"
