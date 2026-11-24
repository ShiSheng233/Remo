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
    let extendedGrant = SessionHandshake.ControlGrant(
        pointerPosition: CGPoint(x: 0.25, y: 0.75), displayWidth: 1512, displayHeight: 982,
        capsLock: true, extendedPointer: true)
    let messages: [SessionHandshake] = [
        .hello(requestsControl: false),
        .hello(requestsControl: true),
        .hello(requestsControl: true, extendedPointer: true),
        .ready(control: nil),
        .ready(control: grant),
        .ready(control: extendedGrant),
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
    #expect(grant.extendedPointer == false)
    #expect(SessionHandshake.hello(requestsControl: true).encoded == Data([1, 1]))
    #expect(SessionHandshake.hello(requestsControl: true, extendedPointer: true).encoded == Data([1, 3]))
    #expect(SessionHandshake.ready(control: grant).encoded.prefix(2) == Data([6, 1]))
    #expect(SessionHandshake.ready(control: extendedGrant).encoded.prefix(2) == Data([6, 3]))
    let badFlags = Data([MessageKind.hello.rawValue, 2])
    #expect(throws: WireFormatError.self) { try SessionHandshake(decoding: badFlags) }
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
