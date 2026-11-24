//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Network
import RemoTransport
import Testing

@testable import RemoEngine

private func png(width: Int = 8, height: Int = 8, gray: CGFloat = 0.5) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(gray: gray, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func shape(_ id: UInt64) throws -> CursorShape {
    CursorShape(
        id: id, size: CGSize(width: 16, height: 24), hotSpot: CGPoint(x: 4, y: 6),
        png: try png(gray: CGFloat(id % 7) / 7))
}

private let display = CGSize(width: 1600, height: 1000)

@Test func cursorMessagesRoundTripAndRejectInvalidOnes() throws {
    let state = CursorState(
        position: CGPoint(x: 0.25, y: 0.5), visible: true, displaySize: display, shapeID: 7,
        externalMoves: 3)
    let messages: [CursorMessage] = [
        .shape(try shape(7)), .state(sequence: 4, state),
        .state(sequence: 5, CursorState(
            position: .zero, visible: false, displaySize: display, shapeID: nil, externalMoves: 0)),
    ]
    for message in messages {
        #expect(try CursorMessage(decoding: message.encoded) == message)
    }
    #expect(throws: WireFormatError.self) {
        try CursorMessage(decoding: messages[1].encoded.dropLast())
    }
    #expect(throws: WireFormatError.self) {
        try CursorMessage(decoding: messages[1].encoded + Data([0]))
    }
    var offDisplay = state
    offDisplay.position.x = 1.5
    #expect(throws: WireFormatError.self) {
        try CursorMessage(decoding: CursorMessage.state(sequence: 1, offDisplay).encoded)
    }
    let outside = CursorShape(
        id: 1, size: CGSize(width: 16, height: 16), hotSpot: CGPoint(x: 17, y: 0),
        png: try png())
    #expect(throws: WireFormatError.self) {
        try CursorMessage(decoding: CursorMessage.shape(outside).encoded)
    }
    // A shape is needed before any state can show it; only the newest state matters.
    #expect(messages[0].delivery.retryBudget == .infinity)
    #expect(messages[1].delivery.retryBudget == .infinity)
    #expect(messages[1].delivery.replacing != nil && messages[0].delivery.replacing == nil)
}

@Test @MainActor func monitorTellsTheServersMovesFromAnyoneElses() throws {
    var reading = CursorSample(
        position: CGPoint(x: 0.5, y: 0.5), visible: true, displaySize: display,
        shape: try shape(1))
    let monitor = CursorMonitor(interval: .seconds(100)) { reading }
    var published: [CursorState] = []
    var shapes: [UInt64?] = []
    let start = Instant.now
    monitor.poll(now: start)
    let id = monitor.subscribe { state, shape in
        published.append(state)
        shapes.append(shape?.id)
    }
    // A new subscriber hears the current cursor at once.
    #expect(published.map(\.externalMoves) == [0])
    #expect(shapes == [1])

    // The server posts a move; the cursor gets there a little later.
    monitor.notePosted(CGPoint(x: 0.6, y: 0.5), now: start + .milliseconds(10))
    monitor.poll(now: start + .milliseconds(20))
    reading.position = CGPoint(x: 0.6, y: 0.5)
    monitor.poll(now: start + .milliseconds(60))
    monitor.poll(now: start + .milliseconds(200))
    #expect(published.last?.position == CGPoint(x: 0.6, y: 0.5))
    #expect(published.last?.externalMoves == 0)

    // Someone at the Mac moves it.
    reading.position = CGPoint(x: 0.1, y: 0.1)
    monitor.poll(now: start + .milliseconds(220))
    #expect(published.last?.externalMoves == 1)
    // Less than a point is noise.
    reading.position.x += 0.0001
    monitor.poll(now: start + .milliseconds(240))
    #expect(published.last?.externalMoves == 1)

    // A new picture travels with the state; nothing changes, nothing is published until the
    // still cursor is published again.
    reading.shape = try shape(2)
    monitor.poll(now: start + .milliseconds(260))
    #expect(published.last?.shapeID == 2 && shapes.last == 2)
    let count = published.count
    monitor.poll(now: start + .milliseconds(300))
    #expect(published.count == count)
    monitor.poll(now: start + .milliseconds(260) + CursorMonitor.republishInterval)
    #expect(published.count == count + 1)
    monitor.unsubscribe(id)
}

@Test func trackerOrdersStatesAndShowsShapesOnceTheyArrive() throws {
    var tracker = CursorTracker()
    #expect(tracker.cursor(at: nil, forceVisible: false) == nil)
    let first = CursorState(
        position: CGPoint(x: 0.5, y: 0.5), visible: true, displaySize: display, shapeID: 1,
        externalMoves: 0)
    // The first state is adopted; the shape it needs hasn't arrived, so nothing is drawn.
    let r1 = tracker.receive(sequence: 2, first)
    #expect(r1 == first.position)
    #expect(tracker.cursor(at: nil, forceVisible: false)?.visible == false)
    let r2 = tracker.receive(try shape(1))
    #expect(r2)
    let cursor = try #require(tracker.cursor(at: nil, forceVisible: false))
    #expect(cursor.visible && cursor.image != nil)
    #expect(cursor.size == CGSize(width: 0.01, height: 0.024))
    #expect(cursor.hotSpot == CGPoint(x: 0.25, y: 0.25))
    #expect(
        cursor.frame(in: CGRect(x: 0, y: 0, width: 1000, height: 500))
            == CGRect(x: 497.5, y: 247, width: 10, height: 12))

    // An older state changes nothing; a newer one moved by the server alone isn't adopted.
    var moved = first
    moved.position = CGPoint(x: 0.9, y: 0.9)
    let r3 = tracker.receive(sequence: 1, moved)
    #expect(r3 == nil)
    #expect(tracker.state?.position == first.position)
    let r4 = tracker.receive(sequence: 3, moved)
    #expect(r4 == nil)
    #expect(tracker.cursor(at: CGPoint(x: 0.2, y: 0.2), forceVisible: false)?.position
        == CGPoint(x: 0.2, y: 0.2))
    moved.externalMoves = 1
    let r5 = tracker.receive(sequence: 4, moved)
    #expect(r5 == moved.position)

    // A new shape still on its way leaves the old one showing.
    var reshaped = moved
    reshaped.shapeID = 2
    _ = tracker.receive(sequence: 5, reshaped)
    let old = try #require(tracker.cursor(at: nil, forceVisible: false)?.image)
    let r6 = tracker.receive(try shape(2))
    #expect(r6)
    #expect(tracker.cursor(at: nil, forceVisible: false)?.image !== old)
    // Off the display, a cursor shows only where this client is moving it.
    reshaped.visible = false
    _ = tracker.receive(sequence: 6, reshaped)
    #expect(tracker.cursor(at: nil, forceVisible: false)?.visible == false)
    #expect(tracker.cursor(at: nil, forceVisible: true)?.visible == true)
    let garbage = tracker.receive(
        CursorShape(id: 9, size: CGSize(width: 1, height: 1), hotSpot: .zero, png: Data([1, 2, 3])))
    #expect(!garbage)
}

/// One flat gray picture, never changing.
private final class StillSource: ScreenFrameSource {
    let width = 320
    let height = 200

    func latestFrame() throws -> ScreenFrame? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(
            CVPixelBufferGetBaseAddressOfPlane(pixels, 0), 100,
            CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * height)
        memset(
            CVPixelBufferGetBaseAddressOfPlane(pixels, 1), 128,
            CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * height / 2)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return ScreenFrame(pixels: pixels, timestamp: CMTime(value: 1, timescale: 30))
    }

    nonisolated(nonsending) func stop() async throws {}
}

@Test @MainActor func clientDrawsTheServersCursorOverLoopback() async throws {
    var reading = CursorSample(
        position: CGPoint(x: 0.25, y: 0.5), visible: true, displaySize: display,
        shape: try shape(3))
    var port: UInt16?
    let server = try await RemoteScreenServer(
        configuration: .init(source: .custom { _ in StillSource() }), cursor: { reading }
    ) { event in
        if case .listening(let value) = event { port = value }
    }
    let listening = Task { try await server.listen(on: 0) }
    defer { server.stop() }
    while port == nil { try await Task.sleep(for: .milliseconds(10)) }

    var cursors: [RemoteCursor] = []
    var client: RemoteScreenClient!
    client = RemoteScreenClient(
        configuration: .init(requestsRemoteControl: false), onFrame: { _ in },
        onEvent: { event in
            guard case .cursor(let cursor) = event else { return }
            cursors.append(cursor)
            if cursor.visible, cursor.position == CGPoint(x: 0.25, y: 0.5) {
                // The server's own cursor moves.
                reading.position = CGPoint(x: 0.75, y: 0.125)
            }
            if cursor.position == CGPoint(x: 0.75, y: 0.125) { client.disconnect() }
        })
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port!)!)
    let run = Task { await client.run(.udp(endpoint)) }
    let timeout = Task {
        try await Task.sleep(for: .seconds(10))
        client.disconnect()
    }
    let failure = await run.value
    timeout.cancel()
    #expect(failure == nil)
    let last = try #require(cursors.last)
    #expect(last.position == CGPoint(x: 0.75, y: 0.125))
    #expect(last.visible && last.image?.width == 8)
    #expect(last.size == CGSize(width: 0.01, height: 0.024))
    server.stop()
    try await listening.value
}
