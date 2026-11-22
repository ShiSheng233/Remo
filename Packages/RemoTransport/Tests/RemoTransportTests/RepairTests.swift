import Foundation
import Testing

@testable import RemoTransport

private struct Random: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private final class Clock {
    var now = 0.0
}

private final class Port {
    let clock: Clock
    var deadline: Double?
    var packets: [Data] = []
    var messages: [Data] = []

    init(_ clock: Clock, mtu: Int = 64) {
        self.clock = clock
        endpoint = MessageTransport(
            datagramLimit: mtu, initialRate: 4_000_000, clock: { clock.now },
            dataHandler: { [unowned self] in messages.append($0) },
            ioHandler: { [unowned self] request in
                switch request {
                case .sendDatagram(let bytes): packets.append(bytes)
                case .setTimer(let time): deadline = time
                case .close: break
                }
                return true
            })
    }

    private(set) var endpoint: MessageTransport!

    /// Delivers what was sent, except the datagrams at `losing` positions.
    func drain(to other: Port, losing: Set<Int> = []) {
        let batch = packets
        packets.removeAll()
        for (position, bytes) in batch.enumerated() where !losing.contains(position) {
            other.endpoint.handleEvent(.datagram(bytes))
        }
    }

    func advance(to time: Double) {
        while let deadline, deadline <= time {
            clock.now = max(clock.now, deadline)
            self.deadline = nil
            endpoint.handleEvent(.timer)
        }
        clock.now = time
    }
}

private func bytes(_ count: Int, seed: UInt64 = 1) -> Data {
    var random = Random(state: seed)
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &random) })
}

@Test func anyFragmentsAsManyAsTheDataRebuildTheMessage() {
    var random = Random(state: 7)
    let length = 47
    for count in [1, 2, 3, 7, 20, Repair.maxData] {
        // The last data fragment is shorter than the rest.
        let message = bytes(count == 1 ? 30 : (count - 1) * length + 5, seed: UInt64(count))
        let fragments = (0..<count).map { message.dropFirst($0 * length).prefix(length) }
        let size = min(length, message.count)
        for repair in [1, 2, 4, min(count, Repair.maxRepair)] {
            let parity = Repair.encode(fragments, repair: repair, length: size)
            #expect(parity.allSatisfy { $0.count == size })
            for _ in 0..<(count > 20 ? 2 : 8) {
                var parts: [Int: Data] = [:]
                for index in (0..<(count + repair)).shuffled(using: &random).prefix(count) {
                    parts[index] = index < count ? fragments[index] : parity[index - count]
                }
                let rebuilt = Repair.decode(parts, count: count, length: size)
                #expect(rebuilt?.count == count)
                var joined = Data()
                for fragment in rebuilt ?? [] { joined.append(fragment) }
                #expect(joined.prefix(message.count) == message)
            }
        }
    }
    // One fragment short is not enough.
    #expect(Repair.decode([0: Data(count: 4), 3: Data(count: 4)], count: 3, length: 4) == nil)
}

@Test func repairableFragmentsOnTheWire() {
    let key = Wire.Fragment(id: 3, index: 4)
    let encoded = Wire.repairable(7, key, count: 3, last: 5, lifetime: 0.25, Data(repeating: 1, count: 47))
    #expect(encoded.count == 64 && encoded.prefix(5) == Data([2, 0, 0, 0, 7]))
    guard case .repairable(7, key, count: 3, last: 5, 0.25, let payload)? = Wire.decode(encoded, mtu: 64)
    else {
        Issue.record("Repair fragment did not decode")
        return
    }
    #expect(payload.count == 47)

    func decodes(index: Int, count: Int, last: Int, size: Int) -> Bool {
        let datagram = Wire.repairable(
            1, .init(id: 1, index: index), count: count, last: last, lifetime: 0, Data(count: size))
        return Wire.decode(datagram, mtu: 64) != nil
    }
    // Data fragments are full but for the last one, and repair fragments match the longest.
    #expect(decodes(index: 0, count: 3, last: 5, size: 47))
    #expect(decodes(index: 2, count: 3, last: 5, size: 5))
    #expect(decodes(index: 0, count: 1, last: 5, size: 5))
    #expect(decodes(index: 1, count: 1, last: 5, size: 5))
    #expect(decodes(index: Repair.maxData + Repair.maxRepair - 1, count: Repair.maxData, last: 5, size: 47))
    #expect(!decodes(index: 0, count: 3, last: 5, size: 46))
    #expect(!decodes(index: 2, count: 3, last: 5, size: 47))
    #expect(!decodes(index: 3, count: 3, last: 5, size: 5))
    #expect(!decodes(index: 1, count: 1, last: 5, size: 47))
    #expect(!decodes(index: 0, count: 3, last: 48, size: 47))
    #expect(!decodes(index: 0, count: Repair.maxData + 1, last: 5, size: 47))
    #expect(!decodes(index: 3 + Repair.maxRepair, count: 3, last: 5, size: 47))
}

@Test func lostFragmentsAreRebuiltWithoutRetransmission() {
    let clock = Clock()
    let a = Port(clock)
    let b = Port(clock)
    let message = bytes(200)
    var outcome: MessageTransport.Outcome?
    // Five data fragments and two for repair.
    a.endpoint.send(message, delivery: .init(retryBudget: 1, redundancy: 0.4)) { outcome = $0 }
    a.advance(to: 0.01)
    #expect(a.packets.count == 7 && a.packets.allSatisfy { $0.first == 2 })
    // The second fragment and the short last one never arrive.
    a.drain(to: b, losing: [1, 4])
    #expect(b.messages == [message])
    b.advance(to: 0.02)
    b.drain(to: a)
    #expect(outcome == .delivered)
    a.advance(to: 2)
    #expect(a.packets.isEmpty && a.deadline == nil)
}

@Test func lossBeyondTheRepairFragmentsIsRetriedOrExpires() {
    for budget in [0.0, 1.0] {
        let clock = Clock()
        let a = Port(clock)
        let b = Port(clock)
        let message = bytes(200)
        var outcome: MessageTransport.Outcome?
        a.endpoint.send(message, delivery: .init(retryBudget: budget, redundancy: 0.4)) { outcome = $0 }
        a.advance(to: 0.01)
        a.drain(to: b, losing: [0, 3, 6])
        #expect(b.messages.isEmpty)
        b.advance(to: 0.02)
        b.drain(to: a)
        a.advance(to: 0.3)
        if budget == 0 {
            #expect(outcome == .expired && a.packets.isEmpty)
        } else {
            // Any one of the missing fragments completes the message.
            #expect(outcome == nil && !a.packets.isEmpty)
            a.drain(to: b)
            #expect(b.messages == [message])
            b.advance(to: 0.4)
            b.drain(to: a)
            #expect(outcome == .delivered)
        }
        a.advance(to: 3)
        b.advance(to: 3)
        #expect(a.packets.isEmpty && b.messages.count == (budget == 0 ? 0 : 1))
    }
}

@Test func singleDatagramIsRepeatedOnlyFromHalfRedundancy() {
    let clock = Clock()
    let a = Port(clock)
    let b = Port(clock)
    let message = bytes(10)
    a.endpoint.send(message, delivery: .init(redundancy: 0.3))
    #expect(a.packets.count == 1 && a.packets[0].first == 0)
    a.drain(to: b)

    a.endpoint.send(message, delivery: .init(redundancy: 0.5))
    #expect(a.packets.count == 2 && a.packets.allSatisfy { $0.first == 2 && $0.count == 27 })
    a.drain(to: b, losing: [0])
    a.endpoint.send(message, delivery: .init(redundancy: 1))
    a.drain(to: b)
    // Rebuilt from the repeat alone, and delivered once when both arrive.
    #expect(b.messages == [message, message, message])
}

@Test func repairFragmentsAreNotSentOnceTheMessageIsAcknowledged() {
    let clock = Clock()
    let a = Port(clock, mtu: 1200)
    var outcome: MessageTransport.Outcome?
    // Four data fragments and two for repair, paced 2.4 ms apart after a burst of two.
    a.endpoint.send(bytes(4700), delivery: .init(redundancy: 0.5)) { outcome = $0 }
    a.advance(to: 0.005)
    #expect(a.packets.count == 4)
    a.endpoint.handleEvent(.datagram(Wire.ack(4, 0b1111)))
    #expect(outcome == .delivered)
    a.advance(to: 1)
    #expect(a.packets.count == 4)
}

@Test func largeMessagesAndInvalidRedundancyAreSentUnprotected() {
    func firstKind(_ size: Int, _ redundancy: Double) -> UInt8? {
        let port = Port(Clock(), mtu: 1200)
        port.endpoint.send(Data(count: size), delivery: .init(redundancy: redundancy))
        return port.packets.first?.first
    }
    #expect(firstKind(3000, 0.5) == 2)
    // Too many fragments for one repair block.
    #expect(firstKind(1183 * Repair.maxData + 1, 0.5) == 1)
    #expect(firstKind(3000, -1) == 1)
    #expect(firstKind(3000, .nan) == 1)
    // An absurd share is capped at what the code can number.
    let port = Port(Clock())
    port.endpoint.send(Data(count: 100), delivery: .init(redundancy: .infinity))
    port.advance(to: 0.05)
    #expect(port.packets.count == 3 + Repair.maxRepair && port.packets.allSatisfy { $0.first == 2 })
}

/// Thirty messages a second of seven datagrams each, over a link losing one datagram in ten.
private func lossyRun(redundancy: Double) -> (delivered: Int, reported: Int, early: Double, late: Double) {
    let clock = Clock()
    let a = Port(clock, mtu: 1200)
    let b = Port(clock, mtu: 1200)
    var random = Random(state: 42)
    var reported = 0
    var early = 0.0
    for tick in 0..<10_500 {
        let now = Double(tick) / 1000
        a.advance(to: now)
        b.advance(to: now)
        if tick < 10_000, tick.isMultiple(of: 33) {
            a.endpoint.send(
                bytes(8000, seed: UInt64(tick)), delivery: .init(retryBudget: 0, redundancy: redundancy)
            ) { if $0 == .delivered { reported += 1 } }
        }
        let losing = Set(a.packets.indices.filter { _ in Double.random(in: 0..<1, using: &random) < 0.1 })
        a.drain(to: b, losing: losing)
        b.drain(to: a)
        if tick == 1000 { early = a.endpoint.statistics.linkLossRatio }
    }
    return (b.messages.count, reported, early, a.endpoint.statistics.linkLossRatio)
}

@Test func redundancyCarriesMessagesThroughRandomLoss() {
    let sent = 304
    let bare = lossyRun(redundancy: 0)
    // 0.9 to the seventh power: about half the messages lose a fragment.
    #expect(bare.delivered > sent * 38 / 100 && bare.delivered < sent * 58 / 100)
    #expect(bare.reported == bare.delivered)

    let protected = lossyRun(redundancy: 0.3)
    #expect(protected.delivered > sent * 90 / 100)
    #expect(protected.reported == protected.delivered)
    // Loss is only called the link's own once sending less has failed to remove it.
    #expect(protected.early <= 0.02)
    #expect(protected.late > 0.05 && protected.late < 0.2)
}
