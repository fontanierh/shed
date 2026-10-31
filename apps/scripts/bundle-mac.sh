#!/bin/bash
# Build the Mac app and wrap the SwiftPM executable in an .app bundle.
# Usage: scripts/bundle-mac.sh [debug|release]  → apps/build/Shed.app
set -euo pipefail
cd "$(dirname "$0")/.."
config="${1:-release}"
swift build -c "$config" --product AgentRemoteMac
bin="$(swift build -c "$config" --show-bin-path)/AgentRemoteMac"
app="build/Shed.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/Shed"
mkdir -p "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Nordwand Mono (SIL OFL), registered for the app alone through ATSApplicationFontsPath.
rm -rf "$app/Contents/Resources/Fonts"
cp -R Resources/Fonts "$app/Contents/Resources/Fonts"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Kept from the Agent Remote days so saved settings carry over. -->
  <key>CFBundleIdentifier</key><string>dev.agentremote.mac</string>
  <key>CFBundleName</key><string>Shed</string>
  <key>CFBundleDisplayName</key><string>Shed</string>
  <key>CFBundleExecutable</key><string>Shed</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null
echo "$app"
