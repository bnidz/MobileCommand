import AVFoundation

/// Captures the iPhone mic and hands out 48 kHz mono Int16 chunks.
final class MicStreamer {
    var onChunk: ((Data) -> Void)?
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private(set) var isRunning = false

    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: PP.audioSampleRate,
                                          channels: 1, interleaved: true)!

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { ok in DispatchQueue.main.async { done(ok) } }
    }

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
        try session.setActive(true)

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "MobileCommand", code: 1, userInfo: [NSLocalizedDescriptionKey: "No converter for \(inFormat)"])
        }
        converter = conv
        let ratio = PP.audioSampleRate / inFormat.sampleRate

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self, let conv = self.converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: self.outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            conv.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let ptr = out.int16ChannelData?[0] else { return }
            self.onChunk?(Data(bytes: ptr, count: Int(out.frameLength) * 2))
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
