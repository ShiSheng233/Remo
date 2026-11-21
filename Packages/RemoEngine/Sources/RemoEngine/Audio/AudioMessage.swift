import Foundation

/// One 20 ms Opus frame of system audio, numbered and stamped with its capture time.
struct AudioMessage: Sendable {
    let sequence: UInt64
    /// Capture PTS in 48 kHz sample ticks.
    let timestamp: Int64
    let opus: Data

    var encoded: Data {
        var data = MessageKind.audio.encoded
        data.put(sequence)
        data.put(timestamp)
        data.append(opus)
        return data
    }

    init(decoding message: Data) throws {
        var bytes = message
        guard (18...1292).contains(bytes.count),
            try bytes.take(UInt8.self) == MessageKind.audio.rawValue
        else { throw WireFormatError.invalid }
        let sequence = try bytes.take(UInt64.self)
        guard sequence < UInt64.max else { throw WireFormatError.invalid }
        let timestamp = try bytes.take(Int64.self)
        self.init(sequence: sequence, timestamp: timestamp, opus: bytes)
    }

    init(sequence: UInt64, timestamp: Int64, opus: Data) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.opus = opus
    }
}
