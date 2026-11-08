import UIKit

final class MainViewController: UIViewController, UITextFieldDelegate {
    private let connection = Connection()
    private let mic = MicStreamer()
    private let pad = PadView()

    private let statusDot = UIView()
    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let keyboardButton = UIButton(type: .system)
    private let legendLabel = UILabel()
    private let keysGrid = UIStackView()
    private let content = UIStackView()
    private let keyCatcher = KeyCatcher()

    private var quickKeys: [QuickKeyInfo] = []
    private var keysSize: NSLayoutConstraint?
    private var isLandscape = false
    private var connected = false
    private var askingPin = false

    private var micOn: Bool {
        get { UserDefaults.standard.object(forKey: "micOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "micOn") }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    // Stop iOS from treating 3-finger swipes as undo/redo.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUI()
        wirePad()

        connection.onState = { [weak self] in self?.apply($0) }
        connection.onWelcome = { [weak self] in self?.applyWelcome($0) }
        mic.onChunk = { [weak self] in self?.connection.sendAudio($0) }
        connection.start()
        if connection.pin.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.askPin(host: "your Mac") } }
    }

    // MARK: UI

    private func buildUI() {
        statusDot.backgroundColor = .systemOrange
        statusDot.layer.cornerRadius = 5
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        statusLabel.text = "Searching for Mac…"
        statusLabel.textColor = .secondaryLabel
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)

        let statusTap = UIStackView(arrangedSubviews: [statusDot, statusLabel])
        statusTap.spacing = 8
        statusTap.alignment = .center
        statusTap.isUserInteractionEnabled = true
        statusTap.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showSettings)))

        keyboardButton.setImage(UIImage(systemName: "keyboard"), for: .normal)
        keyboardButton.tintColor = .white
        keyboardButton.addTarget(self, action: #selector(toggleKeyboard), for: .touchUpInside)
        micButton.addTarget(self, action: #selector(toggleMic), for: .touchUpInside)
        updateMicButton()
        for b in [keyboardButton, micButton] {
            b.widthAnchor.constraint(equalToConstant: 44).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }

        let top = UIStackView(arrangedSubviews: [statusTap, UIView(), keyboardButton, micButton])
        top.alignment = .center
        top.spacing = 8

        pad.backgroundColor = UIColor(white: 0.11, alpha: 1)
        pad.layer.cornerRadius = 22
        pad.layer.cornerCurve = .continuous
        legendLabel.numberOfLines = 0
        legendLabel.textColor = UIColor(white: 1, alpha: 0.28)
        legendLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        legendLabel.isUserInteractionEnabled = false
        legendLabel.translatesAutoresizingMaskIntoConstraints = false
        pad.addSubview(legendLabel)
        NSLayoutConstraint.activate([
            legendLabel.leadingAnchor.constraint(equalTo: pad.leadingAnchor, constant: 14),
            legendLabel.bottomAnchor.constraint(equalTo: pad.bottomAnchor, constant: -12),
            legendLabel.trailingAnchor.constraint(lessThanOrEqualTo: pad.trailingAnchor, constant: -14),
        ])

        keysGrid.axis = .vertical
        keysGrid.spacing = 8
        keysGrid.distribution = .fillEqually

        content.addArrangedSubview(pad)
        content.addArrangedSubview(keysGrid)
        content.spacing = 10

        let root = UIStackView(arrangedSubviews: [top, content])
        root.axis = .vertical
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -12),
            root.topAnchor.constraint(equalTo: g.topAnchor, constant: 6),
            root.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -6),
            top.heightAnchor.constraint(equalToConstant: 36),
        ])

        keyCatcher.delegate = self
        keyCatcher.onDelete = { [weak self] in self?.connection.send(ClientMessage(t: "key", name: "delete")) }
        keyCatcher.autocorrectionType = .no
        keyCatcher.autocapitalizationType = .none
        keyCatcher.spellCheckingType = .no
        keyCatcher.smartQuotesType = .no
        keyCatcher.smartDashesType = .no
        keyCatcher.returnKeyType = .default
        keyCatcher.alpha = 0.01
        keyCatcher.frame = CGRect(x: 0, y: -40, width: 10, height: 10)
        view.addSubview(keyCatcher)

        rebuildKeys()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let landscape = view.bounds.width > view.bounds.height
        if landscape != isLandscape || keysGrid.arrangedSubviews.isEmpty {
            isLandscape = landscape
            content.axis = landscape ? .horizontal : .vertical
            rebuildKeys()
        }
    }

    private func rebuildKeys() {
        keysGrid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        keysSize?.isActive = false
        guard !quickKeys.isEmpty else { keysGrid.isHidden = true; return }
        keysGrid.isHidden = false
        let perRow = isLandscape ? 2 : 4
        for start in stride(from: 0, to: quickKeys.count, by: perRow) {
            let row = UIStackView()
            row.spacing = 8
            row.distribution = .fillEqually
            for (offset, k) in quickKeys[start..<min(start + perRow, quickKeys.count)].enumerated() {
                row.addArrangedSubview(makeKeyButton(k, index: start + offset))
            }
            for _ in row.arrangedSubviews.count..<perRow { row.addArrangedSubview(UIView()) }
            keysGrid.addArrangedSubview(row)
        }
        let rows = CGFloat(keysGrid.arrangedSubviews.count)
        keysSize = isLandscape
            ? keysGrid.widthAnchor.constraint(equalToConstant: 200)
            : keysGrid.heightAnchor.constraint(equalToConstant: rows * 58 + (rows - 1) * 8)
        keysSize?.isActive = true
    }

    private func makeKeyButton(_ k: QuickKeyInfo, index: Int) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.baseBackgroundColor = k.hold ? UIColor.systemRed.withAlphaComponent(0.85) : UIColor(white: 0.2, alpha: 1)
        cfg.baseForegroundColor = .white
        cfg.image = k.symbol.flatMap { UIImage(systemName: $0) }
        cfg.imagePlacement = .top
        cfg.imagePadding = 4
        cfg.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        var title = AttributedString(k.label)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        cfg.attributedTitle = title
        cfg.cornerStyle = .large
        let b = UIButton(configuration: cfg)
        b.tag = index
        b.addTarget(self, action: #selector(keyDown(_:)), for: .touchDown)
        b.addTarget(self, action: #selector(keyUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return b
    }

    private func updateMicButton() {
        micButton.setImage(UIImage(systemName: micOn ? "mic.fill" : "mic.slash"), for: .normal)
        micButton.tintColor = micOn ? (mic.isRunning ? .systemGreen : .white) : .systemGray
    }

    // MARK: Pad wiring

    private func wirePad() {
        pad.onMove = { [weak self] dx, dy in self?.connection.send(ClientMessage(t: "move", dx: Double(dx), dy: Double(dy))) }
        pad.onButton = { [weak self] b, down in self?.connection.send(ClientMessage(t: "button", button: b, down: down)) }
        pad.onScroll = { [weak self] dx, dy in self?.connection.send(ClientMessage(t: "scroll", dx: Double(dx), dy: Double(dy))) }
        pad.onGesture = { [weak self] name in self?.connection.send(ClientMessage(t: "gesture", name: name)) }
    }

    // MARK: Connection state

    private func apply(_ state: Connection.State) {
        switch state {
        case .searching:
            setStatus("Searching for Mac…", .systemOrange)
            setConnected(false)
        case .connecting:
            setStatus("Connecting…", .systemYellow)
        case .connected(let host):
            setStatus(host, .systemGreen)
            setConnected(true)
        case .needPin(let host):
            setStatus("\(host): PIN needed", .systemRed)
            setConnected(false)
            askPin(host: host)
        }
    }

    private func setStatus(_ text: String, _ color: UIColor) {
        statusLabel.text = text
        statusDot.backgroundColor = color
    }

    private func setConnected(_ c: Bool) {
        guard c != connected else { return }
        connected = c
        UIApplication.shared.isIdleTimerDisabled = c
        if c { startMicIfWanted() } else { stopMic(notify: false) }
    }

    private func applyWelcome(_ msg: ServerMessage) {
        quickKeys = msg.quickKeys ?? []
        pad.pointerSpeed = CGFloat(msg.pointerSpeed ?? 1.6)
        pad.scrollSpeed = CGFloat(msg.scrollSpeed ?? 1.2)
        legendLabel.text = (msg.legend ?? []).joined(separator: "\n")
        rebuildKeys()
        // Welcome also arrives after a config reload — re-announce mic state.
        if mic.isRunning { connection.send(ClientMessage(t: "mic", down: true)) }
    }

    // MARK: Mic

    private func startMicIfWanted() {
        guard micOn, connected, !mic.isRunning else { updateMicButton(); return }
        MicStreamer.requestPermission { [weak self] ok in
            guard let self, ok, self.connected, self.micOn else { self?.updateMicButton(); return }
            do {
                try self.mic.start()
                self.connection.send(ClientMessage(t: "mic", down: true))
            } catch {
                self.setStatus("Mic error: \(error.localizedDescription)", .systemRed)
            }
            self.updateMicButton()
        }
    }

    private func stopMic(notify: Bool) {
        if mic.isRunning {
            mic.stop()
            if notify { connection.send(ClientMessage(t: "mic", down: false)) }
        }
        updateMicButton()
    }

    @objc private func toggleMic() {
        micOn.toggle()
        if micOn { startMicIfWanted() } else { stopMic(notify: true) }
        updateMicButton()
    }

    // MARK: Quick keys

    @objc private func keyDown(_ b: UIButton) {
        guard quickKeys.indices.contains(b.tag) else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        connection.send(ClientMessage(t: "quick", down: true, name: quickKeys[b.tag].id))
    }

    @objc private func keyUp(_ b: UIButton) {
        guard quickKeys.indices.contains(b.tag), quickKeys[b.tag].hold else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        connection.send(ClientMessage(t: "quick", down: false, name: quickKeys[b.tag].id))
    }

    // MARK: Keyboard

    @objc private func toggleKeyboard() {
        if keyCatcher.isFirstResponder { keyCatcher.resignFirstResponder() } else { keyCatcher.becomeFirstResponder() }
    }

    func textField(_ tf: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if !string.isEmpty { connection.send(ClientMessage(t: "text", text: string)) }
        return false
    }

    func textFieldShouldReturn(_ tf: UITextField) -> Bool {
        connection.send(ClientMessage(t: "key", name: "return"))
        return false
    }

    // MARK: Settings

    @objc private func showSettings() {
        let a = UIAlertController(title: "PhonePad", message: "Mac: \(statusLabel.text ?? "")", preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: "Enter pairing PIN", style: .default) { [weak self] _ in self?.askPin(host: "your Mac") })
        a.addAction(UIAlertAction(title: "Mac address (if not found)", style: .default) { [weak self] _ in self?.askHost() })
        a.addAction(UIAlertAction(title: "Reconnect", style: .default) { [weak self] _ in self?.connection.reconnect() })
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.popoverPresentationController?.sourceView = statusLabel
        present(a, animated: true)
    }

    private func askPin(host: String) {
        guard !askingPin, presentedViewController == nil else { return }
        askingPin = true
        let a = UIAlertController(title: "Pair with \(host)",
                                  message: "Enter the PIN shown in the PhonePad menu on the Mac.", preferredStyle: .alert)
        a.addTextField { tf in tf.keyboardType = .numberPad; tf.placeholder = "123456"; tf.text = self.connection.pin }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.askingPin = false })
        a.addAction(UIAlertAction(title: "Pair", style: .default) { [weak self, weak a] _ in
            guard let self else { return }
            self.askingPin = false
            self.connection.pin = a?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            self.connection.reconnect()
        })
        present(a, animated: true)
    }

    private func askHost() {
        let a = UIAlertController(title: "Mac address",
                                  message: "Only needed if the Mac isn't found automatically. Leave empty for automatic.",
                                  preferredStyle: .alert)
        a.addTextField { tf in tf.keyboardType = .decimalPad; tf.placeholder = "172.20.10.2"; tf.text = self.connection.manualHost }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak a] _ in
            self?.connection.manualHost = a?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            self?.connection.reconnect()
        })
        present(a, animated: true)
    }
}

/// Invisible text field that forwards the iOS keyboard (including its dictation key) to the Mac.
final class KeyCatcher: UITextField {
    var onDelete: (() -> Void)?
    override func deleteBackward() { onDelete?() }
}
