//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreMedia
import Dispatch
import Foundation
import Network
import RemoCodec
import RemoTransport

/// One client of a `RemoteScreenServer`, from connection setup until it leaves or times out.
@MainActor
final class ServerConnection {
    typealias StartCapture = @MainActor () async throws -> any ScreenFrameSource

    /// Shared by every connection of one server.
    struct Context {
        let framesPerSecond: Int32
        let maximumVideoBitRate: Int
        let startCapture: StartCapture
        let mouse: MouseControlServer?
        let diagnostics: Diagnostics
        let onEvent: @MainActor (RemoteScreenServer.Event) -> Void

        var frameInterval: UInt64 { 1_000_000_000 / UInt64(framesPerSecond) }
    }

    private let peer: String
    private let context: Context
    private let trace: HeartbeatTrace
    private let mousePeer = UUID()
    private var session: NetworkMessageSession?
    private var setup: Task<Void, Never>?
    private var video: VideoSession?
    private var active = false
    private var stopping = false
    private var stopReason = ""
    private var failed = false
    private var lastSeen = DispatchTime.now().uptimeNanoseconds

    // Source
    private var source: (any ScreenFrameSource)?
    private var encoder: VideoEncoder?
    private var previousCapturePTS = CMTime.invalid
    private var lastCaptureSend: UInt64 = 0
    private var targetBitRate: Int
    private var lastRateUpdate: UInt64 = 0
    private var refreshBitRate: Int
    private var lastQualityRefresh: UInt64 = 0
    private var lastImageChange: UInt64 = 0
    private var refreshWhenStill = false

    // Audio
    private var audioSendTask: Task<Void, Never>?
    private var audioQueued = 0
    private var audioBackpressure = 0
    private var audioSourceGaps: UInt64 = 0
    private var audioQueuePeak: TimeInterval = 0
    private var sendsAudio = false

    // Statistics
    private var frames: UInt64 = 0
    private var controls: UInt64 = 0
    private var heartbeats = 0
    private var acknowledgedReferences = 0
    private var backpressureDrops: UInt64 = 0
    private var codecDrops: UInt64 = 0
    private var checkpointSkips: UInt64 = 0
    private var captureSkips = 0
    private var videoBytes = 0
    private var previousFrames: UInt64 = 0
    private var previousBytes = 0
    private var lastReport = DispatchTime.now().uptimeNanoseconds

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
        context.mouse?.end(for: mousePeer)
        setup?.cancel()
        let idleMs = (DispatchTime.now().uptimeNanoseconds - lastSeen) / 1_000_000
        trace.write(
            peer,
            "server stop reason=\(reason) idleMs=\(idleMs) active=\(active) heartbeats=\(heartbeats) frames=\(frames) controls=\(controls)"
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
            send: { [weak self] data, mode in
                guard let self, !stopping, let session else {
                    throw NetworkMessageSession.SendError.closed
                }
                try session.send(data, mode: mode)
            },
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

    private func receive(_ channel: MessageTransport.Channel, _ bytes: Data) {
        guard !stopping, video?.receive(channel, bytes) != true, let first = bytes.first,
            let kind = SessionMessage(rawValue: first)
        else { return }
        switch (channel, kind) {
        case (.reliable, .hello), (.reliable, .screenHello):
            guard bytes.count == 1 else { return }
            if !active { context.onEvent(.streamingStarted(peer: peer)) }
            active = true
            trace.write(peer, "hello accepted")
        case (_, .heartbeat):
            guard channel == .unreliable, bytes.count == 1, active else {
                trace.write(
                    peer,
                    "heartbeat ignored active=\(active) channel=\(channel) bytes=\(bytes.count)")
                return
            }
            heartbeats += 1
            trace.write(peer, "heartbeat accepted count=\(heartbeats)")
        case (.reliable, .goodbye) where bytes.count == 1:
            stop("client left", failed: false)
        case (.reliable, .mouseHello) where active && bytes.count == 1:
            guard let mouse = context.mouse, let session, let ready = mouse.begin(for: mousePeer)
            else { return }
            do {
                try session.send(ready.encoded, mode: .reliable)
            } catch {
                mouse.end(for: mousePeer)
            }
        case (_, .mouseInput) where active:
            context.mouse?.receive(bytes, on: channel, from: mousePeer)
            return
        default: return
        }
        lastSeen = DispatchTime.now().uptimeNanoseconds
    }

    private func stream(_ session: NetworkMessageSession) async throws {
        var nextFrame = DispatchTime.now().uptimeNanoseconds
        var nextControl = nextFrame
        while !stopping {
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastSeen >= SessionTiming.clientTimeout {
                stop("client timed out", failed: false)
                break
            }
            if active {
                if now >= nextControl {
                    do {
                        try session.send(
                            SessionMessage.control(sequence: controls + 1), mode: .reliable)
                        controls += 1
                        nextControl = now + SessionTiming.controlInterval
                    } catch NetworkMessageSession.SendError.backpressure {
                        // Retry on the next frame tick.
                    }
                }
                if source == nil {
                    // Start the source once the client asks for video.
                    let source = try await context.startCapture()
                    self.source = source
                    if stopping { break }
                    try prepareVideo(source)
                    if let capture = source as? any ScreenAudioSource {
                        startAudio(capture, session: session)
                    }
                }
                guard let source, let video else { throw VideoSession.Failure.closed }
                try await send(source, video: video, session: session, now: now)
                report(session, now: now)
            }
            nextFrame += context.frameInterval
            let sent = DispatchTime.now().uptimeNanoseconds
            if nextFrame <= sent { nextFrame = sent + context.frameInterval }
            try await Task.sleep(nanoseconds: nextFrame - sent)
        }
    }

    private func startAudio(_ capture: any ScreenAudioSource, session: NetworkMessageSession) {
        sendsAudio = true
        audioSendTask = Task {
            do {
                var nextSequence: UInt64 = 0
                for try await packet in capture.audioPackets {
                    audioSourceGaps += packet.sequence - nextSequence
                    nextSequence = packet.sequence + 1
                    audioQueuePeak = max(audioQueuePeak, session.statistics.estimatedQueueDelay)
                    guard !Task.isCancelled, !stopping else { return }
                    do {
                        try session.send(
                            packet.message,
                            mode: .unreliable(
                                retryBudget: 0, firstSendDeadline: uptime() + 0.10,
                                priority: .high))
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
        now: UInt64
    ) async throws {
        let stats = session.statistics
        let budget = stats.bitsPerSecond
        let maximum = context.maximumVideoBitRate
        let target = min(maximum, max(128_000, Int(budget * 0.7)))
        if now - lastRateUpdate >= 500_000_000
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
        if capturePTS != previousCapturePTS {
            lastImageChange = now
            refreshWhenStill = true
        }
        // Refresh a still desktop periodically so a lost frame can be recovered.
        guard capturePTS != previousCapturePTS || now - lastCaptureSend >= 500_000_000 else {
            return
        }
        if stats.estimatedQueueDelay > 0.05 {
            captureSkips += 1
            return
        }
        let settled =
            Double(targetBitRate) <= budget && refreshWhenStill
            && now - lastImageChange >= 1_000_000_000
        let improved =
            targetBitRate >= refreshBitRate * 3 / 2
            || (targetBitRate == maximum && refreshBitRate < targetBitRate)
        if (improved || settled) && now - lastQualityRefresh >= 5_000_000_000 {
            video.requestKeyFrame()
            lastQualityRefresh = now
            refreshBitRate = targetBitRate
            refreshWhenStill = false
            log("screen quality refresh encoderBps=\(targetBitRate)")
        }
        previousCapturePTS = capturePTS
        lastCaptureSend = now
        try await submit(
            frame.pixels, pts: CMTime(value: Int64(now), timescale: 1_000_000_000), video: video)
    }

    private func submit(_ pixels: CVPixelBuffer, pts: CMTime, video: VideoSession) async throws {
        frames += 1
        do {
            let bytes = try await video.sendFrame(
                pixels, presentationTime: pts,
                duration: CMTime(value: 1, timescale: context.framesPerSecond))
            if bytes == 0 { checkpointSkips += 1 }
            videoBytes += bytes
        } catch VideoCodecError.frameDropped {
            codecDrops += 1
        } catch NetworkMessageSession.SendError.backpressure {
            backpressureDrops += 1
        }
    }

    private func report(_ session: NetworkMessageSession, now: UInt64) {
        let elapsed = now - lastReport
        guard elapsed >= SessionTiming.reportInterval else { return }
        let seconds = Double(elapsed) / 1e9
        let queued = frames - backpressureDrops - codecDrops - checkpointSkips
        let audio =
            sendsAudio
            ? ServerStatistics.Audio(
                packetsQueued: audioQueued, sourceGaps: audioSourceGaps,
                backpressureDrops: audioBackpressure, peakQueueDelay: audioQueuePeak) : nil
        audioQueuePeak = 0
        let statistics = ServerStatistics(
            framesPerSecond: Double(queued - previousFrames) / seconds,
            videoBitsPerSecond: Double(videoBytes - previousBytes) * 8 / seconds,
            framesGenerated: frames, framesQueued: queued, backpressureDrops: backpressureDrops,
            codecDrops: codecDrops, encoderBitRate: targetBitRate,
            captureSkips: captureSkips, checkpointSkips: checkpointSkips,
            acknowledgedReferences: acknowledgedReferences, controlsSent: controls,
            heartbeatsReceived: heartbeats, audio: audio, link: LinkStatistics(session.statistics))
        previousBytes = videoBytes
        previousFrames = queued
        lastReport = now
        context.onEvent(.statistics(peer: peer, statistics))
    }
}
