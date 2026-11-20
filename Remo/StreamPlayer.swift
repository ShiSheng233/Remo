//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation
import Network
import Observation
import RemoCodec
import RemoEngine
import RemoTransport

@MainActor
@Observable
final class StreamPlayer {
    enum Phase: Equatable {
        case idle, connecting, waitingForVideo, streaming, failed(String)
    }

    private(set) var surface: VideoSurface?
    private(set) var phase = Phase.idle

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var transport: NetworkMessageSession?
    @ObservationIgnored private var video: VideoSession?
    @ObservationIgnored private var failure: String?
    @ObservationIgnored private var lastSeen: TimeInterval = 0
    @ObservationIgnored private var lastFrame: TimeInterval = 0
    @ObservationIgnored private var receivedControl = false

    func connect(to endpoint: NWEndpoint) {
        guard task == nil else { return }
        surface = VideoSurface()
        phase = .connecting
        task = Task { await run(endpoint) }
    }

    func disconnect() {
        task?.cancel()
    }

    private func run(_ endpoint: NWEndpoint) async {
        let setupTimeout = Task { [weak self] in
            try await Task.sleep(for: .seconds(8))
            self?.fail("Couldn’t open a connection to the server.")
        }
        defer {
            setupTimeout.cancel()
            video?.close()
            video = nil
            let session = transport
            transport = nil
            if let session {
                try? session.send(Data([SessionMessage.goodbye.rawValue]), mode: .reliable)
                session.cancel()
            }
            surface = nil
            phase = failure.map(Phase.failed) ?? .idle
            failure = nil
            receivedControl = false
            task = nil
        }

        do {
            let session = try await NetworkMessageSession(
                connection: NWConnection(to: endpoint, using: .udp),
                dataHandler: { [weak self] in self?.receive($0, $1) },
                closeHandler: { [weak self] reason in
                    guard let self, transport != nil else { return }
                    if case .network(let error) = reason {
                        fail(error.localizedDescription)
                    } else {
                        fail("The connection to the server closed.")
                    }
                })
            transport = session
            setupTimeout.cancel()
            try Task.checkCancellation()

            video = VideoSession(
                send: { [weak self] data, mode in
                    guard let session = self?.transport else {
                        throw NetworkMessageSession.SendError.closed
                    }
                    try session.send(data, mode: mode)
                },
                onFrame: { [weak self] _, frame, _ in self?.present(frame) },
                onFailure: { [weak self] error in
                    self?.fail("Video decoding failed. \(error.localizedDescription)")
                })
            // A screen client can receive either the desktop or the server’s test pattern.
            try session.send(Data([SessionMessage.screenHello.rawValue]), mode: .reliable)
            phase = .waitingForVideo
            try await keepAlive(session)
        } catch is CancellationError {
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func keepAlive(_ session: NetworkMessageSession) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        lastSeen = started
        lastFrame = started
        while !Task.isCancelled {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastSeen >= 4 {
                fail("The server stopped responding.")
                return
            }
            if phase == .waitingForVideo, now - started >= 15 {
                fail("The server responded but no video arrived.")
                return
            }
            if receivedControl, now - lastFrame >= 2 {
                try video?.requestRefresh()
            }
            do {
                try session.send(
                    Data([SessionMessage.heartbeat.rawValue]), mode: .unreliable(retryBudget: 0))
            } catch NetworkMessageSession.SendError.backpressure {
                // The next heartbeat replaces this one.
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    private func receive(_ channel: MessageTransport.Channel, _ data: Data) {
        guard task?.isCancelled == false, video?.receive(channel, data) != true,
            channel == .reliable, let byte = data.first
        else { return }

        switch SessionMessage(rawValue: byte) {
        case .control where data.count == 9:
            receivedControl = true
            lastSeen = ProcessInfo.processInfo.systemUptime
        case .modeMismatch where data.count == 1:
            fail("The server doesn’t support this video session.")
        default: break
        }
    }

    private func present(_ frame: DecodedVideoFrame) {
        guard task?.isCancelled == false, let surface else { return }
        lastFrame = ProcessInfo.processInfo.systemUptime
        lastSeen = lastFrame
        do {
            if try surface.present(frame), phase == .waitingForVideo { phase = .streaming }
        } catch {
            fail("Video display failed. \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        guard task?.isCancelled == false else { return }
        failure = message
        task?.cancel()
    }
}
