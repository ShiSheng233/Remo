import Darwin
import Dispatch
import Foundation
import Network
import RemoTransport

enum Message: UInt8 {
    case hello = 1
    case heartbeat, goodbye, video, control

    func packet(sequence: UInt64, size: Int) -> Data {
        var bytes = Data(repeating: rawValue, count: size)
        withUnsafeBytes(of: sequence.bigEndian) { bytes.replaceSubrange(1..<9, with: $0) }
        return bytes
    }
}

@MainActor
final class DemoSession {
    enum Role { case server, client }

    let role: Role
    let peer: NWEndpoint
    private var session: NetworkMessageSession?
    private let trace = HeartbeatTrace(layer: "session")
    private var active = false
    private var stopping = false
    private var lastSeen = DispatchTime.now().uptimeNanoseconds
    private var frames: UInt64 = 0
    private var controls: UInt64 = 0
    private var latestFrame: UInt64 = 0
    private var latestControl: UInt64 = 0
    private var backpressureDrops: UInt64 = 0
    private var lateFrames: UInt64 = 0
    private var heartbeats = 0
    private var videoBytes = 0
    private var previousFrames: UInt64 = 0
    private var previousBytes = 0
    private var lastReport = DispatchTime.now().uptimeNanoseconds
    private var failure: String?
    private var setup: Task<Void, Never>?

    init(role: Role, peer: NWEndpoint) {
        self.role = role
        self.peer = peer
    }

    func run(_ connection: NWConnection) async -> Bool {
        trace.write(peer, "\(role) opening")
        let setup = Task { [self] in
            do {
                session = try await NetworkMessageSession(connection: connection) {
                    [weak self] channel, bytes in
                    self?.receive(channel, bytes)
                } closeHandler: { [weak self] reason in
                    self?.stop("connection closed: \(reason)", failed: true)
                }
            } catch {
                stop("connection setup: \(error)", failed: true)
            }
        }
        self.setup = setup
        let timeout = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            stop("connection setup timed out", failed: true)
        }
        await setup.value
        timeout.cancel()
        self.setup = nil

        if let session, !stopping {
            lastSeen = DispatchTime.now().uptimeNanoseconds
            lastReport = lastSeen
            trace.write(peer, "\(role) ready")
            do {
                if role == .client {
                    try session.send(Data([Message.hello.rawValue]), mode: .reliable)
                    trace.write(peer, "hello queued")
                    try await runClient(session)
                } else {
                    try await runServer(session)
                }
            } catch {
                stop("send failed: \(error)", failed: true)
            }
        }
        session?.cancel()
        session = nil
        return failure == nil
    }

    func requestExit() {
        guard !stopping else { return }
        try? session?.send(Data([Message.goodbye.rawValue]), mode: .reliable)
        stop("leaving", failed: false)
    }

    private func stop(_ reason: String, failed: Bool) {
        guard !stopping else { return }
        stopping = true
        if failed { failure = reason }
        setup?.cancel()
        let idleMs = (DispatchTime.now().uptimeNanoseconds - lastSeen) / 1_000_000
        trace.write(
            peer,
            "\(role) stop reason=\(reason) idleMs=\(idleMs) active=\(active) heartbeats=\(heartbeats) frames=\(frames) controls=\(controls)"
        )
        log("[\(peer)] \(reason)")
    }

    private func receive(_ channel: MessageTransport.Channel, _ bytes: Data) {
        guard !stopping, let first = bytes.first, let kind = Message(rawValue: first) else {
            return
        }
        switch (role, channel, kind) {
        case (.server, .reliable, .hello) where bytes.count == 1:
            if !active { log("[\(peer)] streaming started") }
            active = true
            trace.write(peer, "hello accepted")
        case (.server, _, .heartbeat):
            guard channel == .unreliable, bytes.count == 1, active else {
                trace.write(
                    peer,
                    "heartbeat ignored active=\(active) channel=\(channel) bytes=\(bytes.count)")
                return
            }
            heartbeats += 1
            trace.write(peer, "heartbeat accepted count=\(heartbeats)")
        case (.server, .reliable, .goodbye) where bytes.count == 1:
            stop("client left", failed: false)
        case (.client, .unreliable, .video) where bytes.count == 12_288:
            frames += 1
            let number = sequence(in: bytes)
            if number < latestFrame { lateFrames += 1 }
            latestFrame = max(latestFrame, number)
            videoBytes += bytes.count
        case (.client, .reliable, .control) where bytes.count == 9:
            controls += 1
            latestControl = sequence(in: bytes)
        default: return
        }
        lastSeen = DispatchTime.now().uptimeNanoseconds
    }

    private func sequence(in bytes: Data) -> UInt64 {
        bytes.withUnsafeBytes {
            UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt64.self))
        }
    }

    private func runServer(_ session: NetworkMessageSession) async throws {
        var nextFrame = DispatchTime.now().uptimeNanoseconds
        var nextControl = nextFrame
        while !stopping {
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastSeen >= 2_000_000_000 {
                stop("client timed out", failed: false)
                break
            }
            if active {
                if now >= nextControl {
                    try session.send(
                        Message.control.packet(sequence: controls + 1, size: 9), mode: .reliable)
                    controls += 1
                    nextControl = now + 1_000_000_000
                }
                frames += 1
                let frame = Message.video.packet(sequence: frames, size: 12_288)
                let deadline = Double(DispatchTime.now().uptimeNanoseconds) / 1e9 + 0.033
                do {
                    try session.send(
                        frame, mode: .unreliable(retryBudget: 0.08, firstSendDeadline: deadline))
                    videoBytes += frame.count
                } catch NetworkMessageSession.SendError.backpressure {
                    backpressureDrops += 1
                }
                report(session, now: now)
            }
            nextFrame += 33_333_333
            let sent = DispatchTime.now().uptimeNanoseconds
            if nextFrame <= sent { nextFrame = sent + 33_333_333 }
            try await Task.sleep(nanoseconds: nextFrame - sent)
        }
    }

    private func runClient(_ session: NetworkMessageSession) async throws {
        log("[\(peer)] connected; press Ctrl-C to exit")
        while !stopping {
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastSeen >= 4_000_000_000 {
                stop("server timed out", failed: true)
                break
            }
            try session.send(Data([Message.heartbeat.rawValue]), mode: .unreliable(retryBudget: 0))
            heartbeats += 1
            trace.write(peer, "heartbeat queued count=\(heartbeats)")
            report(session, now: now)
            try await Task.sleep(nanoseconds: 400_000_000)
        }
    }
    private func report(_ session: NetworkMessageSession, now: UInt64) {
        let elapsed = now - lastReport
        guard elapsed >= 1_000_000_000 else { return }
        let seconds = Double(elapsed) / 1e9
        let countedFrames = frames - backpressureDrops
        let fps = Double(countedFrames - previousFrames) / seconds
        let mbps = Double(videoBytes - previousBytes) * 8 / seconds / 1e6
        let stats = session.statistics
        let rtt = stats.roundTripTime.map { String(format: "%.1f ms", $0 * 1000) } ?? "pending"
        let details: String
        if role == .server {
            details =
                "generated=\(frames) queued=\(countedFrames) backpressureDrops=\(backpressureDrops)"
                + " controlsQueued=\(controls) heartbeatsRx=\(heartbeats)"
        } else {
            details =
                "frames=\(frames) latest=#\(latestFrame) missingFrames=\(max(latestFrame, frames) - frames) lateFrames=\(lateFrames)"
                + " controls=\(controls) latest=#\(latestControl) heartbeatsQueued=\(heartbeats)"
        }
        let direction = role == .server ? "video queued" : "video received"
        log(
            "[\(peer)] \(direction) " + String(format: "%.1f fps %.2f Mbps", fps, mbps)
                + "  \(details)  RTT=\(rtt)"
                + String(
                    format: " txBudget=%.2f Mbps txQueue=%.1f ms", stats.bitsPerSecond / 1e6,
                    stats.estimatedQueueDelay * 1000))
        previousBytes = videoBytes
        previousFrames = countedFrames
        lastReport = now
    }

}

func log(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
