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
    /// Frames withheld while a key frame was still on its way to the client.
    public let keyFrameWaits: UInt64
    public let acknowledgedReferences: Int
    public let controlsSent: UInt64
    public let heartbeatsReceived: Int
    /// DATA datagrams accepted by local I/O during this reporting interval.
    public let dataPacketsAccepted: UInt32
    public let newAckAge: Duration?
    public let blocked: Bool
    public let probing: Bool
    public let audio: Audio?
    public let link: LinkStatistics
}

extension ServerStatistics: CustomStringConvertible {
    /// One line in the CLI's format.
    public var description: String {
        var details =
            "generated=\(framesGenerated) queued=\(framesQueued) backpressureDrops=\(backpressureDrops) codecDrops=\(codecDrops)"
            + " encoderBps=\(encoderBitRate) captureSkips=\(captureSkips) keyFrameWaits=\(keyFrameWaits)"
            + " ltrAcks=\(acknowledgedReferences) controlsQueued=\(controlsSent) heartbeatsRx=\(heartbeatsReceived)"
        if let audio, audio.packetsQueued > 0 || audio.backpressureDrops > 0 {
            details +=
                " audioQueued=\(audio.packetsQueued) audioSourceGaps=\(audio.sourceGaps) audioBackpressure=\(audio.backpressureDrops)"
                + " audioFirstSendExpired=\(link.audioExpiredBeforeFirstSend)"
                + " audioQueuePeak=\(audio.peakQueueDelay.logDescription)"
        }
        return "video queued "
            + String(format: "%.1f fps %.2f Mbps", framesPerSecond, videoBitsPerSecond / 1e6)
            + "  \(details)  \(link) dataTxAccepted=\(dataPacketsAccepted)"
            + " newAckAge=\(newAckAge?.logDescription ?? "pending") blocked=\(blocked) probing=\(probing)"
    }
}
