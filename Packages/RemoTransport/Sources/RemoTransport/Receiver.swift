import Foundation

struct Receiver {
    private struct Assembly {
        let count: Int
        let deadline: TimeInterval
        var parts: [Int: Data] = [:]
        var size = 0
    }

    private var nextReliable: UInt64 = 1
    private var reliable: [UInt32: Data] = [:]
    private var highestUnreliable: UInt32 = 0
    private var finished: Set<UInt32> = []
    private var assemblies: [UInt32: Assembly] = [:]
    private var buffered = 0
    var paused = false

    var nextExpiry: TimeInterval? { assemblies.values.map(\.deadline).min() }

    private mutating func remove(_ id: UInt32) {
        buffered -= assemblies.removeValue(forKey: id)?.size ?? 0
    }

    mutating func expire(_ now: TimeInterval) {
        for (id, assembly) in assemblies where assembly.deadline <= now {
            remove(id)
            finished.insert(id)
        }
    }

    mutating func popReliable() -> Data? {
        guard !paused, let id = UInt32(exactly: nextReliable),
            let data = reliable.removeValue(forKey: id)
        else { return nil }
        nextReliable += 1
        return data
    }

    /// Returns whether to acknowledge, whether this is a duplicate, and any complete U message.
    mutating func accept(_ key: Wire.Fragment, count: Int, data: Data, now: TimeInterval) -> (
        Bool, Bool, Data?
    ) {
        let id = key.id
        if key.reliable {
            guard UInt64(id) >= nextReliable else { return (true, true, nil) }
            guard UInt64(id) < nextReliable + 32 else { return (false, false, nil) }
            if let previous = reliable[id] { return (previous == data, true, nil) }
            reliable[id] = Data(data)
            return (true, false, nil)
        }

        if id > highestUnreliable {
            highestUnreliable = id
            if id > 1024 {
                let floor = id - 1023
                finished = finished.filter { $0 >= floor }
                for old in assemblies.keys where old < floor { remove(old) }
            }
        }
        if highestUnreliable - id >= 1024 || finished.contains(id) { return (true, true, nil) }
        if let existing = assemblies[id] {
            guard existing.count == count else { return (false, false, nil) }
            if let previous = existing.parts[key.index] { return (previous == data, true, nil) }
        }
        if count == 1 {
            finished.insert(id)
            return (true, false, data)
        }
        while (assemblies[id] == nil && assemblies.count >= 32) || buffered + data.count > 4 << 20 {
            guard
                let oldest = assemblies.min(by: {
                    ($0.value.deadline, $0.key) < ($1.value.deadline, $1.key)
                })?.key
            else { break }
            remove(oldest)
            finished.insert(oldest)
            if oldest == id { return (true, false, nil) }
        }
        if assemblies[id] == nil { assemblies[id] = Assembly(count: count, deadline: now + 0.5) }
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
