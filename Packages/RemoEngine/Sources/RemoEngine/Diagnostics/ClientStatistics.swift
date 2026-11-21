/// Reported by a client about once per second.
public struct ClientStatistics: Sendable {
    public struct Audio: Sendable {
        public let decodeFailures: Int
        public let concealedPackets: Int
        public let fadeFallbacks: Int
        public let rebufferCount: Int
        public let latePackets: Int
    }

    /// Decoded frames per second over the last interval.
    public let framesPerSecond: Double
    /// Received video bits per second over the last interval.
    public let videoBitsPerSecond: Double
    public let framesDecoded: UInt64
    public let latestFrame: UInt64
    public let controlsReceived: UInt64
    public let latestControl: UInt64
    public let heartbeatsSent: Int
    public let audio: Audio?
    public let link: LinkStatistics

    /// Frames the server numbered but this client never decoded.
    public var missingFrames: UInt64 { max(latestFrame, framesDecoded) - framesDecoded }
}
