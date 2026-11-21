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
import RemoEngine
import UIKit

@MainActor
@Observable
final class StreamPlayer {
    enum Phase: Equatable {
        case idle, connecting, waitingForVideo, streaming, failed(String)
    }

    private(set) var surface: VideoSurface?
    private(set) var phase = Phase.idle
    /// Pixel size of the remote picture once the first frame arrives.
    private(set) var videoSize: CGSize?
    var mouseAvailable: Bool { mouseDisplaySize != nil }

    private var mouseDisplaySize: CGSize?
    @ObservationIgnored private var client: RemoteScreenClient?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastPixels: CVPixelBuffer?

    /// Starts a session; `onFinalFrame` receives a JPEG of the last frame shown once it ends.
    func connect(
        to endpoint: NWEndpoint, wireGuard: WireGuardConfiguration? = nil,
        onFinalFrame: ((Data) -> Void)? = nil
    ) {
        guard task == nil else { return }
        let surface = VideoSurface()
        self.surface = surface
        phase = .connecting
        let client = RemoteScreenClient(
            onFrame: { [weak self] in try self?.present($0, on: surface) },
            onEvent: { [weak self] in self?.handle($0) })
        self.client = client
        task = Task {
            let failure = await client.run(
                wireGuard.map { .datagrams(WireGuardDatagramConnection($0)) } ?? .udp(endpoint))
            if let pixels = lastPixels, let onFinalFrame {
                Task {
                    if let jpeg = await Self.thumbnail(of: pixels) { onFinalFrame(jpeg) }
                }
            }
            lastPixels = nil
            self.surface = nil
            self.client = nil
            videoSize = nil
            mouseDisplaySize = nil
            phase = failure.map { .failed(Self.message(for: $0, wireGuard: wireGuard != nil)) } ?? .idle
            task = nil
        }
    }

    func disconnect() {
        client?.disconnect()
    }

    private func handle(_ event: RemoteScreenClient.Event) {
        switch event {
        case .state(.connecting): phase = .connecting
        case .state(.waitingForVideo): phase = .waitingForVideo
        case .state(.streaming): phase = .streaming
        case .state(.idle), .statistics: break
        case .pointerAvailable(let size): mouseDisplaySize = size
        }
    }

    func handleTrackpad(_ gesture: TrackpadGesture) {
        guard let client, let displaySize = mouseDisplaySize, let surface, !surface.bounds.isEmpty
        else { return }
        switch gesture {
        case let .move(delta):
            // Finger travel follows the picture, so a zoomed view moves the pointer less.
            let bounds = surface.bounds
            let scale =
                min(bounds.width / displaySize.width, bounds.height / displaySize.height)
                * surface.zoom
            client.movePointer(by: CGVector(dx: delta.x / scale, dy: delta.y / scale))
        case let .button(action):
            client.pressPointer(action)
        case let .scroll(lines):
            client.scroll(lines: lines)
        }
    }

    private func present(_ frame: VideoFrame, on surface: VideoSurface) throws {
        guard try surface.present(frame) else { return }
        lastPixels = frame.pixels
        let size = CGSize(
            width: CVPixelBufferGetWidth(frame.pixels), height: CVPixelBufferGetHeight(frame.pixels))
        if videoSize != size { videoSize = size }
    }

    private static func message(for failure: RemoteScreenClient.Failure, wireGuard: Bool) -> String {
        switch failure {
        case .setupTimedOut:
            wireGuard ? "The WireGuard handshake timed out." : "Couldn’t open a connection to the server."
        case .connectionFailed(let error), .sendFailed(let error): error.localizedDescription
        case .network(let error): error.localizedDescription
        case .connectionClosed: "The connection to the server closed."
        case .serverNotResponding: "The server stopped responding."
        case .noVideo: "The server responded but no video arrived."
        case .videoFailed(let error): "Video decoding failed. \(error.localizedDescription)"
        case .presentationFailed(let error): "Video display failed. \(error.localizedDescription)"
        case .pointerInputFailed(let error): "Mouse input couldn’t be sent. \(error.localizedDescription)"
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
}
