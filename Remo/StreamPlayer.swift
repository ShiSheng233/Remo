//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Network
import Observation
import RemoCodec
import RemoEngine
import RemoTransport
import UIKit

@MainActor
@Observable
final class StreamPlayer {
    enum Phase: Equatable {
        case idle, connecting, waitingForVideo, streaming, failed(String)
    }

    private(set) var surface: VideoSurface?
    private(set) var phase = Phase.idle
    var mouseAvailable: Bool { mouseDisplaySize != nil }

    private var mouseDisplaySize: CGSize?
    @ObservationIgnored private var mousePosition = CGPoint.zero
    @ObservationIgnored private var mouseSequence: UInt64 = 0
    @ObservationIgnored private var mouseButtonSequence: UInt64 = 0
    @ObservationIgnored private var scrollRemainder: CGFloat = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var transport: NetworkMessageSession?
    @ObservationIgnored private var playback: ScreenAudioPlayback?
    @ObservationIgnored private var audioDisabled = false
    @ObservationIgnored private var video: VideoSession?
    @ObservationIgnored private var failure: String?
    @ObservationIgnored private var lastSeen: TimeInterval = 0
    @ObservationIgnored private var lastFrame: TimeInterval = 0
    @ObservationIgnored private var receivedControl = false
    @ObservationIgnored private var lastPixels: CVPixelBuffer?
    @ObservationIgnored private var onFinalFrame: ((Data) -> Void)?

    /// Starts a session; `onFinalFrame` receives a JPEG of the last frame shown once it ends.
    func connect(
        to endpoint: NWEndpoint, wireGuard: WireGuardConfiguration? = nil,
        onFinalFrame: ((Data) -> Void)? = nil
    ) {
        guard task == nil else { return }
        self.onFinalFrame = onFinalFrame
        surface = VideoSurface()
        phase = .connecting
        task = Task { await run(endpoint, wireGuard: wireGuard) }
    }

    func disconnect() {
        task?.cancel()
    }

    private func run(_ endpoint: NWEndpoint, wireGuard: WireGuardConfiguration?) async {
        let setupTimeout = Task { [weak self] in
            try await Task.sleep(for: .seconds(8))
            self?.fail(
                wireGuard == nil
                    ? "Couldn’t open a connection to the server." : "The WireGuard handshake timed out.")
        }
        defer {
            setupTimeout.cancel()
            playback?.stop()
            playback = nil
            audioDisabled = false
            video?.close()
            video = nil
            let session = transport
            transport = nil
            if let session {
                try? session.send(Data([SessionMessage.goodbye.rawValue]), mode: .reliable)
                session.cancel()
            }
            if let pixels = lastPixels, let onFinalFrame {
                Task {
                    if let jpeg = await Self.thumbnail(of: pixels) { onFinalFrame(jpeg) }
                }
            }
            lastPixels = nil
            onFinalFrame = nil
            surface = nil
            phase = failure.map(Phase.failed) ?? .idle
            failure = nil
            receivedControl = false
            mouseDisplaySize = nil
            mouseSequence = 0
            mouseButtonSequence = 0
            scrollRemainder = 0
            task = nil
        }

        do {
            let receive: (MessageTransport.Channel, Data) -> Void = { [weak self] in
                self?.receive($0, $1)
            }
            let close: (NetworkMessageSession.CloseReason) -> Void = { [weak self] reason in
                guard let self, transport != nil else { return }
                if case .network(let error) = reason {
                    fail(error.localizedDescription)
                } else {
                    fail("The connection to the server closed.")
                }
            }
            let session: NetworkMessageSession
            if let wireGuard {
                session = try await NetworkMessageSession(
                    driver: WireGuardDatagramConnection(wireGuard),
                    dataHandler: receive, closeHandler: close)
            } else {
                session = try await NetworkMessageSession(
                    connection: NWConnection(to: endpoint, using: .udp),
                    dataHandler: receive, closeHandler: close)
            }
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
        var nextMouseHello = started
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
                if !mouseAvailable, now >= nextMouseHello {
                    nextMouseHello = now + 1.2
                    try session.send(Data([SessionMessage.mouseHello.rawValue]), mode: .reliable)
                }
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
            let byte = data.first
        else { return }

        if channel == .unreliable, byte == SessionMessage.audio.rawValue, !audioDisabled {
            if playback == nil {
                playback = ScreenAudioPlayback { [weak self] error in
                    self?.audioDisabled = true
                    NSLog("Audio playback failed: %@", error.localizedDescription)
                }
            }
            playback?.receive(data)
            return
        }
        guard channel == .reliable else { return }
        switch SessionMessage(rawValue: byte) {
        case .control where data.count == 9:
            receivedControl = true
            lastSeen = ProcessInfo.processInfo.systemUptime
        case .modeMismatch where data.count == 1:
            fail("The server doesn’t support this video session.")
        case .mouseReady where !mouseAvailable:
            if case let .ready(position, width, height) = try? MouseMessage(decoding: data) {
                mousePosition = position
                mouseDisplaySize = CGSize(width: Int(width), height: Int(height))
            }
        default: break
        }
    }

    func handleTrackpad(_ gesture: TrackpadGesture) {
        guard phase == .streaming, task?.isCancelled == false, let transport,
            let displaySize = mouseDisplaySize, let bounds = surface?.bounds, !bounds.isEmpty
        else { return }

        let message: MouseMessage
        let mode: MessageTransport.Mode
        switch gesture {
        case let .move(delta):
            guard delta != .zero else { return }
            let scale = min(bounds.width / displaySize.width, bounds.height / displaySize.height)
            mousePosition = CGPoint(
                x: min(1, max(0, mousePosition.x + delta.x / (displaySize.width * scale))),
                y: min(1, max(0, mousePosition.y + delta.y / (displaySize.height * scale))))
            mouseSequence += 1
            message = .move(
                sequence: mouseSequence, afterButton: mouseButtonSequence, position: mousePosition)
            let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
            mode = .unreliable(retryBudget: 0, firstSendDeadline: now + 0.05)
        case let .button(action):
            mouseSequence += 1
            mouseButtonSequence = mouseSequence
            message = .button(sequence: mouseSequence, action: action, position: mousePosition)
            mode = .reliable
        case let .scroll(delta):
            scrollRemainder = min(1000, max(-1000, scrollRemainder + delta))
            let wheel = Int32(scrollRemainder.rounded(.towardZero))
            guard wheel != 0 else { return }
            scrollRemainder -= CGFloat(wheel)
            message = .scroll(wheel)
            mode = .reliable
        }
        do {
            try transport.send(message.encoded, mode: mode)
        } catch {
            if case .unreliable = mode { return }
            fail("Mouse input couldn’t be sent. \(error.localizedDescription)")
        }
    }

    private func present(_ frame: DecodedVideoFrame) {
        guard task?.isCancelled == false, let surface else { return }
        lastFrame = ProcessInfo.processInfo.systemUptime
        lastSeen = lastFrame
        do {
            guard try surface.present(frame) else { return }
            lastPixels = frame.pixels
            if phase == .waitingForVideo { phase = .streaming }
        } catch {
            fail("Video display failed. \(error.localizedDescription)")
        }
    }

    @concurrent
    private nonisolated static func thumbnail(of pixels: CVPixelBuffer) async -> Data? {
        let image = CIImage(cvPixelBuffer: pixels)
        let longest = max(image.extent.width, image.extent.height)
        guard longest > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = image
        scale.scale = Float(min(1, 1280 / longest))
        scale.aspectRatio = 1
        guard let output = scale.outputImage else { return nil }
        let options = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8
        ]
        return CIContext().jpegRepresentation(of: output, colorSpace: colorSpace, options: options)
    }

    private func fail(_ message: String) {
        guard task?.isCancelled == false else { return }
        failure = message
        task?.cancel()
    }
}
