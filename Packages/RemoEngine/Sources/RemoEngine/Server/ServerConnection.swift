//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreMedia
import Foundation
import Network
import RemoCodec
import RemoTransport

/// One client of a `RemoteScreenServer`, from connection setup until it leaves or times out.
@MainActor
final class ServerConnection {
    typealias StartSource = @MainActor (StreamParameters) async throws -> any ScreenFrameSource

    /// Shared by every connection of one server.
    struct Context {
        let startSource: StartSource
        let pointer: PointerControlServer?
        let keyboard: KeyboardControlServer?
        let cursor: CursorMonitor?
        let diagnostics: Diagnostics
        let onEvent: @MainActor (RemoteScreenServer.Event) -> Void
    }

    /// 96 kbps Opus in 20 ms packets, with their headers.
    private static let audioBitRate = 110_000.0

    private let peer: String
    private let context: Context
    private let trace: HeartbeatTrace
    private let controlPeer = UUID()
    private var session: NetworkMessageSession?
    private var setup: Task<Void, Never>?
    private var video: VideoSession?
    private var active = false
    private var stopping = false
    private var stopReason = ""
    private var failed = false
    private let started = Instant.now
    private var lastSeen = Instant.now
    private var lastNewAck: Instant?
    private var previousAcceptedDataPackets: UInt32 = 0

    // Cursor & keyboard state
    private var cursorSubscription: UUID?
    private var cursorSequence: UInt64 = 0
    /// Shapes this client has been sent, so each goes once.
    private var sentCursorShapes: Set<UInt64> = []
    private var keyboardStateSequence: UInt64 = 0

    // Source
    private var streamParameters = StreamParameters()
    private var source: (any ScreenFrameSource)?
    private var frameForwardTask: Task<Void, Never>?
    private var streamWake: AsyncStream<Void>.Continuation?
    private var encoder: VideoEncoder?
    private var previousCapturePTS = CMTime.invalid
    private var lastCaptureSend: Instant?
    private var targetBitRate = StreamParameters.defaultMaximumVideoBitRate
    private var encoderFrameRate = StreamParameters.defaultFramesPerSecond
    private var lastRateUpdate: Instant?
    private var refreshBitRate = StreamParameters.defaultMaximumVideoBitRate
    private var lastQualityRefresh: Instant?
    private var lastImageChange = Instant.now
    private var refreshWhenStill = false
    /// Steps taken so far in sharpening the picture that is at rest now.
    private var sharpening = 0
    private var stillInterval = Duration.milliseconds(500)
    /// The link's own loss as last seen, fading over seconds so that a quiet moment between
    /// losses does not take the protection away.
    private var protectedLoss = 0.0
    private var protectedLossAt = Instant.now

    // Audio
    private var audioSendTask: Task<Void, Never>?
    private var audioQueued = 0
    private var audioBackpressure = 0
    private var audioSourceGaps: UInt64 = 0
    private var audioQueuePeak = Duration.zero
    private var sendsAudio = false

    // Statistics
    private var frames: UInt64 = 0
    private var controls: UInt64 = 0
    private var heartbeats = 0
    private var acknowledgedReferences = 0
    private var backpressureDrops: UInt64 = 0
    private var codecDrops: UInt64 = 0
    private var keyFrameWaits: UInt64 = 0
    private var captureSkips = 0
    private var videoBytes = 0
    private var previousFrames: UInt64 = 0
    private var previousBytes = 0
    private var lastReport = Instant.now

    init(peer: String, context: Context) {
        self.peer = peer
        self.context = context
        trace = HeartbeatTrace(layer: "session", diagnostics: context.diagnostics)
    }

    private func log(_ message: @autoclosure () -> String) {
        context.diagnostics.info(peer, message())
    }

    func run(_ connection: NWConnection) async {
        trace.write(peer, "server opening")
        context.onEvent(.clientConnected(peer: peer))
        let setup = Task { [self] in
            do {
                session = try await NetworkMessageSession(connection: connection) {
                    [weak self] bytes in
                    self?.receive(bytes)
                } closeHandler: { [weak self] reason in
                    self?.stop("connection closed: \(reason)", failed: true)
                }
            } catch {
                stop("connection setup: \(error)", failed: true)
            }
        }
        self.setup = setup
        let timeout = Task {
            try await Task.sleep(for: SessionTiming.connectionSetupTimeout)
            stop("connection setup timed out", failed: true)
        }
        await setup.value
        timeout.cancel()
        self.setup = nil

        if let session, !stopping {
            session.onDeliveryConfirmed = { [weak self] in
                guard let self else { return }
                let now = Instant.now
                lastNewAck = now
                lastSeen = now
            }
            lastSeen = .now
            lastReport = lastSeen
            trace.write(peer, "server ready")
            do {
                try await stream(session)
            } catch {
                stop("send failed: \(error)", failed: true)
            }
        }
        if let cursorSubscription { context.cursor?.unsubscribe(cursorSubscription) }
        cursorSubscription = nil
        audioSendTask?.cancel()
        frameForwardTask?.cancel()
        frameForwardTask = nil
        streamWake?.finish()
        streamWake = nil
        if let source {
            try? await source.stop()
            self.source = nil
        }
        video?.close()
        session?.cancel()
        session = nil
        context.onEvent(.clientDisconnected(peer: peer, reason: stopReason, failed: failed))
    }

    func stop(_ reason: String, failed: Bool) {
        guard !stopping else { return }
        stopping = true
        stopReason = reason
        self.failed = failed
        context.pointer?.end(for: controlPeer)
        context.keyboard?.end(for: controlPeer)
        setup?.cancel()
        streamWake?.yield(())
        let idle = Instant.now - lastSeen
        trace.write(
            peer,
            "server stop reason=\(reason) idle=\(idle.formatted(.units(allowed: [.milliseconds], width: .narrow))) active=\(active) heartbeats=\(heartbeats) frames=\(frames) controls=\(controls)"
        )
    }

    private func prepareVideo(_ source: any ScreenFrameSource) throws {
        let encoder = try VideoEncoder(
            width: source.width, height: source.height,
            framesPerSecond: Int(encoderFrameRate), bitRate: targetBitRate,
            enableLongTermReferences: true)
        self.encoder = encoder
        video = VideoSession(
            encoder: encoder,
            send: { [weak self] data, delivery, onOutcome in
                guard let self, !stopping, let session else {
                    throw NetworkMessageSession.SendError.closed
                }
                return try session.send(data, delivery: delivery, onOutcome: onOutcome)
            },
            cancel: { [weak self] in self?.session?.cancelMessage($0) },
            onFrame: { _, _, _ in },
            onEvent: { [weak self] event in
                guard let self else { return }
                if case .acknowledged(let frame, let token) = event {
                    acknowledgedReferences += 1
                    if acknowledgedReferences == 1 {
                        log("first LTR acknowledged frame=\(frame) token=\(token.rawValue)")
                    }
                } else if let line = event.diagnostic {
                    log(line)
                }
            },
            onFailure: { [weak self] error in self?.stop("video failed: \(error)", failed: true) })
    }

    private func receive(_ bytes: Data) {
        guard !stopping, let first = bytes.first,
            let kind = MessageKind(rawValue: first)
        else { return }
        if video?.receive(bytes) == true {
            switch kind {
            case .videoAcknowledgement, .videoRecoveryRequest:
                if active && !stopping { lastSeen = .now }
            default: break
            }
            return
        }
        switch kind {
        case .hello:
            guard case let .hello(requestsControl, stream) = try? SessionHandshake(decoding: bytes) else {
                return
            }
            if !active {
                active = true
                streamParameters = stream
                targetBitRate = stream.maximumVideoBitRate
                encoderFrameRate = stream.framesPerSecond
                refreshBitRate = stream.maximumVideoBitRate
                if cursorSubscription == nil, let cursor = context.cursor {
                    cursorSubscription = cursor.subscribe { [weak self] state, shape in
                        self?.sendCursor(state, shape: shape)
                    }
                }
                let grant = requestsControl ? beginControl() : nil
                if let session {
                    let ready = SessionHandshake.ready(control: grant)
                    do {
                        try session.send(ready.encoded, delivery: ready.delivery)
                    } catch {
                        if grant != nil {
                            context.pointer?.end(for: controlPeer)
                            context.keyboard?.end(for: controlPeer)
                        }
                    }
                }
                streamWake?.yield(())
                let sizeText = stream.maximumSize.map { "\($0.width)x\($0.height)" } ?? "default"
                trace.write(
                    peer,
                    "hello accepted control=\(grant != nil) size=\(sizeText) fps=\(stream.framesPerSecond) maxBps=\(stream.maximumVideoBitRate) audio=\(stream.streamsAudio)"
                )
            }
        case .heartbeat:
            guard bytes.count == 1, active else {
                trace.write(peer, "heartbeat ignored active=\(active) bytes=\(bytes.count)")
                return
            }
            heartbeats += 1
            trace.write(peer, "heartbeat accepted count=\(heartbeats)")
        case .goodbye where bytes.count == 1:
            stop("client left", failed: false)
        case .pointerInput where active:
            guard context.pointer?.receive(bytes, from: controlPeer) == true else { return }
        case .keyboardInput where active:
            guard context.keyboard?.receive(bytes, from: controlPeer) == true else { return }
        default: return
        }
        lastSeen = .now
    }

    private func beginControl() -> SessionHandshake.ControlGrant? {
        guard let pointer = context.pointer, let keyboard = context.keyboard,
            let pointerState = pointer.begin(for: controlPeer)
        else { return nil }
        guard
            let capsLock = keyboard.begin(
                for: controlPeer,
                onCapsLockChanged: { [weak self] isOn in
                    self?.sendKeyboardState(capsLock: isOn)
                })
        else {
            pointer.end(for: controlPeer)
            return nil
        }
        return SessionHandshake.ControlGrant(
            pointerPosition: pointerState.position,
            displayWidth: pointerState.width,
            displayHeight: pointerState.height,
            capsLock: capsLock)
    }

    private func sendKeyboardState(capsLock: Bool) {
        guard !stopping, active, let session else { return }
        keyboardStateSequence += 1
        let message = KeyboardMessage.state(sequence: keyboardStateSequence, capsLock: capsLock)
        do {
            try session.send(message.encoded, delivery: message.delivery)
        } catch NetworkMessageSession.SendError.backpressure {
            // The next state change replaces this one.
        } catch {
            stop("send failed: \(error)", failed: true)
        }
    }

    private func sendCursor(_ state: CursorState, shape: CursorShape?) {
        guard !stopping, active, let session else { return }
        do {
            if let shape, !sentCursorShapes.contains(shape.id) {
                // A client keeps more shapes than this, so it still has every one sent since.
                if sentCursorShapes.count >= 128 { sentCursorShapes.removeAll() }
                let message = CursorMessage.shape(shape)
                try session.send(message.encoded, delivery: message.delivery)
                sentCursorShapes.insert(shape.id)
            }
            cursorSequence += 1
            let message = CursorMessage.state(sequence: cursorSequence, state)
            try session.send(message.encoded, delivery: message.delivery)
        } catch NetworkMessageSession.SendError.backpressure {
            // The monitor publishes the cursor again shortly.
        } catch {
            stop("send failed: \(error)", failed: true)
        }
    }

    private func stream(_ session: NetworkMessageSession) async throws {
        var nextFrame = Instant.now
        var nextControl = nextFrame
        let (wakes, wakeSink) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        streamWake = wakeSink
        var wakeIterator = wakes.makeAsyncIterator()
        var eventDriven = false
        while !stopping {
            let now = Instant.now
            if now - lastSeen >= SessionTiming.clientTimeout {
                stop("client timed out", failed: false)
                break
            }
            if active {
                if now >= nextControl, session.dataSendIdleTime >= SessionTiming.controlInterval.timeInterval {
                    do {
                        try session.send(
                            ControlMessage(sequence: controls + 1).encoded,
                            delivery: .retrying(
                                sendWithin: SessionTiming.controlInterval, replacing: .control))
                        controls += 1
                        nextControl = now + SessionTiming.controlInterval
                    } catch NetworkMessageSession.SendError.backpressure {
                        // Retry on the next frame tick.
                    }
                }
                if source == nil {
                    // Start the source once the client sends its stream parameters.
                    let source = try await context.startSource(streamParameters)
                    self.source = source
                    if stopping { break }
                    try prepareVideo(source)
                    if streamParameters.streamsAudio, let capture = source as? any AudioSource {
                        startAudio(capture, session: session)
                    }
                    context.onEvent(
                        .streamingStarted(
                            peer: peer,
                            session: RemoteScreenServer.SessionInfo(
                                width: source.width, height: source.height,
                                framesPerSecond: streamParameters.framesPerSecond,
                                maximumVideoBitRate: streamParameters.maximumVideoBitRate,
                                streamsAudio: sendsAudio)))
                    if let notifying = source as? any NotifyingScreenFrameSource {
                        eventDriven = true
                        let arrivals = notifying.frameArrivals
                        frameForwardTask = Task {
                            for await _ in arrivals { wakeSink.yield(()) }
                            wakeSink.yield(())
                        }
                    }
                }
                guard let source, let video else { throw VideoSession.Failure.closed }
                try await send(source, video: video, session: session, now: now, eventDriven: eventDriven)
                report(session, now: now)
            }
            if eventDriven {
                let deadline = nextMaintenanceDeadline(from: Instant.now, nextControl: nextControl)
                let timer = Task {
                    do {
                        try await Task.sleep(until: deadline, clock: .suspending)
                        wakeSink.yield(())
                    } catch {}
                }
                _ = await wakeIterator.next()
                timer.cancel()
            } else {
                let interval = effectiveFrameInterval
                nextFrame += interval
                let sent = Instant.now
                if nextFrame <= sent { nextFrame = sent + interval }
                try await Task.sleep(until: nextFrame, clock: .suspending)
            }
        }
    }

    /// Effective frame rate cap for current link conditions: full configured FPS on healthy
    /// higher-bitrate links (e.g. 5 Mbps), stepping down to 30 fps when bitrate is tight or loss
    /// is heavy so each frame gets twice the bit budget and half the per-second loss exposure.
    private var effectiveFramesPerSecond: Int32 {
        if streamParameters.framesPerSecond > 30 && (targetBitRate < 2_000_000 || protectedLoss >= 0.05) {
            return 30
        }
        return streamParameters.framesPerSecond
    }

    private var effectiveFrameInterval: Duration {
        .seconds(1) / Int(effectiveFramesPerSecond)
    }

    private func nextMaintenanceDeadline(from now: Instant, nextControl: Instant) -> Instant {
        var deadline = now + .milliseconds(100)
        if let lastCaptureSend {
            deadline = min(deadline, lastCaptureSend + stillInterval)
        }
        deadline = min(deadline, nextControl, lastReport + SessionTiming.reportInterval)
        return max(now + .milliseconds(5), deadline)
    }

    private func startAudio(_ capture: any AudioSource, session: NetworkMessageSession) {
        sendsAudio = true
        audioSendTask = Task {
            do {
                var nextSequence: UInt64 = 0
                for try await packet in capture.audioMessages {
                    audioSourceGaps += packet.sequence - nextSequence
                    nextSequence = packet.sequence + 1
                    // Audio waits only behind other high-priority messages.
                    audioQueuePeak = max(
                        audioQueuePeak, .seconds(session.statistics.queueDelay(for: .high)))
                    guard !Task.isCancelled, !stopping else { return }
                    do {
                        try session.send(
                            packet.encoded,
                            delivery: .retrying(
                                sendWithin: SessionTiming.audioDeadline, priority: .high))
                        audioQueued += 1
                    } catch NetworkMessageSession.SendError.backpressure {
                        audioBackpressure += 1
                    }
                }
            } catch { log("Audio streaming stopped: \(error)") }
        }
    }

    private func send(
        _ source: any ScreenFrameSource, video: VideoSession, session: NetworkMessageSession,
        now: Instant, eventDriven: Bool
    ) async throws {
        let stats = session.statistics
        let budget = stats.bitsPerSecond
        let maximum = streamParameters.maximumVideoBitRate
        protectedLoss = max(
            stats.linkLossRatio, protectedLoss * pow(0.5, (now - protectedLossAt) / .seconds(5)))
        protectedLossAt = now
        let redundancy = videoRedundancy
        // Audio is sent first whatever the video does, so it comes off the top. The rest keeps
        // a margin for retransmissions and for frames larger than the encoder was asked for,
        // and is shared between the picture and its repair fragments.
        let target = min(
            maximum,
            max(128_000, Int((budget * 0.88 - (sendsAudio ? Self.audioBitRate : 0)) / (1 + redundancy))))
        let shouldUpdateRate =
            target < targetBitRate * 9 / 10
            || (now.hasElapsed(.milliseconds(300), since: lastRateUpdate)
                && (abs(target - targetBitRate) > targetBitRate / 20
                    || (target == maximum && target != targetBitRate)))
        if shouldUpdateRate {
            try encoder?.setBitRate(target)
            refreshBitRate = min(refreshBitRate, target)
            targetBitRate = target
            lastRateUpdate = now
        }
        let desiredFPS = effectiveFramesPerSecond
        if desiredFPS != encoderFrameRate {
            try encoder?.setExpectedFrameRate(Int(desiredFPS))
            encoderFrameRate = desiredFPS
        }
        // Skip before encoding so congestion does not break the prediction chain.
        guard let frame = try source.latestFrame() else { return }
        let capturePTS = frame.timestamp
        let changed = capturePTS != previousCapturePTS
        let fastSharpen = targetBitRate >= 2_500_000
        let settleDelay: Duration = fastSharpen ? .milliseconds(300) : .seconds(1)
        let baseStillInterval: Duration = fastSharpen ? .milliseconds(250) : .milliseconds(500)
        if changed {
            lastImageChange = now
            refreshWhenStill = true
            sharpening = 0
            stillInterval = baseStillInterval
        }
        // Send a still desktop again periodically so a lost frame can be recovered.
        guard changed || now.hasElapsed(stillInterval, since: lastCaptureSend) else { return }
        if eventDriven, changed, desiredFPS < streamParameters.framesPerSecond,
            !now.hasElapsed(effectiveFrameInterval - .milliseconds(2), since: lastCaptureSend)
        {
            return
        }
        let maxQueueDelay: Duration = (stats.roundTripTime ?? 0.1) < 0.02 ? .milliseconds(90) : .milliseconds(75)
        if Duration.seconds(stats.estimatedQueueDelay) > maxQueueDelay {
            captureSkips += 1
            return
        }
        let minimumQP =
            encoder?.supportsQuantizerLimit == true
            ? Self.queuePressureMinimumQP(queueDelay: stats.estimatedQueueDelay, bitRate: targetBitRate)
            : nil
        var maximumQP: Int?
        if encoder?.supportsQuantizerLimit == true {
            // A picture that has come to rest is sharpened by ordinary frames, a step at a
            // time. Each is a fraction of a key frame, and losing one costs nothing but itself.
            if !changed, minimumQP == nil, now - lastImageChange >= settleDelay {
                let steps = Self.sharpeningSteps(for: targetBitRate)
                if sharpening < steps.count {
                    maximumQP = steps[sharpening]
                }
            }
        } else {
            // Without a quantizer limit only a key frame makes a still picture any finer.
            let settled =
                Double(targetBitRate) <= budget && refreshWhenStill
                && now - lastImageChange >= settleDelay
            let improved =
                targetBitRate >= refreshBitRate * 3 / 2
                || (targetBitRate == maximum && refreshBitRate < targetBitRate)
            if (improved || settled) && now.hasElapsed(.seconds(5), since: lastQualityRefresh) {
                video.requestKeyFrame()
                lastQualityRefresh = now
                refreshBitRate = targetBitRate
                refreshWhenStill = false
                log("screen quality refresh encoderBps=\(targetBitRate)")
            }
        }
        previousCapturePTS = capturePTS
        lastCaptureSend = now
        // Stamp frames with the send time; a still picture sent again is a new frame.
        let bytes = try await submit(
            frame.pixels, pts: CMTime(value: (now - started).nanoseconds, timescale: 1_000_000_000),
            video: video,
            retryFor: SessionTiming.frameRetryBudget(
                roundTrip: stats.roundTripTime.map(Duration.seconds)),
            minimumQP: minimumQP, maximumQP: maximumQP, expectedLoss: protectedLoss)
        if let maximumQP, bytes > 0 {
            let steps = Self.sharpeningSteps(for: targetBitRate)
            if sharpening < steps.count {
                log("still picture sharpened maxQP=\(maximumQP) bytes=\(bytes)")
            }
            sharpening += 1
            // Give the link time to pay for one step before the next, then relax to steady keepalive.
            if sharpening < steps.count {
                stillInterval = max(
                    baseStillInterval, .seconds(Double(bytes) * 8 / Double(targetBitRate) * 1.5))
            } else {
                stillInterval = .milliseconds(500)
            }
        }
    }

    /// What repair fragments add to a frame of the size the encoder is aiming for. Each frame
    /// gets its own share when it is sent: this is the average to budget for.
    private var videoRedundancy: Double {
        SessionTiming.frameRedundancy(
            bytes: targetBitRate / 8 / max(1, Int(effectiveFramesPerSecond)), loss: protectedLoss)
    }

    /// Quantizer limits for sharpening a still picture, coarsest first. Higher bitrates sharpen
    /// faster and reach finer detail for crisp text.
    private static func sharpeningSteps(for bitRate: Int) -> [Int] {
        switch bitRate {
        case ..<500_000: [32]
        case ..<1_000_000: [32, 29]
        case ..<2_500_000: [32, 29, 26]
        default: [28, 24, 20]
        }
    }

    /// Raises the quantizer floor once the local send queue exceeds the transport's backlog
    /// threshold (35 ms), trading moving-frame sharpness for compact frames so animations stay
    /// fluid without starving pacer-limited bandwidth probing or hitting capture skips.
    nonisolated static func queuePressureMinimumQP(queueDelay: TimeInterval, bitRate: Int) -> Int? {
        guard queueDelay > 0.035 else { return nil }
        let base = VideoEncoder.motionMinimumQP(for: bitRate)
        switch queueDelay {
        case ..<0.050: return min(45, base + 4)
        case ..<0.065: return min(46, base + 8)
        default: return min(48, base + 12)
        }
    }

    /// Returns the bytes admitted, or zero if the frame was dropped or held back.
    private func submit(
        _ pixels: CVPixelBuffer, pts: CMTime, video: VideoSession, retryFor retryBudget: Duration,
        minimumQP: Int?, maximumQP: Int?, expectedLoss: Double
    ) async throws -> Int {
        frames += 1
        do {
            let bytes = try await video.sendFrame(
                pixels, presentationTime: pts,
                duration: CMTime(value: 1, timescale: effectiveFramesPerSecond),
                retryFor: retryBudget, minimumQP: minimumQP, maximumQP: maximumQP,
                expectedLoss: expectedLoss)
            if bytes == 0 {
                keyFrameWaits += 1
                // This picture was not sent. Offer it again once the key frame has arrived,
                // even if the desktop is still by then.
                lastCaptureSend = nil
            }
            videoBytes += bytes
            return bytes
        } catch VideoCodecError.frameDropped {
            codecDrops += 1
        } catch NetworkMessageSession.SendError.backpressure {
            backpressureDrops += 1
        }
        return 0
    }

    private func report(_ session: NetworkMessageSession, now: Instant) {
        let elapsed = now - lastReport
        guard elapsed >= SessionTiming.reportInterval else { return }
        let seconds = elapsed / .seconds(1)
        let queued = frames - backpressureDrops - codecDrops - keyFrameWaits
        let audio =
            sendsAudio
            ? ServerStatistics.Audio(
                packetsQueued: audioQueued, sourceGaps: audioSourceGaps,
                backpressureDrops: audioBackpressure, peakQueueDelay: audioQueuePeak) : nil
        audioQueuePeak = .zero
        let transport = session.statistics
        let sampledAt = Instant.now
        let statistics = ServerStatistics(
            framesPerSecond: Double(queued - previousFrames) / seconds,
            videoBitsPerSecond: Double(videoBytes - previousBytes) * 8 / seconds,
            framesGenerated: frames, framesQueued: queued, backpressureDrops: backpressureDrops,
            codecDrops: codecDrops, encoderBitRate: targetBitRate,
            videoRedundancy: videoRedundancy,
            captureSkips: captureSkips, keyFrameWaits: keyFrameWaits,
            acknowledgedReferences: acknowledgedReferences, controlsSent: controls,
            heartbeatsReceived: heartbeats, dataPacketsAccepted: transport.acceptedDataPackets - previousAcceptedDataPackets,
            newAckAge: lastNewAck.map { sampledAt - $0 }, blocked: transport.blocked, probing: transport.probing,
            audio: audio, link: LinkStatistics(transport))
        previousAcceptedDataPackets = transport.acceptedDataPackets
        previousBytes = videoBytes
        previousFrames = queued
        lastReport = now
        context.onEvent(.statistics(peer: peer, statistics))
    }
}
