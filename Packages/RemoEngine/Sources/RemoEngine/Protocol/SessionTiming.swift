//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

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
}
