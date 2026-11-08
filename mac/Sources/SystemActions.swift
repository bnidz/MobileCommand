import Cocoa

/// macOS actions that trackpad gestures normally trigger, plus how the user's
/// own trackpad settings map phone gestures onto them.
enum SystemActions {
    enum Action: String, CaseIterable {
        case spaceLeft, spaceRight, missionControl, appExpose, showDesktop, launchpad
        case back, forward, none

        var title: String {
            switch self {
            case .spaceLeft: return "Previous Space / full-screen app"
            case .spaceRight: return "Next Space / full-screen app"
            case .missionControl: return "Mission Control"
            case .appExpose: return "App Exposé"
            case .showDesktop: return "Show Desktop"
            case .launchpad: return "Apps"
            case .back: return "Back"
            case .forward: return "Forward"
            case .none: return "—"
            }
        }
    }

    static let gestureNames = [
        "swipe3Left", "swipe3Right", "swipe3Up", "swipe3Down",
        "swipe4Left", "swipe4Right", "swipe4Up", "swipe4Down",
        "pinch4", "spread4",
    ]

    private static let missionControlBinary = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"

    static func perform(_ action: Action, injector: InputInjector) {
        switch action {
        case .spaceLeft: injector.tapKey(123, flags: .maskControl)
        case .spaceRight: injector.tapKey(124, flags: .maskControl)
        case .missionControl: runMissionControl(nil)
        case .appExpose: runMissionControl("2")
        case .showDesktop: runMissionControl("1")
        case .launchpad:
            let apps = URL(fileURLWithPath: "/System/Applications/Apps.app")
            let launchpad = URL(fileURLWithPath: "/System/Applications/Launchpad.app")
            let url = FileManager.default.fileExists(atPath: apps.path) ? apps : launchpad
            DispatchQueue.main.async { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
        case .back: injector.tapKey(33, flags: .maskCommand)      // ⌘[
        case .forward: injector.tapKey(30, flags: .maskCommand)   // ⌘]
        case .none: break
        }
    }

    private static func runMissionControl(_ arg: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: missionControlBinary)
        p.arguments = arg.map { [$0] } ?? []
        do { try p.run() } catch { Log.write("Mission Control launch failed: \(error)") }
    }

    // MARK: Trackpad settings → gesture map

    /// Mirrors System Settings › Trackpad › More Gestures.
    static func gestureMap(overrides: [String: String]) -> [String: Action] {
        let pad = UserDefaults(suiteName: "com.apple.AppleMultitouchTrackpad")
        let dock = UserDefaults(suiteName: "com.apple.dock")
        func int(_ d: UserDefaults?, _ key: String, _ fallback: Int) -> Int {
            (d?.object(forKey: key) as? Int) ?? fallback
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            (dock?.object(forKey: key) as? Bool) ?? fallback
        }

        var map: [String: Action] = [:]
        for n in [3, 4] {
            // Horizontal: 1 = swipe between pages (3-finger only), 2 = swipe between full-screen apps
            let horiz = int(pad, "Trackpad\(n == 3 ? "Three" : "Four")FingerHorizSwipeGesture", 2)
            if horiz == 2 {
                map["swipe\(n)Left"] = .spaceRight   // fingers move left → content to the right slides in
                map["swipe\(n)Right"] = .spaceLeft
            } else if horiz == 1 {
                map["swipe\(n)Left"] = .forward
                map["swipe\(n)Right"] = .back
            }
            // Vertical: 2 = Mission Control up / App Exposé down
            let vert = int(pad, "Trackpad\(n == 3 ? "Three" : "Four")FingerVertSwipeGesture", 2)
            if vert == 2 {
                if bool("showMissionControlGestureEnabled", true) { map["swipe\(n)Up"] = .missionControl }
                if bool("showAppExposeGestureEnabled", false) { map["swipe\(n)Down"] = .appExpose }
            }
        }
        // Three-finger drag disables the three-finger swipes.
        if int(pad, "TrackpadThreeFingerDrag", 0) == 1 {
            for k in ["swipe3Left", "swipe3Right", "swipe3Up", "swipe3Down"] { map[k] = nil }
        }
        if bool("showDesktopGestureEnabled", true) { map["spread4"] = .showDesktop }
        if bool("showLaunchpadGestureEnabled", true) { map["pinch4"] = .launchpad }

        for (gesture, name) in overrides {
            map[gesture] = Action(rawValue: name) ?? Action.none
        }
        return map.filter { $0.value != .none }
    }

    static func legend(_ map: [String: Action]) -> [String] {
        let labels: [String: String] = [
            "swipe3Left": "3 ←", "swipe3Right": "3 →", "swipe3Up": "3 ↑", "swipe3Down": "3 ↓",
            "swipe4Left": "4 ←", "swipe4Right": "4 →", "swipe4Up": "4 ↑", "swipe4Down": "4 ↓",
            "pinch4": "4 pinch", "spread4": "4 spread",
        ]
        return gestureNames.compactMap { g in map[g].map { "\(labels[g]!)  \($0.title)" } }
    }
}
