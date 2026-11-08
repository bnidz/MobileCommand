import Foundation
import Network

/// Bonjour-advertised TCP listener. One phone at a time; the newest connection wins.
final class Server {
    enum Status: Equatable { case waiting, pairing(String), connected(String, micLive: Bool) }

    var onStatus: ((Status) -> Void)?
    var onMessage: ((ClientMessage) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?
    /// Builds the welcome payload (quick keys, gesture legend…) on demand.
    var welcome: (() -> ServerMessage)?
    var pin: () -> String = { "" }

    private let queue = DispatchQueue(label: "pp.server", qos: .userInteractive)
    private var listener: NWListener?
    private var conn: NWConnection?
    private var buffer = Data()
    private var authenticated = false
    private var deviceName = "iPhone"
    private var lastHeard = Date()
    private var watchdog: DispatchSourceTimer?

    func start() {
        startListener()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self, self.conn != nil, Date().timeIntervalSince(self.lastHeard) > 8 else { return }
            Log.write("connection silent for 8 s — dropping")
            self.drop()
        }
        t.resume()
        watchdog = t
    }

    private func startListener() {
        listener?.cancel()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        do {
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: PP.port)!)
            l.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: PP.serviceType)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { state in
                Log.write("listener: \(state)")
                if case .failed = state {
                    // Port busy or network change — retry shortly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startListener() }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            Log.write("listener create failed: \(error)")
        }
    }

    func setMicLive(_ live: Bool) {
        if authenticated { onStatus?(.connected(deviceName, micLive: live)) }
    }

    func sendWelcome() {
        queue.async { [weak self] in
            guard let self, self.authenticated, let msg = self.welcome?() else { return }
            self.send(msg)
        }
    }

    private func accept(_ c: NWConnection) {
        if conn != nil {
            Log.write("replacing existing connection")
            drop()
        }
        conn = c
        buffer = Data()
        authenticated = false
        lastHeard = Date()
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                if self?.conn === c { self?.drop() }
            default: break
            }
        }
        c.start(queue: queue)
        receive(c)
        Log.write("connection from \(c.endpoint)")
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.conn === c else { return }
            if let data, !data.isEmpty {
                self.lastHeard = Date()
                self.buffer.append(data)
                for (type, payload) in Frame.drain(&self.buffer) { self.handle(type, payload) }
            }
            if complete || error != nil { self.drop() } else { self.receive(c) }
        }
    }

    private func handle(_ type: FrameType, _ payload: Data) {
        switch type {
        case .audio:
            if authenticated { onAudio?(payload) }
        case .json:
            guard let msg = try? JSONDecoder().decode(ClientMessage.self, from: payload) else { return }
            if msg.t == "hello" {
                deviceName = msg.device ?? "iPhone"
                if msg.pin == pin() {
                    authenticated = true
                    Log.write("paired with \(deviceName)")
                    onStatus?(.connected(deviceName, micLive: false))
                    if let w = welcome?() { send(w) }
                } else {
                    Log.write("\(deviceName) sent wrong/no PIN")
                    onStatus?(.pairing(deviceName))
                    send(ServerMessage(t: "needPin", host: Host.current().localizedName))
                }
                return
            }
            guard authenticated else { return }
            onMessage?(msg)
        }
    }

    private func send(_ msg: ServerMessage) {
        guard let c = conn, let frame = Frame.json(msg) else { return }
        c.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func drop() {
        conn?.cancel()
        conn = nil
        buffer = Data()
        if authenticated { onDisconnect?() }
        authenticated = false
        onStatus?(.waiting)
        Log.write("disconnected")
    }
}
