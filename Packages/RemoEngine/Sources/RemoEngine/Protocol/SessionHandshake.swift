//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreGraphics
import Foundation
import RemoTransport

/// One-round-trip session handshake: the client opens the stream with its requested video/audio
/// parameters and optional remote control request, and the server replies once with whether
/// control was granted and its initial state.
enum SessionHandshake: Equatable {
    struct ControlGrant: Equatable {
        let pointerPosition: CGPoint
        let displayWidth: UInt32
        let displayHeight: UInt32
        let capsLock: Bool
    }

    private enum HelloFlag {
        static let requestsControl: UInt8 = 1 << 0
        static let streamsAudio: UInt8 = 1 << 1
        static let all: UInt8 = requestsControl | streamsAudio
    }

    case hello(requestsControl: Bool, stream: StreamParameters = StreamParameters())
    case ready(control: ControlGrant?)

    var delivery: MessageTransport.Delivery { .essential }

    var encoded: Data {
        var data = Data()
        switch self {
        case let .hello(requestsControl, stream):
            data.put(MessageKind.hello.rawValue)
            var flags: UInt8 = 0
            if requestsControl { flags |= HelloFlag.requestsControl }
            if stream.streamsAudio { flags |= HelloFlag.streamsAudio }
            data.put(flags)
            data.put(UInt16(stream.maximumSize?.width ?? 0))
            data.put(UInt16(stream.maximumSize?.height ?? 0))
            data.put(UInt16(stream.framesPerSecond))
            data.put(UInt32(stream.maximumVideoBitRate))
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
            guard flags & ~HelloFlag.all == 0 else { throw WireFormatError.invalid }
            let width = Int(try data.take(UInt16.self))
            let height = Int(try data.take(UInt16.self))
            let maximumSize: StreamParameters.Size?
            if width == 0 && height == 0 {
                maximumSize = nil
            } else {
                let size = StreamParameters.Size(width: width, height: height)
                guard size.isValid else { throw WireFormatError.invalid }
                maximumSize = size
            }
            let framesPerSecond = Int32(try data.take(UInt16.self))
            let maximumVideoBitRate = Int(try data.take(UInt32.self))
            let stream = StreamParameters(
                maximumSize: maximumSize,
                framesPerSecond: framesPerSecond,
                maximumVideoBitRate: maximumVideoBitRate,
                streamsAudio: flags & HelloFlag.streamsAudio != 0)
            guard stream.isValid else { throw WireFormatError.invalid }
            self = .hello(
                requestsControl: flags & HelloFlag.requestsControl != 0,
                stream: stream)
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
