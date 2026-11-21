import Foundation

/// Optional observation of a session. None of it changes how the session behaves.
public struct Diagnostics: Sendable {
    /// Receives diagnostic lines. Called from any thread, so it must not block.
    public var handler: (@Sendable (Diagnostic) -> Void)?
    /// Reports outgoing UDP bytes, DATA, ACK and retransmissions once per second.
    public var wireStatistics = false
    /// Traces heartbeat submission, UDP framing, session delivery and timeouts.
    public var traceHeartbeats = false
    /// Records PCM (.f32le) and its timing (.csv) at each audio stage into this directory.
    public var audioTraceDirectory: URL?

    public init(
        handler: (@Sendable (Diagnostic) -> Void)? = nil, wireStatistics: Bool = false,
        traceHeartbeats: Bool = false, audioTraceDirectory: URL? = nil
    ) {
        self.handler = handler
        self.wireStatistics = wireStatistics
        self.traceHeartbeats = traceHeartbeats
        self.audioTraceDirectory = audioTraceDirectory
    }

    func info(_ peer: String?, _ message: @autoclosure () -> String) {
        handler?(Diagnostic(peer: peer, kind: .info, message: message()))
    }
}
