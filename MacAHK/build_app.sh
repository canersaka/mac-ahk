#!/bin/bash
# Builds MacAHK.app and installs it into /Applications.
# Requires Xcode command line tools:  xcode-select --install
#
# Usage:
#   ./build_app.sh                 build + install to /Applications
#   ./build_app.sh --no-install    build only, leave MacAHK.app here
#   ./build_app.sh --dmg           also produce MacAHK.dmg for sharing
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build_app.sh
#                                  properly signed, for distribution

set -euo pipefail
cd "$(dirname "$0")"

INSTALL=1
MAKE_DMG=0
for arg in "$@"; do
    case "$arg" in
        --no-install) INSTALL=0 ;;
        --dmg) MAKE_DMG=1 ;;
        --reset-perms)
            # Clears stale permission entries left behind by rebuilds
            # (ad-hoc signatures change every build, and macOS sometimes
            # keeps a dead entry that a toggle can't revive). After this,
            # launch the app and grant fresh.
            tccutil reset Accessibility com.canersaka.macahk || true
            tccutil reset ListenEvent com.canersaka.macahk || true
            echo "Permission entries cleared. Launch MacAHK and re-grant."
            exit 0
            ;;
    esac
done

VERSION="1.0"
APP="MacAHK.app"

echo "Building (release)…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/MacAHK"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacAHK"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>MacAHK</string>
    <key>CFBundleIdentifier</key><string>com.canersaka.macahk</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>MacAHK</string>
    <key>CFBundleDisplayName</key><string>MacAHK</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

if [ -n "${SIGN_ID:-}" ]; then
    echo "Signing with: $SIGN_ID"
    codesign --force --options runtime --sign "$SIGN_ID" "$APP"
else
    echo "Ad-hoc signing (fine for this Mac; use SIGN_ID to distribute)…"
    codesign --force --sign - "$APP"
fi

if [ "$INSTALL" = 1 ]; then
    echo "Installing to /Applications…"
    # Quit a running copy so the executable isn't busy during replace.
    osascript -e 'tell application "MacAHK" to quit' >/dev/null 2>&1 || true
    sleep 1
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    echo "Installed: /Applications/$APP"
fi

if [ "$MAKE_DMG" = 1 ]; then
    echo "Creating MacAHK.dmg…"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f MacAHK.dmg
    hdiutil create -volname MacAHK -srcfolder "$STAGE" -ov \
        -format UDZO MacAHK.dmg >/dev/null
    rm -rf "$STAGE"
    echo "Created: $(pwd)/MacAHK.dmg"
    echo "(For sharing beyond your own Macs, sign with SIGN_ID and"
    echo " notarize, or recipients will fight Gatekeeper.)"
fi

echo
echo "Done."
echo
echo "Note: macOS ties permissions to the app's signature. After a"
echo "rebuild you may need to re-toggle MacAHK in System Settings >"
echo "Privacy & Security > Input Monitoring / Accessibility."
