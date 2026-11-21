//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreGraphics
import Dispatch
import Foundation
import Network
import RemoCodec
import RemoTransport

/// Views a server's screen: keeps the session alive, decodes video, plays audio and, once the
/// server grants it, drives the remote pointer.
@MainActor
public final class RemoteScreenClient {
    /// How to reach the server.
    public enum Link {
        case udp(NWEndpoint)
        /// An unstarted datagram driver, such as a tunnel, that the session takes ownership of.
        case datagrams(any DatagramConnection)
    }

    public struct Configuration: Sendable {
        /// How long opening the link may take, including any tunnel handshake.
        public var setupTimeout: TimeInterval = 8
        /// How long the server may answer without sending a single frame.
        public var noVideoTimeout: TimeInterval = 15
        /// Asks the server for pointer control. A server grants it to one client at a time.
        public var requestsPointerControl = true
        public var diagnostics = Diagnostics()

        public init(
            setupTimeout: TimeInterval = 8, noVideoTimeout: TimeInterval = 15,
            requestsPointerControl: Bool = true, diagnostics: Diagnostics = Diagnostics()
        ) {
            self.setupTimeout = setupTimeout
            self.noVideoTimeout = noVideoTimeout
            self.requestsPointerControl = requestsPointerControl
            self.diagnostics = diagnostics
        }
    }

    public enum State: Sendable, Equatable {
        case idle, connecting, waitingForVideo, streaming
    }

    public enum Failure: Error {
        case setupTimedOut
        case connectionFailed(any Error)
        case connectionClosed
        case network(NWError)
        case serverNotResponding
        case noVideo
        case sendFailed(any Error)
        case videoFailed(any Error)
        /// The `onFrame` handler threw.
        case presentationFailed(any Error)
        case pointerInputFailed(any Error)
    }

    public enum Event {
        case state(State)
        /// The server granted pointer control. Sizes are in remote display pixels.
        case pointerAvailable(displaySize: CGSize)
        case statistics(ClientStatistics)
    }

    public private(set) var state = State.idle
    /// The remote display's size in pixels while this client controls its pointer.
    public var pointerDisplaySize: CGSize? { mouse.displaySize }

    private let configuration: Configuration
    private let onFrame: (VideoFrame) throws -> Void
    private let onEvent: (Event) -> Void
    private let trace: HeartbeatTrace
    private var work: Task<Void, Never>?
    private var failure: Failure?
    private var transport: NetworkMessageSession?
    private var video: VideoSession?
    private var playback: ScreenAudioPlayback?
    private var audioDisabled = false
    private var mouse = MouseControlClient()
    private var lastSeen: TimeInterval = 0
    private var lastFrame: TimeInterval = 0
    private var receivedControl = false
    private var counters = Counters()

    private struct Counters {
        var framesDecoded: UInt64 = 0
        var latestFrame: UInt64 = 0
        var videoBytes = 0
        var controls: UInt64 = 0
        var latestControl: UInt64 = 0
        var heartbeats = 0
        var previousFrames: UInt64 = 0
        var previousBytes = 0
        var lastReport = DispatchTime.now().uptimeNanoseconds
    }

    /// `onFrame` receives each decoded picture; throwing ends the session.
    public init(
        configuration: Configuration = Configuration(),
        onFrame: @escaping @MainActor (VideoFrame) throws -> Void,
        onEvent: @escaping @MainActor (Event) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.onFrame = onFrame
        self.onEvent = onEvent
        trace = HeartbeatTrace(layer: "session", diagnostics: configuration.diagnostics)
    }

    /// Runs one session until `disconnect()`, cancellation or a failure, which it returns.
    public func run(_ link: Link) async -> Failure? {
        guard work == nil else { return nil }
        failure = nil
        let work = Task { await session(link) }
        self.work = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        self.work = nil
        return failure
    }

    /// Leaves the session. `run` then returns without a failure.
    public func disconnect() {
        work?.cancel()
    }

    // MARK: Pointer

    /// Moves the remote pointer by a distance in remote display pixels.
    public func movePointer(by delta: CGVector) {
        sendPointer { $0.move(by: delta) }
    }

    public func pressPointer(_ button: MouseButton) {
        sendPointer { $0.press(button) }
    }

    /// Whole lines; positive values move the content down, following the finger.
    public func scroll(lines: Int) {
        sendPointer { $0.scroll(lines: lines) }
    }

    private func sendPointer(_ make: (inout MouseControlClient) -> MouseMessage?) {
        guard isRunning, state == .streaming, let transport, let message = make(&mouse) else {
            return
        }
        let mode = message.mode(now: uptime())
        do {
            try transport.send(message.encoded, mode: mode)
        } catch {
            if case .unreliable = mode { return }
            fail(.pointerInputFailed(error))
        }
    }

    // MARK: Session

    private var isRunning: Bool { work.map { !$0.isCancelled } ?? false }

    private func setState(_ state: State) {
        guard state != self.state else { return }
        self.state = state
        onEvent(.state(state))
    }

    /// Only the first failure counts, and none after the client chose to leave.
    private func fail(_ failure: Failure) {
        guard let work, !work.isCancelled else { return }
        self.failure = failure
        work.cancel()
    }

    private func session(_ link: Link) async {
        audioDisabled = false
        mouse = MouseControlClient()
        receivedControl = false
        counters = Counters()
        setState(.connecting)
        trace.write(nil, "client opening")
        let setupTimeout = Task { [weak self, configuration] in
            try await Task.sleep(nanoseconds: UInt64(configuration.setupTimeout * 1e9))
            self?.fail(.setupTimedOut)
        }
        defer {
            setupTimeout.cancel()
            trace.write(nil, "client stop failure=\(failure.map { "\($0)" } ?? "none")")
            playback?.stop()
            playback = nil
            video?.close()
            video = nil
            let session = transport
            transport = nil
            if let session {
                try? session.send(SessionMessage.goodbye.encoded, mode: .reliable)
                session.cancel()
            }
            setState(.idle)
        }

        let session: NetworkMessageSession
        do {
            session = try await open(link)
        } catch is CancellationError {
            return
        } catch {
            fail(.connectionFailed(error))
            return
        }
        transport = session
        setupTimeout.cancel()
        guard isRunning else { return }
        trace.write(nil, "client ready")

        do {
            video = VideoSession(
                send: { [weak self] data, mode in
                    guard let session = self?.transport else {
                        throw NetworkMessageSession.SendError.closed
                    }
                    try session.send(data, mode: mode)
                },
                onFrame: { [weak self] id, frame, bytes in
                    self?.present(VideoFrame(frame), id: id, bytes: bytes)
                },
                onEvent: { [weak self] event in
                    guard let self, let line = event.diagnostic else { return }
                    configuration.diagnostics.info(nil, line)
                },
                onFailure: { [weak self] error in self?.fail(.videoFailed(error)) })
            try session.send(SessionMessage.screenHello.encoded, mode: .reliable)
            trace.write(nil, "hello queued")
            setState(.waitingForVideo)
            try await keepAlive(session)
        } catch is CancellationError {
        } catch {
            fail(.sendFailed(error))
        }
    }

    private func open(_ link: Link) async throws -> NetworkMessageSession {
        let receive: (MessageTransport.Channel, Data) -> Void = { [weak self] in
            self?.receive($0, $1)
        }
        let close: (NetworkMessageSession.CloseReason) -> Void = { [weak self] reason in
            guard let self, transport != nil else { return }
            if case .network(let error) = reason {
                fail(.network(error))
            } else {
                fail(.connectionClosed)
            }
        }
        switch link {
        case .udp(let endpoint):
            let parameters = DatagramMonitor.parameters(for: configuration.diagnostics)
            return try await NetworkMessageSession(
                connection: NWConnection(to: endpoint, using: parameters),
                dataHandler: receive, closeHandler: close)
        case .datagrams(let driver):
            return try await NetworkMessageSession(
                driver: driver, dataHandler: receive, closeHandler: close)
        }
    }

    private func keepAlive(_ session: NetworkMessageSession) async throws {
        let started = uptime()
        lastSeen = started
        lastFrame = started
        counters.lastReport = DispatchTime.now().uptimeNanoseconds
        var nextMouseHello = started
        while isRunning {
            let now = uptime()
            if now - lastSeen >= SessionTiming.serverTimeout {
                fail(.serverNotResponding)
                return
            }
            if state == .waitingForVideo, now - started >= configuration.noVideoTimeout {
                fail(.noVideo)
                return
            }
            if receivedControl, now - lastFrame >= SessionTiming.videoStall {
                try video?.requestRefresh()
            }
            do {
                if configuration.requestsPointerControl, mouse.displaySize == nil,
                    now >= nextMouseHello
                {
                    nextMouseHello = now + SessionTiming.mouseHelloRetry
                    try session.send(SessionMessage.mouseHello.encoded, mode: .reliable)
                }
                try session.send(
                    SessionMessage.heartbeat.encoded, mode: .unreliable(retryBudget: 0))
                counters.heartbeats += 1
                trace.write(nil, "heartbeat queued count=\(counters.heartbeats)")
            } catch NetworkMessageSession.SendError.backpressure {
                // The next heartbeat replaces this one.
            }
            report(session)
            try await Task.sleep(nanoseconds: SessionTiming.heartbeatInterval)
        }
    }

    private func receive(_ channel: MessageTransport.Channel, _ data: Data) {
        // Video first: it also uses unrelated messages to retry lost refresh requests.
        guard isRunning, video?.receive(channel, data) != true, let byte = data.first else {
            return
        }
        if channel == .unreliable, byte == SessionMessage.audio.rawValue, !audioDisabled {
            if playback == nil {
                playback = ScreenAudioPlayback(
                    traceDirectory: configuration.diagnostics.audioTraceDirectory
                ) { [weak self] error in
                    guard let self else { return }
                    audioDisabled = true
                    configuration.diagnostics.info(nil, "Audio playback failed: \(error)")
                }
            }
            playback?.receive(data)
            return
        }
        guard channel == .reliable else { return }
        switch SessionMessage(rawValue: byte) {
        case .control:
            guard let sequence = SessionMessage.controlSequence(in: data) else { return }
            counters.controls += 1
            counters.latestControl = sequence
            receivedControl = true
            lastSeen = uptime()
        case .mouseReady:
            if mouse.receiveReady(data), let size = mouse.displaySize {
                onEvent(.pointerAvailable(displaySize: size))
            }
        default: break
        }
    }

    private func present(_ frame: VideoFrame, id: UInt64, bytes: Int) {
        guard isRunning else { return }
        lastFrame = uptime()
        lastSeen = lastFrame
        counters.framesDecoded += 1
        counters.latestFrame = max(counters.latestFrame, id)
        counters.videoBytes += bytes
        do { try onFrame(frame) } catch {
            fail(.presentationFailed(error))
            return
        }
        if state == .waitingForVideo { setState(.streaming) }
    }

    private func report(_ session: NetworkMessageSession) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - counters.lastReport
        guard elapsed >= SessionTiming.reportInterval else { return }
        let seconds = Double(elapsed) / 1e9
        let statistics = ClientStatistics(
            framesPerSecond: Double(counters.framesDecoded - counters.previousFrames) / seconds,
            videoBitsPerSecond: Double(counters.videoBytes - counters.previousBytes) * 8 / seconds,
            framesDecoded: counters.framesDecoded, latestFrame: counters.latestFrame,
            controlsReceived: counters.controls,
            latestControl: counters.latestControl, heartbeatsSent: counters.heartbeats,
            audio: playback?.statistics, link: LinkStatistics(session.statistics))
        counters.previousFrames = counters.framesDecoded
        counters.previousBytes = counters.videoBytes
        counters.lastReport = now
        onEvent(.statistics(statistics))
    }
}
