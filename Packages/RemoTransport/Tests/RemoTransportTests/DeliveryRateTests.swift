import Foundation
import Testing

@testable import RemoTransport

/// Real sender and receiver sharing a virtual clock and a FIFO bottleneck with 50 ms of buffering.
private final class LimitedLink {
    private var tick = 0
    private var now: Double { Double(tick) / 1000 }
    var capacity = 5_000_000.0
    private var wireFree = 0.0
    private var deadlines = [Double.infinity, Double.infinity]
    private var inbound = [[(arrival: Double, bytes: Data)](), []]
    private var endpoints: [MessageTransport] = []
    private(set) var dropped = 0
    var budget: Double { endpoints[0].statistics.bitsPerSecond }

    init() {
        for side in 0..<2 {
            endpoints.append(MessageTransport(
                initialRate: 4_000_000, clock: { [unowned self] in now }, dataHandler: { _ in },
                ioHandler: { [unowned self] request in handle(request, from: side) })!)
        }
    }

    private func handle(_ request: MessageTransport.IORequest, from side: Int) -> Bool {
        switch request {
        case .setTimer(let deadline):
            deadlines[side] = deadline ?? .infinity
        case .sendDatagram(let bytes):
            var arrival = now + 0.03
            if side == 0 {
                if wireFree - now > 0.05 {
                    dropped += 1
                    return true
                }
                wireFree = max(wireFree, now) + Double(bytes.count) * 8 / capacity
                arrival = wireFree + 0.03
            }
            inbound[1 - side].append((arrival, bytes))
        case .close(let failure):
            Issue.record("Unexpected transport close: \(failure)")
        }
        return true
    }

    func advance(seconds: Int, frameBytes: (Double) -> Int, duplicateACKs: Bool = false) {
        let until = tick + seconds * 1000
        while tick < until {
            for side in 0..<2 {
                while let packet = inbound[side].first, packet.arrival <= now {
                    inbound[side].removeFirst()
                    endpoints[side].handleEvent(.datagram(packet.bytes))
                    if side == 0 && duplicateACKs { endpoints[side].handleEvent(.datagram(packet.bytes)) }
                }
                if deadlines[side] <= now {
                    deadlines[side] = .infinity
                    endpoints[side].handleEvent(.timer)
                }
            }
            if tick.isMultiple(of: 33) {
                endpoints[0].send(Data(count: frameBytes(budget)), delivery: .init(retryBudget: 0.08))
            }
            if tick.isMultiple(of: 20) {
                endpoints[0].send(Data(count: 250), delivery: .init(retryBudget: 0, firstSendDeadline: now + 0.1))
            }
            tick += 1
        }
    }
}

@Test func burstyApplicationCannotRatchetBudgetBeyondDeliveredTraffic() {
    let link = LimitedLink()
    link.advance(seconds: 60, frameBytes: { _ in 12_500 })
    #expect(link.budget < 5_000_000)
    link.advance(seconds: 15, frameBytes: { Int($0 * 0.7 * 0.033 / 8) })
    #expect(link.dropped == 0)
}

@Test func budgetTracksFasterDeliveryAndIgnoresRepeatedACKs() {
    let original = LimitedLink()
    let duplicated = LimitedLink()
    for (link, replay) in [(original, false), (duplicated, true)] {
        link.advance(seconds: 8, frameBytes: { _ in 12_500 }, duplicateACKs: replay)
        link.capacity = 16_000_000
        link.advance(seconds: 45, frameBytes: { Int($0 * 0.95 * 0.033 / 8) }, duplicateACKs: replay)
        #expect(link.budget > 8_000_000)
    }
    #expect(original.budget == duplicated.budget)
}

@Test func backoffRecoveryRequiresRenewedDelivery() {
    let link = LimitedLink()
    let demand: (Double) -> Int = { Int($0 * 0.83 * 0.033 / 8) }
    link.capacity = 12_000_000
    link.advance(seconds: 20, frameBytes: demand)
    let beforeLoss = link.budget
    link.capacity = 2_000_000
    link.advance(seconds: 15, frameBytes: demand)
    #expect(link.dropped > 0)
    #expect(link.budget < beforeLoss * 0.8)

    link.capacity = 12_000_000
    link.advance(seconds: 12, frameBytes: { _ in 100 })
    #expect(link.budget < beforeLoss * 0.8)
    link.advance(seconds: 60, frameBytes: demand)
    #expect(link.budget > beforeLoss * 0.9)
}
