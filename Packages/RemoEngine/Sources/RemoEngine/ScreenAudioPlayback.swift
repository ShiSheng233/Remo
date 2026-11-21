import AVFAudio
import Foundation
import RemoCodec

struct AudioPacketQueue {
    private var packets: [UInt64: CapturedAudioPacket] = [:]
    private static let capacity = 24
    private var nextTimestamp: Double?
    private var lastPlayed: UInt64?
    private(set) var latePackets = 0
    var isEmpty: Bool { packets.isEmpty }

    mutating func insert(_ packet: CapturedAudioPacket) -> Bool {
        if let lastPlayed, packet.sequence <= lastPlayed {
            latePackets += 1
            return false
        }
        if let nextTimestamp, Double(packet.timestamp) < nextTimestamp - 480 {
            latePackets += 1
            return false
        }
        packets[packet.sequence] = packet
        if packets.count > Self.capacity, let oldest = packets.keys.min() {
            packets.removeValue(forKey: oldest)
        }
        return true
    }

    /// The audio device advances this clock by one 20 ms slot per rendered buffer.
    mutating func pop() -> CapturedAudioPacket? {
        let first = packets.keys.min().flatMap { packets[$0] }
        guard let timestamp = nextTimestamp ?? first.map({ Double($0.timestamp) }) else { return nil }
        nextTimestamp = timestamp + 960
        guard let first, Double(first.timestamp) < timestamp + 480 else { return nil }
        packets.removeValue(forKey: first.sequence)
        lastPlayed = first.sequence
        nextTimestamp = Double(first.timestamp) + 960
        return first
    }

    var hasNextPacket: Bool {
        guard let id = packets.keys.min(), let packet = packets[id] else { return false }
        return nextTimestamp.map { Double(packet.timestamp) < $0 + 480 } ?? true
    }

    mutating func reanchor() { nextTimestamp = nil }
}

struct AudioFrameRenderer {
    var consecutiveGaps = 0
    private var needsFadeIn = false
    private var lastSamples: [Float] = [0, 0]
    private(set) var decodeFailures = 0
    private(set) var concealedPackets = 0
    private(set) var fadeFallbacks = 0

    mutating func resetHistory() {
        consecutiveGaps = 0
        needsFadeIn = false
        lastSamples = [0, 0]
    }

    mutating func render(_ packet: CapturedAudioPacket?, using decoder: OpusDecoder) -> AVAudioPCMBuffer? {
        let pcm: AVAudioPCMBuffer
        if let packet, let decoded = try? decoder.decode(packet.opus) {
            pcm = decoded
            consecutiveGaps = 0
        } else {
            if packet != nil { decodeFailures += 1 }
            consecutiveGaps += 1
            concealedPackets += 1
            if let concealed = try? decoder.concealMissingFrame() {
                pcm = concealed
            } else {
                guard let silence = AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm, frameCapacity: 960)
                else { return nil }
                silence.frameLength = 960
                for channel in 0..<2 {
                    let samples = silence.floatChannelData![channel]
                    samples.update(repeating: 0, count: 960)
                    for i in 0..<120 { samples[i] = lastSamples[channel] * Float(119 - i) / 120 }
                    lastSamples[channel] = 0
                }
                fadeFallbacks += 1
                needsFadeIn = true
                return silence
            }
        }
        for channel in 0..<2 {
            let samples = pcm.floatChannelData![channel]
            if needsFadeIn {
                for i in 0..<120 { samples[i] *= Float(i) / 120 }
            }
            lastSamples[channel] = samples[Int(pcm.frameLength) - 1]
        }
        needsFadeIn = false
        return pcm
    }
}

/// Accepts packets on the client's main actor. Audio processing runs on its own serial queue.
@MainActor
final class ScreenAudioPlayback {
    typealias Statistics = AudioPlaybackStatistics

    private let worker: AudioPlaybackWorker
    var statistics: Statistics { worker.statistics }
    var decodeFailures: Int { statistics.decodeFailures }
    var concealedPackets: Int { statistics.concealedPackets }
    var fadeFallbacks: Int { statistics.fadeFallbacks }
    var rebufferCount: Int { statistics.rebufferCount }
    var latePackets: Int { statistics.latePackets }

    init(
        engine: AVAudioEngine = AVAudioEngine(), traceDirectory: URL? = nil,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        worker = AudioPlaybackWorker(engine: engine, traceDirectory: traceDirectory, onError: onError)
    }

    func receive(_ message: Data) { worker.receive(message) }
    func stop() { worker.stop() }
}

// After initialization, all mutable state and graph operations are confined to serial.
private final class AudioPlaybackWorker: @unchecked Sendable {
    private let serial = DispatchQueue(label: "RemoEngine.audio.playback", qos: .userInitiated)
    private let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private var decoder: OpusDecoder?
    private var queue = AudioPacketQueue()
    private var startupPending = false
    private let trace: AudioPCMTrace?
    private let traceDirectory: URL?
    private var traceEnd: Int64 = 0
    private var tapInstalled = false
    private var scheduled = 0
    private var generation = 0
    private var running = false
    private var renderer = AudioFrameRenderer()
    private var rebufferCount = 0
    private let onError: @MainActor (Error) -> Void

    var statistics: ScreenAudioPlayback.Statistics {
        serial.sync {
            .init(decodeFailures: renderer.decodeFailures, concealedPackets: renderer.concealedPackets,
                fadeFallbacks: renderer.fadeFallbacks, rebufferCount: rebufferCount, latePackets: queue.latePackets)
        }
    }

    init(engine: AVAudioEngine, traceDirectory: URL?, onError: @escaping @MainActor (Error) -> Void) {
        self.engine = engine
        self.onError = onError
        self.traceDirectory = traceDirectory
        trace = AudioPCMTrace.open("before-playback", in: traceDirectory)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: OpusFormat.pcm)
    }

    func receive(_ message: Data) {
        serial.async { [weak self] in
            guard let self, let packet = CapturedAudioPacket(message: message), queue.insert(packet) else { return }
            if !running { startAfterBuffering() }
        }
    }

    private func startAfterBuffering() {
        guard !startupPending, !queue.isEmpty else { return }
        startupPending = true
        let epoch = generation
        serial.asyncAfter(deadline: .now() + .milliseconds(180)) { [weak self] in
            guard let self, generation == epoch else { return }
            startupPending = false
            do {
                if decoder == nil { decoder = try OpusDecoder() }
                if trace != nil, !tapInstalled, let mixTrace = AudioPCMTrace.open("mixer-output", in: traceDirectory) {
                    engine.mainMixerNode.installTap(onBus: 0, bufferSize: 960, format: nil) {
                        @Sendable buffer, time in
                        mixTrace.record(buffer, host: time.hostTime, playerFrame: time.sampleTime, kind: "mix")
                    }
                    tapInstalled = true
                }
                if !engine.isRunning { try engine.start() }
                running = true
                fill()
                if running { node.play() }
            } catch {
                reset()
                let failedGeneration = generation
                Task { @MainActor [weak self] in
                    guard let self, serial.sync(execute: { self.generation == failedGeneration }) else { return }
                    onError(error)
                }
            }
        }
    }

    func stop() { serial.sync { reset() } }

    private func reset() {
        generation += 1
        startupPending = false
        running = false
        node.stop()
        engine.stop()
        if tapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        traceEnd = 0
        scheduled = 0
        queue = AudioPacketQueue()
        decoder = nil
        renderer.resetHistory()
    }

    private func fill(callbackHost: UInt64? = nil) {
        guard let decoder else { return }
        while scheduled < 3 {
            // Leave a slot open for a reordered packet until the device needs more PCM.
            if !queue.hasNextPacket && (scheduled > 1 || renderer.consecutiveGaps >= 8) { break }
            let packet = queue.pop()
            let previousGaps = renderer.concealedPackets
            let previousFallbacks = renderer.fadeFallbacks
            guard let pcm = renderer.render(packet, using: decoder) else { return }
            if let trace {
                let host = mach_absolute_time()
                let position = node.lastRenderTime.flatMap { node.playerTime(forNodeTime: $0) }
                let head = position.flatMap { $0.isSampleTimeValid ? $0.sampleTime : nil }
                let kind = previousGaps == renderer.concealedPackets ? "decoded"
                    : (previousFallbacks == renderer.fadeFallbacks ? "PLC" : "fade")
                trace.record(pcm, host: host, sequence: packet?.sequence, timestamp: packet?.timestamp,
                    playerFrame: head, scheduledEnd: traceEnd,
                    callbackDelay: callbackHost.map { AVAudioTime.seconds(forHostTime: host - $0) * 1000 },
                    kind: kind)
                // A buffer scheduled with no explicit time follows the tail, or starts at the
                // next render quantum when the device has already passed the previous tail.
                traceEnd = max(traceEnd, head ?? 0) + Int64(pcm.frameLength)
            }
            scheduled += 1
            let epoch = generation
            let tracing = trace != nil
            node.scheduleBuffer(pcm, completionCallbackType: .dataRendered) { @Sendable [weak self] _ in
                let callbackHost = tracing ? mach_absolute_time() : nil
                self?.serial.async { [weak self] in
                    guard let self, generation == epoch else { return }
                    scheduled -= 1
                    fill(callbackHost: callbackHost)
                    if scheduled == 0 {
                        running = false
                        node.pause()
                        rebufferCount += 1
                        renderer.consecutiveGaps = 0
                        self.decoder = nil
                        queue.reanchor()
                        startAfterBuffering()
                    }
                }
            }
        }
    }
}
