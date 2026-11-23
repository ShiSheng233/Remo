import Foundation

/// One direction pair in an already isolated, authenticated datagram session.
/// Serialize all calls on the same executor. Times are monotonic seconds on the supplied clock.
public final class MessageTransport {
    public enum Priority: Int, Sendable {
        case normal, high
    }

    /// How hard to try for one message. There is one kind of message: what used to be a
    /// reliable one is a message whose retry budget never runs out.
    public struct Delivery: Sendable {
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
        /// Repair fragments to send after the message's own, as a share of their number and
        /// rounded to the nearest whole fragment. The peer rebuilds the message from any of
        /// its fragments, as many as it had before repair, so that much loss costs no round
        /// trip. A message of a single datagram gets a second one from a half upward.
        public var redundancy: Double

        public init(
            retryBudget: TimeInterval = 0, firstSendDeadline: TimeInterval? = nil,
            priority: Priority = .normal, replacing key: Int? = nil, redundancy: Double = 0
        ) {
            self.retryBudget = retryBudget
            self.firstSendDeadline = firstSendDeadline
            self.priority = priority
            replacing = key
            self.redundancy = redundancy
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
        /// The peer acknowledged every fragment, or enough of them to rebuild the message.
        case delivered
        /// Its first-send deadline passed, or too many fragments were lost with no retry
        /// budget left.
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
    public enum Failure: Equatable, Sendable {
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

    public struct Statistics: Sendable {
        public let bitsPerSecond: Double
        public let roundTripTime: TimeInterval?
        /// The lowest round trip of the last several seconds: the path without any queueing.
        public let minimumRoundTripTime: TimeInterval?
        /// The share of data datagrams lost over about the last second.
        public let lossRatio: Double
        /// The part of `lossRatio` that sending less would not remove: loss that stayed when
        /// the rate was reduced, or too little to be worth testing. Redundancy sized by this
        /// does not answer congestion with more traffic.
        public let linkLossRatio: Double
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
        /// Data fragments. Repair fragments are numbered after them.
        let count: Int
        let repair: Int
        let capacity: Int
        /// Retransmissions stop here. Infinite for a message that must arrive.
        let deadline: TimeInterval
        let priority: Priority
        let key: Int?
        let onOutcome: ((Outcome) -> Void)?
        var firstDeadline: TimeInterval?
        var cursor = 0
        var retries: Set<Int> = []
        /// Lost fragments that repair fragments still in play may make up for.
        var spare: Set<Int> = []
        /// Consecutive timeouts per fragment, for retransmission backoff.
        var timeouts: [Int: Int] = [:]
        /// Fragments neither acknowledged nor given up on.
        var remaining: Int
        var confirmed = 0
        private var parity: [Data]?

        init(
            _ data: Data, mtu: Int, now: TimeInterval, delivery: Delivery,
            onOutcome: ((Outcome) -> Void)?
        ) {
            priority = delivery.priority
            key = delivery.replacing
            self.onOutcome = onOutcome
            self.data = data
            let protected = mtu - Wire.repairableHeader
            let fragments = (data.count + protected - 1) / protected
            var repair = 0
            if delivery.redundancy > 0, fragments <= Repair.maxData {
                repair = Int(min(Double(Repair.maxRepair), (Double(fragments) * delivery.redundancy).rounded()))
            }
            self.repair = repair
            if repair > 0 {
                capacity = protected
            } else {
                capacity =
                    data.count <= mtu - Wire.singleHeader
                    ? mtu - Wire.singleHeader : mtu - Wire.fragmentHeader
            }
            count = (data.count + capacity - 1) / capacity
            remaining = count + repair
            deadline = now + delivery.retryBudget
            firstDeadline = delivery.firstSendDeadline
        }

        var total: Int { count + repair }
        /// Repair fragments are as long as the longest data fragment.
        private var repairSize: Int { min(capacity, data.count) }
        func size(_ index: Int) -> Int {
            index < count ? min(capacity, data.count - index * capacity) : repairSize
        }
        var header: Int {
            repair > 0 ? Wire.repairableHeader : count == 1 ? Wire.singleHeader : Wire.fragmentHeader
        }
        var queuedBytes: Int {
            let fresh =
                max(0, data.count - cursor * capacity) + (total - max(cursor, count)) * repairSize
                + (total - cursor) * header
            return retries.reduce(fresh) { $0 + size($1) + header }
        }

        /// Queues lost fragments for retransmission, as few as the message still needs: the
        /// peer can do without any fragment that enough of the others arrive in place of.
        func reinforce() {
            while confirmed + remaining - spare.count < count, let index = spare.min() {
                spare.remove(index)
                retries.insert(index)
            }
        }

        func payload(_ index: Int) -> Data {
            func fragment(_ index: Int) -> Data {
                let start = data.startIndex + index * capacity
                return data[start..<(start + size(index))]
            }
            guard index >= count else { return fragment(index) }
            // Made when the first one is sent: an acknowledgement often gets there first.
            if parity == nil {
                parity = Repair.encode((0..<count).map(fragment), repair: repair, length: repairSize)
            }
            return parity![index - count]
        }
    }

    private struct Attempt {
        let key: Wire.Fragment
        let sent: TimeInterval
        let bytes: Int
        var expires: TimeInterval?
        /// An acknowledgement showed this transmission missing, rather than none arriving in time.
        var lossSeen = false
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
    private var inFlightBytes = 0
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
    /// A modest first guess. Until the link pushes back, the budget grows quickly from here.
    public static let initialRate = 1_500_000.0
    private var rate: Double
    private var startup = true
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
    // Delivery can be confirmed after a fragment expires or another attempt completes it.
    // Retain only wire metadata, independently of retransmission and payload lifetimes.
    private struct DeliveryRecord {
        let number: UInt32
        let sent: TimeInterval
        let bytes: Int
        /// The observation window it was sent in.
        let window: Int
        /// Counted as lost there. An acknowledgement can still take that back.
        var lost = false
    }
    private var deliveryRecords = Array<DeliveryRecord?>(repeating: nil, count: 8192)
    private var deliveryRate = 0.0
    // The budget may run ahead of what was delivered, but only by one step: an application that
    // spends most of its budget then asks the link for a quarter more than it has shown.
    private var probeCeiling: Double { deliveryRate * 1.5 }
    /// Cap unacknowledged bytes in flight to ~2× BDP + 50 ms so a sudden link stall cannot pour
    /// unbounded packets into a bottleneck buffer before rate control reacts.
    private var maxInFlightBytes: Int {
        max(4 * datagramLimit, Int(rate * max(0.15, (rtt ?? 0.1) * 2.0 + 0.05) / 8))
    }
    /// What became of the datagrams sent in one observation window. Loss and delivery are
    /// read against what was sent at the time, so a change of rate does not distort them.
    private struct Sending {
        var packets = 0
        var bytes = 0
        var acknowledged = 0
        var acknowledgedBytes = 0
        var lost = 0
        var interval: TimeInterval = 0.25
        /// When the window's first and last datagrams went out: the span the application was
        /// actually sending in.
        var firstSent: TimeInterval?
        var lastSent: TimeInterval = 0
        private var activeSpan: TimeInterval {
            guard let firstSent else { return interval }
            return min(interval, max(0.05, lastSent - firstSent))
        }
        /// Sent in bursts with quiet in between, as an application with little to say sends:
        /// then the window's averages describe the application, not the link.
        var bursty: Bool { activeSpan < interval * 0.7 }
        /// What got through, and what was sent, while the window was sending. Of a bursty
        /// window these are what the link did; of a busy one they are the window's averages.
        var carriedRate: Double { bursty ? Double(acknowledgedBytes) * 8 / activeSpan : deliveredRate }
        var offeredRate: Double { bursty ? Double(bytes) * 8 / activeSpan : sentRate }
        /// Send times and sizes of the datagrams acknowledged so far, and the send time of the
        /// earliest one lost.
        var acknowledgedSends: [(sent: TimeInterval, bytes: Int)] = []
        var firstLostSent: TimeInterval?
        var lastLostSent: TimeInterval?
        /// Send times and sizes of the datagrams counted lost.
        var lostSends: [(sent: TimeInterval, bytes: Int)] = []
        /// Of what was sent between the first and the last loss, the share lost. A policer that
        /// is being overrun drops a large share; random loss or reordering, a small one.
        var dropShareUnderLoss: Double {
            guard let first = firstLostSent, let last = lastLostSent else { return 0 }
            let lost = lostSends.filter { $0.sent >= first && $0.sent <= last }
            // A handful of losses close together happens by chance on a lossy link, and a link
            // that loses in bursts drops a run at a time. An overrun limit drops all along,
            // between datagrams it lets through.
            guard lost.count >= 6 else { return 0 }
            let got = acknowledgedSends.filter { $0.sent >= first && $0.sent <= last }
            let lostTimes = lost.map(\.sent).sorted()
            var runs = 1
            for (a, b) in zip(lostTimes, lostTimes.dropFirst()) where got.contains(where: { $0.sent > a && $0.sent < b }) {
                runs += 1
            }
            guard runs >= 3 else { return 0 }
            let lostBytes = lost.reduce(0) { $0 + $1.bytes }
            let gotBytes = got.reduce(0) { $0 + $1.bytes }
            return Double(lostBytes) / Double(lostBytes + gotBytes)
        }
        /// `rateUnderLoss` when the loss looks like an overrun limit rather than chance.
        var policedRate: Double? { dropShareUnderLoss >= 0.25 ? rateUnderLoss : nil }
        /// What got through of what was sent between the first and the last loss. A link that
        /// lets a burst through before it starts to drop (a policer with an allowance) has spent
        /// the allowance by then and is dropping all along: this is the rate it holds to, where
        /// the window's averages include whatever the allowance let through first and the quiet
        /// after. Nil when too little was sent meanwhile to tell.
        var rateUnderLoss: Double? {
            guard let first = firstLostSent, let last = lastLostSent, last - first >= 0.04 else { return nil }
            let during = acknowledgedSends.filter { $0.sent >= first && $0.sent <= last }
            guard during.count >= 6 else { return nil }
            return Double(during.reduce(0) { $0 + $1.bytes }) * 8 / (last - first)
        }
        var lossRatio: Double {
            lost >= 3 && acknowledged + lost >= 20 ? Double(lost) / Double(acknowledged + lost) : 0
        }
        var deliveredRate: Double { Double(acknowledgedBytes) * 8 / interval }
        var sentRate: Double { Double(bytes) * 8 / interval }
        /// Whether this one window lost more than `tolerated` beyond what chance explains:
        /// a quarter second of a link that loses a steady share now and then loses twice it.
        func exceeds(_ tolerated: Double) -> Bool {
            Self.exceeds(tolerated, acknowledged: acknowledged, lost: lost)
        }

        static func exceeds(_ tolerated: Double, acknowledged: Int, lost: Int) -> Bool {
            let count = Double(acknowledged + lost)
            let expected = count * tolerated
            return lost >= 3 && count >= 20 && Double(lost) > expected + 2 * (expected * (1 - tolerated)).squareRoot()
        }
    }

    /// Whether more is being lost than `tolerated`, beyond what chance explains: a lot in the
    /// newest window that can tell, or less over a second, or a little over four.
    private func lossExceeds(_ tolerated: Double, onset: Sending) -> Bool {
        if onset.exceeds(tolerated) { return true }
        let settled = windowIndex - settling
        for span in [4, 16] {
            // What was lost before the budget last came down says nothing about it now.
            let (acknowledged, lost) = outcome(from: max(settled - span + 1, lossEpoch), through: settled)
            if Sending.exceeds(tolerated, acknowledged: acknowledged, lost: lost) { return true }
        }
        return false
    }
    /// A budget is worth no more than this over what was delivered when the link was full:
    /// an application that spends little of it would send the rest in bursts the link has
    /// just shown it cannot take.
    private static let headroom = 1.5
    private var sendings: [Int: Sending] = [0: Sending()]
    private var windowIndex = 0
    /// The first window sent at the budget as it was last reduced.
    private var lossEpoch = 0
    /// How many windows back a datagram's loss is certain to have been counted: one for a
    /// suspicion to age, one for it to arise, and the round trip.
    private var settling: Int { 2 + Int((rtt ?? 0.1) / 0.25) }
    private var windowBytes = 0
    private var windowAcknowledged = 0
    private var windowPackets = 0
    /// Whether the local pacer built a meaningful backlog (>35 ms) during the current 0.25 s window.
    private var windowBacklogged = false
    /// Earliest send time and latest ACK time of packets confirmed in the current window, used to
    /// measure the active burst delivery rate when short UI animations saturate the pacer.
    private var windowFirstConfirmedSend: TimeInterval?
    private var windowLastConfirmedAt: TimeInterval?
    private var probeReducedRate = false
    // Recovery acts on a timeout immediately. Rate control waits one full observation
    // window so a later bitmap can clear that exact transmission, even after payload eviction.
    private var suspectedLosses: Set<UInt32> = []
    /// Fragments past their retry budget whose only sign of loss is a missing acknowledgement,
    /// with when to give up on them. Acknowledgements get lost too, and every later one repeats
    /// the last 64 packet numbers, so one can still confirm the fragment.
    private var unconfirmed: [Wire.Fragment: TimeInterval] = [:]
    private var agingLosses: Set<UInt32> = []
    private var confirmations = 0

    private static let minimumRate = 256_000.0
    private struct Window {
        let interval: TimeInterval
        let sent: Int
        let acknowledged: Int
        let packets: Int
        let losses: Int
    }
    /// The last second of observation windows, newest last.
    private var history: [Window] = []
    // Queueing is measured against the fastest round trip of the last five to ten seconds.
    // A queue that outlives that span becomes the new baseline, whoever caused it.
    private var floorRTT: TimeInterval?
    private var previousFloorRTT: TimeInterval?
    private var floorRotatedAt: TimeInterval
    private var minimumRTT: TimeInterval? {
        [floorRTT, previousFloorRTT].compactMap { $0 }.min()
    }
    /// The fastest round trip of the current window. If even that one queued, the queue stands.
    private var windowFastestRTT: TimeInterval?
    private var holdUntil: TimeInterval = 0
    private var cutQueueDelay: TimeInterval?
    private var futileCuts = 0
    /// The budget the link was found to carry the last time it was full. While the memory is
    /// fresh the budget is raised beyond it only by testing: a step up, counted once the
    /// application has sent that much more and those datagrams are accounted for, and taken
    /// back to what got through if the link pushes back. Steps start small, so a failed one
    /// costs little, and grow while they pass, so spare capacity is found in a few.
    private var capacityMark: (rate: Double, at: TimeInterval)?
    private struct Probe {
        /// The budget before the step.
        let base: Double
        /// The window at whose end the step has been tested, and the one at whose end it is
        /// given up as never tried.
        let verify: Int
        let expires: Int
        /// What has to be sent for the step to count as tried: half the way from what was
        /// sent before it toward what the step allows. Nil for an application that was not
        /// spending its budget: sending more then proves nothing, only bursts that the
        /// budget alone held back and that went through do.
        let exercised: Double?
    }
    private var probe: Probe?
    /// When the latest step passed. It stays in doubt for a while: a link that polices its
    /// rate lets a burst through before it starts to drop, so trouble can come seconds late.
    private var passed: TimeInterval?
    /// Whether the latest step was a bold one, taken on the strength of `proven`.
    private var steppedBoldly = false
    /// A budget the link keeps turning out to be full at, and how many times in a row. The
    /// more often, the longer the wait before testing beyond it again: nothing has changed
    /// up there. A different capacity starts the count afresh.
    ///
    /// How the link said so matters. One that queues shows a step too far as a little delay,
    /// at once, and at no cost: it can be tested often. One that polices its rate drops
    /// datagrams instead, and only after letting a burst through: there a step too far costs
    /// loss and shows late, so tests are rarer and each has to hold before the next.
    private var wall: (rate: Double, hits: Int, policed: Bool)?
    private var steadyWall: Bool { wall?.policed == true }
    /// When a queue was last seen building. Loss with no queue anywhere near it is policing.
    private var queueSeenAt: TimeInterval = -.infinity
    private var probeStep = MessageTransport.firstProbeStep
    private var probeWait = MessageTransport.firstProbeWait
    private var nextProbe: TimeInterval = 0
    /// The highest budget that was used without trouble lately. Below it, steps are bold
    /// from the start: a link that dipped usually comes back.
    private var proven: (rate: Double, at: TimeInterval)?
    /// A budget on its way to being proven: used since `at` with nothing pushing back.
    private var proving: (rate: Double, at: TimeInterval)?
    private static let firstProbeStep = 0.05
    private static let maximumProbeStep = 0.25
    private static let firstProbeWait = 1.0
    private static let maximumProbeWait = 16.0
    private static let maximumProbeWaitQueued = 4.0
    /// How far past a wall the budget has to get before steps grow again.
    private static let clearOfWall = 1.15
    private static let markLifetime = 60.0
    private static let doubt = 4.0
    /// After congestion the budget returns to where the application sends this share of
    /// what got through.
    private static let fill = 0.95

    /// Whether a step up is being tested or has passed too recently to be trusted.
    private func stepInDoubt(_ now: TimeInterval) -> Bool {
        probe != nil || (passed.map { now - $0 < Self.doubt } ?? false)
    }

    /// The link was full and carries `capacity`: a measurement, or for a step that failed
    /// only a first reading, which does not move a wall already found.
    private func mark(_ capacity: Double, _ now: TimeInterval, policed: Bool, measured: Bool = true) {
        if let known = wall, !measured || abs(capacity - known.rate) <= known.rate * 0.2 {
            wall = (measured ? (known.rate + capacity) / 2 : known.rate, known.hits + 1, policed)
            probeWait = min(policed ? Self.maximumProbeWait : Self.maximumProbeWaitQueued, probeWait * 2)
        } else {
            wall = (capacity, 1, policed)
            probeWait = Self.firstProbeWait
        }
        // A bold step that failed: the link has not come back to what it was.
        if steppedBoldly, stepInDoubt(now) { proven = nil }
        probeStep = Self.firstProbeStep
        capacityMark = (capacity, now)
        lossEpoch = windowIndex + 1
        nextProbe = now + probeWait
        probe = nil
        passed = nil
        proving = nil
    }

    // Loss alone doesn't say whether the link is full. A reduction that makes it go away does.
    private struct LossTrial {
        /// The budget to return to if the loss turns out to be the link's own.
        let rate: Double
        /// The loss the reduction has to remove.
        var reference: Double
        /// What got through while the loss was seen: the link's capacity, if it was full.
        var delivered: Double
        /// What was sent then.
        var sent: Double
        /// The first window sent entirely at the reduced rate.
        var start: Int
        /// Whether `delivered` is the rate an overrun limit held to (see `Sending.policedRate`).
        var underLoss = false
        /// Whether `delivered` was read from a window with little in it or sent in bursts: it
        /// may be far below what the link carries, so it sizes neither a deep cut nor a wall.
        var thin = false
    }
    private var lossTrial: LossTrial?
    /// What a link that polices its rate held to while it dropped, measured from the first loss
    /// on (BBRv1's long-term bandwidth for policers). Its allowance lets short bursts through
    /// at any rate, so they say nothing beyond it: the budget stays at or under it. A session
    /// that keeps pressing against it tries a little more now and then, as the link may have
    /// changed; loss there measures it afresh.
    private var policedCap: (rate: Double, at: TimeInterval)?
    /// How long the cap holds before a session that keeps sending at it may try more; doubled
    /// each time trying more ended in loss again.
    private var policedCapHold = MessageTransport.firstPolicedCapHold
    private static let firstPolicedCapHold = 20.0
    private static let maximumPolicedCapHold = 160.0
    private static let policedCapStep = 1.15
    private var toleratedLoss = 0.02
    /// Loss is not accepted as the link's own beyond this: a wrong verdict then costs little.
    private static let maximumToleratedLoss = 0.15
    /// Consecutive verdicts that the loss was the link's own, and when the next test is due.
    private var linkVerdicts = 0
    private var nextLossTrial: TimeInterval = 0
    private var toleratedLossAt: TimeInterval = 0
    /// The share lost of the datagrams sent over about a second, as far back as their fate is known.
    private var lossRatio: Double {
        let (acknowledged, lost) = outcome(from: windowIndex - settling - 3, through: windowIndex - settling)
        return acknowledged + lost >= 20 && lost >= 3 ? Double(lost) / Double(acknowledged + lost) : 0
    }

    private func outcome(from first: Int, through last: Int) -> (acknowledged: Int, lost: Int) {
        var acknowledged = 0
        var lost = 0
        guard last >= max(0, first) else { return (0, 0) }
        for index in max(0, first)...last {
            guard let sending = sendings[index] else { continue }
            acknowledged += sending.acknowledged
            lost += sending.lost
        }
        return (acknowledged, lost)
    }

    /// Fits inside IPv6's 1280-byte minimum MTU even after inner IPv4/UDP + WireGuard encapsulation
    /// (20 + 8 + 1160 = 1188, padded to 1200, plus 32-byte WG + 48-byte outer IPv6/UDP = 1280).
    public static let defaultDatagramLimit = 1160
    /// Delayed ACK timer for in-order data. Kept under `tolerance / 2` (10 ms) so delayed ACKs
    /// cannot look like queueing delay relative to immediate gap ACKs, while cutting reverse-path
    /// ACK overhead over Wi-Fi and WireGuard.
    static let delayedAckInterval: TimeInterval = 0.008
    /// Send an immediate ACK after this many in-order data datagrams.
    static let ackPacketThreshold = 10

    /// How many datagrams a message of `bytes` takes when it is sent with repair fragments,
    /// not counting those: what a share given as `Delivery.redundancy` is a share of.
    public static func repairableFragments(in bytes: Int, datagramLimit: Int = defaultDatagramLimit) -> Int {
        let capacity = datagramLimit - Wire.repairableHeader
        return max(1, (bytes + capacity - 1) / capacity)
    }

    /// Return false for sendDatagram only if the datagram was not accepted.
    /// After that, signal writable to resume. Other request return values are ignored.
    /// Data and outcome callbacks run synchronously, and may send or cancel. Messages arrive in
    /// the order they complete, not the order they were sent. The adapter owns peer selection
    /// and session isolation.
    public init?(
        datagramLimit: Int = defaultDatagramLimit, initialRate: Double = MessageTransport.initialRate,
        clock: @escaping () -> TimeInterval,
        dataHandler: @escaping (Data) -> Void,
        ioHandler: @escaping (IORequest) -> Bool
    ) {
        guard datagramLimit >= 64 else { return nil }
        rate = max(Self.minimumRate, initialRate)
        self.datagramLimit = min(datagramLimit, 1200)
        self.clock = clock
        self.dataHandler = dataHandler
        self.ioHandler = ioHandler
        credit = Double(2 * self.datagramLimit)
        creditAt = clock()
        lastDataSend = creditAt
        sampleAt = creditAt
        floorRotatedAt = creditAt
    }

    private var queuedBytes: Int { messages.values.reduce(0) { $0 + $1.queuedBytes } }
    private var queueDelay: TimeInterval { Double(queuedBytes) * 8 / rate }

    public var statistics: Statistics {
        var queued: [Priority: Int] = [:]
        for msg in messages.values { queued[msg.priority, default: 0] += msg.queuedBytes }
        return Statistics(
            bitsPerSecond: rate, roundTripTime: rtt, minimumRoundTripTime: minimumRTT,
            lossRatio: lossRatio, linkLossRatio: min(lossRatio, toleratedLoss), acceptedDataPackets: lastPacket, blocked: blocked, probing: probeAt != nil,
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
        if queueDelay > 0.035 { windowBacklogged = true }
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
        unconfirmed.removeAll()
        inFlightBytes = 0
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
                if ackReady {
                    // ACKs are tiny control datagrams: do not charge them to outbound data pacing
                    // credit or mix them into `windowBytes`.
                    if ioHandler(.sendDatagram(Wire.ack(largest, bitmap))) {
                        ackDue = nil
                        ackCount = 0
                    } else {
                        blocked = true
                    }
                    continue
                }
                if let key = candidate(now), let msg = messages[key.id] {
                    let cost = msg.size(key.index) + msg.header
                    if credit + 1e-7 >= Double(cost) {
                        transmit(key, msg)
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
            accept(number, receiver.accept(key, count: count, lifetime: lifetime, data: payload, now: now), now)
        case .repairable(let number, let key, let count, let last, let lifetime, let payload):
            accept(
                number,
                receiver.accept(key, count: count, last: last, lifetime: lifetime, data: payload, now: now),
                now)
        case nil: break
        }
    }

    private func accept(_ number: UInt32, _ result: (Bool, Bool, Data?), _ now: TimeInterval) {
        let (accepted, duplicate, complete) = result
        guard accepted else { return }
        let gap = UInt64(number) != UInt64(largest) + 1
        if number > largest {
            bitmap = (bitmap << (number - largest)) | 1
            largest = number
        } else {
            bitmap |= UInt64(1) << (largest - number)
        }
        ackCount += 1
        let urgent = duplicate || gap || ackCount >= Self.ackPacketThreshold
        ackDue = min(ackDue ?? .infinity, urgent ? now : now + Self.delayedAckInterval)
        if let complete { dataHandler(complete) }
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
                if sendings[record.window] != nil {
                    sendings[record.window]!.acknowledged += 1
                    sendings[record.window]!.acknowledgedBytes += record.bytes
                    sendings[record.window]!.acknowledgedSends.append((record.sent, record.bytes))
                    if record.lost { sendings[record.window]!.lost -= 1 }
                }
                let elapsed = max(0, now - record.sent)
                if elapsed <= 2 {
                    windowAcknowledged += record.bytes
                    confirmations += 1
                    windowFirstConfirmedSend = min(windowFirstConfirmedSend ?? record.sent, record.sent)
                    windowLastConfirmedAt = max(windowLastConfirmedAt ?? now, now)
                    // Sample RTT only when `largest` itself is newly acknowledged (RFC 9002), so
                    // out-of-order older packets do not inflate RTT and variance.
                    if offset == 0 { sample = elapsed }
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
            floorRTT = min(floorRTT ?? sample, sample)
            windowFastestRTT = min(windowFastestRTT ?? sample, sample)
            progressAt = now
            probeAt = nil
        }
        if !confirmed.isEmpty {
            for key in confirmed {
                guard let msg = messages[key.id] else { continue }
                msg.retries.remove(key.index)
                msg.spare.remove(key.index)
                msg.timeouts[key.index] = nil
                msg.remaining -= 1
                msg.confirmed += 1
                // With repair fragments, the peer has the message once it has this many.
                if msg.confirmed >= msg.count {
                    finish(key.id, .delivered)
                } else if msg.remaining == 0 {
                    finish(key.id, .expired)
                }
            }
            for (number, attempt) in attempts where confirmed.contains(attempt.key) {
                if attempt.expires != nil { inFlightBytes = max(0, inFlightBytes - attempt.bytes) }
                attempts.removeValue(forKey: number)
            }
            for key in confirmed { unconfirmed[key] = nil }
        }
        if !unconfirmed.isEmpty, highConfirmed.count == 3 {
            // A fragment waiting for its acknowledgement is lost once one that covers its packet
            // number shows it missing, behind three later packets that did arrive.
            var missing: Set<Wire.Fragment> = []
            for (number, attempt) in attempts
            where unconfirmed[attempt.key] != nil && number < highConfirmed[2] && number < largest
                && largest - number < 64 && bits & (UInt64(1) << (largest - number)) == 0
            {
                attempts[number]?.lossSeen = true
                missing.insert(attempt.key)
            }
            for key in missing {
                guard let msg = messages[key.id] else { continue }
                if !attempts.values.contains(where: { $0.key == key && !$0.lossSeen }) { abandon(key, msg) }
            }
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
        if !timeout { attempts[number]?.lossSeen = true }
        if attempts[number]?.expires != nil {
            inFlightBytes = max(0, inFlightBytes - attempt.bytes)
            attempts[number]?.expires = nil
        }
        let key = attempt.key
        guard let msg = messages[key.id] else {
            attempts.removeValue(forKey: number)
            return
        }
        // Retransmit as often as the budget allows. The lost attempt stays on record so a late
        // acknowledgement can still confirm the fragment.
        if viable(msg, now) {
            if timeout { msg.timeouts[key.index] = min(5, msg.timeouts[key.index, default: 0] + 1) }
            msg.spare.insert(key.index)
            msg.reinforce()
        } else {
            for index in msg.spare { abandon(.init(id: key.id, index: index), msg) }
            abandon(key, msg)
        }
    }

    /// Gives up on one fragment. Unless repair fragments make up for it the message can no
    /// longer complete, but its other fragments still run their course: a loss verdict can be
    /// wrong, and the fragment may have arrived.
    private func abandon(_ key: Wire.Fragment, _ msg: Message) {
        if unconfirmed[key] == nil {
            let sent = attempts.values.filter { $0.key == key }
            if !sent.isEmpty, !sent.contains(where: \.lossSeen) {
                // Sent, and nothing says it went missing: wait a little for an acknowledgement
                // before telling the application it was lost. It is not sent again meanwhile.
                unconfirmed[key] = clock() + max(0.1, 2 * (rtt ?? 0.05))
                msg.retries.remove(key.index)
                msg.spare.remove(key.index)
                return
            }
        }
        unconfirmed[key] = nil
        for (number, attempt) in attempts where attempt.key == key {
            if attempt.expires != nil { inFlightBytes = max(0, inFlightBytes - attempt.bytes) }
            attempts.removeValue(forKey: number)
        }
        msg.retries.remove(key.index)
        msg.spare.remove(key.index)
        msg.timeouts[key.index] = nil
        msg.remaining -= 1
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
                for index in msg.retries.union(msg.spare) { abandon(.init(id: id, index: index), msg) }
            }
        }
        for (key, deadline) in unconfirmed where deadline <= now {
            if let msg = messages[key.id] {
                abandon(key, msg)
            } else {
                unconfirmed[key] = nil
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
        if now >= floorRotatedAt + 5 {
            previousFloorRTT = floorRTT
            floorRTT = nil
            floorRotatedAt = now
        }
        if now >= sampleAt + 0.25 {
            let interval = now - sampleAt
            // A suspicion that survived a window without an acknowledgement is a loss.
            for number in agingLosses {
                let slot = Int(number) % deliveryRecords.count
                guard let record = deliveryRecords[slot], record.number == number, !record.lost else { continue }
                deliveryRecords[slot]?.lost = true
                sendings[record.window]?.lost += 1
                let earliest = min(sendings[record.window]?.firstLostSent ?? record.sent, record.sent)
                let latestLost = max(sendings[record.window]?.lastLostSent ?? record.sent, record.sent)
                sendings[record.window]?.firstLostSent = earliest
                sendings[record.window]?.lastLostSent = latestLost
                sendings[record.window]?.lostSends.append((record.sent, record.bytes))
            }
            sendings[windowIndex, default: Sending()].interval = interval
            history.append(Window(
                interval: interval, sent: windowBytes, acknowledged: windowAcknowledged,
                packets: windowPackets, losses: agingLosses.count))
            if history.count > 4 { history.removeFirst() }
            if interval > 1.5 {
                deliveryRate = 0
            } else {
                updateDeliveryRate()
            }
            adjustRate(now, interval: interval)
            holdToPolicedCap(now)
            confirmations = 0
            windowBytes = 0
            windowAcknowledged = 0
            windowPackets = 0
            windowBacklogged = false
            windowFirstConfirmedSend = nil
            windowLastConfirmedAt = nil
            windowFastestRTT = nil
            agingLosses = suspectedLosses
            suspectedLosses.removeAll(keepingCapacity: true)
            sampleAt = now
            windowIndex += 1
            sendings[windowIndex] = Sending()
            sendings[windowIndex - 32] = nil
        }
    }

    private func learnPolicedCap(_ measured: Double, _ now: TimeInterval) {
        // Found again soon after trying more: the link has not changed, wait longer next time.
        if let known = policedCap, now - known.at < policedCapHold + 10 {
            policedCapHold = min(Self.maximumPolicedCapHold, policedCapHold * 2)
        }
        policedCap = (max(Self.minimumRate, measured), now)
    }

    private func holdToPolicedCap(_ now: TimeInterval) {
        guard var cap = policedCap else { return }
        // Only a session that has kept sending at the cap for the last two seconds has a use
        // for more, and only it can show whether the link gives more.
        let recent = (windowIndex - 7...windowIndex).compactMap { sendings[$0] }
        let sent = recent.reduce(0.0) { $0 + Double($1.bytes) * 8 }
        let span = recent.reduce(0.0) { $0 + $1.interval }
        if span >= 1.5, sent / span >= cap.rate * 0.9, now - cap.at >= policedCapHold {
            cap = (cap.rate * Self.policedCapStep, now)
            policedCap = cap
        }
        rate = min(rate, cap.rate)
    }

    /// Tracks the rolling 1-second delivered rate every 0.25 s, rising immediately when more
    /// traffic is confirmed and decaying gently (~1.1 s half-life) across brief quiet dips.
    /// Requires at least 0.5 s of history so a single short burst does not establish a rate.
    private func updateDeliveryRate() {
        let duration = history.reduce(0.0) { $0 + $1.interval }
        guard history.count >= 2, duration >= 0.45 else { return }
        let bytes = history.reduce(0) { $0 + $1.acknowledged }
        let measured = Double(bytes) * 8 / duration
        if deliveryRate == 0 {
            deliveryRate = measured
        } else if measured >= deliveryRate {
            // Rise smoothly every 0.25 s (~0.6 s half-life) so rate climbs promptly without
            // overshooting shallow buffers on a sudden demand jump.
            deliveryRate = deliveryRate * 0.75 + measured * 0.25
        } else {
            // Decay gently (~1.4 s half-life) so brief 1-second quiet spells do not stall probing.
            deliveryRate = deliveryRate * 0.88 + measured * 0.12
        }
    }

    /// Re-anchors `deliveryRate` to what the link actually carried right before backoff so stale
    /// pre-congestion peaks cannot prematurely reopen `probeCeiling`.
    private func resetDeliveryRateAfterBackoff() {
        let recent = history.suffix(2)
        let duration = recent.reduce(0.0) { $0 + $1.interval }
        guard duration > 0 else {
            deliveryRate = 0
            return
        }
        let bytes = recent.reduce(0) { $0 + $1.acknowledged }
        deliveryRate = min(deliveryRate, Double(bytes) * 8 / duration)
    }

    /// One step of rate control, on a quarter second of evidence.
    private func adjustRate(_ now: TimeInterval, interval: TimeInterval) {
        // A window stretched by silence says nothing about the link.
        guard interval <= 1.5 else {
            history.removeAll()
            healthyFeedbackTime = 0
            return
        }
        let queued = queuedBytes > 0
        // Timing variation on sparse traffic does not measure link capacity.
        let utilized = Double(windowBytes) * 8 >= rate * interval * 0.5
        let tolerance = max(0.02, (minimumRTT ?? 0) * 0.25)
        var queueDelay: TimeInterval?
        if confirmations >= 8, let fastest = windowFastestRTT, let floor = minimumRTT {
            queueDelay = max(0, fastest - floor)
        }
        if (queueDelay ?? 0) <= tolerance {
            cutQueueDelay = nil
            futileCuts = 0
        }
        // The first sign of a queue ends the quick climb, before it has to be undone.
        if (queueDelay ?? 0) > tolerance / 2 {
            startup = false
            queueSeenAt = now
        }
        if let tested = probe, let queueDelay, queueDelay > tolerance / 2, queueDelay <= tolerance, now >= holdUntil {
            // A queue is forming under the step: far enough. Back to before it, while that
            // costs nothing yet.
            rate = min(rate, tested.base)
            mark(rate, now, policed: false, measured: false)
            return
        }
        let loss = lossRatio
        // The newest window whose deliveries are all in. Its losses are not: what it shows
        // lost so far is the least it lost.
        let latest = windowIndex - settling + 1
        let onset = sendings[latest] ?? Sending()
        if var trial = lossTrial {
            if latest < trial.start, onset.exceeds(toleratedLoss), onset.carriedRate < trial.delivered * 0.9 {
                // Sent before the reduction, and less of it got through than the reduction was
                // sized for: the loss had only begun. Reduce once more, to what this shows.
                trial.delivered = onset.policedRate ?? onset.carriedRate
                trial.underLoss = onset.policedRate != nil
                trial.thin = onset.policedRate == nil && (onset.bursty || onset.acknowledged + onset.lost < 40)
                trial.sent = onset.offeredRate
                trial.reference = max(trial.reference, onset.lossRatio)
                trial.start = windowIndex + 1
                lossEpoch = windowIndex + 1
                rate = max(Self.minimumRate, trial.thin ? rate * 0.5 : 0, min(rate, trial.delivered * 0.9))
                lossTrial = trial
            } else if latest < trial.start {
                trial.reference = max(trial.reference, onset.lossRatio)
                lossTrial = trial
            }
            let settled = windowIndex - settling
            if settled >= trial.start + 2 {
                lossTrial = nil
                let (acknowledged, lost) = outcome(from: trial.start, through: settled)
                let after = acknowledged + lost > 0 ? Double(lost) / Double(acknowledged + lost) : 0
                if acknowledged + lost < 30 {
                    // Too little was sent to tell. Nothing is learned either way.
                    rate = max(rate, trial.rate)
                } else if after > trial.reference * 0.4, after <= trial.reference * 0.7 {
                    // Less, but not gone: this could be chance either way. Nothing is learned.
                    rate = max(rate, trial.rate)
                } else if after <= trial.reference * 0.4 {
                    // Sending less ended the loss: the link was full, and what got through
                    // then is what it carries. Return to that.
                    // The budget that makes the application send just under that: by how much
                    // it overshot, it comes down. One that spends little of its budget is
                    // held to a margin over what it did send.
                    let share = trial.sent > 0 ? min(1, trial.delivered / trial.sent) : 1
                    rate = max(rate, min(trial.rate * share * Self.fill, trial.delivered * Self.headroom))
                    let policed = now - queueSeenAt > 3
                    if policed, trial.underLoss { learnPolicedCap(trial.delivered, now) }
                    if trial.thin {
                        // Not a measurement of the link: no wall to keep to, steps stay as they were.
                        lossEpoch = windowIndex + 1
                    } else {
                        mark(rate, now, policed: policed)
                    }
                    if after > toleratedLoss {
                        // What is left is not for want of capacity.
                        toleratedLoss = min(Self.maximumToleratedLoss, after * 1.3 + 0.01)
                        toleratedLossAt = now
                    }
                    linkVerdicts = 0
                    nextLossTrial = now
                } else {
                    // Sending less changed nothing, so this loss is the link's own. Put the
                    // rate back and stop reading loss at this level as a sign of congestion.
                    toleratedLoss = min(Self.maximumToleratedLoss, max(toleratedLoss, after * 1.3 + 0.01))
                    toleratedLossAt = now
                    rate = max(rate, trial.rate)
                    // Loss beyond what is accepted keeps asking the question. Ask it less often.
                    linkVerdicts += 1
                    nextLossTrial = now + min(30, Double(1 << min(linkVerdicts, 5)))
                }
                // What was lost before the reduction is still in the last second's count.
                holdUntil = max(holdUntil, now + 0.5)
                return
            }
        }
        if toleratedLoss > 0.02, now >= toleratedLossAt + 30 {
            // Test the assumption again now and then.
            toleratedLoss = max(0.02, toleratedLoss * 0.7)
            toleratedLossAt = now
        }

        if let queueDelay, queueDelay > tolerance, now >= holdUntil {
            healthyFeedbackTime = 0
            if let before = cutQueueDelay, queueDelay > before * 0.75 {
                futileCuts += 1
            } else {
                futileCuts = 0
            }
            if futileCuts >= 2 {
                // Two reductions did not shorten the queue: the delay is a longer path or
                // someone else's traffic, and giving way further would only starve this session.
                floorRTT = windowFastestRTT
                previousFloorRTT = nil
                floorRotatedAt = now
                futileCuts = 0
                cutQueueDelay = nil
                // With the floor moved, a queue that is still there no longer shows. Nothing
                // is raised on the strength of it having gone: steps up wait until the floor
                // has had time to come back down, and there is no way back to a ceiling.
                nextProbe = max(nextProbe, now + 5)
                recoveryCeiling = 0
                return
            }
            // A standing queue means the link is saturated, so what it delivered of what was
            // sent (excluding packets still within one RTT of transmission) is what it can carry.
            let recent = history.suffix(2)
            let sent = recent.reduce(0) { $0 + $1.sent }
            let acknowledged = recent.reduce(0) { $0 + $1.acknowledged }
            let rttWindow = rtt ?? 0.05
            let youngInFlight = attempts.values.reduce(0) { sum, attempt in
                attempt.expires != nil && now - attempt.sent <= rttWindow ? sum + attempt.bytes : sum
            }
            let eligibleSent = max(acknowledged, sent - youngInFlight)
            let carried = eligibleSent > 0 ? max(0.25, min(1, Double(acknowledged) / Double(eligibleSent))) : 1
            // The budget also comes down to where the application sends just under what the
            // link was seen to deliver: by the share of the budget it has been spending, or,
            // for one that spends little of it and would not be slowed by a share off, to a
            // margin over what arrived. On a long queue most of what was sent is still on its
            // way and `carried` says little; this then is what holds.
            let duration = recent.reduce(0.0) { $0 + $1.interval }
            let delivered = duration > 0 ? Double(acknowledged) * 8 / duration : rate
            let spending = duration > 0 ? min(1, Double(sent) * 8 / duration / rate) : 1
            let sustainable = max(
                Self.minimumRate,
                min(rate * 0.9 * carried, delivered * min(Self.headroom, Self.fill / max(spending, 0.01))))
            startup = false
            resetDeliveryRateAfterBackoff()
            recoveryCeiling = sustainable
            // An application spending little of its budget says little about the link by what
            // arrived: then the cut goes at most halfway and leaves no wall behind.
            let appLimited = spending < 0.5
            mark(sustainable, now, policed: false, measured: !appLimited)
            rate = max(Self.minimumRate, appLimited ? rate * 0.5 : 0, sustainable * max(0.5, 1 - queueDelay))
            cutQueueDelay = queueDelay
            holdUntil = now + max(0.5, 2 * (rtt ?? 0))
            lossTrial = nil
        } else if lossExceeds(toleratedLoss, onset: onset), lossTrial == nil, now >= max(holdUntil, nextLossTrial) {
            healthyFeedbackTime = 0
            if stepInDoubt(now) {
                // The step up met loss: this is as far as the link goes. Back to what got
                // through, without a trial, and let what was sent meanwhile clear before
                // reading loss again.
                let share = onset.sentRate > 0 ? min(1, onset.deliveredRate / onset.sentRate) : 1
                let thin = onset.policedRate == nil && (onset.bursty || onset.acknowledged + onset.lost < 40)
                rate = max(Self.minimumRate, thin ? rate * 0.5 : 0, min(rate * share * Self.fill, wall?.rate ?? rate))
                // Sized by what got through once an overrun limit began to drop. Whether it is one is
                // left to a loss trial to settle, as a step can meet loss of any kind.
                if let held = onset.policedRate { rate = max(Self.minimumRate, min(rate, held * Self.fill)) }
                mark(rate, now, policed: now - queueSeenAt > 3, measured: false)
                holdUntil = now + Double(settling + 4) * 0.25
                return
            }
            // If the link is full, what got through is what it carries, and sending less than
            // that ends the loss. The reduction is taken from what was delivered, not from the
            // budget: an application that spends less than its budget would not feel a cut in it.
            // The window that shows the loss: the newest settled one if it does, else the one that
            // lost most of the last second's, not a quiet one the longer count happened to end on.
            let settledIndex = windowIndex - settling
            var sample = onset.exceeds(toleratedLoss) ? onset : sendings[settledIndex] ?? onset
            // Unless that one was all but quiet and an overrun limit shows in another: a cut
            // sized by a quiet window lands far below what the link carries.
            if sample.policedRate == nil,
                let overrun = (settledIndex - 3...settledIndex).compactMap({ sendings[$0] })
                    .filter({ $0.policedRate != nil }).max(by: { $0.lost < $1.lost })
            {
                sample = overrun
            }
            // Of a burst a queue took in, all is delivered in the end, but no faster than
            // the link carries: what arrived lately bounds what counts as delivered.
            let lately = history.suffix(2)
            let span = lately.reduce(0.0) { $0 + $1.interval }
            let arriving = span > 0 ? Double(lately.reduce(0) { $0 + $1.acknowledged }) * 8 / span : .infinity
            // An application that sends in bursts with quiet between would be read as a slow link
            // from the window's average: what got through while it was sending is what counts.
            let delivered =
                sample.policedRate.map { max(Self.minimumRate, $0) }
                ?? (sample.bursty
                    ? max(Self.minimumRate, sample.carriedRate)
                    : max(Self.minimumRate, min(sample.deliveredRate, max(arriving, sample.deliveredRate * 0.5))))
            // A window with little in it, or sent in bursts (an application that had just stopped
            // sending), can read far below what the link carries. A cut on its strength goes at
            // most halfway; if the loss goes on, the next one goes further.
            let thin = sample.policedRate == nil && (sample.bursty || sample.acknowledged + sample.lost < 40)
            lossTrial = LossTrial(
                rate: rate, reference: max(loss, sample.lossRatio), delivered: delivered,
                sent: max(delivered, sample.offeredRate), start: windowIndex + 1,
                underLoss: sample.policedRate != nil, thin: thin)
            startup = false
            lossEpoch = windowIndex + 1
            rate = max(Self.minimumRate, thin ? rate * 0.5 : 0, min(rate, delivered * 0.9))
        } else if confirmations > 0, loss <= toleratedLoss, !onset.exceeds(toleratedLoss),
            (queueDelay ?? 0) <= tolerance / 2,
            probeAt == nil, lossTrial == nil, now >= holdUntil
        {
            healthyFeedbackTime += min(interval, 0.5)
            // When the local pacer itself was backlogged (>35 ms) during a clean 0.25 s window and
            // we are not draining after a congestion backoff, measure the active burst delivery rate
            // so short high-bitrate desktop bursts (like opening a Dock grid) prove link capacity
            // without waiting for a full quiet-free second to lift the 1 s average.
            if let known = capacityMark, now - known.at >= Self.markLifetime, !stepInDoubt(now) { capacityMark = nil }
            if let at = passed, now - at >= Self.doubt {
                // The step has held.
                passed = nil
                if let known = wall, rate > known.rate * Self.clearOfWall {
                    // Well past where the link kept being full: it has more to give now.
                    wall = nil
                    probeWait = Self.firstProbeWait
                }
            }
            var pacerLimited = false
            var burstRate = 0.0
            if history.count >= 2, recoveryCeiling == 0, windowBacklogged,
                confirmations >= 8, windowAcknowledged >= 8 * datagramLimit,
                let firstSend = windowFirstConfirmedSend, let lastAck = windowLastConfirmedAt
            {
                let activeSpan = min(interval, max(0.06, lastAck - firstSend - (minimumRTT ?? 0)))
                burstRate = Double(windowAcknowledged) * 8 / activeSpan
                if burstRate >= rate * 0.70 {
                    pacerLimited = true
                    deliveryRate = max(deliveryRate, min(rate, burstRate))
                }
            }
            let sentLately = ((sendings[latest - 1]?.sentRate ?? onset.sentRate) + onset.sentRate) / 2
            if let tested = probe, windowIndex >= tested.expires,
                !(pacerLimited || tested.exercised.map { sentLately >= $0 } ?? false)
            {
                // Never tried: the application had no use for it. Nothing is known about it,
                // so it is not kept.
                rate = min(rate, tested.base)
                probe = nil
                nextProbe = now + probeWait
            }
            if let tested = probe, windowIndex >= tested.verify,
                pacerLimited || tested.exercised.map({ sentLately >= $0 }) ?? false
            {
                // The step was used and nothing pushed back: more was sent, or bursts were held
                // back by the budget alone and went through. The next can be larger. Against
                // a wall it first has to hold: what passes at once there often fails late.
                probe = nil
                passed = now
                if let known = wall, rate <= known.rate * Self.clearOfWall {
                    // Still near where the link was last full: keep to small steps, which cost
                    // next to nothing when they fail, until clear of it.
                    probeStep = Self.firstProbeStep
                } else {
                    probeStep = min(Self.maximumProbeStep, probeStep * 2.5)
                    if wall?.policed == false { wall = nil }
                }
                nextProbe = steadyWall ? now + Self.doubt : now
                capacityMark = (rate, now)
            }
            let used = queued || utilized || pacerLimited
            // A budget counts as proven once it has been used for two seconds without trouble:
            // sooner, trouble may simply not have shown yet.
            if used, proving.map({ rate > $0.rate }) ?? true { proving = (rate, now) }
            if let held = proving, now - held.at >= 2, proven.map({ held.rate > $0.rate || now - $0.at > 120 }) ?? true {
                proven = (held.rate, now)
            }
            if min(recoveryCeiling, probeCeiling) > rate && healthyFeedbackTime >= 0.5 {
                // The queue has emptied: return to what the link was just shown to carry.
                rate = min(recoveryCeiling, probeCeiling, rate * 1.15)
                healthyFeedbackTime = 0
            } else if used, probe == nil, let known = capacityMark, rate < known.rate * 0.98 {
                // Below what the link is known to carry: go back there.
                rate = min(known.rate, rate * 1.25)
            } else if used, capacityMark != nil {
                if probe == nil, now >= nextProbe {
                    // Test a higher rate: boldly where this much was carried not long ago and
                    // the link has not just shown otherwise.
                    // Steps are sized for a short round trip. On a long one their effect shows
                    // later and lasts longer, so they are smaller.
                    let reach = min(1, 0.12 / max(rtt ?? 0.05, 0.03))
                    var step = probeStep * reach
                    steppedBoldly = false
                    if !steadyWall, probeStep > Self.firstProbeStep, let known = proven, now - known.at <= 120,
                        rate * (1 + Self.maximumProbeStep) <= known.rate
                    {
                        step = Self.maximumProbeStep * reach
                        steppedBoldly = true
                    }
                    // What was sent over the last second, against which the step has to show.
                    let before = (windowIndex - 3...windowIndex).compactMap { sendings[$0]?.sentRate }
                    let sentBefore = before.reduce(0, +) / Double(max(1, before.count))
                    probe = Probe(
                        base: rate, verify: windowIndex + 1 + settling, expires: windowIndex + 13 + settling,
                        exercised: sentBefore >= rate * 0.6 ? sentBefore * (1 + 0.5 * step) : nil)
                    rate = min(100_000_000, rate * (1 + step))
                }
            } else if used && (pacerLimited || probeCeiling > rate) {
                // (Reached only without a capacity mark.)
                // The link has not pushed back yet, or not for a while. Probe upward when the
                // budget is used, aggressively when the pacer itself is bottlenecking clean
                // bursts (especially on low-RTT LAN paths during startup).
                let lowRTT = (minimumRTT ?? .infinity) < 0.02
                let step: Double
                let ceiling: Double
                if pacerLimited {
                    step = startup ? (lowRTT ? 2.0 : 1.50) : (lowRTT ? 1.40 : 1.20)
                    ceiling = max(probeCeiling, min(rate, burstRate) * step)
                } else {
                    step = startup ? 1.05 : 1.02
                    ceiling = probeCeiling
                }
                rate = min(100_000_000, ceiling, rate * step)
            }
            // An application that sends little since never earns the way back. The ceiling
            // then only stands in the way of what its bursts can show.
            if rate >= recoveryCeiling || (probeCeiling <= rate && healthyFeedbackTime >= 1) { recoveryCeiling = 0 }
        } else if probeAt != nil {
            healthyFeedbackTime = 0
        }
    }

    private func reduceRate() {
        resetDeliveryRateAfterBackoff()
        recoveryCeiling = max(recoveryCeiling, min(rate, deliveryRate))
        healthyFeedbackTime = 0
        startup = false
        rate = max(Self.minimumRate, rate * 0.8)
    }

    private func candidate(_ now: TimeInterval) -> Wire.Fragment? {
        if let probeAt {
            if now < probeAt { return nil }
        } else if inFlightBytes >= maxInFlightBytes {
            return nil
        }
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
            if msg.cursor < msg.total { return .init(id: id, index: msg.cursor) }
        }
        return nil
    }

    private func transmit(_ key: Wire.Fragment, _ msg: Message) {
        guard lastPacket < .max else {
            close(.sequenceExhausted)
            return
        }
        let lifetime = msg.deadline - clock()
        let payload = msg.payload(key.index)
        let bytes =
            msg.repair > 0
            ? Wire.repairable(
                lastPacket + 1, key, count: msg.count, last: msg.size(msg.count - 1), lifetime: lifetime,
                payload)
            : Wire.data(lastPacket + 1, key, msg.count, lifetime: lifetime, payload)
        guard ioHandler(.sendDatagram(bytes)) else {
            blocked = true
            return
        }
        lastPacket += 1
        if msg.retries.remove(key.index) == nil {
            msg.cursor += 1
            // Repair fragments are extra: the first-send deadline is met without them.
            if msg.cursor == msg.count { msg.firstDeadline = nil }
        }
        let sent = clock()
        lastDataSend = sent
        let timeout = min(0.5, rto * Double(1 << msg.timeouts[key.index, default: 0]))
        deliveryRecords[Int(lastPacket) % deliveryRecords.count] = DeliveryRecord(
            number: lastPacket, sent: sent, bytes: bytes.count, window: windowIndex)
        sendings[windowIndex, default: Sending()].packets += 1
        sendings[windowIndex, default: Sending()].bytes += bytes.count
        if sendings[windowIndex]?.firstSent == nil { sendings[windowIndex]?.firstSent = sent }
        sendings[windowIndex]?.lastSent = sent
        attempts[lastPacket] = Attempt(key: key, sent: sent, bytes: bytes.count, expires: sent + timeout)
        inFlightBytes += bytes.count
        if progressAt == nil { progressAt = sent }
        if probeAt != nil {
            probeAt = sent + probeInterval
            probeInterval = min(0.5, 2 * probeInterval)
        }
        credit -= Double(bytes.count)
        windowBytes += bytes.count
        windowPackets += 1
    }

    private func nextDeadline(_ now: TimeInterval) -> TimeInterval {
        var wake = receiver.nextExpiry ?? .infinity
        if !blocked, let ackDue, ackDue > now { wake = min(wake, ackDue) }
        for msg in messages.values {
            wake = min(wake, msg.firstDeadline ?? .infinity)
            if msg.deadline > now { wake = min(wake, msg.deadline) }
        }
        for attempt in attempts.values { wake = min(wake, attempt.expires ?? .infinity) }
        for deadline in unconfirmed.values { wake = min(wake, deadline) }
        if let probeAt {
            if !blocked && probeAt > now { wake = min(wake, probeAt) }
        } else if let start = progressAt {
            wake = min(wake, start + probeDelay)
        }
        return wake
    }
}
