import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let server = Server()
    private let injector = InputInjector()
    private let audio = AudioSink()
    private var config = ConfigStore.load()
    private var gestureMap: [String: SystemActions.Action] = [:]
    private var status: Server.Status = .waiting
    private var naturalScroll = true

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        reloadSystemPrefs()
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }

        server.pin = { [weak self] in self?.config.pin ?? "" }
        server.welcome = { [weak self] in self?.makeWelcome() ?? ServerMessage(t: "welcome") }
        server.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s; self?.updateIcon() } }
        server.onMessage = { [weak self] m in self?.handle(m) }
        server.onAudio = { [weak self] d in self?.audio.push(d) }
        server.onDisconnect = { [weak self] in
            guard let self else { return }
            self.injector.releaseAll()
            DispatchQueue.main.async { self.audio.stop() }
        }
        server.start()
        Log.write("PhonePad started, config at \(ConfigStore.url.path)")
    }

    func applicationWillTerminate(_ note: Notification) {
        injector.releaseAll()
        audio.stop()
    }

    private func reloadSystemPrefs() {
        gestureMap = SystemActions.gestureMap(overrides: config.gestureOverrides)
        naturalScroll = (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.swipescrolldirection"] as? Bool) ?? true
    }

    private func makeWelcome() -> ServerMessage {
        ServerMessage(
            t: "welcome",
            host: Host.current().localizedName,
            quickKeys: config.quickKeys.map {
                QuickKeyInfo(id: $0.id, label: $0.label, symbol: $0.symbol, hold: $0.hold ?? $0.action.hasPrefix("hold:"))
            },
            pointerSpeed: config.pointerSpeed,
            scrollSpeed: config.scrollSpeed,
            legend: SystemActions.legend(gestureMap)
        )
    }

    // MARK: Messages (server queue)

    private func handle(_ m: ClientMessage) {
        switch m.t {
        case "move":
            injector.move(dx: m.dx ?? 0, dy: m.dy ?? 0)
        case "button":
            injector.button(m.button ?? "left", down: m.down ?? false)
        case "scroll":
            injector.scroll(dx: m.dx ?? 0, dy: m.dy ?? 0, natural: naturalScroll)
        case "gesture":
            guard let name = m.name else { return }
            let action = gestureMap[name] ?? .none
            Log.write("gesture \(name) → \(action.rawValue)")
            SystemActions.perform(action, injector: injector)
        case "quick":
            guard let key = config.quickKeys.first(where: { $0.id == m.name }) else { return }
            runQuickKey(key, down: m.down ?? true)
        case "text":
            if let t = m.text { injector.type(t) }
        case "key":
            if let n = m.name, let (code, flags) = KeyMap.parseCombo(n) { injector.tapKey(code, flags: flags) }
        case "mic":
            let live = m.down ?? false
            DispatchQueue.main.async {
                if live { self.audio.start(deviceUID: self.config.audioDeviceUID, switchDefaultInput: self.config.switchDefaultInput) }
                else { self.audio.stop() }
                self.server.setMicLive(live && self.audio.isRunning)
            }
        default:
            break
        }
    }

    private func runQuickKey(_ key: QuickKey, down: Bool) {
        let parts = key.action.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let (kind, arg) = (parts[0], parts[1])
        switch kind {
        case "hold":
            if let code = KeyMap.modifierNames[arg] { injector.setModifier(code, down: down) }
        case "key":
            guard down, let (code, flags) = KeyMap.parseCombo(arg) else { return }
            injector.tapKey(code, flags: flags)
        case "system":
            guard down, let a = SystemActions.Action(rawValue: arg) else { return }
            SystemActions.perform(a, injector: injector)
        case "text":
            if down { injector.type(arg) }
        default:
            Log.write("unknown quick key action \(key.action)")
        }
    }

    // MARK: Menu bar

    private func updateIcon() {
        let symbol: String
        switch status {
        case .waiting: symbol = "iphone"
        case .pairing: symbol = "iphone.badge.exclamationmark"
        case .connected(_, let mic): symbol = mic ? "iphone.and.arrow.forward.inward" : "iphone.radiowaves.left.and.right"
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "PhonePad")
            ?? NSImage(systemSymbolName: "iphone", accessibilityDescription: "PhonePad")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state: String
        switch status {
        case .waiting: state = "Waiting for iPhone…"
        case .pairing(let d): state = "\(d) needs the PIN"
        case .connected(let d, let mic): state = "Connected: \(d)" + (mic ? " — mic live" : "")
        }
        menu.addItem(disabled(state))
        menu.addItem(disabled("Pairing PIN: \(config.pin)"))
        if !AXIsProcessTrusted() {
            menu.addItem(item("⚠︎ Grant Accessibility…", #selector(openAccessibility)))
        }
        menu.addItem(.separator())

        let gestures = NSMenuItem(title: "Gestures (from Trackpad settings)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for line in SystemActions.legend(gestureMap) { sub.addItem(disabled(line)) }
        gestures.submenu = sub
        menu.addItem(gestures)

        menu.addItem(item("Open config.json", #selector(openConfig)))
        menu.addItem(item("Reload config & trackpad settings", #selector(reloadConfig)))
        menu.addItem(item("New pairing PIN", #selector(newPin)))
        menu.addItem(.separator())
        menu.addItem(item("Quit PhonePad", #selector(quit)))
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func openAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openConfig() { NSWorkspace.shared.open(ConfigStore.url) }

    @objc private func reloadConfig() {
        config = ConfigStore.load()
        reloadSystemPrefs()
        server.sendWelcome()
    }

    @objc private func newPin() {
        config.pin = String(format: "%06d", Int.random(in: 0...999_999))
        ConfigStore.save(config)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
