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

# Compile the asset catalog so modern surfaces (Control Center mic
# indicator, etc.) get the icon via CFBundleIconName + Assets.car.
ACTOOL="$(xcrun --find actool 2>/dev/null || true)"
if [ -n "$ACTOOL" ]; then
    rm -rf build/actool && mkdir -p build/actool
    if "$ACTOOL" --compile build/actool --platform macosx \
        --minimum-deployment-target 14.0 --target-device mac --app-icon AppIcon \
        --output-partial-info-plist build/icon-partial.plist \
        Sources/Szept/Assets.xcassets >/dev/null 2>&1 \
        && [ -f build/actool/Assets.car ]; then
        cp build/actool/Assets.car "$APP/Contents/Resources/Assets.car"
        echo "icon: compiled Assets.car"
    else
        echo "icon: actool compile failed, some surfaces may show no icon"
    fi
else
    echo "note: actool not found (needs Xcode or CLT), skipping Assets.car"
fi

codesign --force --sign - "$APP"
echo "Built $APP"
