import Foundation

/// One quick-key button on the phone. `action` is a small string DSL so the
/// JSON stays hand-editable:
///   "hold:leftOption"        hold a modifier while the button is held
///   "key:return", "key:cmd+v", "key:ctrl+left"
///   "system:showDesktop"     see SystemActions.Action
///   "text:hello"             type literal text
struct QuickKey: Codable {
    var id: String
    var label: String
    var symbol: String?
    var action: String
    var hold: Bool?
}

struct PadConfig: Codable {
    var pin: String
    var pointerSpeed: Double
    var scrollSpeed: Double
    /// Route the phone's mic into this output device and make it the Mac's default input.
    var audioDeviceUID: String
    var switchDefaultInput: Bool
    /// Gesture name → system action, overrides what the trackpad settings imply.
    /// Names: swipe3Left/Right/Up/Down, swipe4…, pinch4, spread4. Value "none" disables.
    var gestureOverrides: [String: String]
    var quickKeys: [QuickKey]

    static func makeDefault() -> PadConfig {
        PadConfig(
            pin: String(format: "%06d", Int.random(in: 0...999_999)),
            pointerSpeed: 1.6,
            scrollSpeed: 1.2,
            audioDeviceUID: "BlackHole2ch_UID",
            switchDefaultInput: true,
            gestureOverrides: [:],
            quickKeys: [
                QuickKey(id: "dictate", label: "Dictate", symbol: "mic.fill", action: "hold:leftOption", hold: true),
                QuickKey(id: "return", label: "Return", symbol: "return", action: "key:return", hold: nil),
                QuickKey(id: "escape", label: "Esc", symbol: "escape", action: "key:escape", hold: nil),
                QuickKey(id: "paste", label: "Paste", symbol: "doc.on.clipboard", action: "key:cmd+v", hold: nil),
                QuickKey(id: "desktop", label: "Desktop", symbol: "menubar.dock.rectangle", action: "system:showDesktop", hold: nil),
                QuickKey(id: "mission", label: "Mission", symbol: "rectangle.3.group", action: "system:missionControl", hold: nil),
                QuickKey(id: "undo", label: "Undo", symbol: "arrow.uturn.backward", action: "key:cmd+z", hold: nil),
                QuickKey(id: "apptab", label: "App ⇥", symbol: "square.stack", action: "key:cmd+tab", hold: nil),
            ]
        )
    }
}

enum ConfigStore {
    /// config.json lives next to PhonePad.app (i.e. in mac/), like Dictator2's settings.
    static var url: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("config.json")
    }

    static func load() -> PadConfig {
        if let data = try? Data(contentsOf: url) {
            do { return try JSONDecoder().decode(PadConfig.self, from: data) }
            catch { Log.write("config.json unreadable (\(error)); using defaults without overwriting") ; return PadConfig.makeDefault() }
        }
        let cfg = PadConfig.makeDefault()
        save(cfg)
        return cfg
    }

    static func save(_ cfg: PadConfig) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(cfg) { try? data.write(to: url) }
    }
}

enum Log {
    private static let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("phonepad.log")
    private static let queue = DispatchQueue(label: "pp.log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func write(_ msg: String) {
        let line = "\(fmt.string(from: Date())) \(msg)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
    }
}
