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

# Sign with the stable "Szept Dev" identity when its keychain exists
# (same identity across rebuilds and releases: TCC permissions persist,
# no mic re-prompt per build), else fall back to ad-hoc. The keychain
# lives at ~/Library/Keychains/szept-dev.keychain-db and must be in the
# user keychain search list (see scripts/setup-signing.md).
KC="$HOME/Library/Keychains/szept-dev.keychain-db"
if [ -f "$KC" ] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "Szept Dev"; then
    # The keychain password lives in ~/.szept-signing (mode 600, user
    # only) - the login keychain refuses non-GUI writes over SSH, and the
    # repo must stay secret-free.
    KCPW=$(cat "$HOME/.szept-signing" 2>/dev/null || true)
    if [ -n "$KCPW" ]; then
        security unlock-keychain -p "$KCPW" "$KC" 2>/dev/null || true
        security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KCPW" "$KC" >/dev/null 2>&1 || true
    fi
    if codesign --force --sign "Szept Dev" "$APP" 2>/dev/null; then
        echo "Signed with Szept Dev identity"
    else
        codesign --force --sign - "$APP"
        echo "warning: Szept Dev identity present but signing failed; fell back to ad hoc"
    fi
else
    codesign --force --sign - "$APP"
    echo "note: Szept Dev identity not found, signed ad hoc (TCC will re-prompt per build)"
fi
echo "Built $APP"
