import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import Network
import RemoTransport
import Testing

@testable import RemoEngine

/// A desktop with a window being dragged: a still, detailed background and a band of new
/// detail that moves every frame.
private final class DraggingSource: ScreenFrameSource {
    let width = 960
    let height = 540
    private var step: Int64 = 0
    private var seed: UInt32 = 7
    private let background: [UInt8]

    init() {
        var seed: UInt32 = 1
        background = (0..<(960 * 540)).map { index in
            if index.isMultiple(of: 3) { seed = seed &* 1_664_525 &+ 1_013_904_223 }
            return 60 + UInt8(seed >> 26)
        }
    }

    func latestFrame() throws -> ScreenFrame? {
        step += 1
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let left = Int(step * 12 % 760)
        for y in 0..<height {
            background.withUnsafeBufferPointer {
                (base + y * stride).update(from: $0.baseAddress! + y * width, count: width)
            }
            guard (120..<420).contains(y) else { continue }
            for x in left..<(left + 200) {
                if x.isMultiple(of: 2) { seed = seed &* 1_664_525 &+ 1_013_904_223 }
                base[y * stride + x] = 120 + UInt8(seed >> 25)
            }
        }
        memset(
            CVPixelBufferGetBaseAddressOfPlane(pixels, 1), 128,
            CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * height / 2)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return ScreenFrame(pixels: pixels, timestamp: CMTime(value: step, timescale: 30))
    }

    nonisolated(nonsending) func stop() async throws {}
}

/// A UDP connection that loses a share of datagrams in each direction and delays the rest.
private final class LossyConnection: DatagramConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let loss: Double
    private let delay: DispatchTimeInterval
    private let queue = DispatchQueue(label: "LossyConnection")
    private var events: AsyncStream<ConnectionEvent>.Continuation?
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var inbox: [(due: DispatchTime, data: Data)] = []
    private var wanted = false

    init(to endpoint: NWEndpoint, loss: Double, delay: Duration) {
        connection = NWConnection(to: endpoint, using: .udp)
        self.loss = loss
        self.delay = .microseconds(Int(delay / .microseconds(1)))
    }

    private func lost() -> Bool {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return Double(seed >> 11) / Double(1 << 53) < loss
    }

    func start(events: AsyncStream<ConnectionEvent>.Continuation) {
        queue.async {
            self.events = events
            self.connection.stateUpdateHandler = { events.yield(.state($0)) }
            self.connection.start(queue: self.queue)
            self.read()
        }
    }

    func receive() {
        queue.async {
            self.wanted = true
            self.deliver()
        }
    }

    /// Reads continuously, so the delay holds datagrams back without slowing their rate.
    private func read() {
        connection.receiveMessage { [weak self] data, _, complete, error in
            guard let self, let events else { return }
            if let error { return _ = events.yield(.failed(error)) }
            if complete, let data, !lost() {
                let due = DispatchTime.now() + delay
                inbox.append((due, data))
                queue.asyncAfter(deadline: due) { self.deliver() }
            }
            read()
        }
    }

    private func deliver() {
        guard wanted, let first = inbox.first, first.due <= .now() else { return }
        inbox.removeFirst()
        wanted = false
        events?.yield(.received(first.data))
    }

    func send(_ datagram: Data) {
        queue.async {
            self.events?.yield(.processed(datagram.count))
            guard !self.lost() else { return }
            self.queue.asyncAfter(deadline: .now() + self.delay) {
                self.connection.send(content: datagram, completion: .idempotent)
            }
        }
    }

    func cancel() {
        queue.async {
            self.events = nil
            self.connection.cancel()
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

struct LinkQuality: CustomStringConvertible, Sendable {
    let loss: Double
    let delay: Duration
    var description: String { "loss \(Int(loss * 100))% RTT \(delay * 2)" }
}

/// The whole path, with the real encoder and decoder: a session keeps a moving picture going
/// through loss, repairs it without key frames, and never freezes for long. The last link is
/// too slow for a retransmission to arrive in time, so only repair fragments can carry it.
@Test(.serialized, arguments: [
    LinkQuality(loss: 0, delay: .milliseconds(40)),
    LinkQuality(loss: 0.03, delay: .milliseconds(10)),
    LinkQuality(loss: 0.10, delay: .milliseconds(75)),
]) @MainActor
func movingPictureSurvivesALossyLink(link: LinkQuality) async throws {
    var port: UInt16?
    let keyFrames = Counter()
    let server = try await RemoteScreenServer(
        configuration: .init(
            source: .custom { DraggingSource() },
            diagnostics: .init {
                if $0.message.hasPrefix("key frame=") && $0.message.hasSuffix(" sent until delivered") {
                    keyFrames.increment()
                }
            })
    ) { if case .listening(let value) = $0 { port = value } }
    let listening = Task { try await server.listen(on: 0) }
    defer { server.stop() }
    while port == nil { try await Task.sleep(for: .milliseconds(10)) }

    var arrivals: [SuspendingClock.Instant] = []
    let requests = Counter()
    var client: RemoteScreenClient!
    client = RemoteScreenClient(
        configuration: .init(
            requestsRemoteControl: false,
            diagnostics: .init {
                if $0.message.hasPrefix("recovery requested") { requests.increment() }
            }),
        onFrame: { _ in arrivals.append(.now) })
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port!)!)
    let seconds = 9.0
    let stop = Task {
        try? await Task.sleep(for: .seconds(seconds))
        client.disconnect()
    }
    defer { stop.cancel() }
    let failure = await client.run(
        .datagrams(LossyConnection(to: endpoint, loss: link.loss, delay: link.delay)))
    #expect(failure == nil, "\(link): \(String(describing: failure))")
    try #require(arrivals.count > 10, "\(link): only \(arrivals.count) frames")

    // Leave out the start: the first key frame and the climb to full rate.
    let steady = arrivals.filter { $0 >= arrivals[0] + .seconds(3) }
    let gaps = zip(steady, steady.dropFirst()).map { $1 - $0 }
    let span = (try #require(steady.last) - steady[0]) / .seconds(1)
    let rate = Double(steady.count) / span
    let longest = try #require(gaps.max())
    let frozen = gaps.filter { $0 > .milliseconds(100) }.reduce(Duration.zero, +) / .seconds(1)
    print(String(
        format: "LOSSY %@: %.1f fps, longest gap %.0f ms, gaps over 100 ms %d (%.1f%% of the time), requests %d, key frames %d",
        "\(link)", rate, longest / .milliseconds(1), gaps.filter { $0 > .milliseconds(100) }.count,
        100 * frozen / span, requests.value, keyFrames.value))
    // Repair fragments and retransmission hide light loss. Heavy loss on a slow link still
    // costs a frame now and then, but not the session and not a string of key frames.
    #expect(rate > (link.loss < 0.05 ? 24 : 18))
    #expect(longest < (link.loss < 0.05 ? .milliseconds(400) : .milliseconds(1000)))
    #expect(keyFrames.value <= 2)

    server.stop()
    try await listening.value
}
