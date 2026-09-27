#!/usr/bin/env bash
# Builds Macasnap.app into ./build. Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Macasnap.app"
BUNDLE_ID="com.evan.macasnap"
VERSION="$(< VERSION)"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Macasnap"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Macasnap"
# Regenerate with: swift scripts/make-icon.swift Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Macasnap</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>Macasnap</string>
    <key>CFBundleDisplayName</key><string>Macasnap</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSScreenCaptureUsageDescription</key><string>Macasnap captures the area you select to beautify it.</string>
</dict>
</plist>
PLIST

# A stable signing identity keeps the Screen Recording grant across rebuilds (ad-hoc would not).
./scripts/make-signing-cert.sh >/dev/null
security unlock-keychain -p macasnap "$HOME/Library/Keychains/macasnap-signing.keychain-db"
codesign --force --sign "Macasnap Self-Signed" --keychain "$HOME/Library/Keychains/macasnap-signing.keychain-db" \
    --identifier "$BUNDLE_ID" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/Macasnap.app"
    pkill -x Macasnap || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "Installed $DEST"
fi
