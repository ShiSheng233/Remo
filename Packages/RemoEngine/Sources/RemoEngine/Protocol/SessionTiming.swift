//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation
import RemoTransport

/// Timers that pair across the two ends of a session. Change them together.
enum SessionTiming {
    /// The client keeps the session alive at this interval.
    static let heartbeatInterval = Duration.milliseconds(400)
    /// The server drops a client after this much silence from messages and delivery confirmations.
    static let clientTimeout = Duration.seconds(4)
    /// The server sends a disposable control after this much outbound data silence.
    static let controlInterval = Duration.seconds(1)
    /// The client gives up after this much server silence.
    static let serverTimeout = Duration.seconds(4)
    /// The client asks for a refresh when no frame has decoded for this long.
    static let videoStall = Duration.seconds(2)
    /// A pointer request repeats until the server answers or the session ends.
    static let pointerHelloRetry = Duration.milliseconds(1200)
    /// A pointer move or scroll is worthless once this old.
    static let pointerDeadline = Duration.milliseconds(50)
    /// Audio that can't be sent this soon would arrive too late to play.
    static let audioDeadline = Duration.milliseconds(100)
    /// How long a server waits for a new connection to become ready.
    static let connectionSetupTimeout = Duration.seconds(5)
    /// Statistics are reported at this interval.
    static let reportInterval = Duration.seconds(1)

    /// Beyond this round trip a retransmitted frame arrives no sooner than a refresh would.
    private static let retransmissionLimit = Duration.milliseconds(120)

    /// How long the server retransmits the fragments of a predicted frame: long enough to
    /// notice one loss and repair it.
    static func frameRetryBudget(roundTrip: Duration?) -> Duration {
        guard let roundTrip, roundTrip <= retransmissionLimit else { return .milliseconds(80) }
        return max(.milliseconds(80), roundTrip * 3 / 2 + .milliseconds(60))
    }

    /// Repair fragments for a predicted frame of `bytes`, as a share of its own fragments, on
    /// a link that loses `loss` of its datagrams whatever the sending rate. As few as let the
    /// frame arrive whole the first time 97 times in 100, which no retransmission can do in
    /// less than a round trip, and never more than half the frame again. A frame of a single
    /// datagram is left alone: repeating it would double it.
    static func frameRedundancy(bytes: Int, loss: Double) -> Double {
        let fragments = MessageTransport.repairableFragments(in: bytes)
        guard loss >= 0.01, fragments >= 2 else { return 0 }
        let loss = min(loss, 0.5)
        var repair = 0
        while repair < fragments / 2 {
            // The chance that more datagrams are lost than there are repair fragments.
            var term = pow(1 - loss, Double(fragments + repair))
            var whole = term
            for lost in 0..<repair {
                term *= Double(fragments + repair - lost) / Double(lost + 1) * loss / (1 - loss)
                whole += term
            }
            if 1 - whole <= 0.03 { break }
            repair += 1
        }
        return Double(repair) / Double(fragments)
    }

    /// How long the client waits for a missing frame before it gives the frames behind it up
    /// and asks for a refresh. Zero when no retransmission could arrive in time.
    static func framePatience(roundTrip: Duration?) -> Duration {
        guard let roundTrip else { return .milliseconds(40) }
        return roundTrip <= retransmissionLimit ? roundTrip + .milliseconds(20) : .zero
    }
}
