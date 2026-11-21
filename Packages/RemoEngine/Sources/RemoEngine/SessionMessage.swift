//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation

/// Values a client and server must agree on outside the session itself.
public enum RemoProtocol {
    /// The UDP port a server listens on unless configured otherwise.
    public static let defaultPort: UInt16 = 7711
}

/// Application messages shared by the streaming server and its clients.
enum SessionMessage: UInt8 {
    /// Asks for video, from clients that predate `screenHello`.
    case hello = 1
    case heartbeat = 2
    case goodbye = 3
    case control = 5
    /// Asks for the server's video.
    case screenHello = 6
    /// Retired: refused a `hello`. Not to be reused.
    case modeMismatch = 7
    case mouseHello = 8
    case mouseReady = 9
    case mouseInput = 10
    case audio = 11

    /// The message for kinds without a body.
    var encoded: Data { Data([rawValue]) }

    static func control(sequence: UInt64) -> Data {
        var data = Data([SessionMessage.control.rawValue])
        data.put(sequence)
        return data
    }

    static func controlSequence(in message: Data) -> UInt64? {
        var body = message
        guard (try? body.take(UInt8.self)) == SessionMessage.control.rawValue,
            let sequence = try? body.take(UInt64.self), body.isEmpty
        else { return nil }
        return sequence
    }
}

/// Timers that pair across the two ends of a session. Change them together.
enum SessionTiming {
    /// The client keeps the session alive at this interval.
    static let heartbeatInterval: UInt64 = 400_000_000
    /// The server drops a client after missing about five heartbeats.
    static let clientTimeout: UInt64 = 2_000_000_000
    /// The server proves it is alive at this interval, even when no video is flowing.
    static let controlInterval: UInt64 = 1_000_000_000
    /// The client gives up after missing about four controls and all video.
    static let serverTimeout: TimeInterval = 4
    /// The client asks for a refresh when no frame has decoded for this long.
    static let videoStall: TimeInterval = 2
    /// A pointer request repeats until the server answers or the session ends.
    static let mouseHelloRetry: TimeInterval = 1.2
    /// A pointer move or scroll is worthless once this old.
    static let pointerDeadline: TimeInterval = 0.05
    /// Statistics are reported at this interval.
    static let reportInterval: UInt64 = 1_000_000_000
}

/// Monotonic uptime in seconds, the clock that transport deadlines use.
func uptime() -> TimeInterval {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
}
