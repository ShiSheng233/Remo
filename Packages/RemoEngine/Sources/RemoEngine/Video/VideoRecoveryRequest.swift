import Foundation

struct VideoRecoveryRequest {
    enum Level: UInt8 { case ltr, idr, reliableIDR }

    /// The first frame after the last successful decode. One-based, including bootstrap.
    let round: UInt64
    let attempt: UInt64
    let epoch: UInt64
    let level: Level

    var encoded: Data {
        var data = MessageKind.videoRecoveryRequest.encoded
        data.put(round)
        data.put(attempt)
        data.put(epoch)
        data.put(level.rawValue)
        return data
    }

    func supersedes(_ previous: Self?) -> Bool {
        guard let previous else { return true }
        if round != previous.round { return round > previous.round }
        return attempt > previous.attempt && level.rawValue >= previous.level.rawValue
    }
}

extension VideoRecoveryRequest {
    init(_ data: Data) throws {
        var body = data
        guard try body.take(UInt8.self) == MessageKind.videoRecoveryRequest.rawValue else {
            throw WireFormatError.invalid
        }
        round = try body.take(UInt64.self)
        attempt = try body.take(UInt64.self)
        epoch = try body.take(UInt64.self)
        guard let level = Level(rawValue: try body.take(UInt8.self)),
            round > 0, attempt > 0, body.isEmpty
        else { throw WireFormatError.invalid }
        self.level = level
    }
}
