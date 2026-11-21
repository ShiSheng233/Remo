import Foundation

/// Heartbeat tracing for one layer of one connection, stamped with the wall-clock time so
/// traces from both ends can be lined up.
struct HeartbeatTrace {
    private let diagnostics: Diagnostics
    private let tag: String

    init(layer: String, diagnostics: Diagnostics) {
        self.diagnostics = diagnostics
        tag = "\(layer)=\(UUID().uuidString.prefix(8))"
    }

    var enabled: Bool { diagnostics.traceHeartbeats && diagnostics.handler != nil }

    func write(_ peer: String?, _ message: @autoclosure () -> String) {
        guard enabled, let handler = diagnostics.handler else { return }
        let time = Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))
        handler(Diagnostic(peer: peer, kind: .trace, message: "t=\(time) \(tag) \(message())"))
    }
}
