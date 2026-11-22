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
    typealias StartSource = @MainActor () async throws -> any ScreenFrameSource

    /// Shared by every connection of one server.
    struct Context {
        let framesPerSecond: Int32
        let maximumVideoBitRate: Int
        let startSource: StartSource
        let pointer: PointerControlServer?
        let diagnostics: Diagnostics
        let onEvent: @MainActor (RemoteScreenServer.Event) -> Void

        var frameInterval: Duration { .seconds(1) / Int(framesPerSecond) }
    }

    /// 96 kbps Opus in 20 ms packets, with their headers.
    private static let audioBitRate = 110_000.0

    private let peer: String
    private let context: Context
    private let trace: HeartbeatTrace
    private let pointerPeer = UUID()
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

    // Source
    private var source: (any ScreenFrameSource)?
    private var encoder: VideoEncoder?
    private var previousCapturePTS = CMTime.invalid
    private var lastCaptureSend: Instant?
    private var targetBitRate: Int
    private var lastRateUpdate: Instant?
    private var refreshBitRate: Int
    private var lastQualityRefresh: Instant?
    private var lastImageChange = Instant.now
    private var refreshWhenStill = false
    /// Steps taken so far in sharpening the picture that is at rest now.
    private var sharpening = 0
    private var stillInterval = Duration.milliseconds(500)

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
        targetBitRate = context.maximumVideoBitRate
        refreshBitRate = context.maximumVideoBitRate
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
        audioSendTask?.cancel()
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
        context.pointer?.end(for: pointerPeer)
        setup?.cancel()
        let idle = Instant.now - lastSeen
        trace.write(
            peer,
            "server stop reason=\(reason) idle=\(idle.formatted(.units(allowed: [.milliseconds], width: .narrow))) active=\(active) heartbeats=\(heartbeats) frames=\(frames) controls=\(controls)"
        )
    }

    private func prepareVideo(_ source: any ScreenFrameSource) throws {
        let encoder = try VideoEncoder(
            width: source.width, height: source.height,
            framesPerSecond: Int(context.framesPerSecond), bitRate: targetBitRate,
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
        case .hello, .screenHello:
            guard bytes.count == 1 else { return }
            if !active { context.onEvent(.streamingStarted(peer: peer)) }
            active = true
            trace.write(peer, "hello accepted")
        case .heartbeat:
            guard bytes.count == 1, active else {
                trace.write(peer, "heartbeat ignored active=\(active) bytes=\(bytes.count)")
                return
            }
            heartbeats += 1
            trace.write(peer, "heartbeat accepted count=\(heartbeats)")
        case .goodbye where bytes.count == 1:
            stop("client left", failed: false)
        case .pointerHello where active && bytes.count == 1:
            lastSeen = .now
            guard let pointer = context.pointer, let session, let ready = pointer.begin(for: pointerPeer)
            else { return }
            do {
                try session.send(ready.encoded, delivery: ready.delivery)
            } catch {
                pointer.end(for: pointerPeer)
            }
        case .pointerInput where active:
            guard context.pointer?.receive(bytes, from: pointerPeer) == true else { return }
        default: return
        }
        lastSeen = .now
    }

    private func stream(_ session: NetworkMessageSession) async throws {
        var nextFrame = Instant.now
        var nextControl = nextFrame
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
                    // Start the source once the client asks for video.
                    let source = try await context.startSource()
                    self.source = source
                    if stopping { break }
                    try prepareVideo(source)
                    if let capture = source as? any AudioSource {
                        startAudio(capture, session: session)
                    }
                }
                guard let source, let video else { throw VideoSession.Failure.closed }
                try await send(source, video: video, session: session, now: now)
                report(session, now: now)
            }
            nextFrame += context.frameInterval
            let sent = Instant.now
            if nextFrame <= sent { nextFrame = sent + context.frameInterval }
            try await Task.sleep(until: nextFrame, clock: .suspending)
        }
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
        now: Instant
    ) async throws {
        let stats = session.statistics
        let budget = stats.bitsPerSecond
        let maximum = context.maximumVideoBitRate
        // Audio is sent first whatever the video does, so it comes off the top. The rest keeps
        // a margin for retransmissions and for frames larger than the encoder was asked for.
        let target = min(
            maximum, max(128_000, Int(budget * 0.85 - (sendsAudio ? Self.audioBitRate : 0))))
        if now.hasElapsed(.milliseconds(500), since: lastRateUpdate)
            && (abs(target - targetBitRate) > targetBitRate / 8
                || (target == maximum && target != targetBitRate))
        {
            try encoder?.setBitRate(target)
            refreshBitRate = min(refreshBitRate, target)
            targetBitRate = target
            lastRateUpdate = now
        }
        // Skip before encoding so congestion does not break the prediction chain.
        guard let frame = try source.latestFrame() else { return }
        let capturePTS = frame.timestamp
        let changed = capturePTS != previousCapturePTS
        if changed {
            lastImageChange = now
            refreshWhenStill = true
            sharpening = 0
            stillInterval = .milliseconds(500)
        }
        // Send a still desktop again periodically so a lost frame can be recovered.
        guard changed || now.hasElapsed(stillInterval, since: lastCaptureSend) else { return }
        if Duration.seconds(stats.estimatedQueueDelay) > .milliseconds(50) {
            captureSkips += 1
            return
        }
        var maximumQP: Int?
        if encoder?.supportsQuantizerLimit == true {
            // A picture that has come to rest is sharpened by ordinary frames, a step at a
            // time. Each is a fraction of a key frame, and losing one costs nothing but itself.
            if !changed, now - lastImageChange >= .seconds(1) {
                let steps = Self.sharpeningSteps(for: targetBitRate)
                maximumQP = steps[min(sharpening, steps.count - 1)]
            }
        } else {
            // Without a quantizer limit only a key frame makes a still picture any finer.
            let settled =
                Double(targetBitRate) <= budget && refreshWhenStill
                && now - lastImageChange >= .seconds(1)
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
            maximumQP: maximumQP)
        if let maximumQP, bytes > 0 {
            if sharpening < Self.sharpeningSteps(for: targetBitRate).count {
                log("still picture sharpened maxQP=\(maximumQP) bytes=\(bytes)")
            }
            sharpening += 1
            // Give the link time to pay for one step before the next.
            stillInterval = max(
                .milliseconds(500), .seconds(Double(bytes) * 8 / Double(targetBitRate) * 1.5))
        }
    }

    /// Quantizer limits for sharpening a still picture, coarsest first. Moving pictures and
    /// key frames stop at 34. A slow link is not asked for the finest steps.
    private static func sharpeningSteps(for bitRate: Int) -> [Int] {
        bitRate < 500_000 ? [32] : bitRate < 1_000_000 ? [32, 29] : [32, 29, 26]
    }

    /// Returns the bytes admitted, or zero if the frame was dropped or held back.
    private func submit(
        _ pixels: CVPixelBuffer, pts: CMTime, video: VideoSession, retryFor retryBudget: Duration,
        maximumQP: Int?
    ) async throws -> Int {
        frames += 1
        do {
            let bytes = try await video.sendFrame(
                pixels, presentationTime: pts,
                duration: CMTime(value: 1, timescale: context.framesPerSecond),
                retryFor: retryBudget, maximumQP: maximumQP)
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
