import Foundation
import Testing

import RemoTransport

@testable import RemoEngine

@Test func onlyVideoKindsGoToTheVideoSession() {
    let video: Set<MessageKind> = [.videoFrame, .videoAcknowledgement, .videoRecoveryRequest]
    for kind in MessageKind.allCases {
        #expect(kind.isVideo == video.contains(kind), "\(kind)")
    }
}

@Test func controlMessagesRoundTripAndRejectOtherBytes() throws {
    let message = ControlMessage(sequence: 42)
    #expect(try ControlMessage(decoding: message.encoded) == message)
    #expect(message.encoded.count == 9)
    for invalid in [message.encoded.dropLast(), message.encoded + [0], MessageKind.heartbeat.encoded] {
        #expect(throws: WireFormatError.self) { try ControlMessage(decoding: invalid) }
    }
}

@Test func sessionHandshakeRoundTripsAndRejectsInvalidBytes() throws {
    let grant = SessionHandshake.ControlGrant(
        pointerPosition: CGPoint(x: 0.25, y: 0.75),
        displayWidth: 1512,
        displayHeight: 982,
        capsLock: true)
    let customStream = StreamParameters(
        maximumSize: .init(width: 2560, height: 1440),
        framesPerSecond: 120,
        maximumVideoBitRate: 12_000_000,
        streamsAudio: true)
    let messages: [SessionHandshake] = [
        .hello(requestsControl: false),
        .hello(requestsControl: true),
        .hello(requestsControl: false, stream: customStream),
        .hello(requestsControl: true, stream: customStream),
        .ready(control: nil),
        .ready(control: grant),
    ]
    for message in messages {
        #expect(try SessionHandshake(decoding: message.encoded) == message)
        #expect(message.delivery.retryBudget == .infinity)
        #expect(message.delivery.priority == .high)
        #expect(throws: WireFormatError.self) {
            try SessionHandshake(decoding: message.encoded.dropLast())
        }
        #expect(throws: WireFormatError.self) {
            try SessionHandshake(decoding: message.encoded + [0])
        }
    }
    func rawHello(flags: UInt8, w: UInt16, h: UInt16, fps: UInt16, bps: UInt32) -> Data {
        var data = Data()
        data.put(MessageKind.hello.rawValue)
        data.put(flags)
        data.put(w)
        data.put(h)
        data.put(fps)
        data.put(bps)
        return data
    }
    for invalid in [
        rawHello(flags: 0x04, w: 0, h: 0, fps: 60, bps: 5_000_000),
        rawHello(flags: 0, w: 1920, h: 0, fps: 60, bps: 5_000_000),
        rawHello(flags: 0, w: 0, h: 1080, fps: 60, bps: 5_000_000),
        rawHello(flags: 0, w: 321, h: 240, fps: 60, bps: 5_000_000),
        rawHello(flags: 0, w: 8194, h: 1080, fps: 60, bps: 5_000_000),
        rawHello(flags: 0, w: 0, h: 0, fps: 0, bps: 5_000_000),
        rawHello(flags: 0, w: 0, h: 0, fps: 241, bps: 5_000_000),
        rawHello(flags: 0, w: 0, h: 0, fps: 60, bps: 0),
        rawHello(flags: 0, w: 0, h: 0, fps: 60, bps: UInt32(Int32.max) + 1),
    ] {
        #expect(throws: WireFormatError.self) { try SessionHandshake(decoding: invalid) }
    }
}

@Test func frameRedundancyFollowsLossAndFrameSize() {
    let frame = 8000
    #expect(MessageTransport.repairableFragments(in: frame) == 7)
    // Too little loss to act on, and a frame that would have to be sent twice.
    #expect(SessionTiming.frameRedundancy(bytes: frame, loss: 0.005) == 0)
    #expect(SessionTiming.frameRedundancy(bytes: 1000, loss: 0.1) == 0)
    // One repair fragment makes seven arrive whole 98 times in 100 at 3% loss. At 10% it
    // takes three.
    #expect(SessionTiming.frameRedundancy(bytes: frame, loss: 0.03) == 1.0 / 7)
    #expect(SessionTiming.frameRedundancy(bytes: frame, loss: 0.1) == 3.0 / 7)
    // Never more than half the frame again, however bad the link.
    #expect(SessionTiming.frameRedundancy(bytes: 2000, loss: 0.3) == 0.5)
    #expect(SessionTiming.frameRedundancy(bytes: frame, loss: 1) == 3.0 / 7)
    var previous = 0.0
    for loss in stride(from: 0.0, through: 0.3, by: 0.01) {
        let share = SessionTiming.frameRedundancy(bytes: 20_000, loss: loss)
        #expect(share >= previous && share <= 0.5)
        previous = share
    }
}
