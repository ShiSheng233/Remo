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

/// Streams a video source to every client that connects, adapting to each client's link.
@MainActor
public final class RemoteScreenServer {
    public enum Source: Sendable {
        /// The main display, scaled to fit within the given pixel size, optionally with system
        /// audio. macOS only.
        case mainDisplay(maximumWidth: Int = 1920, maximumHeight: Int = 1920, capturesAudio: Bool = false)
        /// Starts a source for each client once it asks for video.
        case custom(@MainActor @Sendable () async throws -> any ScreenFrameSource)
    }

    public struct Configuration: Sendable {
        public var source: Source
        public var framesPerSecond: Int32 = 60
        public var maximumVideoBitRate = 5_000_000
        /// Lets one client at a time drive the main display's pointer. Requires Accessibility access.
        public var allowsPointerControl = false
        public var diagnostics = Diagnostics()

        public init(
            source: Source = .mainDisplay(), framesPerSecond: Int32 = 60,
            maximumVideoBitRate: Int = 5_000_000, allowsPointerControl: Bool = false,
            diagnostics: Diagnostics = Diagnostics()
        ) {
            self.source = source
            self.framesPerSecond = framesPerSecond
            self.maximumVideoBitRate = maximumVideoBitRate
            self.allowsPointerControl = allowsPointerControl
            self.diagnostics = diagnostics
        }
    }

    public enum SetupError: Error, CustomStringConvertible {
        case invalidFrameRate
        case invalidBitRate
        case invalidSize
        case invalidSource
        case screenCaptureUnavailable
        case screenDiscoveryFailed(any Error)
        case pointerControlUnavailable
        case accessibilityAccessRequired

        public var description: String {
            switch self {
            case .invalidFrameRate: "The frame rate must be 1...240."
            case .invalidBitRate: "The video bit rate must be positive."
            case .invalidSize: "Video dimensions must be even, from 2 to 8192."
            case .invalidSource: "The frame source must have even dimensions, from 2 to 8192."
            case .screenCaptureUnavailable: "Screen capture requires macOS."
            case .screenDiscoveryFailed(let error):
                "Screen discovery failed: \(error.localizedDescription). Check Screen Recording access in System Settings → Privacy & Security."
            case .pointerControlUnavailable: "Pointer control requires a macOS main display source."
            case .accessibilityAccessRequired:
                "Pointer control requires Accessibility access in System Settings → Privacy & Security."
            }
        }
    }

    public enum Event {
        case listening(port: UInt16)
        case clientConnected(peer: String)
        case streamingStarted(peer: String)
        case clientDisconnected(peer: String, reason: String, failed: Bool)
        case statistics(peer: String, ServerStatistics)
    }

    /// The capture size of a main display source, before any adaptation.
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
    public init(
        configuration: Configuration, onEvent: @escaping @MainActor (Event) -> Void = { _ in }
    ) async throws {
        guard (1...240).contains(configuration.framesPerSecond) else {
            throw SetupError.invalidFrameRate
        }
        guard configuration.maximumVideoBitRate > 0 else { throw SetupError.invalidBitRate }
        var pointer: PointerControlServer?
        if configuration.allowsPointerControl {
            #if os(macOS)
                guard case .mainDisplay = configuration.source else {
                    throw SetupError.pointerControlUnavailable
                }
                guard CGPreflightPostEventAccess() else {
                    throw SetupError.accessibilityAccessRequired
                }
                pointer = PointerControlServer(displayID: CGMainDisplayID())
            #else
                throw SetupError.pointerControlUnavailable
            #endif
        }
        let startSource: ServerConnection.StartSource
        switch configuration.source {
        case .custom(let start):
            startSource = {
                let source = try await start()
                guard valid(source.width), valid(source.height) else {
                    try? await source.stop()
                    throw SetupError.invalidSource
                }
                return source
            }
            screenSize = nil
        case .mainDisplay(let maximumWidth, let maximumHeight, let capturesAudio):
            guard valid(maximumWidth), valid(maximumHeight) else { throw SetupError.invalidSize }
            #if os(macOS)
                let capture: DisplayCapture.Configuration
                do {
                    capture = try await DisplayCapture.Configuration.mainDisplay(
                        maximumWidth: maximumWidth, maximumHeight: maximumHeight,
                        framesPerSecond: configuration.framesPerSecond)
                } catch {
                    throw SetupError.screenDiscoveryFailed(error)
                }
                let traceDirectory = configuration.diagnostics.audioTraceDirectory
                startSource = {
                    try await capture.start(
                        capturesAudio: capturesAudio, audioTraceDirectory: traceDirectory)
                }
                screenSize = (capture.width, capture.height)
            #else
                throw SetupError.screenCaptureUnavailable
            #endif
        }
        context = ServerConnection.Context(
            framesPerSecond: configuration.framesPerSecond,
            maximumVideoBitRate: configuration.maximumVideoBitRate,
            startSource: startSource, pointer: pointer, diagnostics: configuration.diagnostics,
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
