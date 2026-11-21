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

extension MessageTransport.Mode {
    /// Retries for `retryFor` after admission, and drops what can't be sent within `sendWithin`.
    static func unreliable(
        retryFor budget: Duration = .zero, sendWithin limit: Duration? = nil,
        priority: MessageTransport.UnreliablePriority = .normal
    ) -> Self {
        let now = TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1e9
        return .unreliable(
            retryBudget: budget.timeInterval,
            firstSendDeadline: limit.map { now + $0.timeInterval }, priority: priority)
    }
}
