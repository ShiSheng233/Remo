import Foundation
import Testing

@testable import RemoTransport

private final class Clock {
    var now = 0.0
}

private final class Port {
    let clock: Clock
    var deadline: Double?
    var writable = true
    var packets: [Data] = []
    var messages: [Data] = []
    var failures: [MessageTransport.Failure] = []
    let mtu: Int
    var onData: ((Data) -> Void)?

    init(_ clock: Clock, mtu: Int = 1200) {
        self.clock = clock
        self.mtu = mtu
    }

    lazy var endpoint = MessageTransport(
        datagramLimit: mtu, clock: { [clock] in clock.now },
        dataHandler: { [unowned self] bytes in
            messages.append(bytes)
            onData?(bytes)
        },
        ioHandler: { [unowned self] request in
            switch request {
            case .sendDatagram(let bytes):
                guard writable else { return false }
                packets.append(bytes)
            case .setTimer(let time): deadline = time
            case .close(let failure): failures.append(failure)
            }
            return true
        })!

    func drain(to other: Port) {
        let batch = packets
        packets.removeAll()
        for bytes in batch { other.endpoint.handleEvent(.datagram(bytes)) }
    }

    func advance(to time: Double) {
        while let deadline, deadline <= time {
            precondition(deadline >= clock.now)
            clock.now = deadline
            self.deadline = nil
            endpoint.handleEvent(.timer)
        }
        clock.now = time
    }
}

private func packet(
    _ number: UInt32, _ id: UInt32, _ value: UInt8,
    index: Int = 0, count: Int = 1, size: Int = 1, lifetime: Double = 0
) -> Data {
    Wire.data(
        number, .init(id: id, index: index), count, lifetime: lifetime,
        Data(repeating: value, count: size))
}

private func number(of datagram: Data) -> UInt32 {
    datagram.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self)) }
}

@Test func wireVectorsAndInvalidInput() {
    let port = Port(Clock(), mtu: 64)
    let vector = Data([0, 0, 0, 0, 1, 0, 0, 0, 1, 0xab])
    let ack = Data([0x80, 0, 0, 0, 82, 0, 0, 0, 0, 0, 0, 0, 5])
    #expect(Wire.ack(82, 5) == ack)
    let bad = [
        Data(), Data(vector.prefix(9)), Data([2]) + vector.dropFirst(), Data([3]) + vector.dropFirst(),
        packet(0, 1, 1), packet(1, 0, 1), packet(1, 1, 1, size: 56),
        Wire.ack(1, 3), Wire.ack(9, 2), ack + Data([0]), Data(ack.dropLast()),
        packet(99, 1, 1, index: 2, count: 2),
        packet(99, 1, 1, count: 2),
        packet(99, 1, 1, count: 65535, size: 49),
    ]
    for bytes in bad {
        #expect(Wire.decode(bytes, mtu: 64) == nil)
        port.endpoint.handleEvent(.datagram(bytes))
    }
    #expect(port.deadline == nil && port.packets.isEmpty && port.messages.isEmpty)
    #expect(port.endpoint.send(Data([0xab]), delivery: .untilDelivered()).id != nil)
    #expect(port.packets == [vector])
    let fragment = packet(7, 3, 0xcd, index: 1, count: 2, size: 9, lifetime: 1.234)
    #expect(fragment.prefix(15) == Data([1, 0, 0, 0, 7, 0, 0, 0, 3, 0, 1, 0, 2, 0, 124]))
    guard case .data(7, let key, 2, let lifetime, let payload)? = Wire.decode(fragment, mtu: 64) else {
        Issue.record("Fragment did not decode")
        return
    }
    #expect(key == Wire.Fragment(id: 3, index: 1) && lifetime == 1.24 && payload.count == 9)
    for (budget, expected) in [(Double.infinity, Double.infinity), (1e9, 655.34), (-1, 0)] {
        guard case .data(_, _, _, let decoded, _)? = Wire.decode(
            packet(7, 3, 0xcd, index: 1, count: 2, size: 9, lifetime: budget), mtu: 64)
        else {
            Issue.record("Fragment did not decode")
            continue
        }
        #expect(decoded == expected)
    }
    port.endpoint.handleEvent(.datagram(Wire.ack(2, 3)))
    port.advance(to: 0.101)
    #expect(port.packets.last == packet(2, 1, 0xab))
}

@Test func onlyFreshDeliveryConfirmationsSignalPeerActivity() {
    let port = Port(Clock())
    var confirmations = 0
    port.endpoint.onDeliveryConfirmed = { confirmations += 1 }
    port.endpoint.send(Data([1]), delivery: .init(retryBudget: 0))
    port.endpoint.send(Data([2]), delivery: .init(retryBudget: 0))
    port.advance(to: 3)
    port.endpoint.handleEvent(.datagram(Wire.ack(3, 1)))
    #expect(confirmations == 0)
    port.endpoint.handleEvent(.datagram(Wire.ack(2, 1)))
    port.endpoint.handleEvent(.datagram(Wire.ack(2, 1)))
    #expect(confirmations == 1)
    port.endpoint.handleEvent(.datagram(Wire.ack(2, 3)))
    port.endpoint.handleEvent(.datagram(Wire.ack(1, 1)))
    #expect(confirmations == 2)
}

@Test func unorderedFragmentRecovery() {
    let clock = Clock()
    let a = Port(clock, mtu: 64)
    let b = Port(clock, mtu: 64)
    let data = Data((0..<140).map(UInt8.init))
    a.endpoint.send(data, delivery: .init(retryBudget: 1))
    a.endpoint.send(Data([42]), delivery: .init(retryBudget: 0))
    a.advance(to: 0.004)
    let originals = a.packets
    #expect(originals.count == 4)
    for index in [2, 2, 3, 0] { b.endpoint.handleEvent(.datagram(originals[index])) }
    #expect(b.messages == [Data([42])])
    b.drain(to: a)
    a.packets.removeAll()
    a.advance(to: 0.12)
    #expect(a.packets.count == 1)
    a.drain(to: b)
    b.endpoint.handleEvent(.datagram(originals[1]))
    #expect(b.messages == [Data([42]), data])
}

@Test func retriedTailAndLateOriginalAck() {
    let clock = Clock()
    let a = Port(clock)
    let b = Port(clock)
    a.endpoint.send(Data([1]), delivery: .untilDelivered())
    a.drain(to: b)
    a.advance(to: 0.101)
    #expect(a.packets == [packet(2, 1, 1)])
    a.drain(to: b)
    #expect(b.messages == [Data([1])])
    a.endpoint.handleEvent(.datagram(b.packets[0]))
    a.endpoint.handleEvent(.datagram(b.packets[0]))
    a.advance(to: 3)
    #expect(a.packets.isEmpty && a.failures.isEmpty && a.deadline == nil)
}

@Test func unfinishedMessageHoldsLaterIDsInsideTheDuplicateWindow() {
    let clock = Clock()
    let a = Port(clock)
    let b = Port(clock)
    let stuck = Data([0xee])
    a.endpoint.send(stuck, delivery: .untilDelivered())
    var latestStuck = a.packets[0]
    a.packets.removeAll()
    // Every other message is delivered and acknowledged; the first one keeps getting lost.
    func exchange() {
        for bytes in a.packets {
            if bytes.last == 0xee {
                latestStuck = bytes
            } else {
                b.endpoint.handleEvent(.datagram(bytes))
                a.endpoint.handleEvent(.datagram(Wire.ack(number(of: bytes), 1)))
            }
        }
        a.packets.removeAll()
    }
    for _ in 1..<Int(Wire.messageWindow) {
        clock.now += 0.001
        a.endpoint.send(Data([1]))
        exchange()
    }
    #expect(b.messages.count == Int(Wire.messageWindow) - 1)
    // ID 1025 would push ID 1 out of the receiver's duplicate window, so it waits.
    clock.now += 0.001
    a.endpoint.send(Data([2]))
    exchange()
    #expect(b.messages.last == Data([1]))
    b.endpoint.handleEvent(.datagram(latestStuck))
    #expect(b.messages.last == stuck)
    a.endpoint.handleEvent(.datagram(Wire.ack(number(of: latestStuck), 1)))
    exchange()
    #expect(b.messages.last == Data([2]))
}

@Test func fastLossWithOldSelectiveAck() {
    let a = Port(Clock())
    for i in 1...5 { a.endpoint.send(Data([UInt8(i)]), delivery: .untilDelivered()) }
    a.endpoint.handleEvent(.datagram(Wire.ack(5, 1)))
    a.endpoint.handleEvent(.datagram(Wire.ack(4, 1)))
    a.endpoint.handleEvent(.datagram(Wire.ack(4, 1)))
    #expect(a.packets.count == 5)
    a.endpoint.handleEvent(.datagram(Wire.ack(3, 1)))
    #expect(a.packets.suffix(2) == [packet(6, 1, 1), packet(7, 2, 2)])
}

@Test func oldPacketOutsideBitmapCanRecover() {
    let clock = Clock()
    let a = Port(clock)
    let b = Port(clock)
    a.endpoint.send(Data([11]), delivery: .untilDelivered())
    a.drain(to: b)
    // The acknowledgement of the first transmission is lost.
    b.advance(to: 0.005)
    #expect(b.packets == [Wire.ack(1, 1)])
    b.packets.removeAll()
    for _ in 0..<70 {
        a.endpoint.send(Data([42]), delivery: .init(retryBudget: 0))
        a.drain(to: b)
    }
    a.advance(to: 0.101)
    #expect(a.packets == [packet(72, 1, 11)])
    a.drain(to: b)
    b.drain(to: a)
    a.advance(to: 3)
    #expect(b.messages.filter { $0 == Data([11]) }.count == 1)
    #expect(a.failures.isEmpty && a.packets.isEmpty)
}

@Test func blockedAdapterResumesAndClosedTransportIgnoresInput() {
    let a = Port(Clock())
    a.writable = false
    var outcomes: [MessageTransport.Outcome] = []
    a.endpoint.send(Data([1]), delivery: .untilDelivered()) { outcomes.append($0) }
    a.advance(to: 5)
    #expect(a.packets.isEmpty && a.failures.isEmpty && !a.endpoint.isClosed)
    a.writable = true
    a.endpoint.handleEvent(.writable)
    #expect(a.packets == [packet(1, 1, 1)])
    a.endpoint.handleEvent(.closed)
    #expect(a.endpoint.send(Data([2]), delivery: .untilDelivered()) == .closed)
    a.endpoint.handleEvent(.datagram(packet(1, 1, 2)))
    #expect(a.messages.isEmpty && a.deadline == nil && outcomes.isEmpty)
}

@Test func unreliableFirstAndRetryDeadlines() {
    let a = Port(Clock(), mtu: 64)
    a.writable = false
    a.endpoint.send(Data([1]), delivery: .init(retryBudget: 0))
    a.endpoint.send(Data([2]), delivery: .init(retryBudget: 1, firstSendDeadline: 0.05))
    a.advance(to: 0.1)
    a.writable = true
    a.endpoint.handleEvent(.writable)
    #expect(a.packets == [packet(1, 1, 1)])
    a.endpoint.send(Data([3]), delivery: .init(retryBudget: 0.3))
    a.writable = false
    a.advance(to: 0.5)
    a.writable = true
    a.endpoint.handleEvent(.writable)
    a.endpoint.send(Data([4]), delivery: .untilDelivered())
    #expect(a.packets.count == 3 && a.packets.last == packet(3, 4, 4))
}

@Test func reassemblyConflictsEvictionAndExpiry() {
    let b = Port(Clock(), mtu: 64)
    func fragment(_ number: UInt32, _ id: UInt32, _ index: Int, _ value: UInt8) {
        b.endpoint.handleEvent(
            .datagram(
                packet(
                    number, id, value,
                    index: index, count: 2, size: index == 0 ? 49 : 7)))
    }
    fragment(1, 1, 0, 8)
    fragment(2, 1, 0, 9)
    b.endpoint.handleEvent(.datagram(packet(3, 1, 10)))
    fragment(4, 1, 1, 7)
    #expect(b.messages == [Data(repeating: 8, count: 49) + Data(repeating: 7, count: 7)])
    #expect(b.packets.last == Wire.ack(4, 9))
    for id in 2...34 { fragment(UInt32(id + 4), UInt32(id), 0, 1) }
    fragment(40, 2, 1, 42)
    b.advance(to: 0.51)
    fragment(41, 34, 1, 42)
    b.endpoint.handleEvent(.datagram(packet(42, 2048, 7)))
    b.endpoint.handleEvent(.datagram(packet(43, 1024, 9)))
    #expect(b.messages.count == 2 && b.messages.last == Data([7]))
}

@Test func admissionLimits() {
    let a = Port(Clock(), mtu: 64)
    a.writable = false
    #expect(a.endpoint.send(Data()) == .invalidLength)
    #expect(a.endpoint.send(Data(count: (1 << 20) + 1)) == .invalidLength)
    #expect(a.endpoint.send(Data([1]), delivery: .init(retryBudget: -1)) == .invalidTime)
    #expect(a.endpoint.send(Data([1]), delivery: .init(retryBudget: .nan)) == .invalidTime)
    #expect(a.endpoint.send(Data([1]), delivery: .init(firstSendDeadline: .infinity)) == .invalidTime)
    let large = Data(count: 1 << 20)
    for _ in 0..<4 { #expect(a.endpoint.send(large).id != nil) }
    #expect(a.endpoint.send(Data([0]), delivery: .untilDelivered()) == .backpressure)

    let b = Port(Clock(), mtu: 64)
    b.writable = false
    for _ in 0..<256 { #expect(b.endpoint.send(Data([1]), delivery: .untilDelivered()).id != nil) }
    #expect(b.endpoint.send(Data([2]), delivery: .untilDelivered()) == .backpressure)
    b.writable = true
    b.endpoint.handleEvent(.writable)
    #expect(b.packets.first == packet(1, 1, 1))
}

@Test func reentrantReplyAndSessionIsolation() {
    let clock = Clock()
    let payload = Data([8])
    let old = Port(clock)
    let peer = Port(clock)
    peer.onData = { [unowned peer] bytes in peer.endpoint.send(bytes, delivery: .untilDelivered()) }
    old.endpoint.send(payload, delivery: .untilDelivered())
    let delayed = old.packets[0]
    old.drain(to: peer)
    peer.drain(to: old)
    #expect(old.messages == [payload] && peer.messages == [payload])
    old.endpoint.handleEvent(.closed)
    old.endpoint.handleEvent(.datagram(delayed))
    let fresh = Port(clock)
    fresh.endpoint.send(payload, delivery: .untilDelivered())
    #expect(fresh.packets == [delayed] && old.messages == [payload])
}

@Test func serializedFiveMegabitLink() {
    let clock = Clock()
    let a = Port(clock)
    let b = Port(clock)
    let frame = Data((0..<160_000).map { UInt8(truncatingIfNeeded: $0) })
    let control = Data([0xab])
    var arrivals: [(time: Double, packet: Data, destination: Port)] = []
    var sentKinds: [UInt8] = []
    var forwardFree = 0.0
    var reverseFree = 0.0
    func schedule(_ source: Port, _ destination: Port, free: inout Double) {
        for bytes in source.packets {
            free = max(clock.now, free) + Double(bytes.count) * 8 / 5_000_000
            arrivals.append((free + 0.002, bytes, destination))
            if source === a { sentKinds.append(bytes[bytes.startIndex]) }
        }
        source.packets.removeAll()
    }
    a.endpoint.send(frame, delivery: .init(retryBudget: 0))
    var submit = 0.02
    var insertion = 0
    for _ in 0..<5000 {
        schedule(a, b, free: &forwardFree)
        schedule(b, a, free: &reverseFree)
        let nextArrival = arrivals.map(\.time).min() ?? .infinity
        let next = min(submit, nextArrival, a.deadline ?? .infinity, b.deadline ?? .infinity)
        if !next.isFinite { break }
        clock.now = next
        if next == submit {
            insertion = sentKinds.count
            a.endpoint.send(control, delivery: .untilDelivered(priority: .high))
            submit = .infinity
        }
        for port in [a, b] where port.deadline == next {
            port.deadline = nil
            port.endpoint.handleEvent(.timer)
        }
        let ready = arrivals.filter { $0.time <= next }
        arrivals.removeAll { $0.time <= next }
        for item in ready { item.destination.endpoint.handleEvent(.datagram(item.packet)) }
    }
    #expect(sentKinds.firstIndex(of: 0) == insertion)
    #expect(insertion > 0 && insertion < sentKinds.count - 1)
    #expect(b.messages == [control, frame])
    // One short burst does not establish a sustained delivery rate.
    #expect(a.endpoint.statistics.bitsPerSecond == 4_000_000)
    #expect(a.deadline == nil && b.deadline == nil && arrivals.isEmpty)
}

@Test func pacingDropsExpiredRetry() {
    let a = Port(Clock())
    let payload = Data(repeating: 1, count: 1191)
    a.endpoint.send(payload, delivery: .init(retryBudget: 0.153))
    a.advance(to: 0.09999)
    for _ in 0..<2 { a.endpoint.send(payload, delivery: .init(retryBudget: 0)) }
    a.advance(to: 0.10001)
    #expect(a.packets.count == 3)
    #expect(a.endpoint.statistics.estimatedQueueDelay > 0)
    a.advance(to: 0.16)
    #expect(a.packets.count == 3)
    a.endpoint.send(Data([7]), delivery: .untilDelivered())
    #expect(a.packets.last == packet(4, 4, 7))
}

@Test func blackHoleProbeAndRecovery() {
    let a = Port(Clock())
    let data = Data(repeating: 1, count: 1191)
    a.endpoint.send(data, delivery: .untilDelivered())
    a.advance(to: 0.201)
    let before = a.packets.count
    for _ in 0..<20 { a.endpoint.send(data, delivery: .init(retryBudget: 0)) }
    #expect(a.packets.count == before + 1)
    a.advance(to: 0.29)
    #expect(a.packets.count == before + 1)
    #expect(a.endpoint.statistics.bitsPerSecond < 4_000_000)
    a.endpoint.handleEvent(.datagram(Wire.ack(1, 1)))
    a.advance(to: 0.31)
    #expect(a.packets.count > before + 2)
}

@Test func delayedAckThresholdAndNoAckLoop() {
    let a = Port(Clock())
    for i in 1...7 {
        a.endpoint.handleEvent(.datagram(packet(UInt32(i), UInt32(i), 1)))
    }
    #expect(a.packets.isEmpty && a.deadline == 0.005)
    a.endpoint.handleEvent(.datagram(packet(8, 8, 1)))
    #expect(a.packets == [Wire.ack(8, 255)] && a.deadline == nil)
    a.endpoint.handleEvent(.datagram(packet(9, 9, 1)))
    a.advance(to: 0.005)
    #expect(a.packets.last == Wire.ack(9, 511))
    let b = Port(a.clock)
    a.drain(to: b)
    #expect(b.packets.isEmpty && b.deadline == nil)
}

@Test func allFirstTransmissionsLost() {
    let clock = Clock()
    let a = Port(clock, mtu: 64)
    let b = Port(clock, mtu: 64)
    let payload = Data(repeating: 0xa5, count: 90)
    a.endpoint.send(payload, delivery: .init(retryBudget: 1))
    #expect(a.packets.count == 2)
    a.packets.removeAll()
    a.advance(to: 0.101)
    #expect(a.packets.count == 2)
    a.drain(to: b)
    #expect(b.messages == [payload])
    b.advance(to: 0.11)
    b.drain(to: a)
    a.advance(to: 1.1)
    #expect(a.packets.isEmpty && a.deadline == nil)
}

@Test func unlimitedBudgetRetriesWithBackoffUntilAcknowledged() {
    let clock = Clock()
    let sender = Port(clock)
    let peer = Port(clock)
    var outcomes: [MessageTransport.Outcome] = []
    sender.endpoint.send(Data([7]), delivery: .untilDelivered()) { outcomes.append($0) }
    sender.drain(to: peer)
    var retransmissions: [Double] = []
    while let wake = sender.deadline, wake < 6 {
        sender.advance(to: wake)
        if !sender.packets.isEmpty { retransmissions.append(clock.now) }
        sender.drain(to: peer)
        peer.packets.removeAll()
    }
    #expect(peer.messages == [Data([7])])
    #expect(sender.failures.isEmpty && !sender.endpoint.isClosed && outcomes.isEmpty)
    // Retries back off, but never further than half a second apart.
    #expect(retransmissions.count >= 10 && retransmissions.count <= 16)
    #expect(zip(retransmissions, retransmissions.dropFirst()).allSatisfy { $1 - $0 <= 0.5 + 1e-9 })
    #expect(retransmissions[1] - retransmissions[0] > retransmissions[0])
    sender.advance(to: sender.deadline!)
    sender.drain(to: peer)
    peer.drain(to: sender)
    #expect(outcomes == [.delivered] && sender.deadline == nil)
}

@Test func outcomesReportDeliveryExpiryAndCancellation() {
    let clock = Clock()
    let a = Port(clock, mtu: 64)
    let b = Port(clock, mtu: 64)
    var outcomes: [String: MessageTransport.Outcome] = [:]
    func send(_ name: String, _ data: Data, _ delivery: MessageTransport.Delivery = .init())
        -> MessageTransport.MessageID?
    {
        a.endpoint.send(data, delivery: delivery) { outcome in
            #expect(outcomes[name] == nil)
            outcomes[name] = outcome
        }.id
    }
    // Delivered: both fragments are acknowledged, one only after a retransmission.
    _ = send("delivered", Data(count: 90), .init(retryBudget: 1))
    a.packets.removeFirst()
    a.drain(to: b)
    a.advance(to: 0.101)
    a.drain(to: b)
    b.drain(to: a)
    #expect(outcomes == ["delivered": .delivered] && b.messages.count == 1)

    // Expired: the retry budget ends with a fragment still missing.
    _ = send("lost", Data(count: 90), .init(retryBudget: 0.05))
    a.packets.removeFirst()
    a.drain(to: b)
    b.drain(to: a)
    // The verdict waits for the missing fragment's transmission to time out.
    a.advance(to: 0.15)
    #expect(outcomes["lost"] == nil)
    a.advance(to: 0.7)
    #expect(outcomes["lost"] == .expired && a.packets.isEmpty)

    // Expired: nothing could be sent before the first-send deadline.
    a.writable = false
    _ = send("late", Data([1]), .init(retryBudget: 1, firstSendDeadline: 0.71))
    a.advance(to: 0.72)
    #expect(outcomes["late"] == .expired)

    // Cancelled: queued fragments are never sent and the message is not retransmitted.
    let cancelled = send("cancelled", Data(count: 500), .untilDelivered())
    let untouched = send("untouched", Data([2]), .untilDelivered())
    a.endpoint.cancelMessage(cancelled!)
    a.endpoint.cancelMessage(cancelled!)
    #expect(outcomes["cancelled"] == .cancelled)
    a.writable = true
    a.endpoint.handleEvent(.writable)
    #expect(a.packets.count == 1)
    a.drain(to: b)
    b.advance(to: 0.73)
    b.drain(to: a)
    #expect(outcomes["untouched"] == .delivered && untouched != cancelled)
    #expect(outcomes.count == 5 && b.messages.last == Data([2]))
    a.advance(to: 3)
    #expect(a.packets.isEmpty && a.deadline == nil)
}

@Test func replacingKeyKeepsOnlyTheNewestMessage() {
    let clock = Clock()
    let a = Port(clock)
    let b = Port(clock)
    var outcomes: [MessageTransport.Outcome] = []
    a.writable = false
    for value: UInt8 in 1...3 {
        a.endpoint.send(Data([value]), delivery: .untilDelivered(replacing: 7)) { outcomes.append($0) }
    }
    a.endpoint.send(Data([9]), delivery: .untilDelivered(replacing: 8))
    #expect(outcomes == [.cancelled, .cancelled])
    a.writable = true
    a.endpoint.handleEvent(.writable)
    a.drain(to: b)
    #expect(b.messages == [Data([3]), Data([9])])
    // A sent message stops being retransmitted once it is replaced.
    a.endpoint.send(Data([4]), delivery: .untilDelivered(replacing: 7))
    a.packets.removeAll()
    a.advance(to: 1)
    #expect(a.packets.contains { $0.last == 4 } && !a.packets.contains { $0.last == 3 })
    #expect(outcomes == [.cancelled, .cancelled, .cancelled])
}

@Test func outcomeHandlersMaySendAndCancel() {
    let clock = Clock()
    let a = Port(clock)
    let b = Port(clock)
    var log: [String] = []
    var second: MessageTransport.MessageID?
    a.writable = false
    let first = a.endpoint.send(Data([1]), delivery: .untilDelivered()) { outcome in
        log.append("first \(outcome)")
        a.endpoint.cancelMessage(second!)
        a.endpoint.send(Data([3]), delivery: .untilDelivered()) { log.append("third \($0)") }
    }.id
    second = a.endpoint.send(Data([2]), delivery: .untilDelivered()) { log.append("second \($0)") }.id
    a.endpoint.cancelMessage(first!)
    #expect(log == ["first cancelled", "second cancelled"])
    a.writable = true
    a.endpoint.handleEvent(.writable)
    a.drain(to: b)
    b.advance(to: 0.005)
    b.drain(to: a)
    #expect(b.messages == [Data([3])] && log.last == "third delivered")
}

@Test func partialMessagesLiveAsLongAsTheSenderRetries() {
    let b = Port(Clock(), mtu: 64)
    func fragment(_ number: UInt32, _ id: UInt32, _ index: Int, lifetime: Double) {
        b.endpoint.handleEvent(.datagram(packet(
            number, id, UInt8(id), index: index, count: 2, size: index == 0 ? 49 : 7, lifetime: lifetime)))
    }
    // A slow or long-lived message outlasts the half-second grace of a one-shot message.
    fragment(1, 1, 0, lifetime: 3)
    fragment(2, 2, 0, lifetime: 0)
    fragment(3, 3, 0, lifetime: .infinity)
    b.advance(to: 3.4)
    fragment(4, 1, 1, lifetime: 0)
    fragment(5, 2, 1, lifetime: 0)
    #expect(b.messages.map(\.first) == [1])
    b.advance(to: 100)
    #expect(b.deadline == nil)
    fragment(6, 3, 1, lifetime: .infinity)
    #expect(b.messages.map(\.first) == [1, 3])

    // With every slot held by a message still being retried, a new one is refused rather
    // than acknowledged and dropped, so its sender tries again.
    for id in 10..<42 { fragment(UInt32(id), UInt32(id), 0, lifetime: 2) }
    b.advance(to: 100.01)
    b.packets.removeAll()
    fragment(50, 50, 0, lifetime: 2)
    b.advance(to: 100.1)
    #expect(b.packets.isEmpty)
    b.advance(to: 102.01)
    fragment(51, 50, 0, lifetime: 2)
    fragment(52, 50, 1, lifetime: 2)
    #expect(b.messages.map(\.first) == [1, 3, 50])
    fragment(53, 10, 1, lifetime: 2)
    #expect(b.messages.count == 3)
}

@Test func aggregateReassemblyByteLimit() {
    var receiver = Receiver()
    let capacity = 1185
    let count = 800
    let chunk = Data(repeating: 0x7f, count: capacity)
    for id: UInt32 in 1...5 {
        for index in 0..<(count - 1) {
            let key = Wire.Fragment(id: id, index: index)
            let (_, _, message) = receiver.accept(
                key, count: count, lifetime: 0, data: chunk, now: Double(id) / 1000)
            #expect(message == nil)
        }
    }
    let tail = Data([0x80])
    for id: UInt32 in 1...5 {
        let key = Wire.Fragment(id: id, index: count - 1)
        let (_, _, message) = receiver.accept(key, count: count, lifetime: 0, data: tail, now: 0.01)
        if id == 1 {
            #expect(message == nil)
        } else {
            #expect(message?.count == capacity * (count - 1) + 1 && message?.last == 0x80)
        }
    }
}

@Test func sparseAcknowledgementsDoNotRatchetDownTheSendingBudget() {
    let endpoint = Port(Clock())
    endpoint.endpoint.send(Data([1]), delivery: .untilDelivered())
    endpoint.advance(to: 0.005)
    endpoint.endpoint.handleEvent(.datagram(Wire.ack(1, 1)))
    for i in 1...12 {
        endpoint.advance(to: Double(i))
        endpoint.endpoint.send(Data([1]), delivery: .untilDelivered())
        let packet = UInt32(endpoint.packets.count)
        endpoint.advance(to: Double(i) + 0.105)
        endpoint.endpoint.handleEvent(.datagram(Wire.ack(packet, 1)))
    }
    #expect(endpoint.endpoint.statistics.bitsPerSecond == 4_000_000)
}

@Test(arguments: [false, true])
func sparseACKsCannotRestoreAnUnverifiedBudgetAfterBackoff(lateACKs: Bool) throws {
    let port = Port(Clock())
    func acknowledgeLatest() throws {
        let bytes = try #require(port.packets.last)
        let number = bytes.withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self))
        }
        let bitmap = UInt64.max >> (64 - min(64, Int(number)))
        port.endpoint.handleEvent(.datagram(Wire.ack(number, bitmap)))
    }
    let full = Data(count: 1191)
    for _ in 0..<16 {
        port.endpoint.send(full, delivery: .untilDelivered())
        for _ in 0..<6 { port.endpoint.send(full, delivery: .init(retryBudget: 0.4)) }
        port.advance(to: port.clock.now + 0.25)
        for _ in 0..<3 { port.endpoint.send(full, delivery: .init(retryBudget: 0)) }
        for _ in 0..<30 {
            try acknowledgeLatest()
            port.advance(to: port.clock.now + 0.01)
        }
    }
    for _ in 0..<1000 {
        if port.deadline == nil { break }
        try acknowledgeLatest()
        port.advance(to: port.clock.now + 0.01)
    }
    try #require(port.deadline == nil && !port.endpoint.isClosed)
    let reduced = port.endpoint.statistics.bitsPerSecond
    try #require(reduced < 300_000)
    port.advance(to: port.clock.now + 20)
    #expect(port.endpoint.statistics.bitsPerSecond == reduced)
    if lateACKs {
        // Original DATA arrives, but one ACK in each burst arrives after the RTO.
        for i in 0..<2400 {
            port.endpoint.send(Data([1]), delivery: .init(retryBudget: 0))
            port.advance(to: port.clock.now + (i.isMultiple(of: 8) ? 0.095 : 0.005))
            try acknowledgeLatest()
            port.advance(to: port.clock.now + 0.025)
        }
    } else {
        // A mostly static desktop has one small frame per half second and no pacing backlog.
        for _ in 0..<240 {
            port.endpoint.send(Data([1]), delivery: .untilDelivered())
            port.advance(to: port.clock.now + 0.01)
            try acknowledgeLatest()
            port.advance(to: port.clock.now + 0.49)
        }
    }
    #expect(port.endpoint.statistics.estimatedQueueDelay == 0)
    #expect(port.endpoint.statistics.bitsPerSecond == reduced)
}

@Test func persistentPacketLossCutsRateWhileOtherPacketsAreAcknowledged() {
    let port = Port(Clock())
    let original = port.endpoint.statistics.bitsPerSecond
    let full = Data(count: 1191)
    var inspected = 0
    for _ in 0..<500 {
        port.endpoint.send(full, delivery: .init(retryBudget: 0))
        port.advance(to: port.clock.now + 0.0025)
        for bytes in port.packets.dropFirst(inspected) {
            let packet = bytes.withUnsafeBytes {
                UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self))
            }
            if !packet.isMultiple(of: 4) {
                port.endpoint.handleEvent(.datagram(Wire.ack(packet, 1)))
            }
        }
        inspected = port.packets.count
    }
    #expect(port.endpoint.statistics.bitsPerSecond < original)
    #expect(!port.endpoint.isClosed)
}

@Test func highPriorityAudioPreemptsVideoAtFragmentBoundaries() {
    let sender = Port(Clock())
    let receiver = Port(sender.clock)
    let video = Data(repeating: 7, count: 12_000)
    let normal = Data([8])
    let firstAudio = Data(repeating: 9, count: 120)
    let secondAudio = Data(repeating: 10, count: 120)
    let control = Data([11])

    sender.endpoint.send(video, delivery: .init(retryBudget: 0))
    #expect(sender.packets.count == 2)
    sender.endpoint.send(normal, delivery: .init(retryBudget: 0))
    for audio in [firstAudio, secondAudio] {
        sender.endpoint.send(audio, delivery: .init(retryBudget: 0, priority: .high))
    }
    sender.endpoint.send(control, delivery: .untilDelivered(priority: .high))
    #expect(sender.packets.count == 2)
    sender.advance(to: 0.04)
    sender.drain(to: receiver)
    #expect(receiver.messages == [firstAudio, secondAudio, control, video, normal])
}

@Test func firstSendExpiryCountsOnlyAdmittedMessagesWithNoAcceptedDatagram() {
    let sender = Port(Clock())
    sender.writable = false
    let high = MessageTransport.Delivery(retryBudget: 0, firstSendDeadline: 0.01, priority: .high)
    let normal = MessageTransport.Delivery(retryBudget: 0, firstSendDeadline: 0.01)
    for delivery in [high, normal, high] {
        #expect(sender.endpoint.send(Data([1]), delivery: delivery).id != nil)
    }
    sender.advance(to: 0.01)
    #expect(sender.endpoint.send(Data([2]), delivery: high) == .invalidTime)
    sender.writable = true
    sender.endpoint.handleEvent(.writable)
    #expect(sender.packets.isEmpty)

    sender.endpoint.send(Data([3]), delivery: .init(retryBudget: 0, firstSendDeadline: 0.02, priority: .high))
    sender.endpoint.send(Data(count: 12_000), delivery: .init(retryBudget: 0, firstSendDeadline: 0.01001))
    #expect(sender.packets.count == 2)
    sender.advance(to: 0.04)
    #expect(sender.packets.count == 2)
    #expect(sender.endpoint.statistics.expiredBeforeFirstSend == [.high: 2, .normal: 1])
}
