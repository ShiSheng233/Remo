import CoreMedia
import Darwin
import Dispatch
import Foundation
import Network
import RemoCodec
import RemoEngine
import RemoTransport

private extension SessionMessage {
    func packet(sequence: UInt64, size: Int) -> Data {
        var bytes = Data(repeating: rawValue, count: size)
        withUnsafeBytes(of: sequence.bigEndian) { bytes.replaceSubrange(1..<9, with: $0) }
        return bytes
    }
}

@MainActor
final class DemoSession {
    enum Role { case server, client }

    typealias StartCapture = @MainActor () async throws -> any ScreenFrameSource
    let screen: Bool
    private let startCapture: StartCapture?
    private let mouse: MouseControlServer?
    private let mousePeer = UUID()
    private var source: (any ScreenFrameSource)?
    private var previousCapturePTS = CMTime.invalid
    private var lastCaptureSend: UInt64 = 0
    #if os(macOS)
        private var scaler: ScreenScaler?
        private var resolutionDivisor = 1
        private var lastResolutionChange: UInt64 = 0
    #endif
    private var screenEncoder: VideoEncoder?
    private var targetBitRate: Int
    private var lastRateUpdate: UInt64 = 0
    private var refreshBitRate: Int
    private var lastQualityRefresh: UInt64 = 0
    private var lastImageChange: UInt64 = 0
    private var refreshWhenStill = false
    private var checkpointSkips: UInt64 = 0
    private var captureSkips = 0
    private var displayEnqueued = 0
    private var lastVideoTime = DispatchTime.now().uptimeNanoseconds
    var present: ((DecodedVideoFrame) throws -> Bool)?
    let settings: VideoSettings
    let role: Role
    let peer: NWEndpoint
    private var video: VideoSession?
    private var acknowledgedReferences = 0
    private var codecDrops: UInt64 = 0
    private var verifiedFrames: UInt64 = 0
    private var session: NetworkMessageSession?
    private let trace = HeartbeatTrace(layer: "session")
    private var active = false
    private var stopping = false
    private var lastSeen = DispatchTime.now().uptimeNanoseconds
    private var frames: UInt64 = 0
    private var controls: UInt64 = 0
    private var latestFrame: UInt64 = 0
    private var latestControl: UInt64 = 0
    private var backpressureDrops: UInt64 = 0
    private var heartbeats = 0
    private var videoBytes = 0
    private var previousFrames: UInt64 = 0
    private var previousBytes = 0
    private var lastReport = DispatchTime.now().uptimeNanoseconds
    private var failure: String?
    private var setup: Task<Void, Never>?

    init(
        role: Role, peer: NWEndpoint, screen: Bool = false, startCapture: StartCapture? = nil,
        mouse: MouseControlServer? = nil, settings: VideoSettings = VideoSettings()
    ) {
        self.settings = settings
        targetBitRate = settings.maxVideoBitRate
        refreshBitRate = settings.maxVideoBitRate
        self.screen = screen
        self.startCapture = startCapture
        self.mouse = mouse
        self.role = role
        self.peer = peer
    }

    func run(_ connection: NWConnection) async -> Bool {
        trace.write(peer, "\(role) opening")
        let setup = Task { [self] in
            do {
                session = try await NetworkMessageSession(connection: connection) {
                    [weak self] channel, bytes in
                    self?.receive(channel, bytes)
                } closeHandler: { [weak self] reason in
                    self?.stop("connection closed: \(reason)", failed: true)
                }
            } catch {
                stop("connection setup: \(error)", failed: true)
            }
        }
        self.setup = setup
        let timeout = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            stop("connection setup timed out", failed: true)
        }
        await setup.value
        timeout.cancel()
        self.setup = nil

        if let session, !stopping {
            lastSeen = DispatchTime.now().uptimeNanoseconds
            lastReport = lastSeen
            trace.write(peer, "\(role) ready")
            do {
                if role == .client || !screen { try prepareVideo() }
                if role == .client {
                    let hello: SessionMessage = screen ? .screenHello : .hello
                    try session.send(Data([hello.rawValue]), mode: .reliable)
                    trace.write(peer, "hello queued")
                    try await runClient(session)
                } else {
                    try await runServer(session)
                }
            } catch {
                stop("send failed: \(error)", failed: true)
            }
        }
        if let source {
            try? await source.stop()
            self.source = nil
        }
        video?.close()
        session?.cancel()
        session = nil
        return failure == nil
    }

    private func prepareVideo() throws {
        let encoder =
            role == .server
            ? try VideoEncoder(
                width: source?.width ?? settings.simulatedSize.width,
                height: source?.height ?? settings.simulatedSize.height,
                framesPerSecond: Int(settings.fps), bitRate: targetBitRate,
                enableLongTermReferences: true) : nil
        if source != nil { screenEncoder = encoder }
        video = VideoSession(
            encoder: encoder,
            send: { [weak self] data, mode in
                guard let self, !stopping, let session else {
                    throw NetworkMessageSession.SendError.closed
                }
                try session.send(data, mode: mode)
            },
            onFrame: { [weak self] id, frame, bytes in
                guard let self, !stopping else { return }
                if screen {
                    do { if try present?(frame) == true { displayEnqueued += 1 } } catch {
                        stop("video display failed: \(error)", failed: true)
                        return
                    }
                } else {
                    let position = (frame.presentationTime.seconds / frame.duration.seconds)
                        .rounded()
                    guard let index = UInt64(exactly: position),
                        SimulatedVideo.matches(frame.pixels, index: index)
                    else {
                        stop(
                            "decoded image mismatch frame=\(id) framePosition=\(position)",
                            failed: true)
                        return
                    }
                    verifiedFrames += 1
                }
                frames += 1
                latestFrame = max(latestFrame, id)
                videoBytes += bytes
                lastSeen = DispatchTime.now().uptimeNanoseconds
                lastVideoTime = lastSeen
            },
            onEvent: { [weak self] event in
                guard let self else { return }
                switch event {
                case .acknowledged(let frame, let token):
                    acknowledgedReferences += 1
                    if acknowledgedReferences == 1 {
                        log(
                            "[\(peer)] first LTR acknowledged frame=\(frame) token=\(token.rawValue)"
                        )
                    }
                case .requestedRecovery(let last, let available):
                    log(
                        "[\(peer)] recovery requested lastDecoded=\(last) nextAvailable=\(available)"
                    )
                case .reliableKeyFrame(let id, let bytes):
                    log("[\(peer)] reliable IDR frame=\(id) bytes=\(bytes)")
                case .encodedRefresh(let id, let reference):
                    log(
                        "[\(peer)] recovery encoded frame=\(id) kind=\(reference.map { "LTR-P ackToken=\($0.rawValue)" } ?? "IDR")"
                    )
                case .decodedRefresh(let id, let idr):
                    log("[\(peer)] recovery decoded frame=\(id) kind=\(idr ? "IDR" : "LTR-P")")
                }
            },
            onFailure: { [weak self] error in self?.stop("video failed: \(error)", failed: true) })
    }

    func requestExit() {
        guard !stopping else { return }
        try? session?.send(Data([SessionMessage.goodbye.rawValue]), mode: .reliable)
        stop("leaving", failed: false)
    }

    private func stop(_ reason: String, failed: Bool) {
        guard !stopping else { return }
        stopping = true
        mouse?.end(for: mousePeer)
        if failed { failure = reason }
        setup?.cancel()
        let idleMs = (DispatchTime.now().uptimeNanoseconds - lastSeen) / 1_000_000
        trace.write(
            peer,
            "\(role) stop reason=\(reason) idleMs=\(idleMs) active=\(active) heartbeats=\(heartbeats) frames=\(frames) controls=\(controls)"
        )
        log("[\(peer)] \(reason)")
    }

    private func receive(_ channel: MessageTransport.Channel, _ bytes: Data) {
        guard !stopping, video?.receive(channel, bytes) != true, let first = bytes.first,
            let kind = SessionMessage(rawValue: first)
        else {
            return
        }
        switch (role, channel, kind) {
        case (.server, .reliable, .hello), (.server, .reliable, .screenHello):
            guard bytes.count == 1 else { return }
            guard !screen || kind == .screenHello else {
                try? session?.send(Data([SessionMessage.modeMismatch.rawValue]), mode: .reliable)
                stop("screen sharing requires client --screen", failed: true)
                return
            }
            if !active { log("[\(peer)] streaming started") }
            active = true
            trace.write(peer, "hello accepted")
        case (.server, _, .heartbeat):
            guard channel == .unreliable, bytes.count == 1, active else {
                trace.write(
                    peer,
                    "heartbeat ignored active=\(active) channel=\(channel) bytes=\(bytes.count)")
                return
            }
            heartbeats += 1
            trace.write(peer, "heartbeat accepted count=\(heartbeats)")
        case (.server, .reliable, .goodbye) where bytes.count == 1:
            stop("client left", failed: false)
        case (.server, .reliable, .mouseHello) where active && bytes.count == 1:
            guard let mouse, let session, let ready = mouse.begin(for: mousePeer) else { return }
            do {
                try session.send(ready.encoded, mode: .reliable)
            } catch {
                mouse.end(for: mousePeer)
            }
        case (.server, _, .mouseInput) where active:
            mouse?.receive(bytes, on: channel, from: mousePeer)
            return
        case (.client, .reliable, .modeMismatch):
            stop("screen sharing requires client --screen", failed: true)
        case (.client, .reliable, .control) where bytes.count == 9:
            controls += 1
            latestControl = sequence(in: bytes)
        default: return
        }
        lastSeen = DispatchTime.now().uptimeNanoseconds
    }

    private func sequence(in bytes: Data) -> UInt64 {
        bytes.withUnsafeBytes {
            UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt64.self))
        }
    }

    private func runServer(_ session: NetworkMessageSession) async throws {
        var nextFrame = DispatchTime.now().uptimeNanoseconds
        var nextControl = nextFrame
        while !stopping {
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastSeen >= 2_000_000_000 {
                stop("client timed out", failed: false)
                break
            }
            if active {
                if now >= nextControl {
                    try session.send(
                        SessionMessage.control.packet(sequence: controls + 1, size: 9), mode: .reliable)
                    controls += 1
                    nextControl = now + 1_000_000_000
                }
                if let startCapture, source == nil {
                    source = try await startCapture()
                    if stopping { break }
                    try prepareVideo()
                }
                guard let video else { throw VideoSession.Failure.closed }
                if let source {
                    let stats = session.statistics
                    let budget = stats.bitsPerSecond
                    let target = min(settings.maxVideoBitRate, max(128_000, Int(budget * 0.7)))
                    if now - lastRateUpdate >= 500_000_000
                        && (abs(target - targetBitRate) > targetBitRate / 8
                            || (target == settings.maxVideoBitRate && target != targetBitRate))
                    {
                        try screenEncoder?.setBitRate(target)
                        refreshBitRate = min(refreshBitRate, target)
                        targetBitRate = target
                        lastRateUpdate = now
                    }
                    #if os(macOS)
                        try adaptResolution(source, video: video, budget: budget, now: now)
                    #endif
                    // Skip before encoding so congestion does not break the prediction chain.
                    if let sample = try source.latestSample(),
                        let pixels = CMSampleBufferGetImageBuffer(sample)
                    {
                        let capturePTS = CMSampleBufferGetPresentationTimeStamp(sample)
                        if capturePTS != previousCapturePTS {
                            lastImageChange = now
                            refreshWhenStill = true
                        }
                        // Refresh a still desktop periodically so a lost frame can be recovered.
                        if capturePTS != previousCapturePTS || now - lastCaptureSend >= 500_000_000
                        {
                            if stats.estimatedQueueDelay > 0.05 {
                                captureSkips += 1
                            } else {
                                let settled =
                                    Double(targetBitRate) <= budget && refreshWhenStill
                                    && now - lastImageChange >= 1_000_000_000
                                let improved =
                                    targetBitRate >= refreshBitRate * 3 / 2
                                    || (targetBitRate == settings.maxVideoBitRate
                                        && refreshBitRate < targetBitRate)
                                if (improved || settled)
                                    && now - lastQualityRefresh >= 5_000_000_000
                                {
                                    video.requestKeyFrame()
                                    lastQualityRefresh = now
                                    refreshBitRate = targetBitRate
                                    refreshWhenStill = false
                                    log(
                                        "[\(peer)] screen quality refresh encoderBps=\(targetBitRate)"
                                    )
                                }
                                previousCapturePTS = capturePTS
                                lastCaptureSend = now
                                #if os(macOS)
                                    let pixels = try scaler?.resize(pixels) ?? pixels
                                #endif
                                try await submit(
                                    pixels,
                                    pts: CMTime(value: Int64(now), timescale: 1_000_000_000),
                                    video: video)
                            }
                        }
                    }
                } else {
                    let index = frames + 1
                    try await submit(
                        SimulatedVideo.pixels(
                            index, width: settings.simulatedSize.width,
                            height: settings.simulatedSize.height),
                        pts: CMTime(value: Int64(index), timescale: settings.fps), video: video)
                }
                report(session, now: now)
            }
            nextFrame += settings.interval
            let sent = DispatchTime.now().uptimeNanoseconds
            if nextFrame <= sent { nextFrame = sent + settings.interval }
            try await Task.sleep(nanoseconds: nextFrame - sent)
        }
    }

    #if os(macOS)
        private func adaptResolution(
            _ source: any ScreenFrameSource, video: VideoSession, budget: Double,
            now: UInt64
        ) throws {
            guard now - lastResolutionChange >= 3_000_000_000 else { return }
            // Separate up/down thresholds to avoid repeatedly restarting the reference chain.
            let divisor: Int
            if budget < 300_000 {
                divisor = 4
            } else if budget < 1_000_000 && resolutionDivisor < 4 {
                divisor = 2
            } else if budget > 1_800_000 {
                divisor = 1
            } else if budget > 600_000 && resolutionDivisor == 4 {
                divisor = 2
            } else {
                return
            }
            guard divisor != resolutionDivisor else { return }
            lastResolutionChange = now
            let width = max(2, source.width / (2 * divisor) * 2)
            let height = max(2, source.height / (2 * divisor) * 2)
            let newScaler = divisor == 1 ? nil : try ScreenScaler(width: width, height: height)
            let replacement = try VideoEncoder(
                width: width, height: height, framesPerSecond: Int(settings.fps),
                bitRate: targetBitRate, enableLongTermReferences: true)
            guard try video.replaceEncoder(replacement) else { return }
            screenEncoder = replacement
            scaler = newScaler
            resolutionDivisor = divisor
            refreshBitRate = targetBitRate
            lastQualityRefresh = now
            refreshWhenStill = false
            log("[\(peer)] screen encode size=\(width)x\(height) budget=\(Int(budget)) bps")
        }

    #endif

    private func submit(_ pixels: CVPixelBuffer, pts: CMTime, video: VideoSession) async throws {
        frames += 1
        do {
            let bytes = try await video.sendFrame(
                pixels, presentationTime: pts, duration: CMTime(value: 1, timescale: settings.fps))
            if bytes == 0 { checkpointSkips += 1 }
            videoBytes += bytes
        } catch VideoCodecError.frameDropped {
            codecDrops += 1
        } catch NetworkMessageSession.SendError.backpressure {
            backpressureDrops += 1
        }
    }

    private func runClient(_ session: NetworkMessageSession) async throws {
        lastVideoTime = DispatchTime.now().uptimeNanoseconds
        log("[\(peer)] connected; press Ctrl-C to exit")
        while !stopping {
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastSeen >= 4_000_000_000 {
                stop("server timed out", failed: true)
                break
            }
            if screen && controls > 0 && now - lastVideoTime >= 2_000_000_000 {
                try video?.requestRefresh()
            }
            try session.send(
                Data([SessionMessage.heartbeat.rawValue]), mode: .unreliable(retryBudget: 0))
            heartbeats += 1
            trace.write(peer, "heartbeat queued count=\(heartbeats)")
            report(session, now: now)
            try await Task.sleep(nanoseconds: 400_000_000)
        }
    }
    private func report(_ session: NetworkMessageSession, now: UInt64) {
        let elapsed = now - lastReport
        guard elapsed >= 1_000_000_000 else { return }
        let seconds = Double(elapsed) / 1e9
        let countedFrames = frames - backpressureDrops - codecDrops - checkpointSkips
        let fps = Double(countedFrames - previousFrames) / seconds
        let mbps = Double(videoBytes - previousBytes) * 8 / seconds / 1e6
        let stats = session.statistics
        let rtt = stats.roundTripTime.map { String(format: "%.1f ms", $0 * 1000) } ?? "pending"
        let details: String
        if role == .server {
            details =
                "generated=\(frames) queued=\(countedFrames) backpressureDrops=\(backpressureDrops) codecDrops=\(codecDrops)"
                + (screen
                    ? " encoderBps=\(targetBitRate) captureSkips=\(captureSkips) checkpointSkips=\(checkpointSkips)"
                    : "")
                + " ltrAcks=\(acknowledgedReferences) controlsQueued=\(controls) heartbeatsRx=\(heartbeats)"
        } else {
            details =
                "frames=\(frames) latest=#\(latestFrame) missingFrames=\(max(latestFrame, frames) - frames)"
                + (screen ? " displayEnqueued=\(displayEnqueued)" : " verified=\(verifiedFrames)")
                + " controls=\(controls) latest=#\(latestControl) heartbeatsQueued=\(heartbeats)"
        }
        let direction = role == .server ? "video queued" : "video received"
        log(
            "[\(peer)] \(direction) " + String(format: "%.1f fps %.2f Mbps", fps, mbps)
                + "  \(details)  RTT=\(rtt)"
                + String(
                    format: " txBudget=%.2f Mbps txQueue=%.1f ms", stats.bitsPerSecond / 1e6,
                    stats.estimatedQueueDelay * 1000))
        previousBytes = videoBytes
        previousFrames = countedFrames
        lastReport = now
    }

}

func log(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
