//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Dispatch
import Foundation
import Network

#if os(macOS)
    import CoreGraphics
#endif

private func valid(_ length: Int) -> Bool {
    (2...8192).contains(length) && length.isMultiple(of: 2)
}

/// Streams a video source to every client that connects, adapting to each client's link and
/// requested stream parameters.
@MainActor
public final class RemoteScreenServer {
    public enum Source: Sendable {
        /// The main display, scaled to fit each client's requested size and optionally capturing
        /// system audio when the client asks for it. macOS only.
        case mainDisplay
        /// Starts a source for each client once its handshake arrives.
        case custom(@MainActor @Sendable (StreamParameters) async throws -> any ScreenFrameSource)
    }

    public struct Configuration: Sendable {
        public var source: Source
        /// Lets one client at a time drive the main display's pointer and keyboard. Requires Accessibility access.
        public var allowsRemoteControl = false
        public var diagnostics = Diagnostics()

        public init(
            source: Source = .mainDisplay,
            allowsRemoteControl: Bool = false,
            diagnostics: Diagnostics = Diagnostics()
        ) {
            self.source = source
            self.allowsRemoteControl = allowsRemoteControl
            self.diagnostics = diagnostics
        }
    }

    /// The resolved stream settings a client is receiving after its handshake.
    public struct SessionInfo: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public let framesPerSecond: Int32
        public let maximumVideoBitRate: Int
        public let streamsAudio: Bool

        public init(
            width: Int, height: Int, framesPerSecond: Int32, maximumVideoBitRate: Int,
            streamsAudio: Bool
        ) {
            self.width = width
            self.height = height
            self.framesPerSecond = framesPerSecond
            self.maximumVideoBitRate = maximumVideoBitRate
            self.streamsAudio = streamsAudio
        }
    }

    public enum SetupError: Error, CustomStringConvertible {
        case invalidSource
        case screenCaptureUnavailable
        case screenDiscoveryFailed(any Error)
        case remoteControlUnavailable
        case accessibilityAccessRequired

        public var description: String {
            switch self {
            case .invalidSource: "The frame source must have even dimensions, from 2 to 8192."
            case .screenCaptureUnavailable: "Screen capture requires macOS."
            case .screenDiscoveryFailed(let error):
                "Screen discovery failed: \(error.localizedDescription). Check Screen Recording access in System Settings → Privacy & Security."
            case .remoteControlUnavailable: "Remote control requires a macOS main display source."
            case .accessibilityAccessRequired:
                "Remote control requires Accessibility access in System Settings → Privacy & Security."
            }
        }
    }

    public enum Event {
        case listening(port: UInt16)
        case clientConnected(peer: String)
        case streamingStarted(peer: String, session: SessionInfo)
        case clientDisconnected(peer: String, reason: String, failed: Bool)
        case statistics(peer: String, ServerStatistics)
    }

    /// The native pixel size of the main display, when streaming it.
    public let screenSize: (width: Int, height: Int)?

    private let context: ServerConnection.Context
    private var listener: NWListener?
    private var listenerEvents: AsyncStream<NWListener.State>.Continuation?
    private var connections: [ObjectIdentifier: (ServerConnection, Task<Void, Never>)] = [:] {
        didSet { updateActivity() }
    }
    /// Held while any client is connected. Streaming is latency-critical: once the app is in the
    /// background, App Nap and timer coalescing stretch the transport's pacing timer from about
    /// 1 ms to 7–14 ms, which caps the send rate far below the budget (measured: 2.0 instead of
    /// 4.9 Mbps, latency p50 143 instead of 28 ms). Idle system sleep waits too; the display may
    /// still sleep.
    private var activity: (any NSObjectProtocol)?
    private var stopped = false

    /// Validates the configuration and resolves the source, prompting for any permissions.
    public convenience init(
        configuration: Configuration, onEvent: @escaping @MainActor (Event) -> Void = { _ in }
    ) async throws {
        try await self.init(configuration: configuration, cursor: nil, onEvent: onEvent)
    }

    /// `cursor`, `pointer`, and `keyboard` stand in for the system hooks in tests.
    init(
        configuration: Configuration, cursor: (@MainActor () -> CursorSample?)?,
        pointer testPointer: PointerControlServer? = nil,
        keyboard testKeyboard: KeyboardControlServer? = nil,
        onEvent: @escaping @MainActor (Event) -> Void = { _ in }
    ) async throws {
        // 60 Hz is plenty for the eye and matches most displays; runs only while a client is subscribed.
        let cursorInterval = Duration.seconds(1) / 60
        var cursorMonitor = cursor.map { CursorMonitor(interval: cursorInterval, sample: $0) }
        #if os(macOS)
            if cursorMonitor == nil, case .mainDisplay = configuration.source {
                let system = SystemCursor(displayID: CGMainDisplayID())
                cursorMonitor = CursorMonitor(interval: cursorInterval, sample: system.sample)
            }
        #endif
        var pointer = testPointer
        var keyboard = testKeyboard
        if pointer == nil, keyboard == nil, configuration.allowsRemoteControl {
            #if os(macOS)
                guard case .mainDisplay = configuration.source else {
                    throw SetupError.remoteControlUnavailable
                }
                guard CGPreflightPostEventAccess() else {
                    throw SetupError.accessibilityAccessRequired
                }
                let keyboardServer = KeyboardControlServer()
                keyboard = keyboardServer
                pointer = PointerControlServer(
                    displayID: CGMainDisplayID(),
                    modifierFlags: { [weak keyboardServer] in
                        keyboardServer?.activeModifiers.cgEventFlags ?? []
                    },
                    onPost: { [cursorMonitor] in
                        cursorMonitor?.notePosted($0)
                    })
            #else
                throw SetupError.remoteControlUnavailable
            #endif
        }
        let startSource: ServerConnection.StartSource
        switch configuration.source {
        case .custom(let start):
            startSource = { parameters in
                let source = try await start(parameters)
                guard valid(source.width), valid(source.height) else {
                    try? await source.stop()
                    throw SetupError.invalidSource
                }
                return source
            }
            screenSize = nil
        case .mainDisplay:
            #if os(macOS)
                do {
                    screenSize = try await DisplayCapture.Configuration.discoverMainDisplay()
                } catch {
                    throw SetupError.screenDiscoveryFailed(error)
                }
                let traceDirectory = configuration.diagnostics.audioTraceDirectory
                startSource = { parameters in
                    let maxWidth = parameters.maximumSize?.width ?? StreamParameters.defaultScreenEdge
                    let maxHeight = parameters.maximumSize?.height ?? StreamParameters.defaultScreenEdge
                    let capture = try await DisplayCapture.Configuration.mainDisplay(
                        maximumWidth: maxWidth, maximumHeight: maxHeight,
                        framesPerSecond: parameters.framesPerSecond)
                    return try await capture.start(
                        capturesAudio: parameters.streamsAudio,
                        audioTraceDirectory: traceDirectory)
                }
            #else
                throw SetupError.screenCaptureUnavailable
            #endif
        }
        context = ServerConnection.Context(
            startSource: startSource, pointer: pointer, keyboard: keyboard, cursor: cursorMonitor,
            diagnostics: configuration.diagnostics,
            onEvent: onEvent)
    }

    /// Accepts clients until `stop()`, cancellation or a listener failure.
    /// Port 0 picks a free port, which the `listening` event reports.
    public func listen(on port: UInt16 = RemoProtocol.defaultPort) async throws {
        guard listener == nil, !stopped else { return }
        let listener = try NWListener(
            using: DatagramMonitor.parameters(for: context.diagnostics),
            on: NWEndpoint.Port(rawValue: port) ?? .any)
        let (states, events) = AsyncStream<NWListener.State>.makeStream()
        listener.stateUpdateHandler = { events.yield($0) }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        self.listener = listener
        listenerEvents = events
        listener.start(queue: DispatchQueue(label: "RemoEngine.listener"))
        var failure: (any Error)?
        loop: for await state in states {
            switch state {
            case .ready:
                context.onEvent(.listening(port: listener.port?.rawValue ?? port))
            case .failed(let error):
                failure = error
                break loop
            case .cancelled: break loop
            default: break
            }
        }
        stop()
        // Let every connection stop its capture before returning.
        for (_, task) in connections.values { await task.value }
        self.listener = nil
        if let failure { throw failure }
    }

    /// Stops listening and ends every session, releasing the pointer if a client held it.
    public func stop() {
        stopped = true
        listener?.cancel()
        listenerEvents?.finish()
        listenerEvents = nil
        for (connection, _) in connections.values {
            connection.stop("server stopped", failed: false)
        }
        context.pointer?.stop()
        context.keyboard?.stop()
    }

    private func updateActivity() {
        if connections.isEmpty {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        } else if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical], reason: "Streaming to a Remo client")
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else {
            connection.cancel()
            return
        }
        let client = ServerConnection(peer: connection.endpoint.debugDescription, context: context)
        let id = ObjectIdentifier(client)
        let task = Task { [weak self] in
            await client.run(connection)
            self?.connections[id] = nil
        }
        connections[id] = (client, task)
    }
}
