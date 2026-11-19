import Darwin
import Dispatch
import Foundation
import Network

@main
enum Command {
    static let usage = """
        Usage:
          remo-transport server [port] [--wire-stats] [--trace-heartbeats]
          remo-transport client <host> [port] [--wire-stats] [--trace-heartbeats]

        Default UDP port: 7711
        --trace-heartbeats traces heartbeat submission, UDP framing, session delivery, and timeouts.
        --wire-stats observes outgoing UDP payload bytes, DATA, ACK, and retransmissions.
        """

    @MainActor
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let wireStats = args.contains("--wire-stats")
        args.removeAll { $0 == "--wire-stats" || $0 == "--trace-heartbeats" }
        if args == ["--help"] || args == ["-h"] {
            log(usage)
            return
        }
        guard
            (args.first == "server" && (1...2).contains(args.count))
                || (args.first == "client" && (2...3).contains(args.count))
        else { fail(usage) }
        let server = args[0] == "server"
        let value = args.dropFirst(server ? 1 : 2).first ?? "7711"
        guard let raw = UInt16(value), raw > 0, let port = NWEndpoint.Port(rawValue: raw) else {
            fail("Invalid UDP port: \(value)")
        }
        let parameters: NWParameters =
            (wireStats || HeartbeatTrace.enabled) ? DatagramMonitor.parameters() : .udp
        if server {
            do { try await listen(port, parameters: parameters) } catch {
                fail("Listener failed: \(error)")
            }
        } else {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(args[1]), port: port)
            let client = DemoSession(role: .client, peer: endpoint)
            let signals = [SIGINT, SIGTERM].map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler(
                    handler: DispatchWorkItem {
                        Task { @MainActor in client.requestExit() }
                    })
                source.activate()
                return source
            }
            let success = await client.run(NWConnection(to: endpoint, using: parameters))
            for source in signals { source.cancel() }
            if !success { exit(EXIT_FAILURE) }
        }
    }

    @MainActor
    static func listen(_ port: NWEndpoint.Port, parameters: NWParameters) async throws {
        let listener = try NWListener(using: parameters, on: port)
        let (states, events) = AsyncStream<NWListener.State>.makeStream()
        listener.stateUpdateHandler = { events.yield($0) }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let peer = DemoSession(role: .server, peer: connection.endpoint)
                _ = await peer.run(connection)
            }
        }
        listener.start(queue: DispatchQueue(label: "RemoTransportCLI.listener"))
        defer {
            listener.cancel()
            events.finish()
        }
        for await state in states {
            switch state {
            case .ready: log("Listening on UDP port \(port)")
            case .failed(let error): throw error
            case .cancelled: return
            default: break
            }
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(EXIT_FAILURE)
    }
}
