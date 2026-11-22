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

private func makePixels(_ width: Int, _ height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    try #require(
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
            == kCVReturnSuccess)
    return try #require(buffer)
}

private func fill(_ pixels: CVPixelBuffer, luma: Int) {
    CVPixelBufferLockBaseAddress(pixels, [])
    memset(
        CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!, Int32(48 + luma % 160),
        CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * CVPixelBufferGetHeight(pixels))
    memset(
        CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!, 128,
        CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * CVPixelBufferGetHeight(pixels) / 2)
    CVPixelBufferUnlockBaseAddress(pixels, [])
}

/// How the receiver's side of a loss is repaired.
enum LossScenario: CaseIterable {
    /// The link reports each loss, and no request from the receiver gets through.
    case reported
    /// A frame the link took for delivered is missing at the receiver, which has to ask. Its
    /// first request is lost, and so is the first refresh, which the link does report.
    case requested
    /// Refreshes vanish without a word: only frames that keep arriving unusable give it away.
    case silent
}

@Test(arguments: LossScenario.allCases) @MainActor
func delayedBootstrapAndLostFrames(scenario: LossScenario) async throws {
    let encoder = try VideoEncoder(
        width: 320, height: 240, framesPerSecond: 30,
        bitRate: 1_000_000, enableLongTermReferences: true)
    let pixels = try makePixels(320, 240)
    var receiver: VideoSession!
    var sender: VideoSession!
    // A key frame the link is still retransmitting: not yet with the receiver.
    var inFlight: (data: Data, settle: (MessageTransport.Outcome) -> Void)?
    var waits = 0
    var keyFrames = 0
    var requests = 0
    var delayedInitial = false
    var lostDelta = false
    var lostRefreshes = 0
    var bootstrapped = false
    var recovered: Bool?
    var confirmed = false
    var lastID: UInt64 = 0
    var submittedPTS = CMTime.invalid
    var expectedPTS: [UInt64: CMTime] = [:]
    var framesAfterRecovery = 0
    sender = VideoSession(
        encoder: encoder,
        send: { data, delivery, onOutcome in
            let frame = try VideoFrameMessage(data)
            let settle = try #require(onOutcome)
            expectedPTS[frame.id] = submittedPTS
            #expect(inFlight == nil, "Nothing is sent while a key frame is on its way")
            if frame.kind == .idr {
                #expect(delivery.retryBudget == .infinity)
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
            #expect(delivery.retryBudget < 1)
            var lost = false
            if bootstrapped && confirmed && !lostDelta && frame.kind == .predicted {
                lostDelta = true
                lost = true
            } else if lostDelta, frame.kind == .ltrRefresh, scenario == .silent || lostRefreshes == 0 {
                lostRefreshes += 1
                lost = true
            }
            if !lost {
                receiver.receive(data)
                settle(.delivered)
            } else if scenario == .reported || (scenario == .requested && frame.kind == .ltrRefresh) {
                settle(.expired)
            }
            return nil
        }, onFrame: { _, _, _ in Issue.record("Unexpected reverse video") },
        onEvent: { if case .acknowledged = $0 { confirmed = true } },
        onFailure: { Issue.record("Sender failed: \($0)") })
    receiver = VideoSession(
        send: { data, delivery, _ in
            #expect(delivery.retryBudget < 1 && delivery.replacing != nil)
            if data.first == MessageKind.videoRecoveryRequest.rawValue {
                requests += 1
                if scenario == .reported || requests == 1 { return nil }
            }
            sender.receive(data)
            return nil
        },
        onFrame: { id, frame, _ in
            #expect(id > lastID)
            lastID = id
            #expect(frame.presentationTime == expectedPTS[id])
            if recovered != nil { framesAfterRecovery += 1 }
        },
        onEvent: {
            if case .decodedRefresh(_, let idr) = $0 {
                if !bootstrapped { bootstrapped = idr } else { recovered = idr }
            }
        }, onFailure: { Issue.record("Receiver failed: \($0)") })
    defer {
        sender.close()
        receiver.close()
        sender = nil
        receiver = nil
    }
    for index in 1...900 {
        fill(pixels, luma: index)
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
    #expect(lostDelta && lostRefreshes > 0 && framesAfterRecovery >= 3)
    // A lost frame is repaired from the last reference the receiver confirmed. Only a
    // refresh that can't be made to work ends in a key frame, sent until it arrives.
    #expect(recovered == (scenario == .silent))
    #expect(keyFrames == (scenario == .silent ? 2 : 1))
}

@Test @MainActor func refreshThatDidNotHelpEscalatesToAKeyFrame() async throws {
    let encoder = try VideoEncoder(
        width: 320, height: 180, framesPerSecond: 30, bitRate: 300_000, enableLongTermReferences: true)
    var frames: [VideoFrameMessage] = []
    var settle: ((MessageTransport.Outcome) -> Void)?
    let session = VideoSession(
        encoder: encoder,
        send: { data, _, onOutcome in
            let frame = try VideoFrameMessage(data)
            frames.append(frame)
            if frame.kind == .idr { onOutcome?(.delivered) } else { settle = onOutcome }
            return nil
        },
        onFrame: { _, _, _ in }, onFailure: { Issue.record("Unexpected failure: \($0)") })
    defer { session.close() }
    let pixels = try makePixels(320, 180)
    var index: Int64 = 0
    func encode() async throws -> VideoFrameMessage {
        index += 1
        fill(pixels, luma: Int(index))
        _ = try await session.sendFrame(
            pixels, presentationTime: CMTime(value: index, timescale: 30),
            duration: CMTime(value: 1, timescale: 30))
        return try #require(frames.last)
    }
    var attempt: UInt64 = 0
    func ask(after round: UInt64, seen refreshSeen: UInt64) -> Bool {
        attempt += 1
        return session.receive(
            VideoRecoveryRequest(
                round: round, attempt: attempt, epoch: frames[0].epoch, level: .ltr,
                refreshSeen: refreshSeen
            ).encoded)
    }
    // Run until the peer has confirmed a long-term reference.
    var reference: VideoFrameMessage?
    while reference == nil {
        let frame = try await encode()
        if frame.token != nil { reference = frame }
        try #require(index < 120)
    }
    var acknowledgement = MessageKind.videoAcknowledgement.encoded
    acknowledgement.put(try #require(reference).epoch)
    acknowledgement.put(try #require(reference).id)
    acknowledgement.put(try #require(reference?.token).rawValue)
    #expect(session.receive(acknowledgement))

    // The link gives up on a frame: the next one refreshes from the reference, unasked.
    #expect(try await encode().kind == .predicted)
    settle?(.expired)
    let first = try await encode()
    #expect(first.kind == .ltrRefresh)
    // The peer asked before that refresh reached it. The refresh is the answer.
    #expect(ask(after: first.id, seen: frames[0].id))
    #expect(try await encode().kind == .predicted)
    // A frame the link reported delivered was lost on the peer: it asks, and gets a refresh.
    let later = try #require(frames.last)
    #expect(ask(after: later.id, seen: first.id))
    let second = try await encode()
    #expect(second.kind == .ltrRefresh)
    // It had that refresh in hand and still could not decode. Only a key frame is left.
    #expect(ask(after: second.id, seen: second.id))
    let last = try await encode()
    #expect(last.kind == .idr && last.epoch > frames[0].epoch)
}

@Test @MainActor func framesWaitBrieflyForOneThatIsLate() async throws {
    let encoder = try VideoEncoder(width: 320, height: 180, framesPerSecond: 30, bitRate: 300_000)
    var encoded: [Data] = []
    let sender = VideoSession(
        encoder: encoder,
        send: { data, _, onOutcome in
            encoded.append(data)
            onOutcome?(.delivered)
            return nil
        },
        onFrame: { _, _, _ in }, onFailure: { Issue.record("Sender failed: \($0)") })
    let pixels = try makePixels(320, 180)
    for index in 1...9 {
        fill(pixels, luma: index)
        _ = try await sender.sendFrame(
            pixels, presentationTime: CMTime(value: Int64(index), timescale: 30),
            duration: CMTime(value: 1, timescale: 30))
    }
    sender.close()
    try #require(encoded.count == 9)

    var decoded: [UInt64] = []
    var requests: [VideoRecoveryRequest] = []
    var patience = Duration.seconds(10)
    let receiver = VideoSession(
        send: { data, _, _ in
            if data.first == MessageKind.videoRecoveryRequest.rawValue {
                requests.append(try VideoRecoveryRequest(data))
            }
            return nil
        },
        patience: { patience },
        onFrame: { id, _, _ in decoded.append(id) },
        onFailure: { Issue.record("Receiver failed: \($0)") })
    defer { receiver.close() }
    func deliver(_ ids: Int...) { for id in ids { receiver.receive(encoded[id - 1]) } }
    func settled(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
    // Frame 3 arrives after 4 and 5: a retransmission. Everything is decoded, in order.
    deliver(1, 2, 4, 5)
    #expect(try await settled { decoded.count >= 2 })
    try await Task.sleep(for: .milliseconds(50))
    #expect(decoded == [1, 2])
    deliver(3)
    #expect(try await settled { decoded.count >= 5 })
    #expect(decoded == [1, 2, 3, 4, 5] && requests.isEmpty)
    // Frame 7 does not arrive in time. After the wait, the receiver asks for a refresh.
    patience = .milliseconds(100)
    deliver(6, 8, 9)
    #expect(try await settled { !requests.isEmpty })
    #expect(decoded.last == 6 && requests.first?.round == 7)
    // It turns up after all, and the frames that waited behind it are still good.
    deliver(7)
    #expect(try await settled { decoded.count >= 9 })
    #expect(decoded == Array(1...9) && requests.count == 1)
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
            VideoRecoveryRequest(
            round: 1, attempt: attempt, epoch: epoch, level: .idr, refreshSeen: 0
        ).encoded)
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
    let staleRecovery = VideoRecoveryRequest(
        round: frames[1].id, attempt: 7, epoch: epoch, level: .idr, refreshSeen: 0)
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
        let message = VideoRecoveryRequest(
            round: round, attempt: attempt, epoch: 1, level: level, refreshSeen: round + 3)
        let decoded = try VideoRecoveryRequest(message.encoded)
        #expect(decoded.refreshSeen == round + 3 && decoded.encoded == message.encoded)
        return decoded
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
    let expected = VideoRecoveryRequest(
        round: 1, attempt: 1, epoch: 0, level: .idr, refreshSeen: 0)
    #expect(requests == [expected.encoded])
}

@Test @MainActor func stillPictureIsSharpenedByPredictedFrames() async throws {
    let encoder = try VideoEncoder(
        width: 640, height: 360, framesPerSecond: 30, bitRate: 2_000_000,
        enableLongTermReferences: true)
    try #require(encoder.supportsQuantizerLimit)
    var frames: [VideoFrameMessage] = []
    let session = VideoSession(
        encoder: encoder,
        send: { data, _, onOutcome in
            frames.append(try VideoFrameMessage(data))
            onOutcome?(.delivered)
            return nil
        },
        onFrame: { _, _, _ in }, onFailure: { Issue.record("Unexpected failure: \($0)") })
    defer { session.close() }
    // Fine detail everywhere, as on a desktop full of text.
    let pixels = try makePixels(640, 360)
    try #require(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
    let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
    var seed: UInt32 = 1
    for y in 0..<360 {
        for x in 0..<640 {
            if x.isMultiple(of: 4) { seed = seed &* 1_664_525 &+ 1_013_904_223 }
            base[y * stride + x] = 48 + UInt8(seed >> 25)
        }
    }
    memset(CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * 180)
    CVPixelBufferUnlockBaseAddress(pixels, [])

    var time: Int64 = 0
    /// Submits the same picture half a second later, as the server does for a still desktop.
    func encode(maximumQP: Int?) async throws -> VideoFrameMessage {
        for _ in 0..<12 {
            let count = frames.count
            do {
                _ = try await session.sendFrame(
                    pixels, presentationTime: CMTime(value: time, timescale: 30),
                    duration: CMTime(value: 1, timescale: 30), maximumQP: maximumQP)
            } catch VideoCodecError.frameDropped {}
            time += 15
            if frames.count > count { return frames[count] }
        }
        throw VideoCodecError.frameDropped
    }
    var decoder: VideoDecoder?
    var format: CMVideoFormatDescription?
    func lumaError(_ packet: VideoFrameMessage) async throws -> Int {
        if let description = packet.format {
            format = description
            decoder = try VideoDecoder(format: description)
        }
        let frame = try await #require(decoder).decode(packet.sample(format: #require(format)))
        try #require(CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        try #require(CVPixelBufferLockBaseAddress(frame.pixels, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(frame.pixels, .readOnly) }
        let decoded = CVPixelBufferGetBaseAddressOfPlane(frame.pixels, 0)!.assumingMemoryBound(
            to: UInt8.self)
        let decodedStride = CVPixelBufferGetBytesPerRowOfPlane(frame.pixels, 0)
        var error = 0
        for y in 0..<360 {
            for x in 0..<640 { error += abs(Int(base[y * stride + x]) - Int(decoded[y * decodedStride + x])) }
        }
        return error
    }

    let key = try await encode(maximumQP: nil)
    #expect(key.kind == .idr)
    var errors = [try await lumaError(key)]
    // Left alone, a still picture stays as coarse as its key frame.
    let idle = try await encode(maximumQP: nil)
    errors.append(try await lumaError(idle))
    #expect(idle.kind == .predicted && Double(errors[1]) > 0.8 * Double(errors[0]))
    for limit in [32, 29, 26] {
        let step = try await encode(maximumQP: limit)
        errors.append(try await lumaError(step))
        #expect(step.kind == .predicted && step.epoch == key.epoch)
        #expect(step.bytes.count < key.bytes.count)
    }
    // Each step is finer than the last, with no key frame and no break in the chain.
    #expect(errors[2] < errors[1] && errors[3] < errors[2] && errors[4] < errors[3])
    #expect(Double(errors[4]) < 0.6 * Double(errors[0]))
}
