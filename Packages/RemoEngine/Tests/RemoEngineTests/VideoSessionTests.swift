import CoreMedia
import CoreVideo
import Foundation
import RemoCodec
import RemoTransport
import Testing

@testable import RemoEngine

@Test func malformedVideoMessages() {
    for data in [Data(), Data([0x40]), Data([0x40, 0xff]), Data(repeating: 0x40, count: 42)] {
        #expect(throws: (any Error).self) { try VideoFrameMessage(data) }
    }
}

@Test(arguments: [false, true]) @MainActor
func lostBootstrapAndRefreshFrames(loseAllLTR: Bool) async throws {
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
    var reliableIDR = false
    var recovered = false
    var confirmed = false
    var lastID: UInt64 = 0
    var submittedPTS = CMTime.invalid
    var expectedPTS: [UInt64: CMTime] = [:]
    var framesAfterRecovery = 0
    sender = VideoSession(
        encoder: encoder,
        send: { data, mode in
            if case .reliable = mode {
                receiver.receive(.reliable, data)
                return
            }
            let frame = try VideoFrameMessage(data)
            expectedPTS[frame.id] = submittedPTS
            if !lostInitial && frame.kind == .idr {
                lostInitial = true
                return
            }
            if bootstrapped && confirmed && !lostDelta && frame.kind == .predicted {
                lostDelta = true
                return
            }
            if lostDelta && (loseAllLTR || !lostRefresh) && frame.kind == .ltrRefresh {
                lostRefresh = true
                return
            }
            receiver.receive(.unreliable, data)
        }, onFrame: { _, _, _ in Issue.record("Unexpected reverse video") },
        onEvent: {
            if case .acknowledged = $0 { confirmed = true }
            if case .reliableKeyFrame(let id, _) = $0 {
                expectedPTS[id] = submittedPTS
                reliableIDR = true
            }
        }, onFailure: { Issue.record("Sender failed: \($0)") })
    receiver = VideoSession(
        send: { data, mode in
            if data.first == MessageKind.videoAcknowledgement.rawValue {
                guard case .unreliable(let retries, _, _) = mode else { throw WireFormatError.invalid }
                #expect(retries == 0)
                sender.receive(.unreliable, data)
            } else {
                guard case .reliable = mode else { throw WireFormatError.invalid }
                sender.receive(.reliable, data)
            }
        },
        onFrame: { id, frame, _ in
            #expect(id > lastID)
            lastID = id
            #expect(frame.presentationTime == expectedPTS[id])
            if recovered { framesAfterRecovery += 1 }
        },
        onEvent: {
            if case .decodedRefresh(_, let idr) = $0 {
                if !bootstrapped { bootstrapped = idr } else { recovered = (idr == loseAllLTR) }
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
        submittedPTS = CMTime(value: Int64(index), timescale: 30)
        _ = try await sender.sendFrame(
            pixels, presentationTime: submittedPTS,
            duration: CMTime(value: 1, timescale: 30))
        try await Task.sleep(nanoseconds: 5_000_000)
        if framesAfterRecovery >= 3 { break }
    }
    #expect(lostInitial && bootstrapped && confirmed)
    #expect(lostDelta && lostRefresh && recovered)
    #expect(reliableIDR == loseAllLTR)
    #expect(framesAfterRecovery >= 3)
}

@Test @MainActor func ltrAcknowledgementsAdvanceOnlyWithinTheCurrentEpoch() async throws {
    let encoder = try VideoEncoder(
        width: 320, height: 180, framesPerSecond: 30, bitRate: 300_000, enableLongTermReferences: true)
    var frames: [VideoFrameMessage] = []
    var accepted: [UInt64] = []
    let session = VideoSession(
        encoder: encoder, send: { data, _ in frames.append(try VideoFrameMessage(data)) },
        onFrame: { _, _, _ in },
        onEvent: { if case .acknowledged(let frame, _) = $0 { accepted.append(frame) } },
        onFailure: { Issue.record("Unexpected failure: \($0)") })
    defer { session.close() }
    var buffer: CVPixelBuffer?
    try #require(CVPixelBufferCreate(
        nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    func encode(_ index: Int64) async throws {
        _ = try await session.sendFrame(
            pixels, presentationTime: CMTime(value: index, timescale: 30),
            duration: CMTime(value: 1, timescale: 30))
    }
    func acknowledge(epoch: UInt64, frame: UInt64) {
        var message = MessageKind.videoAcknowledgement.encoded
        message.put(epoch)
        message.put(frame)
        message.put(Int64(frame))
        session.receive(.unreliable, message)
    }
    try await encode(0)
    try await encode(1)
    let epoch = frames[0].epoch
    try #require(frames[1].epoch == epoch)
    acknowledge(epoch: epoch, frame: frames[1].id)
    acknowledge(epoch: epoch, frame: frames[0].id)
    acknowledge(epoch: epoch, frame: frames[1].id)
    session.requestKeyFrame()
    try await encode(2)
    let newEpoch = frames[2].epoch
    try #require(newEpoch > epoch)
    acknowledge(epoch: epoch, frame: frames[2].id)
    acknowledge(epoch: newEpoch, frame: frames[2].id + 1)
    #expect(accepted == [frames[1].id])
    acknowledge(epoch: newEpoch, frame: frames[2].id)
    #expect(accepted == [frames[1].id, frames[2].id])
}

@Test func recoveryChunksRespectCreditAndRetryBackpressure() throws {
    let data = Data((0..<16_385).map { UInt8(truncatingIfNeeded: $0) })
    let sender = try KeyFrameSender(id: 37, bytes: data)
    var receiver = KeyFrameReceiver(id: 37, total: data.count)
    var paused = true
    var confirmed = 0
    var firstPass = true
    while confirmed < data.count {
        try sender.pump { chunk, mode in
            guard case .reliable = mode else { throw WireFormatError.invalid }
            guard chunk.count <= 55 else { throw NetworkMessageSession.SendError.invalidLength }
            if paused {
                paused = false
                throw NetworkMessageSession.SendError.backpressure
            }
            var body = chunk
            try #require(try body.take(UInt8.self) == MessageKind.keyFrameChunk.rawValue)
            try #require(try body.take(UInt64.self) == receiver.id)
            try #require(try body.take(UInt32.self) == UInt32(data.count))
            let offset = try body.take(UInt32.self)
            try receiver.append(body, offset: Int(offset))
        }
        let submitted = receiver.bytes.count
        if firstPass {
            try #require(submitted == 0 && !paused)
            firstPass = false
            continue
        }
        try #require(submitted > confirmed && submitted <= confirmed + 4096)
        #expect(try sender.advance(to: submitted) == (submitted == data.count))
        confirmed = submitted
    }
    #expect(receiver.bytes == data)
}

@Test func stalledVideoCanRequestRecoveryBeforeTheFirstDecodedFrame() throws {
    var requests: [Data] = []
    let session = VideoSession(
        send: { data, mode in
            guard case .reliable = mode else { throw WireFormatError.invalid }
            requests.append(data)
        }, onFrame: { _, _, _ in }, onFailure: { Issue.record("Unexpected failure: \($0)") })
    try session.requestRefresh()
    try session.requestRefresh()
    var expected = MessageKind.videoRefresh.encoded
    expected.put(UInt64(0))
    expected.put(UInt8(0))
    #expect(requests == [expected])
}

@Test @MainActor func higherBitRateRefreshesAnUnchangedPicture() async throws {
    let encoder = try VideoEncoder(width: 320, height: 180, framesPerSecond: 30, bitRate: 300_000)
    var latest: VideoFrameMessage?
    let session = VideoSession(
        encoder: encoder, send: { data, _ in latest = try VideoFrameMessage(data) },
        onFrame: { _, _, _ in }, onFailure: { Issue.record("Unexpected failure: \($0)") })
    defer { session.close() }
    var buffer: CVPixelBuffer?
    try #require(
        CVPixelBufferCreate(
            nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
            == kCVReturnSuccess)
    let pixels = try #require(buffer)
    try #require(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
    let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
    var seed: UInt32 = 1
    for y in 0..<180 {
        for x in 0..<320 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            base[y * CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) + x] = 48 + UInt8(seed >> 25)
        }
    }
    memset(
        CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!, 128,
        CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * 90)
    CVPixelBufferUnlockBaseAddress(pixels, [])
    func encode(_ index: Int64) async throws -> VideoFrameMessage {
        _ = try await session.sendFrame(
            pixels, presentationTime: CMTime(value: index, timescale: 30),
            duration: CMTime(value: 1, timescale: 30))
        return try #require(latest)
    }
    let first = try await encode(0)
    #expect(first.kind == .idr)
    try encoder.setBitRate(2_000_000)
    session.requestKeyFrame()
    let refined = try await encode(30)
    #expect(refined.kind == .idr && refined.epoch > first.epoch)
    func lumaError(_ packet: VideoFrameMessage) async throws -> Int {
        let format = try #require(packet.format)
        let decoder = try VideoDecoder(format: format)
        let frame = try await decoder.decode(packet.sample(format: format))
        #expect(frame.presentationTime == packet.pts)
        try #require(CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        try #require(CVPixelBufferLockBaseAddress(frame.pixels, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(frame.pixels, .readOnly) }
        let source = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(
            to: UInt8.self)
        let decoded = CVPixelBufferGetBaseAddressOfPlane(frame.pixels, 0)!.assumingMemoryBound(
            to: UInt8.self)
        var error = 0
        for y in 0..<180 {
            let a = source.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(pixels, 0))
            let b = decoded.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(frame.pixels, 0))
            for x in 0..<320 { error += abs(Int(a[x]) - Int(b[x])) }
        }
        return error
    }
    let lowError = try await lumaError(first)
    let highError = try await lumaError(refined)
    #expect(highError < lowError)
}
