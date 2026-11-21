/// One line from a session's `Diagnostics`.
public struct Diagnostic: Sendable {
    public enum Kind: Sendable {
        /// Notable session events such as recovery.
        case info
        /// `Diagnostics.traceHeartbeats` output.
        case trace
        /// `Diagnostics.wireStatistics` output.
        case wire
    }

    /// The remote endpoint, when the line concerns one connection.
    public let peer: String?
    public let kind: Kind
    public let message: String
}
