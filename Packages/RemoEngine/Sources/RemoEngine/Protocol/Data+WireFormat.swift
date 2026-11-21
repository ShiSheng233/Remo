import Foundation

/// Big-endian integers, read from the front of a message.
extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func take<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard count >= MemoryLayout<T>.size else { throw WireFormatError.invalid }
        let value = withUnsafeBytes { T(bigEndian: $0.loadUnaligned(as: T.self)) }
        self = dropFirst(MemoryLayout<T>.size)
        return value
    }

    mutating func takeBytes(_ count: Int) throws -> Data {
        guard count <= self.count else { throw WireFormatError.invalid }
        let result = prefix(count)
        self = dropFirst(count)
        return result
    }
}
