import Darwin
import Dispatch
import Foundation
import Network
import RemoEngine

#if os(macOS)
    import AppKit
#endif

@main
enum Command {
    static let usage = """
        Usage:
          remo-engine server [port] [--screen] [--control] [--wire-stats] [--trace-heartbeats]
          remo-engine client <host> [port] [--resolution WIDTHxHEIGHT] [--fps FPS] [--max-video-bitrate BPS] [--screen] [--audio] [--wire-stats] [--trace-heartbeats]

        Default UDP port: \(RemoProtocol.defaultPort)
        --resolution sets the test pattern size or caps screen capture at WIDTHxHEIGHT pixels (client).
        Dimensions must be even (2...8192). Defaults: 640x360 test pattern, screen longest edge 1920.
        --fps sets the target frame rate (1...240, default 60, client). Screen capture runs VFR up to this rate.
        --max-video-bitrate sets the video bitrate ceiling in bits per second (default 5000000, client).
        --screen streams the main display on the server and opens a video window on the client (macOS).
          Without it, the server streams a test pattern and the client verifies every frame of it.
        --audio requests system playback audio from a screen server (client, macOS 13 or later on server).
        --control enables remote pointer and keyboard input on a macOS screen server (requires Accessibility access).
        --trace-heartbeats traces heartbeat submission, UDP framing, session delivery, and timeouts.
        REMO_AUDIO_TRACE_DIR records diagnostic PCM (.f32le) and timing (.csv) in that directory.
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
        let flags = ["--screen", "--audio", "--control", "--wire-stats", "--trace-heartbeats"]
        let present = Set(args.filter(flags.contains))
        args.removeAll(where: flags.contains)
        if args == ["--help"] || args == ["-h"] {
            log(usage)
            return
        }
        let screen = present.contains("--screen")
        let audio = present.contains("--audio")
        var resolution: StreamParameters.Size?
        var fps: Int32 = StreamParameters.defaultFramesPerSecond
        var bitRate = StreamParameters.defaultMaximumVideoBitRate
        for option in ["--resolution", "--fps", "--max-video-bitrate"] {
            guard let index = args.firstIndex(of: option) else { continue }
            guard args.first == "client" else { fail("\(option) is a client option.") }
            guard index + 1 < args.count else { fail("Missing value for \(option).") }
            let value = args[index + 1]
            switch option {
            case "--fps":
                guard let value = Int32(value) else { fail("Expected --fps FPS.") }
                fps = value
            case "--max-video-bitrate":
                guard let value = Int32(value) else {
                    fail("Expected --max-video-bitrate in bits per second (1...2147483647).")
                }
                bitRate = Int(value)
            default:
                let parts = value.lowercased().split(
                    separator: "x", omittingEmptySubsequences: false)
                guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else {
                    fail("Expected --resolution WIDTHxHEIGHT.")
                }
                resolution = StreamParameters.Size(width: w, height: h)
            }
            args.removeSubrange(index...index + 1)
        }
        guard
            (args.first == "server" && (1...2).contains(args.count))
                || (args.first == "client" && (2...3).contains(args.count))
        else { fail(usage) }
        let server = args[0] == "server"
        if audio && server { fail("--audio is a client option.") }
        if present.contains("--control") && (!server || !screen) {
            fail("--control requires server --screen.")
        }
        let value = args.dropFirst(server ? 1 : 2).first ?? String(RemoProtocol.defaultPort)
        guard let port = UInt16(value), port > 0 else { fail("Invalid UDP port: \(value)") }
        let diagnostics = Diagnostics(
            handler: { logDiagnostic($0) }, wireStatistics: present.contains("--wire-stats"),
            traceHeartbeats: present.contains("--trace-heartbeats"),
            audioTraceDirectory: ProcessInfo.processInfo.environment["REMO_AUDIO_TRACE_DIR"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) })

        if server {
            let source: RemoteScreenServer.Source = screen ? .mainDisplay : testPattern()
            await serve(
                RemoteScreenServer.Configuration(
                    source: source,
                    allowsRemoteControl: present.contains("--control"),
                    diagnostics: diagnostics),
                port: port)
        } else {
            let stream = StreamParameters(
                maximumSize: resolution, framesPerSecond: fps, maximumVideoBitRate: bitRate,
                streamsAudio: audio)
            if let problem = stream.validationProblem { fail(problem) }
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(args[1]), port: NWEndpoint.Port(rawValue: port)!)
            let success = await view(
                endpoint, screen: screen, stream: stream, diagnostics: diagnostics)
            if !success { exit(EXIT_FAILURE) }
        }
    }

    @MainActor
    static func serve(_ configuration: RemoteScreenServer.Configuration, port: UInt16) async {
        let server: RemoteScreenServer
        do {
            server = try await RemoteScreenServer(configuration: configuration) { event in
                switch event {
                case .listening(let port): log("Listening on UDP port \(port)")
                case .clientConnected: break
                case let .streamingStarted(peer, session):
                    log(
                        "[\(peer)] streaming started (\(session.width) × \(session.height), up to \(session.framesPerSecond) fps, max \(session.maximumVideoBitRate) bps, audio \(session.streamsAudio ? "on" : "off"))"
                    )
                case .clientDisconnected(let peer, let reason, _): log("[\(peer)] \(reason)")
                case .statistics(let peer, let statistics):
                    let stamp = Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))
                    log("\(stamp) [\(peer)] \(statistics)")
                }
            }
        } catch {
            fail("\(error)")
        }
        if let size = server.screenSize {
            log("Screen source: main display (\(size.width) × \(size.height) native)")
        }
        let signals = onTermination { server.stop() }
        defer { signals.forEach { $0.cancel() } }
        do {
            try await server.listen(on: port)
        } catch {
            fail("Listener failed: \(error)")
        }
    }

    /// A new test pattern source for each client, using the client's requested size and frame rate.
    static func testPattern() -> RemoteScreenServer.Source {
        log("Test pattern source")
        return .custom { parameters in
            let size = parameters.maximumSize ?? StreamParameters.Size(width: 640, height: 360)
            return try TestPatternSource(
                width: size.width, height: size.height, framesPerSecond: parameters.framesPerSecond)
        }
    }

    @MainActor
    static func view(
        _ endpoint: NWEndpoint, screen: Bool, stream: StreamParameters, diagnostics: Diagnostics
    ) async -> Bool {
        #if os(macOS)
            var client: RemoteScreenClient?
            let window =
                screen
                ? VideoWindow(title: "Remo — \(endpoint)") {
                    log("[\(endpoint)] leaving")
                    client?.disconnect()
                } : nil
            defer { window?.close() }
        #else
            if screen { fail("The screen viewer requires macOS.") }
        #endif
        var displayEnqueued = 0
        var verifier = TestPatternVerifier()
        let viewer = RemoteScreenClient(
            configuration: .init(
                requestsRemoteControl: false, stream: stream, diagnostics: diagnostics),
            onFrame: { frame in
                #if os(macOS)
                    if let window {
                        if try window.present(frame.pixels, duration: frame.duration) {
                            displayEnqueued += 1
                        }
                        return
                    }
                #endif
                try verifier.check(frame)
            },
            onEvent: { event in
                switch event {
                case .state(.waitingForVideo): log("[\(endpoint)] connected; press Ctrl-C to exit")
                case .statistics(let statistics):
                    let frames =
                        screen ? "displayEnqueued=\(displayEnqueued)" : "verified=\(verifier.verified)"
                    log("[\(endpoint)] \(statistics)  \(frames)")
                case .cursor(let cursor):
                    #if os(macOS)
                        window?.show(cursor)
                    #endif
                default: break
                }
            })
        #if os(macOS)
            client = viewer
        #endif
        let signals = onTermination {
            log("[\(endpoint)] leaving")
            viewer.disconnect()
        }
        defer { signals.forEach { $0.cancel() } }
        guard let failure = await viewer.run(.udp(endpoint)) else { return true }
        log("[\(endpoint)] \(failure)")
        return false
    }

    @MainActor
    static func onTermination(_ handler: @escaping @MainActor () -> Void) -> [any DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler(handler: DispatchWorkItem { MainActor.assumeIsolated(handler) })
            source.activate()
            return source
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(EXIT_FAILURE)
    }
}

// MARK: - Output

func log(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func logDiagnostic(_ diagnostic: Diagnostic) {
    log(diagnostic.description)
}
