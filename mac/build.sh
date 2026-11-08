#!/bin/bash
# Builds PhonePad.app (Mac companion) with swiftc and signs it with the
# Apple Development identity so the Accessibility grant survives rebuilds.
set -e
cd "$(dirname "$0")"

APP="PhonePad.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -target arm64-apple-macosx14.0 -O \
    -framework Cocoa -framework AVFoundation -framework CoreAudio -framework Network \
    -o "$APP/Contents/MacOS/PhonePad" \
    Sources/*.swift ../shared/Protocol.swift

IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
codesign --force --sign "${IDENTITY:--}" --identifier com.ramisuvanto.phonepad.mac "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"
