import AVFoundation
import CoreAudio

/// Plays the phone's mic stream into a loopback device (BlackHole) and makes that
/// device the Mac's default input, so any app — Dictator2 included — hears the iPhone.
final class AudioSink {
    private var engine: AVAudioEngine?
    private let ring = SampleRing(capacity: Int(PP.audioSampleRate) * 2)
    private var previousDefaultInput: AudioDeviceID?
    private(set) var isRunning = false
    private var pushedSamples = 0

    func start(deviceUID: String, switchDefaultInput: Bool) {
        guard !isRunning else { return }
        guard let device = CoreAudioDevices.find(uid: deviceUID) else {
            Log.write("audio: device \(deviceUID) not found — is BlackHole installed?")
            return
        }
        let engine = AVAudioEngine()
        do {
            var id = device
            let status = AudioUnitSetProperty(engine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { Log.write("audio: set output device failed \(status)"); return }

            let format = AVAudioFormat(standardFormatWithSampleRate: PP.audioSampleRate, channels: 1)!
            let ring = self.ring
            let node = AVAudioSourceNode(format: format) { _, _, frameCount, abl -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(abl)
                guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                ring.read(into: out, count: Int(frameCount))
                for b in 1..<max(buffers.count, 1) {
                    if let dst = buffers[b].mData { memcpy(dst, out, Int(frameCount) * 4) }
                }
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
        } catch {
            Log.write("audio: engine start failed \(error)")
            return
        }
        self.engine = engine
        ring.reset()
        isRunning = true

        if switchDefaultInput {
            let current = CoreAudioDevices.defaultInput()
            if current != device {
                previousDefaultInput = current
                CoreAudioDevices.setDefaultInput(device)
            }
        }
        Log.write("audio: streaming phone mic → \(deviceUID)")
    }

    func stop() {
        guard isRunning else { return }
        Log.write("audio: received \(pushedSamples) samples, rendered \(ring.renderedSamples) with signal")
        pushedSamples = 0
        engine?.stop()
        engine = nil
        isRunning = false
        if let prev = previousDefaultInput {
            CoreAudioDevices.setDefaultInput(prev)
            previousDefaultInput = nil
        }
        Log.write("audio: stopped, default input restored")
    }

    /// 48 kHz mono Int16 little-endian.
    func push(_ data: Data) {
        guard isRunning else { return }
        pushedSamples += data.count / 2
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            ring.write(samples)
        }
    }
}

/// Jitter buffer between the network thread and the render thread.
final class SampleRing {
    private var buf: [Float]
    private var readIdx = 0
    private var writeIdx = 0
    private var count = 0
    private var primed = false
    private(set) var renderedSamples = 0
    private var lock = os_unfair_lock()
    private let prime = Int(PP.audioSampleRate * 0.04)     // wait for 40 ms before playing
    private let maxLatency = Int(PP.audioSampleRate * 0.25) // drop backlog beyond 250 ms

    init(capacity: Int) { buf = [Float](repeating: 0, count: capacity) }

    func reset() {
        os_unfair_lock_lock(&lock); readIdx = 0; writeIdx = 0; count = 0; primed = false; renderedSamples = 0; os_unfair_lock_unlock(&lock)
    }

    func write(_ samples: UnsafeBufferPointer<Int16>) {
        os_unfair_lock_lock(&lock)
        let cap = buf.count
        for s in samples {
            buf[writeIdx] = Float(Int16(littleEndian: s)) / 32768
            writeIdx = (writeIdx + 1) % cap
            if count < cap { count += 1 } else { readIdx = (readIdx + 1) % cap }
        }
        if count > maxLatency {
            let drop = count - prime * 2
            readIdx = (readIdx + drop) % cap
            count -= drop
        }
        if count >= prime { primed = true }
        os_unfair_lock_unlock(&lock)
    }

    func read(into out: UnsafeMutablePointer<Float>, count n: Int) {
        os_unfair_lock_lock(&lock)
        let cap = buf.count
        var i = 0
        if primed {
            while i < n && count > 0 {
                out[i] = buf[readIdx]
                if out[i] != 0 { renderedSamples += 1 }
                readIdx = (readIdx + 1) % cap
                count -= 1
                i += 1
            }
            if count == 0 { primed = false }
        }
        while i < n { out[i] = 0; i += 1 }
        os_unfair_lock_unlock(&lock)
    }
}

enum CoreAudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func find(uid: String) -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var uidAddr = address(kAudioDevicePropertyDeviceUID)
            var cfUID: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &cfUID) == noErr,
               let s = cfUID?.takeRetainedValue() as String?, s == uid {
                return id
            }
        }
        return nil
    }

    static func defaultInput() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    static func setDefaultInput(_ id: AudioDeviceID) {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var dev = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
        if status != noErr { Log.write("audio: set default input failed \(status)") }
    }
}
