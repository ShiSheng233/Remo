/// Reported by a server for each streaming client about once per second.
public struct ServerStatistics: Sendable {
    public struct Audio: Sendable {
        public let packetsQueued: Int
        public let sourceGaps: UInt64
        public let backpressureDrops: Int
        /// The longest send-queue delay seen when queuing audio during the last interval.
        public let peakQueueDelay: Duration
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
