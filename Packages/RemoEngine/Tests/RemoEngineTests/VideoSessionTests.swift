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
func delayedBootstrapAndLostRefreshFrames(loseAllLTR: Bool) async throws {
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
    // A key frame the link is still retransmitting: not yet with the receiver.
    var inFlight: (data: Data, settle: (MessageTransport.Outcome) -> Void)?
    var waits = 0
    var keyFrames = 0
    var lostRecoveryRequest = false
    var delayedInitial = false
    var lostDelta = false
    var lostRefresh = false
    var bootstrapped = false
    var recovered = false
    var confirmed = false
    var lastID: UInt64 = 0
    var submittedPTS = CMTime.invalid
    var expectedPTS: [UInt64: CMTime] = [:]
    var framesAfterRecovery = 0
    sender = VideoSession(
        encoder: encoder,
        send: { data, delivery, onOutcome in
            let frame = try VideoFrameMessage(data)
            expectedPTS[frame.id] = submittedPTS
            #expect(inFlight == nil, "Nothing is sent while a key frame is on its way")
            if frame.kind == .idr {
                #expect(delivery.retryBudget == .infinity)
                let settle = try #require(onOutcome)
                keyFrames += 1
                if !delayedInitial {
                    delayedInitial = true
                    inFlight = (data, settle)
                } else {
                    receiver.receive(data)
                    settle(.delivered)
                }
                return nil
            }
            #expect(delivery.retryBudget < 1 && onOutcome == nil)
            if bootstrapped && confirmed && !lostDelta && frame.kind == .predicted {
                lostDelta = true
                return nil
            }
            if lostDelta && (loseAllLTR || !lostRefresh) && frame.kind == .ltrRefresh {
                lostRefresh = true
                return nil
            }
            receiver.receive(data)
            return nil
        }, onFrame: { _, _, _ in Issue.record("Unexpected reverse video") },
        onEvent: { if case .acknowledged = $0 { confirmed = true } },
        onFailure: { Issue.record("Sender failed: \($0)") })
    receiver = VideoSession(
        send: { data, delivery, _ in
            #expect(delivery.retryBudget == 0 && delivery.replacing != nil)
            if data.first == MessageKind.videoRecoveryRequest.rawValue && !lostRecoveryRequest {
                lostRecoveryRequest = true
                return nil
            }
            sender.receive(data)
            return nil
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
    for index in 1...260 {
        try #require(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
        memset(
            CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!, Int32(48 + index),
            CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * 240)
        memset(
            CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!, 128,
            CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * 120)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        submittedPTS = CMTime(value: Int64(index), timescale: 30)
        let waiting = inFlight != nil
        let bytes = try await sender.sendFrame(
            pixels, presentationTime: submittedPTS,
            duration: CMTime(value: 1, timescale: 30))
        if waiting {
            #expect(bytes == 0)
            waits += 1
            // The stalled receiver asks for video, which must not start a second key frame.
            try receiver.requestRefresh()
            if waits == 5, let held = inFlight {
                inFlight = nil
                receiver.receive(held.data)
                held.settle(.delivered)
            }
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        if framesAfterRecovery >= 3 { break }
    }
    #expect(delayedInitial && waits == 5 && bootstrapped && confirmed)
    #expect(lostRecoveryRequest && lostDelta && lostRefresh && recovered)
    // Losing every LTR refresh ends in one more key frame, which is sent until it arrives.
    #expect(keyFrames == (loseAllLTR ? 2 : 1))
    #expect(framesAfterRecovery >= 3)
}

@Test @MainActor func abandonedKeyFramesAreReplacedAndStaleRequestsIgnored() async throws {
    let encoder = try VideoEncoder(
        width: 320, height: 180, framesPerSecond: 30, bitRate: 300_000, enableLongTermReferences: true)
    var frames: [VideoFrameMessage] = []
    var settle: ((MessageTransport.Outcome) -> Void)?
    let session = VideoSession(
        encoder: encoder,
        send: { data, _, onOutcome in
            frames.append(try VideoFrameMessage(data))
            settle = onOutcome
            return nil
        },
        onFrame: { _, _, _ in }, onFailure: { Issue.record("Unexpected failure: \($0)") })
    defer { session.close() }
    var buffer: CVPixelBuffer?
    try #require(CVPixelBufferCreate(
        nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    var index: Int64 = 0
    func encode() async throws -> Int {
        index += 1
        return try await session.sendFrame(
            pixels, presentationTime: CMTime(value: index, timescale: 30),
            duration: CMTime(value: 1, timescale: 30))
    }
    func request(epoch: UInt64, attempt: UInt64) -> Bool {
        session.receive(
            VideoRecoveryRequest(round: 1, attempt: attempt, epoch: epoch, level: .idr).encoded)
    }
    #expect(try await encode() > 0)
    #expect(try await encode() == 0 && frames.map(\.kind) == [.idr])
    // The link gave up on the key frame, so the next frame has to be one.
    settle?(.expired)
    #expect(try await encode() > 0)
    #expect(frames.map(\.kind) == [.idr, .idr] && frames[1].epoch > frames[0].epoch)
    // A request made before the key frame arrived is answered by the key frame itself.
    #expect(request(epoch: frames[0].epoch, attempt: 1))
    settle?(.delivered)
    #expect(!request(epoch: frames[0].epoch, attempt: 2))
    #expect(try await encode() > 0)
    #expect(frames.map(\.kind) == [.idr, .idr, .predicted])
    // A request about the delivered key frame is a real one.
    #expect(request(epoch: frames[1].epoch, attempt: 3))
    #expect(try await encode() > 0)
    #expect(frames.last?.kind == .idr)
}

@Test @MainActor func ltrAcknowledgementsAdvanceOnlyWithinTheCurrentEpoch() async throws {
    let encoder = try VideoEncoder(
        width: 320, height: 180, framesPerSecond: 30, bitRate: 300_000, enableLongTermReferences: true)
    var frames: [VideoFrameMessage] = []
    var accepted: [UInt64] = []
    let session = VideoSession(
        encoder: encoder,
        send: { data, _, onOutcome in
            frames.append(try VideoFrameMessage(data))
            onOutcome?(.delivered)
            return nil
        },
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
        session.receive(message)
    }
    try await encode(0)
    try await encode(1)
    let epoch = frames[0].epoch
    try #require(frames[1].epoch == epoch)
    acknowledge(epoch: epoch, frame: frames[1].id)
    let staleRecovery = VideoRecoveryRequest(round: frames[1].id, attempt: 7, epoch: epoch, level: .idr)
    #expect(!session.receive(staleRecovery.encoded))
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

@Test func recoveryRequestsRejectStaleRoundsAttemptsAndDowngrades() throws {
    func request(_ round: UInt64, _ attempt: UInt64, _ level: VideoRecoveryRequest.Level) throws -> VideoRecoveryRequest {
        let message = VideoRecoveryRequest(round: round, attempt: attempt, epoch: 1, level: level)
        return try VideoRecoveryRequest(message.encoded)
    }
    let current = try request(10, 3, .idr)
    #expect(try !request(9, 8, .idr).supersedes(current))
    #expect(try !request(10, 2, .idr).supersedes(current))
    #expect(!current.supersedes(current))
    #expect(try !request(10, 4, .ltr).supersedes(current))
    #expect(try request(10, 4, .idr).supersedes(current))
    #expect(try request(11, 1, .ltr).supersedes(current))
}

@Test func stalledVideoCanRequestRecoveryBeforeTheFirstDecodedFrame() throws {
    var requests: [Data] = []
    let session = VideoSession(
        send: { data, delivery, _ in
            guard delivery.retryBudget == 0, delivery.firstSendDeadline != nil else {
                throw WireFormatError.invalid
            }
            requests.append(data)
            return nil
        }, onFrame: { _, _, _ in }, onFailure: { Issue.record("Unexpected failure: \($0)") })
    try session.requestRefresh()
    try session.requestRefresh()
    let expected = VideoRecoveryRequest(round: 1, attempt: 1, epoch: 0, level: .idr)
    #expect(requests == [expected.encoded])
}

@Test @MainActor func higherBitRateRefreshesAnUnchangedPicture() async throws {
    let encoder = try VideoEncoder(width: 320, height: 180, framesPerSecond: 30, bitRate: 300_000)
    var latest: VideoFrameMessage?
    let session = VideoSession(
        encoder: encoder,
        send: { data, _, onOutcome in
            latest = try VideoFrameMessage(data)
            onOutcome?(.delivered)
            return nil
        },
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
