import Foundation

enum Wire {
    static let maxMessage = 1 << 20

    struct Fragment: Hashable {
        let reliable: Bool
        let id: UInt32
        let index: Int
    }

    enum Packet {
        case data(UInt32, Fragment, Int, Data)
        case ack(UInt32, UInt64)
    }

    private static func append<T: FixedWidthInteger>(_ n: T, to bytes: inout Data) {
        withUnsafeBytes(of: n.bigEndian) { bytes.append(contentsOf: $0) }
    }

    static func ack(_ largest: UInt32, _ bits: UInt64) -> Data {
        var bytes = Data([0x80])
        append(largest, to: &bytes)
        append(bits, to: &bytes)
        return bytes
    }

    static func data(_ number: UInt32, _ key: Fragment, _ count: Int, _ payload: Data) -> Data {
        var bytes = Data([key.reliable ? 2 : count == 1 ? 0 : 1])
        append(number, to: &bytes)
        append(key.id, to: &bytes)
        if count > 1 {
            append(UInt16(key.index), to: &bytes)
            append(UInt16(count), to: &bytes)
        }
        bytes.append(payload)
        return bytes
    }

    static func decode(_ bytes: Data, mtu: Int) -> Packet? {
        guard bytes.count >= 9, bytes.count <= mtu else { return nil }
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
        case 0, 2:
            guard bytes.count > 9 else { return nil }
            return .data(
                number, Fragment(reliable: kind == 2, id: id, index: 0), 1, bytes.dropFirst(9))
        case 1:
            guard bytes.count > 13 else { return nil }
            let index = Int(integer(9) as UInt16)
            let count = Int(integer(11) as UInt16)
            let capacity = mtu - 13
            let size = bytes.count - 13
            let prefixSize = (count - 1) * capacity
            guard count >= 2, index < count, prefixSize < maxMessage else { return nil }
            if index == count - 1 {
                let total = prefixSize + size
                guard total > mtu - 9, total <= maxMessage else { return nil }
            } else if size != capacity {
                return nil
            }
            return .data(
                number, Fragment(reliable: false, id: id, index: index), count, bytes.dropFirst(13))
        default:
            return nil
        }
    }
}
