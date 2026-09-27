#!/bin/bash
# Builds the release binary and wraps it in an ad hoc signed Szept.app.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Szept.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swift build -c release
cp .build/release/Szept "$APP/Contents/MacOS/Szept"
cp packaging/Info.plist "$APP/Contents/Info.plist"
if [ -f packaging/AppIcon.icns ]; then
    cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    echo "note: packaging/AppIcon.icns missing, run scripts/make-icon.sh on macOS"
fi

# NOTE: deliberately NOT compiling an Assets.car. A flat (non-layered)
# catalog makes Tahoe's LaunchServices surfaces (Control Center mic list,
# Privacy panes) render a blank icon even though Finder uses the .icns.
# With no car present, the .icns via CFBundleIconFile is authoritative.

codesign --force --sign - "$APP"
echo "Built $APP"
