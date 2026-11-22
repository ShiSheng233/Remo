import Dispatch
import Foundation
import RemoTransport

// RemoTransport measures time in seconds of uptime. These are the only conversions to it;
// everything else in the engine uses `Duration` and `SuspendingClock`, which share that clock.

extension Duration {
    /// Seconds, for APIs that take a `TimeInterval`.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    /// Whole nanoseconds.
    var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}

/// State where a newer message makes an unfinished older one worthless.
enum ReplaceableMessage: Int {
    case heartbeat, control, pointerHello, pointerMove, videoAcknowledgement, videoRecoveryRequest
}

extension MessageTransport.Delivery {
    /// Retries for `budget` after admission, and drops what can't be sent within `sendWithin`.
    /// `redundancy` adds repair fragments, as a share of the message's own.
    static func retrying(
        for budget: Duration = .zero, sendWithin limit: Duration? = nil,
        priority: MessageTransport.Priority = .normal, replacing key: ReplaceableMessage? = nil,
        redundancy: Double = 0
    ) -> Self {
        let now = TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1e9
        return Self(
            retryBudget: budget.timeInterval,
            firstSendDeadline: limit.map { now + $0.timeInterval }, priority: priority,
            replacing: key?.rawValue, redundancy: redundancy)
    }

    /// A small message the session depends on: retried until it arrives, ahead of media.
    static var essential: Self { .untilDelivered(priority: .high) }
}
