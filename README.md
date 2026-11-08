# MobileCommand

**Let your Mac keep working while you step away, and check in, steer and dictate from your iPhone.**

AI agents, long builds and renders don't need you at the desk the whole time, but they do need you
now and then. MobileCommand turns the iPhone into a remote control for the Mac: a full multi-touch
trackpad, a pad of shortcut keys, a keyboard, and a wireless microphone that the Mac sees as a real
audio input. So voice dictation works from across the room, the couch or the kitchen.

## What it does

- **Trackpad that behaves like your Mac's.** One-finger pointer with acceleration, tap to click,
  tap-and-drag, double/triple click, two-finger scroll with momentum, two-finger right-click.
- **Your own gestures, mirrored.** The Mac companion reads *System Settings › Trackpad* and maps
  phone gestures onto the same actions: 3/4-finger swipes between Spaces and full-screen apps,
  Mission Control, App Exposé, Show Desktop, Apps. Change a setting on the Mac and the phone follows.
- **iPhone as the Mac's microphone.** The phone mic streams to the Mac, plays into a loopback
  device (BlackHole), and that device becomes the system default input while the mic is live.
  Any app can use it, including push-to-talk dictation tools. The previous input is restored on disconnect.
- **Quick keys.** Configurable buttons: hold-to-talk (holds a specific modifier such as Left Option),
  key combos, system actions, text snippets. Defined in one JSON file on the Mac.
- **Keyboard.** Type on the Mac with the iPhone keyboard, including iOS dictation.
- **Works where you are.** Bonjour discovery over Wi-Fi, peer-to-peer, or the iPhone's own Personal
  Hotspot (when the Mac is tethered to the phone). PIN pairing, heartbeat, auto-reconnect.

## Architecture

```
iPhone (UIKit)                                   Mac (menu bar app)
┌──────────────────────────┐   TCP :47800      ┌───────────────────────────────┐
│ PadView: raw touches →   │   Bonjour          │ Server: pairing, framing      │
│   move/scroll/gestures   │ ─────────────────► │ InputInjector: CGEvent mouse, │
│ Quick keys, keyboard     │  JSON frames       │   keys, L/R modifier holds    │
│ MicStreamer: 48 kHz PCM  │  PCM audio frames  │ SystemActions: gesture map    │
└──────────────────────────┘                    │   from Trackpad settings      │
                                                │ AudioSink: jitter buffer →    │
                                                │   BlackHole → default input   │
                                                └───────────────────────────────┘
```

- `shared/Protocol.swift`: length-prefixed frames `[UInt32 len][type][payload]`; JSON control
  messages and 48 kHz mono Int16 audio.
- `mac/`: Swift, built with `swiftc` (no Xcode project). Signed with an Apple Development identity so
  the Accessibility grant survives rebuilds.
- `ios/`: Swift/UIKit, project generated with XcodeGen.

## Build & run

Requirements: macOS 14+, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
[BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole), an iPhone on iOS 17+.

```bash
mac/build.sh && open mac/MobileCommand.app   # then allow Accessibility when asked
ios/deploy.sh                                # builds, installs and launches on the connected iPhone
```

Set your own `DEVELOPMENT_TEAM` and bundle ID prefix in `ios/project.yml` first.
On the phone, enter the pairing PIN shown in the Mac's menu bar item.

## Configuration

`mac/config.json` is created on first launch. Edit it, then choose *Reload config* in the menu.

```json
{
  "quickKeys": [
    { "id": "dictate", "label": "Dictate", "symbol": "mic.fill", "action": "hold:leftOption", "hold": true },
    { "id": "paste",   "label": "Paste",   "symbol": "doc.on.clipboard", "action": "key:cmd+v" },
    { "id": "desktop", "label": "Desktop", "symbol": "menubar.dock.rectangle", "action": "system:showDesktop" }
  ],
  "gestureOverrides": { "swipe3Down": "appExpose" },
  "pointerSpeed": 1.6,
  "scrollSpeed": 1.2
}
```

Actions: `hold:<modifier>`, `key:<combo>`, `system:<spaceLeft|spaceRight|missionControl|appExpose|showDesktop|launchpad>`, `text:<string>`.
Gestures: `swipe3|swipe4` + `Left|Right|Up|Down`, `pinch4`, `spread4`.

## Status & roadmap

Working: Mac companion, protocol, pairing, gesture mapping, and the audio path (verified end to end
with a scripted client). The iOS app builds; on-device tuning is in progress.

Next:
- Trackpad feel tuning on device; landscape layout polish
- Lower latency audio, Opus compression
- Own Core Audio HAL driver to drop the BlackHole dependency
- In-app editor for quick keys and gestures
- Glanceable status of what the Mac is doing (agent/job progress, notifications)
- USB connection mode

## License

Copyright (C) 2026 Rami Suvanto.

MobileCommand is free software, licensed under the [GNU General Public License v3.0](LICENSE).
You may use, study, modify and share it, but any distributed version, including apps or products
built on this code, must also be released under GPL-3.0 with its source code.
