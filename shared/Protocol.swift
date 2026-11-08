import Foundation

// Wire protocol shared by the iPhone app and the Mac companion.
// Every frame: [UInt32 big-endian length of (type + payload)][UInt8 type][payload]
// JSON frames carry control messages; audio frames carry 48 kHz mono Int16 PCM.

enum PP {
    static let serviceType = "_mobilecommand._tcp"
    static let port: UInt16 = 47800
    static let audioSampleRate: Double = 48000
}

enum FrameType: UInt8 {
    case json = 1
    case audio = 2
}

/// Phone → Mac.
/// t: hello, ping, move, button, scroll, gesture, quick, text, key, mic
struct ClientMessage: Codable {
    var t: String
    var dx: Double? = nil
    var dy: Double? = nil
    var button: String? = nil   // "left" / "right"
    var down: Bool? = nil
    var name: String? = nil     // gesture name, quick key id, key name
    var text: String? = nil
    var pin: String? = nil
    var device: String? = nil
}

/// Mac → phone.
/// t: welcome, needPin
struct ServerMessage: Codable {
    var t: String
    var host: String? = nil
    var quickKeys: [QuickKeyInfo]? = nil
    var pointerSpeed: Double? = nil
    var scrollSpeed: Double? = nil
    var legend: [String]? = nil     // human-readable gesture map, e.g. "3↑ Mission Control"
}

struct QuickKeyInfo: Codable {
    var id: String
    var label: String
    var symbol: String?
    var hold: Bool
}

enum Frame {
    static func encode(_ type: FrameType, _ payload: Data) -> Data {
        var len = UInt32(payload.count + 1).bigEndian
        var out = Data(bytes: &len, count: 4)
        out.append(type.rawValue)
        out.append(payload)
        return out
    }

    static func json<T: Encodable>(_ value: T) -> Data? {
        guard let body = try? JSONEncoder().encode(value) else { return nil }
        return encode(.json, body)
    }

    /// Pulls complete frames off the front of `buffer`.
    static func drain(_ buffer: inout Data) -> [(FrameType, Data)] {
        var frames: [(FrameType, Data)] = []
        while buffer.count >= 5 {
            let b = buffer.startIndex
            let len = Int(buffer[b]) << 24 | Int(buffer[b + 1]) << 16 | Int(buffer[b + 2]) << 8 | Int(buffer[b + 3])
            guard len >= 1, len < 4_000_000 else { buffer.removeAll(); break }
            guard buffer.count >= 4 + len else { break }
            let typeByte = buffer[b + 4]
            let payload = Data(buffer[(b + 5)..<(b + 4 + len)])
            buffer = Data(buffer[(b + 4 + len)...])
            if let type = FrameType(rawValue: typeByte) { frames.append((type, payload)) }
        }
        return frames
    }
}
