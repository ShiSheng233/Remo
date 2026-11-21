//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation

/// The server's periodic proof of life, numbered so a client can count what it missed.
struct ControlMessage: Equatable {
    let sequence: UInt64

    var encoded: Data {
        var data = MessageKind.control.encoded
        data.put(sequence)
        return data
    }

    init(sequence: UInt64) { self.sequence = sequence }

    init(decoding message: Data) throws {
        var body = message
        guard try body.take(UInt8.self) == MessageKind.control.rawValue else {
            throw WireFormatError.invalid
        }
        sequence = try body.take(UInt64.self)
        guard body.isEmpty else { throw WireFormatError.invalid }
    }
}
