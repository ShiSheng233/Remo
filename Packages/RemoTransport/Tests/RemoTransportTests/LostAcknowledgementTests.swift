import Foundation
import Testing

@testable import RemoTransport

/// A sender and a receiver joined by a 10 ms link whose datagrams the test can drop.
private final class AckLink {
    var now = 0.0
    let delay = 0.01
    /// Drops what the receiver sends (acknowledgements) while true.
    var dropAcknowledgements = false
    /// Drops the sender's datagram with this packet number.
    var dropPacket: UInt32?
    private var inFlight: [(at: Double, to: Int, bytes: Data)] = []
    private var deadlines: [Double?] = [nil, nil]
    var ends: [MessageTransport] = []

    init() {
        for side in 0..<2 {
            ends.append(
                MessageTransport(
                    datagramLimit: 1200, initialRate: 4_000_000, clock: { [unowned self] in now },
                    dataHandler: { _ in },
                    ioHandler: { [unowned self] request in
                        switch request {
                        case .sendDatagram(let bytes):
                            if side == 1 && dropAcknowledgements { return true }
                            if side == 0, let drop = dropPacket, bytes.count >= 5,
                                UInt32(bigEndian: bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self) }) == drop
                            {
                                return true
                            }
                            inFlight.append((now + delay, 1 - side, bytes))
                        case .setTimer(let time): deadlines[side] = time
                        case .close: break
                        }
                        return true
                    })!)
        }
    }

    func run(until time: Double) {
        while true {
            let arrival = inFlight.map(\.at).min()
            let timer = deadlines.compactMap { $0 }.min()
            guard let next = [arrival, timer].compactMap({ $0 }).min(), next <= time else { break }
            now = max(now, next)
            if let index = inFlight.firstIndex(where: { $0.at <= now }) {
                let (_, to, bytes) = inFlight.remove(at: index)
                ends[to].handleEvent(.datagram(bytes))
            } else if let side = deadlines.firstIndex(where: { $0.map { $0 <= now } ?? false }) {
                deadlines[side] = nil
                ends[side].handleEvent(.timer)
            }
        }
        now = time
    }
}

@Test func lostAcknowledgementsDoNotExpireADeliveredMessage() {
    let link = AckLink()
    var outcome: MessageTransport.Outcome?
    // A predicted frame: three fragments with an 80 ms retry budget.
    link.dropAcknowledgements = true
    link.ends[0].send(Data(repeating: 1, count: 3000), delivery: .init(retryBudget: 0.08)) { outcome = $0 }
    // Every acknowledgement is lost until well past the budget and the first timeout.
    link.run(until: 0.15)
    #expect(outcome == nil)
    link.dropAcknowledgements = false
    // The next frame's acknowledgement repeats the earlier packet numbers in its bitmap.
    link.ends[0].send(Data(repeating: 2, count: 3000), delivery: .init(retryBudget: 0.08))
    link.run(until: 0.5)
    #expect(outcome == .delivered)
}

@Test func lostDataStillExpiresPromptly() {
    let link = AckLink()
    var outcome: MessageTransport.Outcome?
    var expiredAt: Double?
    link.dropPacket = 2
    link.ends[0].send(Data(repeating: 1, count: 3000), delivery: .init(retryBudget: 0.0)) {
        outcome = $0
        expiredAt = link.now
    }
    // Later frames keep acknowledgements coming, which show packet 2 missing.
    for step in 1...6 {
        link.run(until: Double(step) * 0.016)
        link.ends[0].send(Data(repeating: UInt8(step), count: 1000), delivery: .init(retryBudget: 0.0))
    }
    link.run(until: 0.5)
    #expect(outcome == .expired)
    // Shown missing by acknowledgements, not left to the grace period.
    #expect((expiredAt ?? 1) < 0.08)
}
