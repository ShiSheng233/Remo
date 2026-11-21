import Dispatch
import Foundation
import Network

/// Observes v1 headers immediately above UDP. Each connection owns its own counters.
final class DatagramMonitor: NWProtocolFramerImplementation {
    static let label = "Remo datagram statistics"
    static let definition = NWProtocolFramer.Definition(implementation: DatagramMonitor.self)

    // Network creates each framer itself, so the options reach it through here. The most recent
    // session's diagnostics apply to every monitored connection.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current = Diagnostics()

    /// UDP parameters, with the monitor in place only when the diagnostics need it.
    static func parameters(for diagnostics: Diagnostics) -> NWParameters {
        guard diagnostics.handler != nil, diagnostics.wireStatistics || diagnostics.traceHeartbeats
        else { return .udp }
        lock.withLock { current = diagnostics }
        let parameters = NWParameters.udp
        parameters.defaultProtocolStack.applicationProtocols.insert(
            NWProtocolFramer.Options(definition: definition), at: 0)
        return parameters
    }

    private struct Fragment: Hashable {
        let kind: UInt8
        let message: UInt32
        let index: UInt16
    }

    private let diagnostics: Diagnostics
    private let trace: HeartbeatTrace
    private var recent: [Fragment: UInt64] = [:]
    private var data = 0
    private var acks = 0
    private var unreliableRetries = 0
    private var reliableRetries = 0
    private var bytes = 0
    private var previousBytes = 0
    private var previousTime = DispatchTime.now().uptimeNanoseconds

    required init(framer: NWProtocolFramer.Instance) {
        diagnostics = Self.lock.withLock { Self.current }
        trace = HeartbeatTrace(layer: "flow", diagnostics: diagnostics)
    }

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        // Keep handleInput active so each UDP datagram retains its message boundary.
        trace.write(framer.remote?.debugDescription, "UDP flow opened")
        return .ready
    }

    private func traceHeader(_ buffer: UnsafeMutableRawBufferPointer, size: Int) -> String? {
        guard trace.enabled, size == 10, buffer.count >= 10 else { return nil }
        let name: String
        switch (buffer[0], buffer[9]) {
        case (0, SessionMessage.heartbeat.rawValue): name = "heartbeat"
        case (2, SessionMessage.hello.rawValue): name = "hello"
        case (2, SessionMessage.screenHello.rawValue): name = "screen hello"
        default: return nil
        }
        let packet = UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: 1, as: UInt32.self))
        let message = UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: 5, as: UInt32.self))
        return "\(name) packet=\(packet) message=\(message)"
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var size = 0
            var description: String?
            _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 65535) {
                buffer, complete in
                guard let buffer, complete else { return 0 }
                size = buffer.count
                description = traceHeader(buffer, size: size)
                return 0
            }
            guard size > 0 else { return 1 }
            if let description { trace.write(framer.remote?.debugDescription, "UDP rx \(description)") }
            guard
                framer.deliverInputNoCopy(
                    length: size, message: .init(instance: framer), isComplete: true)
            else { return 0 }
        }
    }

    func handleOutput(
        framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
        messageLength: Int, isComplete: Bool
    ) {
        var fragment: Fragment?
        var ack = false
        var description: String?
        let length = min(13, messageLength)
        if length > 0 {
            _ = framer.parseOutput(minimumIncompleteLength: length, maximumLength: length) {
                buffer, _ in
                guard let buffer, buffer.count >= 9 else { return 0 }
                description = traceHeader(buffer, size: messageLength)
                let kind = buffer[0]
                if kind == 0x80 {
                    ack = true
                } else if kind == 0 || kind == 2 || (kind == 1 && buffer.count >= 13) {
                    let id = UInt32(
                        bigEndian: buffer.loadUnaligned(fromByteOffset: 5, as: UInt32.self))
                    let index =
                        kind == 1
                        ? UInt16(
                            bigEndian: buffer.loadUnaligned(fromByteOffset: 9, as: UInt16.self)) : 0
                    fragment = Fragment(kind: kind, message: id, index: index)
                }
                return 0
            }
        }
        do { try framer.writeOutputNoCopy(length: messageLength) } catch {
            framer.markFailed(error: .posix(.EIO))
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if let description { trace.write(framer.remote?.debugDescription, "UDP tx \(description)") }
        bytes += messageLength
        if ack { acks += 1 }
        if let fragment {
            data += 1
            if recent.updateValue(now, forKey: fragment) != nil {
                if fragment.kind == 2 { reliableRetries += 1 } else { unreliableRetries += 1 }
            }
        }
        if now - previousTime >= 1_000_000_000 {
            if diagnostics.wireStatistics { report(framer, now: now) }
            previousBytes = bytes
            previousTime = now
            // Every retry lifetime in use is shorter than three seconds.
            recent = recent.filter { now - $0.value < 3_000_000_000 }
        }
    }

    private func report(_ framer: NWProtocolFramer.Instance, now: UInt64) {
        let seconds = Double(now - previousTime) / 1e9
        let mbps = Double(bytes - previousBytes) * 8 / max(seconds, 1e-9) / 1e6
        diagnostics.handler?(
            Diagnostic(
                peer: framer.remote?.debugDescription, kind: .wire,
                message: "UDP tx" + String(format: " %.3f Mbps", mbps)
                    + "  bytes=\(bytes) DATA=\(data) ACK=\(acks) U-retries=\(unreliableRetries) R-retries=\(reliableRetries)"
            ))
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool {
        trace.write(framer.remote?.debugDescription, "UDP flow stopped")
        if diagnostics.wireStatistics, bytes != previousBytes {
            report(framer, now: DispatchTime.now().uptimeNanoseconds)
        }
        return true
    }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}
