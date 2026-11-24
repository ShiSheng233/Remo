//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreGraphics
import Foundation
import RemoTransport

/// One-round-trip session handshake: the client opens the stream and optionally requests remote
/// control, and the server replies once with whether control was granted and its initial state.
enum SessionHandshake: Equatable {
    struct ControlGrant: Equatable {
        let pointerPosition: CGPoint
        let displayWidth: UInt32
        let displayHeight: UInt32
        let capsLock: Bool
    }

    case hello(requestsControl: Bool)
    case ready(control: ControlGrant?)

    var delivery: MessageTransport.Delivery { .essential }

    var encoded: Data {
        var data = Data()
        switch self {
        case .hello(let requestsControl):
            data.put(MessageKind.hello.rawValue)
            data.put(UInt8(requestsControl ? 1 : 0))
        case .ready(let control):
            data.put(MessageKind.sessionReady.rawValue)
            if let control {
                data.put(UInt8(1))
                data.putPosition(control.pointerPosition)
                data.put(control.displayWidth)
                data.put(control.displayHeight)
                data.put(UInt8(control.capsLock ? 1 : 0))
            } else {
                data.put(UInt8(0))
            }
        }
        return data
    }

    init(decoding bytes: Data) throws {
        var data = bytes
        switch MessageKind(rawValue: try data.take(UInt8.self)) {
        case .hello:
            let flags = try data.take(UInt8.self)
            guard flags <= 1 else { throw WireFormatError.invalid }
            self = .hello(requestsControl: flags == 1)
        case .sessionReady:
            let granted = try data.take(UInt8.self)
            switch granted {
            case 0:
                self = .ready(control: nil)
            case 1:
                let position = try data.takePosition()
                let width = try data.take(UInt32.self)
                let height = try data.take(UInt32.self)
                let caps = try data.take(UInt8.self)
                guard width > 0, height > 0, caps <= 1 else { throw WireFormatError.invalid }
                self = .ready(
                    control: ControlGrant(
                        pointerPosition: position, displayWidth: width, displayHeight: height,
                        capsLock: caps == 1))
            default:
                throw WireFormatError.invalid
            }
        default:
            throw WireFormatError.invalid
        }
        guard data.isEmpty else { throw WireFormatError.invalid }
    }
}
