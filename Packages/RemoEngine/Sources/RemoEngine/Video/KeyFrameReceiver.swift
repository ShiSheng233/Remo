import Foundation

/// Reassembles a reliable key frame from `KeyFrameSender` chunks.
struct KeyFrameReceiver {
    static let limit = 1 << 20
    let id: UInt64
    let total: Int
    var bytes = Data()

    mutating func append(_ part: Data, offset: Int) throws {
        guard offset == bytes.count, !part.isEmpty, part.count <= total - offset else {
            throw WireFormatError.invalid
        }
        bytes.append(part)
    }
}
