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
        /// Whether the extended pointer input was granted, echoing the hello's flag.
        let extendedPointer: Bool

        init(
            pointerPosition: CGPoint, displayWidth: UInt32, displayHeight: UInt32,
            capsLock: Bool, extendedPointer: Bool = false
        ) {
            self.pointerPosition = pointerPosition
            self.displayWidth = displayWidth
            self.displayHeight = displayHeight
            self.capsLock = capsLock
            self.extendedPointer = extendedPointer
        }
    }

    /// `requestsControl` asks to drive the remote pointer and keyboard; `extendedPointer`
    /// is only meaningful with it, so the flag byte accepts 0, 1 and 3.
    case hello(requestsControl: Bool, extendedPointer: Bool = false)
    /// The granted byte echoes the hello's flags: 1 for original input, 3 extended.
    case ready(control: ControlGrant?)

    var delivery: MessageTransport.Delivery { .essential }

    var encoded: Data {
        var data = Data()
        switch self {
        case .hello(let requestsControl, let extendedPointer):
            data.put(MessageKind.hello.rawValue)
            data.put(UInt8(requestsControl ? 1 : 0) | UInt8(extendedPointer ? 2 : 0))
        case .ready(let control):
            data.put(MessageKind.sessionReady.rawValue)
            if let control {
                data.put(UInt8(control.extendedPointer ? 3 : 1))
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
            guard flags == 0 || flags == 1 || flags == 3 else { throw WireFormatError.invalid }
            self = .hello(requestsControl: flags & 1 == 1, extendedPointer: flags & 2 != 0)
        case .sessionReady:
            let granted = try data.take(UInt8.self)
            switch granted {
            case 0:
                self = .ready(control: nil)
            case 1, 3:
                let position = try data.takePosition()
                let width = try data.take(UInt32.self)
                let height = try data.take(UInt32.self)
                let caps = try data.take(UInt8.self)
                guard width > 0, height > 0, caps <= 1 else { throw WireFormatError.invalid }
                self = .ready(
                    control: ControlGrant(
                        pointerPosition: position, displayWidth: width, displayHeight: height,
                        capsLock: caps == 1, extendedPointer: granted == 3))
            default:
                throw WireFormatError.invalid
            }
        default:
            throw WireFormatError.invalid
        }
        guard data.isEmpty else { throw WireFormatError.invalid }
    }
}

