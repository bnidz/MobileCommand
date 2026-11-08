#!/bin/bash
# Builds PhonePad for the connected iPhone, installs and launches it.
set -e
cd "$(dirname "$0")"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate -q
xcodebuild -project PhonePad.xcodeproj -scheme PhonePad -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates -quiet build
DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /available|connected/ {print $3; exit}')
[ -z "$DEVICE" ] && { echo "No iPhone available — unlock it and keep it on the same network or cable."; exit 1; }
xcrun devicectl device install app --device "$DEVICE" build/Build/Products/Release-iphoneos/PhonePad.app
xcrun devicectl device process launch --device "$DEVICE" com.ramisuvanto.phonepad
