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
        dataHandler: { [unowned self] _, bytes in
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
    _ number: UInt32, _ id: UInt32, _ value: UInt8, reliable: Bool = true,
    index: Int = 0, count: Int = 1, size: Int = 1
) -> Data {
    Wire.data(
        number, .init(reliable: reliable, id: id, index: index), count,
        Data(repeating: value, count: size))
}

@Test func wireVectorsAndInvalidInput() {
    let port = Port(Clock(), mtu: 64)
    let vector = Data([2, 0, 0, 0, 1, 0, 0, 0, 1, 0xab])
    let ack = Data([0x80, 0, 0, 0, 82, 0, 0, 0, 0, 0, 0, 0, 5])
    #expect(Wire.ack(82, 5) == ack)
    let bad = [
        Data(), Data(vector.prefix(9)), Data([3]) + vector.dropFirst(),
        packet(0, 1, 1), packet(1, 0, 1), packet(1, 1, 1, size: 56),
        Wire.ack(1, 3), Wire.ack(9, 2), ack + Data([0]), Data(ack.dropLast()),
        packet(99, 1, 1, reliable: false, index: 2, count: 2),
        packet(99, 1, 1, reliable: false, count: 2),
        packet(99, 1, 1, reliable: false, count: 65535, size: 51),
    ]
    for bytes in bad {
        #expect(Wire.decode(bytes, mtu: 64) == nil)
        port.endpoint.handleEvent(.datagram(bytes))
    }
    #expect(port.deadline == nil && port.packets.isEmpty && port.messages.isEmpty)
    #expect(port.endpoint.send(Data([0xab]), mode: .reliable) == .queued)
    #expect(port.packets == [vector])
    port.endpoint.handleEvent(.datagram(Wire.ack(2, 3)))
    port.advance(to: 0.101)
    #expect(port.packets.last == packet(2, 1, 0xab))
}

@Test func onlyFreshDeliveryConfirmationsSignalPeerActivity() {
    let port = Port(Clock())
    var confirmations = 0
    port.endpoint.onDeliveryConfirmed = { confirmations += 1 }
    port.endpoint.send(Data([1]), mode: .unreliable(retryBudget: 0))
    port.endpoint.send(Data([2]), mode: .unreliable(retryBudget: 0))
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
    a.endpoint.send(data, mode: .unreliable(retryBudget: 1))
    a.endpoint.send(Data([42]), mode: .unreliable(retryBudget: 0))
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

@Test func reliableTailAndLateOriginalAck() {
    let clock = Clock()
    let a = Port(clock)
    let b = Port(clock)
    a.endpoint.send(Data([1]), mode: .reliable)
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

@Test func protectedWindowAndPausedDelivery() {
    let clock = Clock()
    let a = Port(clock)
    let b = Port(clock)
    b.endpoint.setReliableDeliveryPaused(true)
    for i in 1...35 { a.endpoint.send(Data([UInt8(i)]), mode: .reliable) }
    #expect(a.packets.count == 32)
    let first = a.packets.removeFirst()
    a.drain(to: b)
    b.drain(to: a)
    #expect(a.packets == [packet(33, 1, 1)])
    a.packets.removeAll()
    b.endpoint.handleEvent(.datagram(first))
    b.drain(to: a)
    #expect(a.packets.count == 3)
    a.drain(to: b)
    #expect(b.packets.isEmpty && b.messages.isEmpty)
    b.endpoint.handleEvent(.datagram(packet(100, 1, 99, reliable: false)))
    #expect(b.messages == [Data([99])])
    b.endpoint.setReliableDeliveryPaused(false)
    #expect(Array(b.messages.dropFirst()) == (1...32).map { Data([UInt8($0)]) })
    a.advance(to: 0.15)
    a.drain(to: b)
    #expect(b.messages.suffix(3) == [Data([33]), Data([34]), Data([35])])
}

@Test func fastLossWithOldSelectiveAck() {
    let a = Port(Clock())
    for i in 1...5 { a.endpoint.send(Data([UInt8(i)]), mode: .reliable) }
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
    a.endpoint.send(Data([11]), mode: .reliable)
    a.drain(to: b)
    b.packets.removeAll()
    for _ in 0..<70 {
        a.endpoint.send(Data([42]), mode: .unreliable(retryBudget: 0))
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

@Test func blockedAdapterAndSessionFailure() {
    let a = Port(Clock())
    a.writable = false
    a.endpoint.send(Data([1]), mode: .reliable)
    a.advance(to: 1.85)
    #expect(a.packets.isEmpty)
    a.writable = true
    a.endpoint.handleEvent(.writable)
    #expect(a.packets == [packet(1, 1, 1)])
    a.advance(to: 2)
    #expect(a.failures == [.reliableDeadline(
        firstByte: 1, sequence: 1, firstSent: true, retransmissions: a.packets.count - 1)])
    #expect(a.endpoint.send(Data([2]), mode: .reliable) == .closed)
    a.endpoint.handleEvent(.datagram(packet(1, 1, 2)))
    #expect(a.messages.isEmpty && a.deadline == nil)
}

@Test func reliableDeadlineReportsOldestUnsentMessage() {
    let sender = Port(Clock())
    sender.writable = false
    sender.endpoint.send(Data([0x41]), mode: .reliable)
    sender.endpoint.send(Data([0x42]), mode: .reliable)
    sender.advance(to: 2)
    #expect(sender.failures == [.reliableDeadline(
        firstByte: 0x41, sequence: 1, firstSent: false, retransmissions: 0)])
}

@Test func unreliableFirstAndRetryDeadlines() {
    let a = Port(Clock(), mtu: 64)
    a.writable = false
    a.endpoint.send(Data([1]), mode: .unreliable(retryBudget: 0))
    a.endpoint.send(Data([2]), mode: .unreliable(retryBudget: 1, firstSendDeadline: 0.05))
    a.advance(to: 0.1)
    a.writable = true
    a.endpoint.handleEvent(.writable)
    #expect(a.packets == [packet(1, 1, 1, reliable: false)])
    a.endpoint.send(Data([3]), mode: .unreliable(retryBudget: 0.3))
    a.writable = false
    a.advance(to: 0.5)
    a.writable = true
    a.endpoint.handleEvent(.writable)
    a.endpoint.send(Data([4]), mode: .reliable)
    #expect(a.packets.count == 3 && a.packets.last == packet(3, 1, 4))
}

@Test func reassemblyConflictsEvictionAndExpiry() {
    let b = Port(Clock(), mtu: 64)
    func fragment(_ number: UInt32, _ id: UInt32, _ index: Int, _ value: UInt8) {
        b.endpoint.handleEvent(
            .datagram(
                packet(
                    number, id, value, reliable: false,
                    index: index, count: 2, size: index == 0 ? 51 : 5)))
    }
    fragment(1, 1, 0, 8)
    fragment(2, 1, 0, 9)
    b.endpoint.handleEvent(.datagram(packet(3, 1, 10, reliable: false)))
    fragment(4, 1, 1, 7)
    #expect(b.messages == [Data(repeating: 8, count: 51) + Data(repeating: 7, count: 5)])
    #expect(b.packets.last == Wire.ack(4, 9))
    for id in 2...34 { fragment(UInt32(id + 4), UInt32(id), 0, 1) }
    fragment(40, 2, 1, 42)
    b.advance(to: 0.51)
    fragment(41, 34, 1, 42)
    b.endpoint.handleEvent(.datagram(packet(42, 2048, 7, reliable: false)))
    b.endpoint.handleEvent(.datagram(packet(43, 1024, 9, reliable: false)))
    #expect(b.messages.count == 2 && b.messages.last == Data([7]))
}

@Test func admissionAndQueueIsolation() {
    let a = Port(Clock(), mtu: 64)
    a.writable = false
    #expect(a.endpoint.send(Data(), mode: .reliable) == .invalidLength)
    #expect(a.endpoint.send(Data(count: 56), mode: .reliable) == .invalidLength)
    #expect(
        a.endpoint.send(Data(count: (1 << 20) + 1), mode: .unreliable(retryBudget: 0))
            == .invalidLength
    )
    let large = Data(count: 1 << 20)
    for _ in 0..<4 { #expect(a.endpoint.send(large, mode: .unreliable(retryBudget: 0)) == .queued) }
    #expect(a.endpoint.send(Data([0]), mode: .unreliable(retryBudget: 0)) == .backpressure)
    for _ in 0..<256 { #expect(a.endpoint.send(Data([1]), mode: .reliable) == .queued) }
    #expect(a.endpoint.send(Data([2]), mode: .reliable) == .backpressure)
    a.writable = true
    a.endpoint.handleEvent(.writable)
    #expect(a.packets.first == packet(1, 1, 1))
}

@Test func reentrantReplyAndSessionIsolation() {
    let clock = Clock()
    let payload = Data([8])
    let old = Port(clock)
    let peer = Port(clock)
    peer.onData = { [unowned peer] bytes in peer.endpoint.send(bytes, mode: .reliable) }
    old.endpoint.send(payload, mode: .reliable)
    let delayed = old.packets[0]
    old.drain(to: peer)
    peer.drain(to: old)
    #expect(old.messages == [payload] && peer.messages == [payload])
    old.endpoint.handleEvent(.closed)
    old.endpoint.handleEvent(.datagram(delayed))
    let fresh = Port(clock)
    fresh.endpoint.send(payload, mode: .reliable)
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
    a.endpoint.send(frame, mode: .unreliable(retryBudget: 0))
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
            a.endpoint.send(control, mode: .reliable)
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
    #expect(sentKinds.firstIndex(of: 2) == insertion)
    #expect(insertion > 0 && insertion < sentKinds.count - 1)
    #expect(b.messages == [control, frame])
    // One short burst does not establish a sustained delivery rate.
    #expect(a.endpoint.statistics.bitsPerSecond == 4_000_000)
    #expect(a.deadline == nil && b.deadline == nil && arrivals.isEmpty)
}

@Test func pacingDropsExpiredRetry() {
    let a = Port(Clock())
    let payload = Data(repeating: 1, count: 1191)
    a.endpoint.send(payload, mode: .unreliable(retryBudget: 0.153))
    a.advance(to: 0.09999)
    for _ in 0..<2 { a.endpoint.send(payload, mode: .unreliable(retryBudget: 0)) }
    a.advance(to: 0.10001)
    #expect(a.packets.count == 3)
    #expect(a.endpoint.statistics.estimatedQueueDelay > 0)
    a.advance(to: 0.16)
    #expect(a.packets.count == 3)
    a.endpoint.send(Data([7]), mode: .reliable)
    #expect(a.packets.last == packet(4, 1, 7))
}

@Test func blackHoleProbeAndRecovery() {
    let a = Port(Clock())
    let data = Data(repeating: 1, count: 1191)
    a.endpoint.send(data, mode: .reliable)
    a.advance(to: 0.201)
    let before = a.packets.count
    for _ in 0..<20 { a.endpoint.send(data, mode: .unreliable(retryBudget: 0)) }
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
        a.endpoint.handleEvent(.datagram(packet(UInt32(i), UInt32(i), 1, reliable: false)))
    }
    #expect(a.packets.isEmpty && a.deadline == 0.005)
    a.endpoint.handleEvent(.datagram(packet(8, 8, 1, reliable: false)))
    #expect(a.packets == [Wire.ack(8, 255)] && a.deadline == nil)
    a.endpoint.handleEvent(.datagram(packet(9, 9, 1, reliable: false)))
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
    a.endpoint.send(payload, mode: .unreliable(retryBudget: 1))
    #expect(a.packets.count == 2)
    a.packets.removeAll()
    a.advance(to: 0.101)
    #expect(a.packets.count == 2)
    a.drain(to: b)
    #expect(b.messages == [payload])
    a.advance(to: 1.1)
    #expect(a.packets.isEmpty && a.deadline == nil)
}

@Test func reliableAckBlackHoleFailsWholeSession() {
    let clock = Clock()
    let sender = Port(clock)
    let peer = Port(clock)
    sender.endpoint.send(Data([7]), mode: .reliable)
    sender.drain(to: peer)
    var retransmissions = 0
    while let wake = sender.deadline, wake < 2 {
        sender.advance(to: wake)
        retransmissions += sender.packets.count
        sender.drain(to: peer)
        peer.packets.removeAll()
    }
    sender.advance(to: 2)
    #expect(peer.messages == [Data([7])])
    #expect(retransmissions > 0)
    #expect(sender.failures == [.reliableDeadline(
        firstByte: 7, sequence: 1, firstSent: true, retransmissions: retransmissions)])
    #expect(sender.deadline == nil)
    peer.endpoint.handleEvent(.closed)
    peer.endpoint.handleEvent(.datagram(packet(100, 2, 9)))
    #expect(peer.messages == [Data([7])])
}

@Test func aggregateReassemblyByteLimit() {
    var receiver = Receiver()
    let capacity = 1187
    let count = 800
    let chunk = Data(repeating: 0x7f, count: capacity)
    for id: UInt32 in 1...5 {
        for index in 0..<(count - 1) {
            let key = Wire.Fragment(reliable: false, id: id, index: index)
            let (_, _, message) = receiver.accept(
                key, count: count, data: chunk, now: Double(id) / 1000)
            #expect(message == nil)
        }
    }
    let tail = Data([0x80])
    for id: UInt32 in 1...5 {
        let key = Wire.Fragment(reliable: false, id: id, index: count - 1)
        let (_, _, message) = receiver.accept(key, count: count, data: tail, now: 0.01)
        if id == 1 {
            #expect(message == nil)
        } else {
            #expect(message?.count == capacity * (count - 1) + 1 && message?.last == 0x80)
        }
    }
}

@Test func sparseAcknowledgementsDoNotRatchetDownTheSendingBudget() {
    let endpoint = Port(Clock())
    endpoint.endpoint.send(Data([1]), mode: .reliable)
    endpoint.advance(to: 0.005)
    endpoint.endpoint.handleEvent(.datagram(Wire.ack(1, 1)))
    for i in 1...12 {
        endpoint.advance(to: Double(i))
        endpoint.endpoint.send(Data([1]), mode: .reliable)
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
        port.endpoint.send(full, mode: .reliable)
        for _ in 0..<6 { port.endpoint.send(full, mode: .unreliable(retryBudget: 0.4)) }
        port.advance(to: port.clock.now + 0.25)
        for _ in 0..<3 { port.endpoint.send(full, mode: .unreliable(retryBudget: 0)) }
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
            port.endpoint.send(Data([1]), mode: .unreliable(retryBudget: 0))
            port.advance(to: port.clock.now + (i.isMultiple(of: 8) ? 0.095 : 0.005))
            try acknowledgeLatest()
            port.advance(to: port.clock.now + 0.025)
        }
    } else {
        // A mostly static desktop has one small frame per half second and no pacing backlog.
        for _ in 0..<240 {
            port.endpoint.send(Data([1]), mode: .reliable)
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
        port.endpoint.send(full, mode: .unreliable(retryBudget: 0))
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

    sender.endpoint.send(video, mode: .unreliable(retryBudget: 0))
    #expect(sender.packets.count == 2)
    sender.endpoint.send(normal, mode: .unreliable(retryBudget: 0))
    for audio in [firstAudio, secondAudio] {
        sender.endpoint.send(audio, mode: .unreliable(retryBudget: 0, priority: .high))
    }
    sender.endpoint.send(control, mode: .reliable)
    #expect(sender.packets.count == 2)
    sender.advance(to: 0.04)
    sender.drain(to: receiver)
    #expect(receiver.messages == [control, firstAudio, secondAudio, video, normal])
}

@Test func firstSendExpiryCountsOnlyAdmittedMessagesWithNoAcceptedDatagram() {
    let sender = Port(Clock())
    sender.writable = false
    let high = MessageTransport.Mode.unreliable(retryBudget: 0, firstSendDeadline: 0.01, priority: .high)
    let normal = MessageTransport.Mode.unreliable(retryBudget: 0, firstSendDeadline: 0.01)
    for mode in [high, normal, high] {
        #expect(sender.endpoint.send(Data([1]), mode: mode) == .queued)
    }
    sender.advance(to: 0.01)
    #expect(sender.endpoint.send(Data([2]), mode: high) == .invalidTime)
    sender.writable = true
    sender.endpoint.handleEvent(.writable)
    #expect(sender.packets.isEmpty)

    sender.endpoint.send(Data([3]), mode: .unreliable(retryBudget: 0, firstSendDeadline: 0.02, priority: .high))
    sender.endpoint.send(Data(count: 12_000), mode: .unreliable(retryBudget: 0, firstSendDeadline: 0.01001))
    #expect(sender.packets.count == 2)
    sender.advance(to: 0.04)
    #expect(sender.packets.count == 2)
    #expect(sender.endpoint.statistics.expiredBeforeFirstSend == [.high: 2, .normal: 1])
}
