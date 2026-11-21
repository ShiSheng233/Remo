import Foundation
import Testing

@testable import RemoTransport

/// A sender and receiver on a virtual clock, joined by a bottleneck with a configurable rate,
/// buffer and random loss. The application spends its budget the way the screen server does:
/// 30 frames a second at 85% of the budget less audio, a frame skipped while more than 50 ms
/// is queued, and 20 ms audio packets at high priority.
private final class Bottleneck {
    static let audioBitRate = 110_000.0
    private var tick = 0
    private var now: Double { Double(tick) / 1000 }
    var capacity = 50_000_000.0
    var buffer = 0.05
    var loss = 0.0
    var maximumVideo = 2_000_000.0
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var wireFree = 0.0
    private var deadlines = [Double.infinity, Double.infinity]
    private var inbound = [[(arrival: Double, bytes: Data)](), []]
    private var endpoints: [MessageTransport] = []
    private(set) var sent = 0
    private(set) var dropped = 0
    private(set) var slowestRoundTrip = 0.0
    var statistics: MessageTransport.Statistics { endpoints[0].statistics }
    var budget: Double { statistics.bitsPerSecond }
    /// What the application sends at the current budget.
    var demand: Double { video + Self.audioBitRate }
    private var video: Double {
        min(maximumVideo, max(128_000, budget * 0.85 - Self.audioBitRate))
    }

    init() {
        for side in 0..<2 {
            endpoints.append(MessageTransport(
                clock: { [unowned self] in now }, dataHandler: { _ in },
                ioHandler: { [unowned self] request in handle(request, from: side) })!)
        }
    }

    private func random() -> Double {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return Double(seed >> 11) / Double(1 << 53)
    }

    private func handle(_ request: MessageTransport.IORequest, from side: Int) -> Bool {
        switch request {
        case .setTimer(let deadline): deadlines[side] = deadline ?? .infinity
        case .sendDatagram(let bytes):
            var arrival = now + 0.03
            if side == 0 {
                sent += 1
                if wireFree - now > buffer || random() < loss {
                    dropped += 1
                    return true
                }
                wireFree = max(wireFree, now) + Double(bytes.count) * 8 / capacity
                arrival = wireFree + 0.03
            }
            inbound[1 - side].append((arrival, bytes))
        case .close(let failure): Issue.record("Unexpected transport close: \(failure)")
        }
        return true
    }

    func resetCounters() {
        sent = 0
        dropped = 0
        slowestRoundTrip = 0
    }

    func advance(seconds: Int) {
        let until = tick + seconds * 1000
        while tick < until {
            for side in 0..<2 {
                while let packet = inbound[side].first, packet.arrival <= now {
                    inbound[side].removeFirst()
                    endpoints[side].handleEvent(.datagram(packet.bytes))
                }
                if deadlines[side] <= now {
                    deadlines[side] = .infinity
                    endpoints[side].handleEvent(.timer)
                }
            }
            if tick.isMultiple(of: 33), statistics.estimatedQueueDelay <= 0.05 {
                endpoints[0].send(
                    Data(count: Int(video * 0.033 / 8)), delivery: .init(retryBudget: 0.08))
            }
            if tick.isMultiple(of: 20) {
                endpoints[0].send(
                    Data(count: 250),
                    delivery: .init(retryBudget: 0, firstSendDeadline: now + 0.1, priority: .high))
            }
            tick += 1
            if tick.isMultiple(of: 10) {
                slowestRoundTrip = max(slowestRoundTrip, statistics.roundTripTime ?? 0)
            }
        }
    }
}

@Test func budgetClimbsFromItsFirstGuessOnAnOpenLink() {
    let link = Bottleneck()
    #expect(link.budget == MessageTransport.initialRate)
    link.advance(seconds: 10)
    // Enough for full-rate video and audio, with nothing queued along the way.
    #expect(link.demand == link.maximumVideo + Bottleneck.audioBitRate)
    #expect(link.dropped == 0 && link.slowestRoundTrip < 0.08)
}

@Test func budgetReturnsAfterCongestionAtTheServersOwnShare() {
    let link = Bottleneck()
    link.advance(seconds: 15)
    let before = link.demand
    link.capacity = 1_000_000
    link.advance(seconds: 15)
    #expect(link.demand < 1_000_000)
    link.capacity = 50_000_000
    link.advance(seconds: 45)
    #expect(link.demand == before)
}

@Test(arguments: [0.01, 0.03, 0.10])
func randomLossDoesNotCollapseTheBudget(loss: Double) {
    let link = Bottleneck()
    link.loss = loss
    link.advance(seconds: 90)
    // The loss stays whatever is sent, so sending less would give up bit rate for nothing.
    #expect(link.demand > 0.9 * (link.maximumVideo + Bottleneck.audioBitRate))
    #expect(abs(link.statistics.lossRatio - loss) < 0.6 * loss + 0.01)
}

@Test(arguments: [2_000_000.0, 1_000_000.0, 500_000.0])
func deepBufferDoesNotHoldAStandingQueue(capacity: Double) {
    let link = Bottleneck()
    link.capacity = capacity
    link.buffer = 4
    link.advance(seconds: 30)
    link.resetCounters()
    link.advance(seconds: 90)
    // The path alone takes 60 ms. A second of buffer is available and stays unused.
    #expect(link.slowestRoundTrip < 0.2)
    #expect(link.dropped == 0)
    #expect(link.demand > 0.6 * capacity && link.demand < 1.05 * capacity)
    #expect(try! #require(link.statistics.minimumRoundTripTime) < 0.07)
}

@Test func startingOnASlowLinkOvershootsBrieflyAndOnce() {
    let link = Bottleneck()
    link.capacity = 1_000_000
    link.buffer = 4
    link.advance(seconds: 3)
    #expect(link.slowestRoundTrip < 0.35)
    link.resetCounters()
    link.advance(seconds: 20)
    #expect(link.slowestRoundTrip < 0.2 && link.demand < 1_050_000)
}

@Test func suddenLossOfCapacityIsFollowedWithinTwoSeconds() {
    let link = Bottleneck()
    link.buffer = 0.3
    link.advance(seconds: 15)
    link.capacity = 400_000
    link.advance(seconds: 2)
    #expect(link.demand < 400_000)
    // What was already queued when the link narrowed takes a moment to clear.
    link.advance(seconds: 2)
    link.resetCounters()
    link.advance(seconds: 20)
    #expect(link.slowestRoundTrip < 0.2 && link.dropped == 0)
}

@Test func policedLinkWithLittleBufferSettlesNearItsRate() {
    let link = Bottleneck()
    link.capacity = 1_500_000
    link.buffer = 0.02
    link.advance(seconds: 40)
    link.resetCounters()
    link.advance(seconds: 80)
    // The queue is too short to measure. Only loss that stops when less is sent gives it away.
    #expect(link.demand > 0.6 * link.capacity && link.demand < 1.15 * link.capacity)
    #expect(Double(link.dropped) / Double(link.sent) < 0.02)
}
