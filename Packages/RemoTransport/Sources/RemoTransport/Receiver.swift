import Foundation

struct Receiver {
    /// How long a partial message outlives the sender's retries, for datagrams still in flight.
    static let grace: TimeInterval = 0.5
    static let maxAssemblies = 32
    static let maxBufferedBytes = 4 << 20

    private struct Assembly {
        let count: Int
        /// The size of the last data fragment, for a message sent with repair fragments.
        let last: Int?
        /// When the sender stops retransmitting, as far as its fragments have said.
        var retryEnd: TimeInterval
        var parts: [Int: Data] = [:]
        var size = 0
        var deadline: TimeInterval { retryEnd + Receiver.grace }
    }

    private var highest: UInt32 = 0
    private var finished: Set<UInt32> = []
    private var assemblies: [UInt32: Assembly] = [:]
    private var buffered = 0

    var nextExpiry: TimeInterval? { assemblies.values.map(\.deadline).filter(\.isFinite).min() }

    private mutating func remove(_ id: UInt32) {
        buffered -= assemblies.removeValue(forKey: id)?.size ?? 0
    }

    mutating func expire(_ now: TimeInterval) {
        for (id, assembly) in assemblies where assembly.deadline <= now {
            remove(id)
            finished.insert(id)
        }
    }

    /// Returns whether to acknowledge, whether this is a duplicate, and any complete message.
    /// A fragment that isn't acknowledged was not kept, so the sender retries it.
    /// `last` is given for a message sent with repair fragments, which completes as soon as
    /// any `count` of its fragments are here.
    mutating func accept(
        _ key: Wire.Fragment, count: Int, last: Int? = nil, lifetime: TimeInterval, data: Data,
        now: TimeInterval
    ) -> (Bool, Bool, Data?) {
        let id = key.id
        if id > highest {
            highest = id
            if id > Wire.messageWindow {
                // The sender has finished with everything this far behind.
                let floor = id - (Wire.messageWindow - 1)
                finished = finished.filter { $0 >= floor }
                for old in assemblies.keys where old < floor { remove(old) }
            }
        }
        if highest - id >= Wire.messageWindow || finished.contains(id) {
            // Fragments beyond the ones that completed a repairable message are expected, and
            // say nothing about the sender having missed an acknowledgement.
            return (true, last == nil, nil)
        }
        if let existing = assemblies[id] {
            guard existing.count == count, existing.last == last else { return (false, false, nil) }
            if let previous = existing.parts[key.index] {
                guard previous == data else { return (false, true, nil) }
                assemblies[id]!.retryEnd = max(existing.retryEnd, now + lifetime)
                return (true, true, nil)
            }
        }
        if count == 1 && key.index == 0 {
            finished.insert(id)
            return (true, false, data)
        }
        // Make room only at the expense of messages their sender has stopped retrying. Dropping
        // one it still retries would acknowledge fragments of a message that never completes.
        while (assemblies[id] == nil && assemblies.count >= Self.maxAssemblies)
            || buffered + data.count > Self.maxBufferedBytes
        {
            guard
                let stale = assemblies.filter({ $0.key != id && $0.value.retryEnd <= now }).min(by: {
                    ($0.value.retryEnd, $0.key) < ($1.value.retryEnd, $1.key)
                })?.key
            else { return (false, false, nil) }
            remove(stale)
            finished.insert(stale)
        }
        // Mutate in place: a copy of the assembly would copy every part on each fragment.
        if assemblies[id] == nil {
            assemblies[id] = Assembly(count: count, last: last, retryEnd: now + lifetime)
        }
        assemblies[id]!.retryEnd = max(assemblies[id]!.retryEnd, now + lifetime)
        assemblies[id]!.parts[key.index] = Data(data)
        assemblies[id]!.size += data.count
        buffered += data.count
        guard assemblies[id]!.parts.count == count else { return (true, false, nil) }
        let complete = assemblies[id]!
        remove(id)
        finished.insert(id)
        var fragments: [Data]?
        if let last {
            let length = complete.parts.values.reduce(0) { max($0, $1.count) }
            fragments = Repair.decode(complete.parts, count: count, length: length)
            if let rebuilt = fragments?[count - 1] { fragments![count - 1] = rebuilt.prefix(last) }
        } else {
            fragments = (0..<count).map { complete.parts[$0]! }
        }
        guard let fragments else { return (true, false, nil) }
        var payload = Data(capacity: complete.size)
        for fragment in fragments { payload.append(fragment) }
        return (true, false, payload)
    }
}
