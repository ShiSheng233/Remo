import Foundation
import Testing

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
