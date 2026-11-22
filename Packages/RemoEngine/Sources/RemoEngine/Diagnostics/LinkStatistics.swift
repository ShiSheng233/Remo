import RemoTransport

/// The datagram link as the sender sees it.
public struct LinkStatistics: Sendable {
    public let roundTripTime: Duration?
    /// The fastest round trip of the last several seconds. The gap to `roundTripTime` is
    /// time spent in queues along the path.
    public let minimumRoundTripTime: Duration?
    /// The share of data datagrams lost over about the last second.
    public let lossRatio: Double
    /// The part of `lossRatio` that sending less would not remove.
    public let linkLossRatio: Double
    /// Estimated sending budget in bits per second.
    public let bitsPerSecond: Double
    public let queueDelay: Duration
    /// High-priority (audio) messages that expired before their first transmission.
    public let audioExpiredBeforeFirstSend: UInt64

    init(_ statistics: MessageTransport.Statistics) {
        roundTripTime = statistics.roundTripTime.map(Duration.seconds)
        minimumRoundTripTime = statistics.minimumRoundTripTime.map(Duration.seconds)
        lossRatio = statistics.lossRatio
        linkLossRatio = statistics.linkLossRatio
        bitsPerSecond = statistics.bitsPerSecond
        queueDelay = .seconds(statistics.estimatedQueueDelay)
        audioExpiredBeforeFirstSend = statistics.expiredBeforeFirstSend[.high, default: 0]
    }
}

extension LinkStatistics: CustomStringConvertible {
    public var description: String {
        "RTT=\(roundTripTime.map(\.logDescription) ?? "pending")"
            + " minRTT=\(minimumRoundTripTime.map(\.logDescription) ?? "pending")"
            + String(format: " loss=%.1f%% txBudget=%.2f Mbps", lossRatio * 100, bitsPerSecond / 1e6)
            + " txQueue=\(queueDelay.logDescription)"
    }
}

extension Duration {
    /// Milliseconds with one decimal, as statistics lines print them.
    var logDescription: String {
        formatted(
            .units(allowed: [.milliseconds], width: .abbreviated, fractionalPart: .show(length: 1)))
    }
}
