import CoreMedia
import CoreVideo
import Foundation
import RemoCodec
import Testing

@testable import RemoEngine

@Test func malformedVideoMessages() {
    for data in [Data(), Data([0x40]), Data([0x40, 0xff]), Data(repeating: 0x40, count: 42)] {
        #expect(throws: (any Error).self) { try VideoPacket(data) }
    }
}

@Test @MainActor func lostBootstrapAndRefreshFrames() async throws {
    let encoder = try VideoEncoder(
        width: 320, height: 240, framesPerSecond: 30,
        bitRate: 1_000_000, enableLongTermReferences: true)
    var buffer: CVPixelBuffer?
    try #require(
        CVPixelBufferCreate(
            nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
            == kCVReturnSuccess)
    let pixels = try #require(buffer)
    var receiver: VideoSession!
    var sender: VideoSession!
    var lostInitial = false
    var lostDelta = false
    var lostRefresh = false
    var bootstrapped = false
    var recovered = false
    var confirmed = false
    var lastID: UInt64 = 0
    sender = VideoSession(
        encoder: encoder,
        send: { data, _ in
            let frame = try VideoPacket(data)
            if !lostInitial && frame.kind == .idr {
                lostInitial = true
                return
            }
            if bootstrapped && confirmed && !lostDelta && frame.kind == .predicted {
                lostDelta = true
                return
            }
            if lostDelta && !lostRefresh && frame.kind == .ltrRefresh {
                lostRefresh = true
                return
            }
            receiver.receive(.unreliable, data)
        }, onFrame: { _, _, _ in Issue.record("Unexpected reverse video") },
        onEvent: {
            if case .acknowledged = $0 { confirmed = true }
        }, onFailure: { Issue.record("Sender failed: \($0)") })
    receiver = VideoSession(
        send: { data, _ in sender.receive(.reliable, data) },
        onFrame: { id, frame, _ in
            #expect(id > lastID)
            lastID = id
            #expect(
                CMTimeCompare(frame.presentationTime, CMTime(value: Int64(id), timescale: 30)) == 0)
        },
        onEvent: {
            if case .decodedRefresh(_, let idr) = $0 {
                if idr { bootstrapped = true } else { recovered = true }
            }
        }, onFailure: { Issue.record("Receiver failed: \($0)") })
    defer {
        sender.close()
        receiver.close()
        sender = nil
        receiver = nil
    }
    for index in 1...90 {
        try #require(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
        memset(
            CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!, Int32(48 + index),
            CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * 240)
        memset(
            CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!, 128,
            CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * 120)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        _ = try await sender.sendFrame(
            pixels, presentationTime: CMTime(value: Int64(index), timescale: 30),
            duration: CMTime(value: 1, timescale: 30))
        try await Task.sleep(nanoseconds: 5_000_000)
        if recovered && lastID == UInt64(index) { break }
    }
    #expect(lostInitial && bootstrapped && confirmed)
    #expect(lostDelta && lostRefresh && recovered)
}
