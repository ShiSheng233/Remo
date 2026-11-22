import Foundation

enum Wire {
    static let maxMessage = 1 << 20
    /// A sender keeps every unfinished message within this many IDs of its oldest one, so the
    /// receiver's duplicate window never mistakes a message still being retried for an old one.
    static let messageWindow: UInt32 = 1024
    static let singleHeader = 9
    static let fragmentHeader = 15
    static let repairableHeader = 17

    struct Fragment: Hashable {
        let id: UInt32
        let index: Int
    }

    enum Packet {
        /// Packet number, fragment, fragment count, the sender's remaining retry time and payload.
        case data(UInt32, Fragment, Int, TimeInterval, Data)
        /// A fragment of a message sent with repair fragments, which are numbered from the data
        /// fragment count. Also carries the size of the last data fragment, since that one may
        /// have to be rebuilt.
        case repairable(UInt32, Fragment, count: Int, last: Int, TimeInterval, Data)
        case ack(UInt32, UInt64)
    }

    private static func append<T: FixedWidthInteger>(_ n: T, to bytes: inout Data) {
        withUnsafeBytes(of: n.bigEndian) { bytes.append(contentsOf: $0) }
    }

    private static func append(lifetime: TimeInterval, to bytes: inout Data) {
        let units = (max(0, lifetime) * 100).rounded(.up)
        append(units < Double(UInt16.max) ? UInt16(units) : lifetime.isFinite ? .max - 1 : .max, to: &bytes)
    }

    static func ack(_ largest: UInt32, _ bits: UInt64) -> Data {
        var bytes = Data([0x80])
        append(largest, to: &bytes)
        append(bits, to: &bytes)
        return bytes
    }

    /// `lifetime` is how much longer the sender may retransmit this message. Fragments carry it
    /// in 10 ms units so the receiver knows how long a partial message is worth keeping.
    static func data(
        _ number: UInt32, _ key: Fragment, _ count: Int, lifetime: TimeInterval = 0, _ payload: Data
    ) -> Data {
        var bytes = Data([count == 1 ? 0 : 1])
        append(number, to: &bytes)
        append(key.id, to: &bytes)
        if count > 1 {
            append(UInt16(key.index), to: &bytes)
            append(UInt16(count), to: &bytes)
            append(lifetime: lifetime, to: &bytes)
        }
        bytes.append(payload)
        return bytes
    }

    static func repairable(
        _ number: UInt32, _ key: Fragment, count: Int, last: Int, lifetime: TimeInterval, _ payload: Data
    ) -> Data {
        var bytes = Data([2])
        append(number, to: &bytes)
        append(key.id, to: &bytes)
        append(UInt16(key.index), to: &bytes)
        append(UInt16(count), to: &bytes)
        append(lifetime: lifetime, to: &bytes)
        append(UInt16(last), to: &bytes)
        bytes.append(payload)
        return bytes
    }

    static func decode(_ bytes: Data, mtu: Int) -> Packet? {
        guard bytes.count >= singleHeader, bytes.count <= mtu else { return nil }
        func integer<T: FixedWidthInteger>(_ offset: Int) -> T {
            bytes.withUnsafeBytes {
                T(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self))
            }
        }
        let kind = bytes[bytes.startIndex]
        let number: UInt32 = integer(1)
        guard number > 0 else { return nil }
        if kind == 0x80 {
            guard bytes.count == 13 else { return nil }
            let bits: UInt64 = integer(5)
            guard bits & 1 == 1, number >= 64 || bits >> number == 0 else { return nil }
            return .ack(number, bits)
        }
        let id: UInt32 = integer(5)
        guard id > 0 else { return nil }
        switch kind {
        case 0:
            guard bytes.count > singleHeader else { return nil }
            return .data(number, Fragment(id: id, index: 0), 1, 0, bytes.dropFirst(singleHeader))
        case 1:
            guard bytes.count > fragmentHeader else { return nil }
            let index = Int(integer(9) as UInt16)
            let count = Int(integer(11) as UInt16)
            let units: UInt16 = integer(13)
            let capacity = mtu - fragmentHeader
            let size = bytes.count - fragmentHeader
            let prefixSize = (count - 1) * capacity
            guard count >= 2, index < count, prefixSize < maxMessage else { return nil }
            if index == count - 1 {
                let total = prefixSize + size
                guard total > mtu - singleHeader, total <= maxMessage else { return nil }
            } else if size != capacity {
                return nil
            }
            return .data(
                number, Fragment(id: id, index: index), count,
                units == .max ? .infinity : Double(units) / 100, bytes.dropFirst(fragmentHeader))
        case 2:
            guard bytes.count > repairableHeader else { return nil }
            let index = Int(integer(9) as UInt16)
            let count = Int(integer(11) as UInt16)
            let units: UInt16 = integer(13)
            let last = Int(integer(15) as UInt16)
            let capacity = mtu - repairableHeader
            guard (1...Repair.maxData).contains(count), index < count + Repair.maxRepair,
                (1...capacity).contains(last)
            else { return nil }
            // Repair fragments are as long as the longest data fragment.
            let expected = index == count - 1 || count == 1 ? last : capacity
            guard bytes.count - repairableHeader == expected else { return nil }
            return .repairable(
                number, Fragment(id: id, index: index), count: count, last: last,
                units == .max ? .infinity : Double(units) / 100, bytes.dropFirst(repairableHeader))
        default:
            return nil
        }
    }
}
