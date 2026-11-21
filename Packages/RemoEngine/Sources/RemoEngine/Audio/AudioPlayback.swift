import AVFAudio
import Foundation
import RemoCodec

/// Plays `AudioMessage`s. Accepts them on the client's main actor. Audio processing runs on its own serial queue.
@MainActor
final class AudioPlayback {
    typealias Statistics = ClientStatistics.Audio

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

    func receive(_ packet: AudioMessage) { worker.receive(packet) }
    func stop() { worker.stop() }
}

// After initialization, all mutable state and graph operations are confined to serial.
private final class AudioPlaybackWorker: @unchecked Sendable {
    private let serial = DispatchQueue(label: "RemoEngine.audio.playback", qos: .userInitiated)
    private let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private var decoder: OpusDecoder?
    private var queue = AudioJitterBuffer()
    private var startupPending = false
    private let trace: AudioTrace?
    private let traceDirectory: URL?
    private var traceEnd: Int64 = 0
    private var tapInstalled = false
    private var scheduled = 0
    private var generation = 0
    private var running = false
    private var renderer = AudioConcealer()
    private var rebufferCount = 0
    private let onError: @MainActor (Error) -> Void

    var statistics: AudioPlayback.Statistics {
        serial.sync {
            .init(decodeFailures: renderer.decodeFailures, concealedPackets: renderer.concealedPackets,
                fadeFallbacks: renderer.fadeFallbacks, rebufferCount: rebufferCount, latePackets: queue.latePackets)
        }
    }

    init(engine: AVAudioEngine, traceDirectory: URL?, onError: @escaping @MainActor (Error) -> Void) {
        self.engine = engine
        self.onError = onError
        self.traceDirectory = traceDirectory
        trace = AudioTrace.open("before-playback", in: traceDirectory)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: OpusFormat.pcm)
    }

    func receive(_ packet: AudioMessage) {
        serial.async { [weak self] in
            guard let self, queue.insert(packet) else { return }
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
                if trace != nil, !tapInstalled, let mixTrace = AudioTrace.open("mixer-output", in: traceDirectory) {
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
        queue = AudioJitterBuffer()
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
