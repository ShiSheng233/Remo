import Darwin
import Dispatch
import Foundation
import Network
import RemoEngine

#if os(macOS)
    import AppKit
#endif

struct VideoSettings {
    var resolution: (width: Int, height: Int)?
    var simulatedSize: (width: Int, height: Int) { resolution ?? (640, 360) }
    var screenBounds: (width: Int, height: Int) { resolution ?? (1920, 1920) }
    var maxVideoBitRate = 2_000_000
    var fps: Int32 = 30
    var interval: UInt64 { 1_000_000_000 / UInt64(fps) }
}

@main
enum Command {
    static let usage = """
        Usage:
          remo-engine server [port] [--resolution WIDTHxHEIGHT] [--fps FPS] [--max-video-bitrate BPS] [--screen] [--wire-stats] [--trace-heartbeats]
          remo-engine client <host> [port] [--screen] [--wire-stats] [--trace-heartbeats]

        Default UDP port: 7711
        --resolution sets the simulated frame size or fits the screen inside WIDTHxHEIGHT.
        Dimensions must be even (2...8192). Defaults: 640x360 simulated, screen longest edge 1920.
        --fps sets the server frame rate (1...240, default 30). Screen capture may run slower.
        --max-video-bitrate sets the video bitrate ceiling in bits per second (default 2000000).
        --screen streams the main display on the server and opens a video window on the client (macOS).
        --trace-heartbeats traces heartbeat submission, UDP framing, session delivery, and timeouts.
        --wire-stats observes outgoing UDP payload bytes, DATA, ACK, and retransmissions.
        """

    @MainActor
    static func main() {
        #if os(macOS)
            if CommandLine.arguments.dropFirst().first == "client"
                && CommandLine.arguments.contains("--screen")
            {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                Task { @MainActor in
                    await run()
                    exit(EXIT_SUCCESS)
                }
                app.run()
                return
            }
        #endif
        Task { @MainActor in
            await run()
            exit(EXIT_SUCCESS)
        }
        RunLoop.main.add(Port(), forMode: .default)
        RunLoop.main.run()
    }

    @MainActor
    static func run() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let wireStats = args.contains("--wire-stats")
        let screen = args.contains("--screen")
        args.removeAll { $0 == "--screen" || $0 == "--wire-stats" || $0 == "--trace-heartbeats" }
        if args == ["--help"] || args == ["-h"] {
            log(usage)
            return
        }
        var settings = VideoSettings()
        for option in ["--resolution", "--fps", "--max-video-bitrate"] {
            guard let index = args.firstIndex(of: option) else { continue }
            guard args.first == "server" else { fail("\(option) is a server option.") }
            guard index + 1 < args.count else { fail("Missing value for \(option).") }
            let value = args[index + 1]
            if option == "--fps" {
                guard let fps = Int32(value), (1...240).contains(fps) else {
                    fail("Expected --fps 1...240.")
                }
                settings.fps = fps
            } else if option == "--max-video-bitrate" {
                guard let rate = Int32(value), rate > 0 else {
                    fail("Expected --max-video-bitrate in bits per second (1...2147483647).")
                }
                settings.maxVideoBitRate = Int(rate)
            } else {
                let parts = value.lowercased().split(
                    separator: "x", omittingEmptySubsequences: false)
                guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
                    [w, h].allSatisfy({ (2...8192).contains($0) && $0.isMultiple(of: 2) })
                else {
                    fail("Expected --resolution WIDTHxHEIGHT with even dimensions from 2 to 8192.")
                }
                settings.resolution = (w, h)
            }
            args.removeSubrange(index...index + 1)
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
            var capture: DemoSession.StartCapture?
            if screen {
                #if os(macOS)
                    guard #available(macOS 12.3, *) else {
                        fail("Screen capture requires macOS 12.3 or later.")
                    }
                    do {
                        let config = try await ScreenCaptureConfiguration.mainDisplay(
                            maximumWidth: settings.screenBounds.width,
                            maximumHeight: settings.screenBounds.height,
                            framesPerSecond: settings.fps)
                        capture = { try await config.start() }
                        log(
                            "Screen source: main display, \(config.width) × \(config.height) at up to \(settings.fps) fps"
                        )
                    } catch {
                        fail(
                            "Screen discovery failed: \(error.localizedDescription). Check Screen Recording access in System Settings → Privacy & Security."
                        )
                    }
                #else
                    fail("Screen capture requires macOS.")
                #endif
            }
            if !screen {
                log(
                    "Simulated source: \(settings.simulatedSize.width) × \(settings.simulatedSize.height) at \(settings.fps) fps"
                )
            }
            do {
                try await listen(port, parameters: parameters, capture: capture, settings: settings)
            } catch {
                fail("Listener failed: \(error)")
            }
        } else {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(args[1]), port: port)
            let client = DemoSession(role: .client, peer: endpoint, screen: screen)
            #if os(macOS)
                let window =
                    screen
                    ? VideoWindow(title: "Remo — \(endpoint)", onClose: { client.requestExit() })
                    : nil
                if let window {
                    client.present = {
                        try window.present($0.pixels, duration: $0.duration)
                    }
                }
                defer {
                    client.present = nil
                    window?.close()
                }
            #else
                if screen { fail("The screen viewer requires macOS.") }
            #endif
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
    static func listen(
        _ port: NWEndpoint.Port, parameters: NWParameters, capture: DemoSession.StartCapture?,
        settings: VideoSettings
    ) async throws {
        let listener = try NWListener(using: parameters, on: port)
        let (states, events) = AsyncStream<NWListener.State>.makeStream()
        listener.stateUpdateHandler = { events.yield($0) }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let peer = DemoSession(
                    role: .server, peer: connection.endpoint, screen: capture != nil,
                    startCapture: capture, settings: settings)
                _ = await peer.run(connection)
            }
        }
        listener.start(queue: DispatchQueue(label: "RemoEngineCLI.listener"))
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
