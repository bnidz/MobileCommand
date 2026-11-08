import Foundation
import Network
import UIKit

/// Finds the Mac over Bonjour (works on Wi-Fi, Personal Hotspot and peer-to-peer),
/// keeps one TCP connection alive and reconnects on its own.
final class Connection {
    enum State { case searching, connecting, connected(String), needPin(String) }

    var onState: ((State) -> Void)?
    var onWelcome: ((ServerMessage) -> Void)?

    private let queue = DispatchQueue(label: "pp.conn", qos: .userInteractive)
    private var browser: NWBrowser?
    private var conn: NWConnection?
    private var endpoints: [NWEndpoint] = []
    private var buffer = Data()
    private var pingTimer: DispatchSourceTimer?
    private var retryScheduled = false
    private(set) var isConnected = false

    var pin: String {
        get { UserDefaults.standard.string(forKey: "pin") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "pin") }
    }
    /// Optional fallback when Bonjour can't see the Mac, e.g. "172.20.10.11".
    var manualHost: String {
        get { UserDefaults.standard.string(forKey: "manualHost") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "manualHost") }
    }

    func start() {
        queue.async { self.startBrowsing(); self.connectNext() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self, self.isConnected else { return }
            self.send(ClientMessage(t: "ping"))
        }
        t.resume()
        pingTimer = t
    }

    /// Drop the current connection and try again (e.g. after entering a PIN).
    func reconnect() {
        queue.async {
            self.conn?.cancel()
            self.conn = nil
            self.isConnected = false
            self.connectNext()
        }
    }

    private func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: PP.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.endpoints = results.map(\.endpoint)
            if self.conn == nil { self.connectNext() }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.queue.asyncAfter(deadline: .now() + 2) { self?.browser?.cancel(); self?.startBrowsing() }
            }
        }
        b.start(queue: queue)
        browser = b
    }

    private func connectNext() {
        guard conn == nil else { return }
        var target = endpoints.first
        if target == nil, !manualHost.isEmpty {
            target = .hostPort(host: NWEndpoint.Host(manualHost), port: NWEndpoint.Port(rawValue: PP.port)!)
        }
        guard let endpoint = target else {
            emit(.searching)
            scheduleRetry()
            return
        }
        emit(.connecting)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 4
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVoice

        let c = NWConnection(to: endpoint, using: params)
        conn = c
        buffer = Data()
        c.stateUpdateHandler = { [weak self] state in
            guard let self, self.conn === c else { return }
            switch state {
            case .ready:
                self.isConnected = true
                self.send(ClientMessage(t: "hello", pin: self.pin, device: UIDevice.current.name))
                self.receive(c)
            case .failed, .cancelled, .waiting:
                self.fail(c)
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func fail(_ c: NWConnection) {
        guard conn === c else { return }
        c.cancel()
        conn = nil
        isConnected = false
        emit(.searching)
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + 1.5) {
            self.retryScheduled = false
            self.connectNext()
        }
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.conn === c else { return }
            if let data { self.buffer.append(data) }
            for (type, payload) in Frame.drain(&self.buffer) where type == .json {
                guard let msg = try? JSONDecoder().decode(ServerMessage.self, from: payload) else { continue }
                switch msg.t {
                case "welcome":
                    self.emit(.connected(msg.host ?? "Mac"))
                    DispatchQueue.main.async { self.onWelcome?(msg) }
                case "needPin":
                    self.emit(.needPin(msg.host ?? "Mac"))
                default: break
                }
            }
            if complete || error != nil { self.fail(c) } else { self.receive(c) }
        }
    }

    private func emit(_ s: State) {
        DispatchQueue.main.async { self.onState?(s) }
    }

    // MARK: Sending (any thread)

    func send(_ msg: ClientMessage) {
        guard let frame = Frame.json(msg) else { return }
        queue.async { self.conn?.send(content: frame, completion: .contentProcessed { _ in }) }
    }

    func sendAudio(_ pcm: Data) {
        let frame = Frame.encode(.audio, pcm)
        queue.async {
            guard self.isConnected else { return }
            self.conn?.send(content: frame, completion: .contentProcessed { _ in })
        }
    }
}
