import RemoTransport

/// The datagram link as the sender sees it.
public struct LinkStatistics: Sendable {
    public let roundTripTime: Duration?
    /// Estimated sending budget in bits per second.
    public let bitsPerSecond: Double
    public let queueDelay: Duration
    /// High-priority (audio) messages that expired before their first transmission.
    public let audioExpiredBeforeFirstSend: UInt64

    init(_ statistics: MessageTransport.Statistics) {
        roundTripTime = statistics.roundTripTime.map(Duration.seconds)
        bitsPerSecond = statistics.bitsPerSecond
        queueDelay = .seconds(statistics.estimatedQueueDelay)
        audioExpiredBeforeFirstSend = statistics.expiredBeforeFirstSend[.high, default: 0]
    }
}
