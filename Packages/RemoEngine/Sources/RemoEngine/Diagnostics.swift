import CoreMedia
import Foundation
import RemoCodec
import RemoTransport

/// A decoded picture handed to the application for display.
public struct VideoFrame {
    public let pixels: CVPixelBuffer
    public let presentationTime: CMTime
    public let duration: CMTime

    init(_ frame: DecodedVideoFrame) {
        pixels = frame.pixels
        presentationTime = frame.presentationTime
        duration = frame.duration
    }
}

/// Optional observation of a session. None of it changes how the session behaves.
public struct Diagnostics: Sendable {
    /// Receives diagnostic lines. Called from any thread, so it must not block.
    public var handler: (@Sendable (Diagnostic) -> Void)?
    /// Reports outgoing UDP bytes, DATA, ACK and retransmissions once per second.
    public var wireStatistics = false
    /// Traces heartbeat submission, UDP framing, session delivery and timeouts.
    public var traceHeartbeats = false
    /// Records PCM (.f32le) and its timing (.csv) at each audio stage into this directory.
    public var audioTraceDirectory: URL?

    public init(
        handler: (@Sendable (Diagnostic) -> Void)? = nil, wireStatistics: Bool = false,
        traceHeartbeats: Bool = false, audioTraceDirectory: URL? = nil
    ) {
        self.handler = handler
        self.wireStatistics = wireStatistics
        self.traceHeartbeats = traceHeartbeats
        self.audioTraceDirectory = audioTraceDirectory
    }

    func info(_ peer: String?, _ message: @autoclosure () -> String) {
        handler?(Diagnostic(peer: peer, kind: .info, message: message()))
    }
}

public struct Diagnostic: Sendable {
    public enum Kind: Sendable {
        /// Notable session events such as recovery and adaptation.
        case info
        /// `Diagnostics.traceHeartbeats` output.
        case trace
        /// `Diagnostics.wireStatistics` output.
        case wire
    }

    /// The remote endpoint, when the line concerns one connection.
    public let peer: String?
    public let kind: Kind
    public let message: String
}

/// Heartbeat tracing for one layer of one connection.
struct HeartbeatTrace {
    private let diagnostics: Diagnostics
    private let tag: String

    init(layer: String, diagnostics: Diagnostics) {
        self.diagnostics = diagnostics
        tag = "\(layer)=\(UUID().uuidString.prefix(8))"
    }

    var enabled: Bool { diagnostics.traceHeartbeats && diagnostics.handler != nil }

    func write(_ peer: String?, _ message: @autoclosure () -> String) {
        guard enabled, let handler = diagnostics.handler else { return }
        let time = String(format: "%.3f", Date().timeIntervalSince1970)
        handler(Diagnostic(peer: peer, kind: .trace, message: "t=\(time) \(tag) \(message())"))
    }
}

/// The datagram link as the sender sees it.
public struct LinkStatistics: Sendable {
    public let roundTripTime: TimeInterval?
    /// Estimated sending budget in bits per second.
    public let bitsPerSecond: Double
    public let queueDelay: TimeInterval
    /// High-priority (audio) messages that expired before their first transmission.
    public let audioExpiredBeforeFirstSend: UInt64

    init(_ statistics: MessageTransport.Statistics) {
        roundTripTime = statistics.roundTripTime
        bitsPerSecond = statistics.bitsPerSecond
        queueDelay = statistics.estimatedQueueDelay
        audioExpiredBeforeFirstSend = statistics.expiredBeforeFirstSend[.high, default: 0]
    }
}

public struct AudioPlaybackStatistics: Sendable {
    public let decodeFailures: Int
    public let concealedPackets: Int
    public let fadeFallbacks: Int
    public let rebufferCount: Int
    public let latePackets: Int
}

/// Reported by a client about once per second.
public struct ClientStatistics: Sendable {
    /// Decoded frames per second over the last interval.
    public let framesPerSecond: Double
    /// Received video bits per second over the last interval.
    public let videoBitsPerSecond: Double
    public let framesDecoded: UInt64
    public let latestFrame: UInt64
    public let controlsReceived: UInt64
    public let latestControl: UInt64
    public let heartbeatsSent: Int
    public let audio: AudioPlaybackStatistics?
    public let link: LinkStatistics

    /// Frames the server numbered but this client never decoded.
    public var missingFrames: UInt64 { max(latestFrame, framesDecoded) - framesDecoded }
}

/// Reported by a server for each streaming client about once per second.
public struct ServerStatistics: Sendable {
    public struct Audio: Sendable {
        public let packetsQueued: Int
        public let sourceGaps: UInt64
        public let backpressureDrops: Int
        /// The longest send-queue delay seen when queuing audio during the last interval.
        public let peakQueueDelay: TimeInterval
    }

    /// Frames admitted to the transport per second over the last interval.
    public let framesPerSecond: Double
    /// Admitted video bits per second over the last interval.
    public let videoBitsPerSecond: Double
    public let framesGenerated: UInt64
    public let framesQueued: UInt64
    public let backpressureDrops: UInt64
    public let codecDrops: UInt64
    /// The adaptive encoder bit rate.
    public let encoderBitRate: Int
    /// Source frames skipped because the send queue was too deep.
    public let captureSkips: Int
    /// Frames withheld while a reliable key frame was in flight.
    public let checkpointSkips: UInt64
    public let acknowledgedReferences: Int
    public let controlsSent: UInt64
    public let heartbeatsReceived: Int
    public let audio: Audio?
    public let link: LinkStatistics
}
