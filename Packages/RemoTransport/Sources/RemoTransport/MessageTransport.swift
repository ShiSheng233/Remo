import Foundation

/// One direction pair in an already isolated, authenticated datagram session.
/// Serialize all calls on the same executor. Times are monotonic seconds on the supplied clock.
public final class MessageTransport {
    public enum Priority: Int, Sendable {
        case normal, high
    }

    /// How hard to try for one message. There is one kind of message: what used to be a
    /// reliable one is a message whose retry budget never runs out.
    public struct Delivery {
        /// Lost fragments are retransmitted until this long after admission. Zero sends each
        /// fragment once. Infinity retransmits until the peer has the message or it is cancelled.
        public var retryBudget: TimeInterval
        /// An optional absolute time by which every fragment must have been sent once.
        public var firstSendDeadline: TimeInterval?
        /// Local to the sender, applied at each datagram scheduling decision.
        public var priority: Priority
        /// Cancels the unfinished message last admitted with the same key, for state where only
        /// the newest value matters.
        public var replacing: Int?

        public init(
            retryBudget: TimeInterval = 0, firstSendDeadline: TimeInterval? = nil,
            priority: Priority = .normal, replacing key: Int? = nil
        ) {
            self.retryBudget = retryBudget
            self.firstSendDeadline = firstSendDeadline
            self.priority = priority
            replacing = key
        }

        public static func untilDelivered(priority: Priority = .normal, replacing key: Int? = nil) -> Self {
            Self(retryBudget: .infinity, priority: priority, replacing: key)
        }
    }

    /// Names an admitted message for `cancelMessage`.
    public struct MessageID: Hashable, Sendable {
        let rawValue: UInt32
    }

    /// How a message ended. None is reported once the transport has closed.
    public enum Outcome: Equatable, Sendable {
        /// The peer acknowledged every fragment.
        case delivered
        /// Its first-send deadline passed, or a fragment was lost with no retry budget left.
        case expired
        /// Cancelled or replaced. Fragments already sent can still complete at the peer.
        case cancelled
    }

    public enum SendResult: Equatable {
        case queued(MessageID)
        case backpressure, invalidLength, invalidTime, closed

        public var id: MessageID? {
            if case .queued(let id) = self { return id }
            return nil
        }
    }
    public enum Failure: Equatable {
        case sequenceExhausted
    }
    public enum Event {
        case datagram(Data)
        case timer, writable, closed
    }
    public enum IORequest {
        case sendDatagram(Data)
        /// Replace the previous one-shot timer. A nil deadline cancels it.
        case setTimer(TimeInterval?)
        case close(Failure)
    }

    public struct Statistics {
        public let bitsPerSecond: Double
        public let roundTripTime: TimeInterval?
        /// Includes retransmissions. Standalone ACK datagrams use no packet number.
        public let acceptedDataPackets: UInt32
        public let blocked: Bool
        public let probing: Bool
        public let estimatedQueueDelay: TimeInterval
        /// Bytes waiting for a first transmission or a retransmission, by message priority.
        public let queuedBytes: [Priority: Int]
        /// Admitted messages whose deadline elapsed before any datagram was accepted by I/O.
        public let expiredBeforeFirstSend: [Priority: UInt64]

        /// How long a message admitted now at `priority` waits behind what is already queued.
        public func queueDelay(for priority: Priority) -> TimeInterval {
            let ahead = queuedBytes.reduce(0) { $0 + ($1.key.rawValue >= priority.rawValue ? $1.value : 0) }
            return Double(ahead) * 8 / bitsPerSecond
        }
    }

    private final class Message {
        let data: Data
        let count: Int
        let capacity: Int
        /// Retransmissions stop here. Infinite for a message that must arrive.
        let deadline: TimeInterval
        let priority: Priority
        let key: Int?
        let onOutcome: ((Outcome) -> Void)?
        var firstDeadline: TimeInterval?
        var cursor = 0
        var retries: Set<Int> = []
        /// Consecutive timeouts per fragment, for retransmission backoff.
        var timeouts: [Int: Int] = [:]
        /// Fragments neither acknowledged nor given up on.
        var remaining: Int
        var abandoned = false

        init(
            _ data: Data, mtu: Int, now: TimeInterval, delivery: Delivery,
            onOutcome: ((Outcome) -> Void)?
        ) {
            priority = delivery.priority
            key = delivery.replacing
            self.onOutcome = onOutcome
            self.data = data
            capacity =
                data.count <= mtu - Wire.singleHeader
                ? mtu - Wire.singleHeader : mtu - Wire.fragmentHeader
            count = (data.count + capacity - 1) / capacity
            remaining = count
            deadline = now + delivery.retryBudget
            firstDeadline = delivery.firstSendDeadline
        }

        func size(_ index: Int) -> Int { min(capacity, data.count - index * capacity) }
        var header: Int { count == 1 ? Wire.singleHeader : Wire.fragmentHeader }
        var queuedBytes: Int {
            let fresh = max(0, data.count - cursor * capacity) + (count - cursor) * header
            return retries.reduce(fresh) { $0 + size($1) + header }
        }
    }

    private struct Attempt {
        let key: Wire.Fragment
        var expires: TimeInterval?
    }

    public let datagramLimit: Int
    public private(set) var isClosed = false

    private let clock: () -> TimeInterval
    private let dataHandler: (Data) -> Void
    private let ioHandler: (IORequest) -> Bool
    var onDeliveryConfirmed: (() -> Void)?
    private var receiver = Receiver()
    private var messages: [UInt32: Message] = [:]
    private var lastMessage: UInt32 = 0
    private var replaceable: [Int: UInt32] = [:]
    private var outcomes: [(handler: (Outcome) -> Void, outcome: Outcome)] = []
    private var expiredBeforeFirstSend: [Priority: UInt64] = [:]
    private var lastPacket: UInt32 = 0
    private var attempts: [UInt32: Attempt] = [:]
    private var highConfirmed: [UInt32] = []
    private var largest: UInt32 = 0
    private var bitmap: UInt64 = 0
    private var ackCount = 0
    private var ackDue: TimeInterval?
    private var blocked = false
    private var running = false
    private var needsDrive = false
    private var events: [Event] = []
    private var armed: TimeInterval?
    private var credit: Double
    private var lastDataSend: TimeInterval
    /// Time since I/O accepted a data datagram, or since initialization before the first send.
    public var dataSendIdleTime: TimeInterval { clock() - lastDataSend }
    private var creditAt: TimeInterval
    private var rate = 4_000_000.0
    private var recoveryCeiling = 0.0
    private var healthyFeedbackTime: TimeInterval = 0
    private var rtt: TimeInterval?
    private var variation = 0.0
    private var rto: TimeInterval { max(0.03, min(0.5, (rtt ?? 0.1) + 4 * variation)) }
    // Allow transient wireless ACK batching before declaring a feedback blackout.
    private var probeDelay: TimeInterval { max(0.2, 2 * rto) }
    private var progressAt: TimeInterval?
    private var probeAt: TimeInterval?
    private var probeInterval = 0.1
    private var sampleAt: TimeInterval
    private var congestedLastWindow = false
    // Delivery can be confirmed after a fragment expires or another attempt completes it.
    // Retain only wire metadata, independently of retransmission and payload lifetimes.
    private struct DeliveryRecord {
        let number: UInt32
        let sent: TimeInterval
        let bytes: Int
    }
    private var deliveryRecords = Array<DeliveryRecord?>(repeating: nil, count: 8192)
    private var deliverySampleAt: TimeInterval
    private var acknowledgedBytes = 0
    private var deliveryRate = 0.0
    // Leave room to probe when the adaptive encoder targets only part of the pacing budget.
    private var probeCeiling: Double { deliveryRate * 1.4 }
    private var windowBytes = 0
    private var probeReducedRate = false
    // Recovery acts on a timeout immediately. Rate control waits one full observation
    // window so a later bitmap can clear that exact transmission, even after payload eviction.
    private var suspectedLosses: Set<UInt32> = []
    private var agingLosses: Set<UInt32> = []
    private var agingWindowUtilized = false
    private var confirmations = 0
    private var baselineRTT: TimeInterval?

    /// Return false for sendDatagram only if the datagram was not accepted.
    /// After that, signal writable to resume. Other request return values are ignored.
    /// Data and outcome callbacks run synchronously, and may send or cancel. Messages arrive in
    /// the order they complete, not the order they were sent. The adapter owns peer selection
    /// and session isolation.
    public init?(
        datagramLimit: Int = 1200, clock: @escaping () -> TimeInterval,
        dataHandler: @escaping (Data) -> Void,
        ioHandler: @escaping (IORequest) -> Bool
    ) {
        guard datagramLimit >= 64 else { return nil }
        self.datagramLimit = min(datagramLimit, 1200)
        self.clock = clock
        self.dataHandler = dataHandler
        self.ioHandler = ioHandler
        credit = Double(2 * self.datagramLimit)
        creditAt = clock()
        lastDataSend = creditAt
        sampleAt = creditAt
        deliverySampleAt = creditAt
    }

    private var queuedBytes: Int { messages.values.reduce(0) { $0 + $1.queuedBytes } }
    private var queueDelay: TimeInterval { Double(queuedBytes) * 8 / rate }

    public var statistics: Statistics {
        var queued: [Priority: Int] = [:]
        for msg in messages.values { queued[msg.priority, default: 0] += msg.queuedBytes }
        return Statistics(
            bitsPerSecond: rate, roundTripTime: rtt,
            acceptedDataPackets: lastPacket, blocked: blocked, probing: probeAt != nil,
            estimatedQueueDelay: queueDelay, queuedBytes: queued,
            expiredBeforeFirstSend: expiredBeforeFirstSend)
    }

    /// Attempts admission without waiting for network credit or acknowledgement.
    /// `onOutcome` reports how the message ended, once, unless the transport closes first.
    @discardableResult
    public func send(
        _ data: Data, delivery: Delivery = Delivery(), onOutcome: ((Outcome) -> Void)? = nil
    ) -> SendResult {
        let now = clock()
        if !running && !isClosed { expire(now) }
        guard !isClosed else { return .closed }
        guard !data.isEmpty, data.count <= Wire.maxMessage else { return .invalidLength }
        guard delivery.retryBudget >= 0, delivery.firstSendDeadline?.isFinite != false else {
            return .invalidTime
        }
        guard delivery.firstSendDeadline.map({ now < $0 }) ?? true else { return .invalidTime }
        // The newest value wins even if it then finds no room: the old one is stale either way.
        if let key = delivery.replacing, let old = replaceable[key] { finish(old, .cancelled) }
        guard messages.count < 256,
            messages.values.reduce(data.count, { $0 + $1.data.count }) <= 4 << 20
        else {
            drive()
            return .backpressure
        }
        guard lastMessage < .max else {
            close(.sequenceExhausted)
            return .closed
        }
        lastMessage += 1
        messages[lastMessage] = Message(
            data, mtu: datagramLimit, now: now, delivery: delivery, onOutcome: onOutcome)
        if let key = delivery.replacing { replaceable[key] = lastMessage }
        let id = MessageID(rawValue: lastMessage)
        drive()
        return .queued(id)
    }

    /// Stops sending and retransmitting a message. Fragments already sent can still complete at
    /// the peer, so the application must tolerate the message arriving anyway.
    public func cancelMessage(_ id: MessageID) {
        guard !isClosed else { return }
        finish(id.rawValue, .cancelled)
        drive()
    }

    public func handleEvent(_ event: Event) {
        guard !isClosed else { return }
        events.append(event)
        drive()
    }

    /// Ends a message. Its transmissions in flight are forgotten as they time out.
    private func finish(_ id: UInt32, _ outcome: Outcome) {
        guard let msg = messages.removeValue(forKey: id) else { return }
        if let key = msg.key, replaceable[key] == id { replaceable[key] = nil }
        if let handler = msg.onOutcome { outcomes.append((handler, outcome)) }
    }

    private func close(_ reason: Failure?) {
        guard !isClosed else { return }
        isClosed = true
        receiver = Receiver()
        messages.removeAll()
        replaceable.removeAll()
        outcomes.removeAll()
        attempts.removeAll()
        events.removeAll()
        if armed != nil {
            armed = nil
            _ = ioHandler(.setTimer(nil))
        }
        if let reason { _ = ioHandler(.close(reason)) }
    }

    private func drive() {
        guard !isClosed else { return }
        if running {
            needsDrive = true
            return
        }
        running = true
        defer { running = false }
        while !isClosed {
            needsDrive = false
            let now = clock()
            credit = min(Double(2 * datagramLimit), credit + max(0, now - creditAt) * rate / 8)
            creditAt = now
            if let event = events.first {
                events.removeFirst()
                if case .closed = event {
                    close(nil)
                    return
                }
                expire(now)
                guard !isClosed else { return }
                switch event {
                case .datagram(let bytes): receive(bytes, now)
                case .timer: armed = nil
                case .writable: blocked = false
                case .closed: break
                }
                continue
            }
            expire(now)
            guard !isClosed else { return }
            if !outcomes.isEmpty {
                let (handler, outcome) = outcomes.removeFirst()
                handler(outcome)
                continue
            }
            var wake = nextDeadline(now)
            if !blocked {
                let ackReady = ackDue.map { $0 <= now } ?? false
                let key = ackReady ? nil : candidate(now)
                if ackReady || key != nil {
                    let msg = key.flatMap { messages[$0.id] }
                    let cost = key.map { msg!.size($0.index) + msg!.header } ?? 13
                    if credit + 1e-7 >= Double(cost) {
                        if ackReady {
                            if ioHandler(.sendDatagram(Wire.ack(largest, bitmap))) {
                                ackDue = nil
                                ackCount = 0
                                credit -= 13
                                windowBytes += 13
                            } else {
                                blocked = true
                            }
                        } else if let key, let msg {
                            transmit(key, msg)
                        }
                        continue
                    }
                    wake = min(wake, max(now.nextUp, now + (Double(cost) - credit) * 8 / rate))
                }
            }
            let deadline = wake.isFinite ? wake : nil
            if armed != deadline {
                armed = deadline
                _ = ioHandler(.setTimer(deadline))
                if needsDrive { continue }
            }
            break
        }
    }

    private func receive(_ bytes: Data, _ now: TimeInterval) {
        switch Wire.decode(bytes, mtu: datagramLimit) {
        case .ack(let number, let bits):
            guard number <= lastPacket else { return }
            acknowledge(number, bits, now)
        case .data(let number, let key, let count, let lifetime, let payload):
            let (accepted, duplicate, complete) = receiver.accept(
                key, count: count, lifetime: lifetime, data: payload, now: now)
            guard accepted else { return }
            let gap = UInt64(number) != UInt64(largest) + 1
            if number > largest {
                bitmap = (bitmap << (number - largest)) | 1
                largest = number
            } else {
                bitmap |= UInt64(1) << (largest - number)
            }
            ackCount += 1
            let urgent = duplicate || gap || ackCount >= 8
            ackDue = min(ackDue ?? .infinity, urgent ? now : now + 0.005)
            if let complete { dataHandler(complete) }
        case nil: break
        }
    }

    private func acknowledge(_ largest: UInt32, _ bits: UInt64, _ now: TimeInterval) {
        var newDelivery = false
        var confirmed: Set<Wire.Fragment> = []
        var sample: TimeInterval?
        for offset in 0..<64 where bits & (UInt64(1) << offset) != 0 {
            let number = largest - UInt32(offset)
            suspectedLosses.remove(number)
            agingLosses.remove(number)
            if (highConfirmed.count < 3 || number > highConfirmed[2])
                && !highConfirmed.contains(number)
            {
                highConfirmed = Array((highConfirmed + [number]).sorted(by: >).prefix(3))
            }
            let slot = Int(number) % deliveryRecords.count
            if let record = deliveryRecords[slot], record.number == number {
                deliveryRecords[slot] = nil
                newDelivery = true
                let elapsed = max(0, now - record.sent)
                if elapsed <= 2 {
                    acknowledgedBytes += record.bytes
                    confirmations += 1
                    if sample == nil { sample = elapsed }
                }
            }
            guard let attempt = attempts[number] else { continue }
            confirmed.insert(attempt.key)
        }
        if newDelivery || !confirmed.isEmpty { onDeliveryConfirmed?() }
        if let sample {
            if let old = rtt {
                variation = variation * 0.75 + abs(old - sample) * 0.25
                rtt = old * 0.875 + sample * 0.125
            } else {
                variation = sample / 2
                rtt = sample
            }
            progressAt = now
            probeAt = nil
        }
        if !confirmed.isEmpty {
            for key in confirmed {
                guard let msg = messages[key.id] else { continue }
                msg.retries.remove(key.index)
                msg.timeouts[key.index] = nil
                msg.remaining -= 1
                if msg.remaining == 0 { finish(key.id, msg.abandoned ? .expired : .delivered) }
            }
            attempts = attempts.filter { !confirmed.contains($0.value.key) }
        }
        if highConfirmed.count == 3 {
            for (number, attempt) in attempts
            where number < highConfirmed[2] && attempt.expires != nil {
                lose(number, attempt, now, timeout: false)
            }
        }
    }

    private func viable(_ msg: Message, _ now: TimeInterval) -> Bool {
        now + queueDelay + (rtt ?? 0.1) / 2 < msg.deadline
    }

    private func lose(_ number: UInt32, _ attempt: Attempt, _ now: TimeInterval, timeout: Bool) {
        suspectedLosses.insert(number)
        attempts[number]?.expires = nil
        let key = attempt.key
        guard let msg = messages[key.id] else {
            attempts.removeValue(forKey: number)
            return
        }
        // Retransmit as often as the budget allows. The lost attempt stays on record so a late
        // acknowledgement can still confirm the fragment.
        if viable(msg, now) {
            if timeout { msg.timeouts[key.index] = min(5, msg.timeouts[key.index, default: 0] + 1) }
            msg.retries.insert(key.index)
        } else {
            abandon(key, msg)
        }
    }

    /// Gives up on one fragment. The message can no longer complete, but its other fragments
    /// still run their course: a loss verdict can be wrong, and the fragment may have arrived.
    private func abandon(_ key: Wire.Fragment, _ msg: Message) {
        attempts = attempts.filter { $0.value.key != key }
        msg.retries.remove(key.index)
        msg.timeouts[key.index] = nil
        msg.remaining -= 1
        msg.abandoned = true
        if msg.remaining == 0 { finish(key.id, .expired) }
    }

    private func expire(_ now: TimeInterval) {
        receiver.expire(now)
        for (id, msg) in messages {
            if let firstDeadline = msg.firstDeadline, firstDeadline <= now {
                if msg.cursor == 0 { expiredBeforeFirstSend[msg.priority, default: 0] += 1 }
                finish(id, .expired)
            } else if now >= msg.deadline {
                // Fragments still in flight are settled by their acknowledgement or timeout.
                for index in msg.retries { abandon(.init(id: id, index: index), msg) }
            }
        }
        for (number, attempt) in attempts {
            if let deadline = attempt.expires, deadline <= now {
                lose(number, attempt, now, timeout: true)
            } else if attempt.expires == nil && messages[attempt.key.id] == nil {
                attempts.removeValue(forKey: number)
            }
        }
        if attempts.isEmpty && messages.isEmpty {
            progressAt = nil
            probeAt = nil
        }
        if let start = progressAt, probeAt == nil, now >= start + probeDelay {
            probeAt = now
            probeInterval = rto
            probeReducedRate = false
        }
        if probeAt != nil && !probeReducedRate && queuedBytes >= 2 * datagramLimit {
            probeReducedRate = true
            reduceRate()
        }
        // Use wall-clock delivery windows, including idle time between ACK bursts.
        let deliveryInterval = now - deliverySampleAt
        if deliveryInterval >= 1 {
            let measured = Double(acknowledgedBytes) * 8 / deliveryInterval
            if deliveryInterval > 2 {
                deliveryRate = 0
            } else if deliveryRate == 0 {
                deliveryRate = measured
            } else {
                deliveryRate = (deliveryRate + measured) / 2
            }
            deliverySampleAt = now
            acknowledgedBytes = 0
        }
        if now >= sampleAt + 0.25 {
            let queued = statistics.estimatedQueueDelay > 0
            let inflated = rtt.map { $0 > (baselineRTT ?? $0) * 1.25 + 0.005 } ?? false
            // Timing variation on sparse traffic does not measure link capacity.
            let utilized = Double(windowBytes) * 8 >= rate * (now - sampleAt) * 0.5
            let losses = agingLosses.count
            let congested = (agingWindowUtilized && losses >= 2) || (utilized && queued && inflated)
            let healthy =
                now - sampleAt <= 1.5 && confirmations > 0 && losses == 0
                && !inflated && probeAt == nil
            if congested && congestedLastWindow {
                reduceRate()
            } else if healthy {
                // An adaptive encoder can empty the queue at its reduced target. Use fresh
                // ACKs to recover toward a previously demonstrated delivery rate.
                healthyFeedbackTime += min(now - sampleAt, 0.5)
                if min(recoveryCeiling, probeCeiling) > rate && healthyFeedbackTime >= 1 {
                    rate = min(recoveryCeiling, probeCeiling, rate * 1.15)
                    healthyFeedbackTime = 0
                } else if (queued || utilized) && probeCeiling > rate {
                    rate = min(100_000_000, probeCeiling, rate * pow(1.05, 0.25))
                }
                if rate >= recoveryCeiling { recoveryCeiling = 0 }
            } else if congested || probeAt != nil || now - sampleAt > 1.5 {
                healthyFeedbackTime = 0
            }
            congestedLastWindow = congested
            baselineRTT = rtt
            confirmations = 0
            windowBytes = 0
            agingLosses = suspectedLosses
            suspectedLosses.removeAll(keepingCapacity: true)
            agingWindowUtilized = utilized
            sampleAt = now
        }
    }

    private func reduceRate() {
        recoveryCeiling = max(recoveryCeiling, min(rate, deliveryRate))
        healthyFeedbackTime = 0
        rate = max(64_000, rate * 0.8)
    }

    private func candidate(_ now: TimeInterval) -> Wire.Fragment? {
        if let probeAt, now < probeAt { return nil }
        guard let oldest = messages.keys.min() else { return nil }
        let ordered = messages.sorted {
            if $0.value.priority == $1.value.priority { return $0.key < $1.key }
            return $0.value.priority.rawValue > $1.value.priority.rawValue
        }
        // Stay within the receiver's duplicate window of the oldest message still in play.
        for (id, msg) in ordered where id - oldest < Wire.messageWindow {
            while let index = msg.retries.min() {
                let key = Wire.Fragment(id: id, index: index)
                if viable(msg, now) { return key }
                abandon(key, msg)
            }
            if msg.cursor < msg.count { return .init(id: id, index: msg.cursor) }
        }
        return nil
    }

    private func transmit(_ key: Wire.Fragment, _ msg: Message) {
        guard lastPacket < .max else {
            close(.sequenceExhausted)
            return
        }
        let start = msg.data.startIndex + key.index * msg.capacity
        let bytes = Wire.data(
            lastPacket + 1, key, msg.count, lifetime: msg.deadline - clock(),
            msg.data[start..<(start + msg.size(key.index))])
        guard ioHandler(.sendDatagram(bytes)) else {
            blocked = true
            return
        }
        lastPacket += 1
        if msg.retries.remove(key.index) == nil {
            msg.cursor += 1
            if msg.cursor == msg.count { msg.firstDeadline = nil }
        }
        let sent = clock()
        lastDataSend = sent
        let timeout = min(0.5, rto * Double(1 << msg.timeouts[key.index, default: 0]))
        deliveryRecords[Int(lastPacket) % deliveryRecords.count] = DeliveryRecord(
            number: lastPacket, sent: sent, bytes: bytes.count)
        attempts[lastPacket] = Attempt(key: key, expires: sent + timeout)
        if progressAt == nil { progressAt = sent }
        if probeAt != nil {
            probeAt = sent + probeInterval
            probeInterval = min(0.5, 2 * probeInterval)
        }
        credit -= Double(bytes.count)
        windowBytes += bytes.count
    }

    private func nextDeadline(_ now: TimeInterval) -> TimeInterval {
        var wake = receiver.nextExpiry ?? .infinity
        if !blocked, let ackDue, ackDue > now { wake = min(wake, ackDue) }
        for msg in messages.values {
            wake = min(wake, msg.firstDeadline ?? .infinity)
            if msg.deadline > now { wake = min(wake, msg.deadline) }
        }
        for attempt in attempts.values { wake = min(wake, attempt.expires ?? .infinity) }
        if let probeAt {
            if !blocked && probeAt > now { wake = min(wake, probeAt) }
        } else if let start = progressAt {
            wake = min(wake, start + probeDelay)
        }
        return wake
    }
}
