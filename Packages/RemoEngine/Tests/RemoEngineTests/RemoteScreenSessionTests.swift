//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreMedia
import CoreVideo
import Foundation
import Network
import RemoTransport
import Testing

@testable import RemoEngine

/// A flat picture whose brightness steps every time it is polled.
private final class SteppingSource: ScreenFrameSource {
    let width = 320
    let height = 180
    private(set) var started = 0
    private var step: Int64 = 0

    let firstFrameAt: SuspendingClock.Instant

    init(delay: Duration = .zero) {
        firstFrameAt = .now + delay
    }

    func latestFrame() throws -> ScreenFrame? {
        guard .now >= firstFrameAt else { return nil }
        step += 1
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(
            CVPixelBufferGetBaseAddressOfPlane(pixels, 0), Int32(16 + step % 200),
            CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * height)
        memset(
            CVPixelBufferGetBaseAddressOfPlane(pixels, 1), 128,
            CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * height / 2)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return ScreenFrame(pixels: pixels, timestamp: CMTime(value: step, timescale: 30))
    }

    nonisolated(nonsending) func stop() async throws {}
}

@Test(arguments: [false, true]) @MainActor
func clientReceivesACustomSourceOverLoopback(delayedVideo: Bool) async throws {
    var sources: [SteppingSource] = []
    var port: UInt16?
    var disconnects: [(reason: String, failed: Bool)] = []
    var serverStatistics: ServerStatistics?
    let server = try await RemoteScreenServer(
        configuration: .init(
            source: .custom {
                let source = SteppingSource(delay: delayedVideo ? .seconds(5) : .zero)
                sources.append(source)
                return source
            })
    ) { event in
        switch event {
        case .listening(let value): port = value
        case .clientDisconnected(_, let reason, let failed): disconnects.append((reason, failed))
        case .statistics(_, let statistics): serverStatistics = statistics
        default: break
        }
    }
    let listening = Task { try await server.listen(on: 0) }
    defer { server.stop() }
    while port == nil { try await Task.sleep(nanoseconds: 10_000_000) }

    var states: [RemoteScreenClient.State] = []
    var clientStatistics: ClientStatistics?
    var frames = 0
    var client: RemoteScreenClient!
    let (recoveries, recoveryEvents) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    client = RemoteScreenClient(
        configuration: .init(requestsPointerControl: false, diagnostics: .init { event in
            if event.message.hasPrefix("recovery requested lastDecoded=0 ") { recoveryEvents.yield(()) }
        }),
        onFrame: { frame in
            #expect(CVPixelBufferGetWidth(frame.pixels) == 320)
            frames += 1
            if frames == 45 { client.disconnect() }
        },
        onEvent: { event in
            switch event {
            case .state(let state): states.append(state)
            case .statistics(let statistics): clientStatistics = statistics
            default: break
            }
        })
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port!)!)
    let failure = await client.run(.udp(endpoint))

    recoveryEvents.finish()
    if delayedVideo {
        var iterator = recoveries.makeAsyncIterator()
        let requestedFirstFrame = await iterator.next() != nil
        #expect(requestedFirstFrame)
        #expect(clientStatistics.map { $0.controlsReceived > 0 } == true)
    } else {
        #expect(serverStatistics?.controlsSent == 0)
    }
    #expect(failure == nil)
    #expect(states == [.connecting, .waitingForVideo, .streaming, .idle])
    #expect(frames == 45)
    // One source for the one client, started when it asked for video.
    #expect(sources.count == 1)
    #expect(clientStatistics.map { $0.framesDecoded > 0 } == true)
    #expect(serverStatistics.map { $0.framesQueued > 0 && $0.heartbeatsReceived > 0 } == true)
    // The goodbye ends the server's side cleanly.
    for _ in 0..<100 where disconnects.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(disconnects.map(\.reason) == ["client left"])
    #expect(disconnects.first?.failed == false)

    server.stop()
    try await listening.value
}

@Test @MainActor func deliveryAcksAloneKeepClientAliveUntilSilent() async throws {
    var port: UInt16?
    var reason: String?
    let server = try await RemoteScreenServer(
        configuration: .init(source: .custom { SteppingSource(delay: .seconds(30)) })
    ) { event in
        switch event {
        case .listening(let value): port = value
        case .clientDisconnected(_, let value, _): reason = value
        default: break
        }
    }
    let listening = Task { try await server.listen(on: 0) }
    defer { server.stop() }
    while port == nil { try await Task.sleep(for: .milliseconds(10)) }

    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port!)!)
    var controls = 0
    let client = try await NetworkMessageSession(connection: NWConnection(to: endpoint, using: .udp)) {
        _, data in
        if (try? ControlMessage(decoding: data)) != nil { controls += 1 }
    } closeHandler: { _ in }
    try client.send(MessageKind.screenHello.encoded, mode: .reliable)
    try await Task.sleep(for: .seconds(5))
    #expect(reason == nil)
    #expect(controls >= 4)
    client.cancel()
    try await Task.sleep(for: .seconds(2))
    #expect(reason == nil)
    for _ in 0..<40 where reason == nil { try await Task.sleep(for: .milliseconds(100)) }
    #expect(reason == "client timed out")
    server.stop()
    try await listening.value
}

@Test @MainActor func serverRejectsInvalidConfigurations() async {
    for configuration: RemoteScreenServer.Configuration in [
        .init(source: .mainDisplay(maximumWidth: 321)),
        .init(framesPerSecond: 0),
        .init(maximumVideoBitRate: 0),
        .init(source: .custom { SteppingSource() }, allowsPointerControl: true),
    ] {
        await #expect(throws: RemoteScreenServer.SetupError.self) {
            _ = try await RemoteScreenServer(configuration: configuration)
        }
    }
}
