//
//  Created by Cyandev on 11/22/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation
import Observation
import RemoEngine

/// One line in the event log.
struct LogEntry: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        /// Server and client lifecycle.
        case event
        /// Errors that ended the server or a session.
        case error
        /// Notable session events such as recovery.
        case info
        /// `--wire-stats` lines.
        case wire
        /// `--trace-heartbeats` lines.
        case trace

        var id: Self { self }
    }

    let id: Int
    let time: Date
    let kind: Kind
    let peer: String?
    let message: String
}

/// Runs a `RemoteScreenServer` with the app's settings and collects what it reports.
@MainActor
@Observable
final class ServerController {
    enum State: Equatable {
        case stopped
        case starting
        case listening(port: UInt16)
        case stopping
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .starting, .listening, .stopping: true
            case .stopped, .failed: false
            }
        }
    }

    static let logLimit = 5000

    var settings: ServerSettings {
        didSet { settings.save() }
    }
    private(set) var state = State.stopped
    /// The settings the running server was started with.
    private(set) var activeSettings: ServerSettings?
    /// The capture size of the main display, while streaming it.
    private(set) var screenSize: (width: Int, height: Int)?
    /// Every client of the current or last run, newest first.
    private(set) var clients: [ClientMonitor] = []
    private(set) var log: [LogEntry] = []
    private(set) var startedAt: Date?

    private var server: RemoteScreenServer?
    private var runTask: Task<Void, Never>?
    private var nextLogID = 0

    init() {
        settings = ServerSettings.load()
    }

    /// Whether the edited settings differ from those the running server uses.
    var needsRestart: Bool {
        guard let activeSettings, state.isRunning else { return false }
        return activeSettings != settings.effective
    }

    var activeClients: [ClientMonitor] { clients.filter(\.status.isActive) }

    func start() {
        guard !state.isRunning, settings.problems.isEmpty else { return }
        let settings = settings.effective
        state = .starting
        activeSettings = settings
        screenSize = nil
        clients.removeAll()
        append(.event, nil, "Starting: \(settings.commandLine)")
        runTask = Task { await run(settings) }
    }

    func stop() {
        guard state.isRunning else { return }
        state = .stopping
        server?.stop()
        runTask?.cancel()
    }

    /// Stops the server if it is running and starts it again with the edited settings.
    func restart() {
        Task {
            if state.isRunning {
                stop()
                await runTask?.value
            }
            start()
        }
    }

    func clearDisconnectedClients() {
        clients.removeAll { !$0.status.isActive }
    }

    func clearLog() {
        log.removeAll()
    }

    // MARK: - Running

    private func run(_ settings: ServerSettings) async {
        let (lines, continuation) = AsyncStream<Diagnostic>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.logLimit))
        let relay = Task { [weak self] in
            for await line in lines { self?.receive(line) }
        }
        defer {
            continuation.finish()
            relay.cancel()
        }
        let diagnostics = Diagnostics(
            handler: { continuation.yield($0) }, wireStatistics: settings.wireStatistics,
            traceHeartbeats: settings.traceHeartbeats,
            audioTraceDirectory: settings.audioTraceDirectory.flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
            })
        let source: RemoteScreenServer.Source
        let resolution = settings.limitsResolution ? (width: settings.width, height: settings.height) : nil
        switch settings.source {
        case .screen:
            source = .mainDisplay(
                maximumWidth: resolution?.width ?? ServerSettings.screenDefaultEdge,
                maximumHeight: resolution?.height ?? ServerSettings.screenDefaultEdge,
                capturesAudio: settings.capturesAudio)
        case .testPattern:
            let size = resolution ?? ServerSettings.testPatternDefault
            let fps = Int32(settings.framesPerSecond)
            do {
                _ = try TestPatternSource(width: size.width, height: size.height, framesPerSecond: fps)
            } catch {
                finish(failure: "\(error)")
                return
            }
            append(.event, nil, "Test pattern source: \(size.width) × \(size.height)")
            source = .custom { try TestPatternSource(width: size.width, height: size.height, framesPerSecond: fps) }
        }
        let configuration = RemoteScreenServer.Configuration(
            source: source, framesPerSecond: Int32(settings.framesPerSecond),
            maximumVideoBitRate: settings.maximumVideoBitRate,
            allowsPointerControl: settings.allowsPointerControl, diagnostics: diagnostics)

        let server: RemoteScreenServer
        do {
            server = try await RemoteScreenServer(configuration: configuration) { [weak self] event in
                self?.handle(event)
            }
        } catch {
            finish(failure: "\(error)")
            return
        }
        if Task.isCancelled {
            server.stop()
            finish(failure: nil)
            return
        }
        self.server = server
        if let size = server.screenSize {
            screenSize = size
            append(
                .event, nil,
                "Screen source: main display, \(size.width) × \(size.height) at up to \(settings.framesPerSecond) fps")
        }
        do {
            try await server.listen(on: UInt16(settings.port))
            finish(failure: nil)
        } catch {
            finish(failure: "Listener failed: \(error)")
        }
    }

    private func finish(failure: String?) {
        server = nil
        runTask = nil
        startedAt = nil
        activeSettings = nil
        for client in clients where client.status.isActive {
            client.disconnect(reason: "server stopped", failed: false)
        }
        if let failure {
            state = .failed(failure)
            append(.error, nil, failure)
        } else {
            state = .stopped
            append(.event, nil, "Server stopped")
        }
    }

    private func handle(_ event: RemoteScreenServer.Event) {
        switch event {
        case .listening(let port):
            state = .listening(port: port)
            startedAt = .now
            append(.event, nil, "Listening on UDP port \(port)")
        case .clientConnected(let peer):
            clients.insert(ClientMonitor(peer: peer), at: 0)
            append(.event, peer, "client connected")
        case .streamingStarted(let peer):
            client(peer)?.startStreaming()
            append(.event, peer, "streaming started")
        case .clientDisconnected(let peer, let reason, let failed):
            client(peer)?.disconnect(reason: reason, failed: failed)
            append(failed ? .error : .event, peer, reason)
        case .statistics(let peer, let statistics):
            client(peer)?.record(statistics)
        }
    }

    private func receive(_ diagnostic: Diagnostic) {
        let kind: LogEntry.Kind
        switch diagnostic.kind {
        case .info: kind = .info
        case .trace: kind = .trace
        case .wire:
            kind = .wire
            if let peer = diagnostic.peer { client(peer)?.recordWire(diagnostic.message) }
        }
        append(kind, diagnostic.peer, diagnostic.message)
    }

    /// The newest active session for a peer.
    private func client(_ peer: String) -> ClientMonitor? {
        clients.first { $0.peer == peer && $0.status.isActive } ?? clients.first { $0.peer == peer }
    }

    private func append(_ kind: LogEntry.Kind, _ peer: String?, _ message: String) {
        log.append(LogEntry(id: nextLogID, time: .now, kind: kind, peer: peer, message: message))
        nextLogID += 1
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }
}
