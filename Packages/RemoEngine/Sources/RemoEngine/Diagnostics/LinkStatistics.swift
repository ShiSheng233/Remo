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

extension LinkStatistics: CustomStringConvertible {
    public var description: String {
        "RTT=\(roundTripTime.map(\.logDescription) ?? "pending")"
            + String(format: " txBudget=%.2f Mbps", bitsPerSecond / 1e6)
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
