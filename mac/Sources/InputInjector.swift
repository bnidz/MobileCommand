import Cocoa
import CoreGraphics

/// Posts synthetic mouse/keyboard events. Needs Accessibility permission.
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)

    private var pos: CGPoint = .zero
    private var lastMoveAt: TimeInterval = 0
    private var leftDown = false
    private var lastClickAt: TimeInterval = 0
    private var lastClickPos: CGPoint = .zero
    private var clickCount = 1
    private var heldFlags: CGEventFlags = []
    private var heldModifierKeys = Set<CGKeyCode>()
    private var scrollRemainder = CGPoint.zero

    // MARK: Pointer

    private func currentPosition() -> CGPoint {
        // Re-sync with the real cursor when the physical trackpad may have moved it.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMoveAt > 0.25, let loc = CGEvent(source: nil)?.location { pos = loc }
        return pos
    }

    func move(dx: Double, dy: Double) {
        let old = currentPosition()
        pos = clamp(CGPoint(x: old.x + dx, y: old.y + dy), from: old)
        lastMoveAt = ProcessInfo.processInfo.systemUptime
        let type: CGEventType = leftDown ? .leftMouseDragged : .mouseMoved
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: pos, mouseButton: .left) else { return }
        e.flags = heldFlags
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        e.post(tap: .cghidEventTap)
    }

    func button(_ name: String, down: Bool) {
        let p = currentPosition()
        let isRight = name == "right"
        if !isRight {
            if down {
                let now = ProcessInfo.processInfo.systemUptime
                let near = hypot(p.x - lastClickPos.x, p.y - lastClickPos.y) < 8
                clickCount = (now - lastClickAt < NSEvent.doubleClickInterval && near) ? clickCount + 1 : 1
                lastClickAt = now
                lastClickPos = p
            }
            leftDown = down
        }
        let type: CGEventType = isRight ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .leftMouseDown : .leftMouseUp)
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: isRight ? .right : .left) else { return }
        e.flags = heldFlags
        e.setIntegerValueField(.mouseEventClickState, value: Int64(isRight ? 1 : clickCount))
        e.post(tap: .cghidEventTap)
    }

    /// dx/dy are finger motion in points; positive dy = fingers moved down.
    /// Pixel scroll events aren't flipped by the natural-scrolling setting, so we flip here.
    func scroll(dx: Double, dy: Double, natural: Bool) {
        let sign: Double = natural ? 1 : -1
        scrollRemainder.x += dx * sign
        scrollRemainder.y += dy * sign
        let wx = Int32(scrollRemainder.x.rounded(.towardZero))
        let wy = Int32(scrollRemainder.y.rounded(.towardZero))
        guard wx != 0 || wy != 0 else { return }
        scrollRemainder.x -= Double(wx)
        scrollRemainder.y -= Double(wy)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: wy, wheel2: wx, wheel3: 0) else { return }
        e.flags = heldFlags
        e.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    func tapKey(_ code: CGKeyCode, flags: CGEventFlags) {
        var f = flags.union(heldFlags)
        if KeyMap.isArrowOrFunction(code) { f.insert(.maskSecondaryFn) }
        if KeyMap.isArrow(code) { f.insert(.maskNumericPad) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = f
            e.post(tap: .cghidEventTap)
        }
    }

    /// Press/release a single modifier key as a real flagsChanged event,
    /// including the device-dependent left/right bits apps like Dictator2 check.
    func setModifier(_ code: CGKeyCode, down: Bool) {
        guard let info = KeyMap.modifierInfo[code] else { return }
        if down { heldModifierKeys.insert(code) } else { heldModifierKeys.remove(code) }
        heldFlags = heldModifierKeys.reduce(CGEventFlags()) { acc, key in
            guard let i = KeyMap.modifierInfo[key] else { return acc }
            return acc.union(i.flag).union(CGEventFlags(rawValue: i.deviceBit))
        }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.type = .flagsChanged
        e.flags = heldFlags.union(down ? CGEventFlags(rawValue: info.deviceBit) : [])
        e.post(tap: .cghidEventTap)
    }

    func type(_ text: String) {
        let utf16 = Array(text.utf16)
        var i = 0
        while i < utf16.count {
            let chunk = Array(utf16[i..<min(i + 16, utf16.count)])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e.post(tap: .cghidEventTap)
            }
            i += 16
        }
    }

    /// Called on disconnect so nothing stays stuck down.
    func releaseAll() {
        if leftDown { button("left", down: false) }
        for code in heldModifierKeys { setModifier(code, down: false) }
    }

    // MARK: Screen bounds

    private func clamp(_ p: CGPoint, from old: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let bounds = ids.map { CGDisplayBounds($0) }
        if bounds.contains(where: { $0.contains(p) }) { return p }
        let home = bounds.first(where: { $0.contains(old) }) ?? bounds.first ?? .zero
        return CGPoint(x: min(max(p.x, home.minX), home.maxX - 1), y: min(max(p.y, home.minY), home.maxY - 1))
    }
}

enum KeyMap {
    struct ModInfo { let flag: CGEventFlags; let deviceBit: UInt64 }

    // NX_DEVICE*KEYMASK bits
    static let modifierInfo: [CGKeyCode: ModInfo] = [
        59: ModInfo(flag: .maskControl, deviceBit: 0x01),     // left control
        56: ModInfo(flag: .maskShift, deviceBit: 0x02),       // left shift
        60: ModInfo(flag: .maskShift, deviceBit: 0x04),       // right shift
        55: ModInfo(flag: .maskCommand, deviceBit: 0x08),     // left command
        54: ModInfo(flag: .maskCommand, deviceBit: 0x10),     // right command
        58: ModInfo(flag: .maskAlternate, deviceBit: 0x20),   // left option
        61: ModInfo(flag: .maskAlternate, deviceBit: 0x40),   // right option
        62: ModInfo(flag: .maskControl, deviceBit: 0x2000),   // right control
    ]

    static let modifierNames: [String: CGKeyCode] = [
        "leftOption": 58, "rightOption": 61, "leftCommand": 55, "rightCommand": 54,
        "leftShift": 56, "rightShift": 60, "leftControl": 59, "rightControl": 62,
    ]

    static let comboModifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "opt": .maskAlternate, "option": .maskAlternate,
        "alt": .maskAlternate, "ctrl": .maskControl, "control": .maskControl, "shift": .maskShift, "fn": .maskSecondaryFn,
    ]

    static let keys: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    static func isArrow(_ c: CGKeyCode) -> Bool { (123...126).contains(c) }
    static func isArrowOrFunction(_ c: CGKeyCode) -> Bool {
        isArrow(c) || [115, 116, 117, 119, 121, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].contains(c)
    }

    /// "cmd+shift+v" → (keycode, flags)
    static func parseCombo(_ combo: String) -> (CGKeyCode, CGEventFlags)? {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last, let code = keys[last] else { return nil }
        var flags: CGEventFlags = []
        for p in parts.dropLast() {
            guard let f = comboModifiers[p] else { return nil }
            flags.insert(f)
        }
        return (code, flags)
    }
}
