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
    let virtualDisplayStream = StreamParameters(
        virtualDisplay: .init(logicalWidth: 890, logicalHeight: 626),
        framesPerSecond: 60,
        maximumVideoBitRate: 8_000_000,
        streamsAudio: true)
    let messages: [SessionHandshake] = [
        .hello(requestsControl: false),
        .hello(requestsControl: true),
        .hello(requestsControl: false, stream: customStream),
        .hello(requestsControl: true, stream: customStream),
        .hello(requestsControl: false, stream: virtualDisplayStream),
        .hello(requestsControl: true, stream: virtualDisplayStream),
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
    func rawHello(
        flags: UInt8, w: UInt16, h: UInt16, fps: UInt16, bps: UInt32,
        virtualDisplay: (UInt16, UInt16)? = nil
    ) -> Data {
        var data = Data()
        data.put(MessageKind.hello.rawValue)
        data.put(flags)
        data.put(w)
        data.put(h)
        data.put(fps)
        data.put(bps)
        if let virtualDisplay {
            data.put(virtualDisplay.0)
            data.put(virtualDisplay.1)
        }
        return data
    }
    for invalid in [
        rawHello(flags: 0x08, w: 0, h: 0, fps: 60, bps: 5_000_000),
        rawHello(flags: 0x04, w: 0, h: 0, fps: 60, bps: 5_000_000),
        rawHello(flags: 0x04, w: 0, h: 0, fps: 60, bps: 5_000_000, virtualDisplay: (799, 600)),
        rawHello(flags: 0x04, w: 0, h: 0, fps: 60, bps: 5_000_000, virtualDisplay: (800, 599)),
        rawHello(flags: 0x04, w: 0, h: 0, fps: 60, bps: 5_000_000, virtualDisplay: (3601, 1000)),
        rawHello(flags: 0x04, w: 0, h: 0, fps: 60, bps: 5_000_000, virtualDisplay: (1000, 3601)),
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

@Test func virtualDisplayFittingPreservesInRangeSizesAndScalesOutOfRangeSizes() {
    // iPhone Duo: 2670×1878 @3x → 890×626 pt → 1780×1252 px @2x
    let duo = StreamParameters.VirtualDisplay.fitting(logicalWidth: 890, logicalHeight: 626)
    #expect(duo == .init(logicalWidth: 890, logicalHeight: 626))
    #expect(duo.pixelWidth == 1780 && duo.pixelHeight == 1252)
    #expect(duo.isValid)

    // iPad Pro 11": already in range
    let ipad = StreamParameters.VirtualDisplay.fitting(logicalWidth: 1194, logicalHeight: 834)
    #expect(ipad == .init(logicalWidth: 1194, logicalHeight: 834))
    #expect(ipad.pixelWidth == 2388 && ipad.pixelHeight == 1668)

    // Standard iPhone landscape: height below 600 pt scales up proportionally
    let iphoneLandscape = StreamParameters.VirtualDisplay.fitting(logicalWidth: 874, logicalHeight: 402)
    #expect(iphoneLandscape.logicalHeight == 600)
    #expect(iphoneLandscape.logicalWidth == 1304)
    #expect(iphoneLandscape.isValid)

    // Standard iPhone portrait: width below 800 pt scales up proportionally
    let iphonePortrait = StreamParameters.VirtualDisplay.fitting(logicalWidth: 402, logicalHeight: 874)
    #expect(iphonePortrait.logicalWidth == 800)
    #expect(iphonePortrait.logicalHeight == 1739)
    #expect(iphonePortrait.isValid)

    // Oversized screen scales down into 3600×3600
    let huge = StreamParameters.VirtualDisplay.fitting(logicalWidth: 4000, logicalHeight: 2500)
    #expect(huge == .init(logicalWidth: 3600, logicalHeight: 2250))
    #expect(huge.isValid)
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
