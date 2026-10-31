#!/bin/bash
# Build the iPhone app and install it on a connected iPhone (USB or the same Wi-Fi, with Developer Mode on).
# Needs Xcode signed in to an Apple account (Xcode > Settings > Accounts); a free account works.
#
#   apps/scripts/install-iphone.sh TEAM_ID [BUNDLE_ID] [DEVICE]
#
#   TEAM_ID    your Apple developer team, shown in Xcode > Settings > Accounts
#   BUNDLE_ID  defaults to dev.agentremote.shed; pick your own (com.example.shed) unless you are on that team
#   DEVICE     an identifier from `xcrun devicectl list devices`; defaults to the only iPhone available
set -euo pipefail
cd "$(dirname "$0")/../iOS"
TEAM="${1:?usage: apps/scripts/install-iphone.sh TEAM_ID [BUNDLE_ID] [DEVICE]}"
BUNDLE="${2:-dev.agentremote.shed}"
DEVICE="${3:-}"

if [ -z "$DEVICE" ]; then
  list="$(mktemp)"
  xcrun devicectl list devices --json-output "$list" >/dev/null
  field() { plutil -extract "result.devices.$i.$1" raw -o - "$list" 2>/dev/null || true; }
  i=0
  while udid="$(plutil -extract "result.devices.$i.hardwareProperties.udid" raw -o - "$list" 2>/dev/null)"; do
    if [ "$(field hardwareProperties.reality)" = physical ] && [ "$(field hardwareProperties.deviceType)" = iPhone ] &&
      [ "$(field connectionProperties.pairingState)" = paired ]; then
      [ -z "$DEVICE" ] || { echo "More than one iPhone is paired: pass the identifier of one as DEVICE." >&2; exit 1; }
      DEVICE="$udid"
    fi
    i=$((i + 1))
  done
  rm -f "$list"
  [ -n "$DEVICE" ] || { echo "Connect and pair an iPhone (Xcode > Window > Devices and Simulators) first." >&2; exit 1; }
fi

xcodebuild -project Shed.xcodeproj -scheme Shed -configuration Release \
  -destination "id=$DEVICE" -derivedDataPath ../build/ios-device -allowProvisioningUpdates -quiet \
  DEVELOPMENT_TEAM="$TEAM" SHED_BUNDLE_ID="$BUNDLE" build
xcrun devicectl device install app --device "$DEVICE" ../build/ios-device/Build/Products/Release-iphoneos/Shed.app
