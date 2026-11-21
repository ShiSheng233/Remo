import Foundation

struct Receiver {
    /// How long a partial message outlives the sender's retries, for datagrams still in flight.
    static let grace: TimeInterval = 0.5
    static let maxAssemblies = 32
    static let maxBufferedBytes = 4 << 20

    private struct Assembly {
        let count: Int
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
    mutating func accept(
        _ key: Wire.Fragment, count: Int, lifetime: TimeInterval, data: Data, now: TimeInterval
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
        if highest - id >= Wire.messageWindow || finished.contains(id) { return (true, true, nil) }
        if let existing = assemblies[id] {
            guard existing.count == count else { return (false, false, nil) }
            if let previous = existing.parts[key.index] {
                guard previous == data else { return (false, true, nil) }
                assemblies[id]!.retryEnd = max(existing.retryEnd, now + lifetime)
                return (true, true, nil)
            }
        }
        if count == 1 {
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
        if assemblies[id] == nil { assemblies[id] = Assembly(count: count, retryEnd: now + lifetime) }
        assemblies[id]!.retryEnd = max(assemblies[id]!.retryEnd, now + lifetime)
        assemblies[id]!.parts[key.index] = Data(data)
        assemblies[id]!.size += data.count
        buffered += data.count
        guard assemblies[id]!.parts.count == count else { return (true, false, nil) }
        let complete = assemblies[id]!
        var payload = Data(capacity: complete.size)
        for index in 0..<count { payload.append(complete.parts[index]!) }
        remove(id)
        finished.insert(id)
        return (true, false, payload)
    }
}
