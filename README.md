# MobileCommand

iPhone as a Mac trackpad, quick-key pad and wireless microphone.

- `mac/` — menu bar companion (swiftc, `./build.sh`). Posts mouse/keyboard events,
  maps phone gestures onto your Trackpad settings, and plays the phone mic into
  BlackHole 2ch, switching the Mac's default input to it while the mic is live.
  Edit `mac/config.json` (quick keys, speeds, gesture overrides), then menu › Reload.
- `ios/` — UIKit app (`xcodegen`, `./deploy.sh`). Finds the Mac over Bonjour
  (works over Personal Hotspot), pairs with the PIN from the Mac's menu.
- `shared/Protocol.swift` — length-prefixed JSON + PCM frames, TCP port 47800.

Quick-key actions: `hold:leftOption`, `key:cmd+v`, `system:showDesktop`
(spaceLeft, spaceRight, missionControl, appExpose, showDesktop, launchpad), `text:…`.
Gesture overrides: `{"swipe3Down": "appExpose"}` — names swipe3/4Left/Right/Up/Down, pinch4, spread4.
