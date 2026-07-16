#!/bin/bash
# Builds MacAHK.app from source. Requires Xcode command line tools:
#   xcode-select --install
#
# Usage:
#   ./build_app.sh                 ad-hoc signed, for your own Mac
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build_app.sh
#                                  properly signed, for distribution

set -euo pipefail
cd "$(dirname "$0")"

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

echo
echo "Done: $(pwd)/$APP"
echo "Move it to /Applications and open it."
echo
echo "Note: macOS ties permissions to the app's signature. After a"
echo "rebuild you may need to re-toggle MacAHK in System Settings >"
echo "Privacy & Security > Input Monitoring / Accessibility."
