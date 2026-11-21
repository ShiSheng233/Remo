import RemoTransport

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

extension Diagnostic: CustomStringConvertible {
    public var description: String {
        (peer.map { "[\($0)] " } ?? "") + (kind == .trace ? "trace " : "") + message
    }
}

extension NetworkMessageSession.CloseReason {
    var diagnosticDescription: String {
        guard case .transport(.reliableDeadline(let byte, let sequence, let firstSent, let retries)) = self
        else { return String(describing: self) }
        let type = MessageKind(rawValue: byte).map { String(describing: $0) } ?? "unknown(\(byte))"
        return "transport(reliableDeadline) type=\(type) reliableSequence=\(sequence)"
            + " firstSent=\(firstSent) retransmissions=\(retries)"
    }
}
