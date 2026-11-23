//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation
import RemoTransport

/// Positions are normalized to the captured display, with the origin at its upper left.
enum PointerMessage: Equatable {
    case ready(position: CGPoint, width: UInt32, height: UInt32)
    case move(sequence: UInt64, afterButton: UInt64, position: CGPoint)
    /// `afterButton` is the previous button change, or zero for the first.
    case button(sequence: UInt64, afterButton: UInt64, action: PointerButton, position: CGPoint)
    /// Whole lines; positive values move the content down, following the finger.
    case scroll(lines: Int32)

    /// Button changes must arrive. The newest move must arrive too, since the client already
    /// shows the cursor there, but it makes an older one pointless. A late scroll is only noise.
    var delivery: MessageTransport.Delivery {
        switch self {
        case .ready, .button: .essential
        case .move:
            .untilDelivered(priority: .high, replacing: ReplaceableMessage.pointerMove.rawValue)
        case .scroll: .retrying(sendWithin: SessionTiming.pointerDeadline)
        }
    }

    private enum Input: UInt8 {
        case move = 1, button, scroll
    }

    var encoded: Data {
        var data = Data()
        switch self {
        case let .ready(position, width, height):
            data.put(MessageKind.pointerReady.rawValue)
            data.putPosition(position)
            data.put(width)
            data.put(height)
        case let .move(sequence, afterButton, position):
            data.put(MessageKind.pointerInput.rawValue)
            data.put(Input.move.rawValue)
            data.put(sequence)
            data.put(afterButton)
            data.putPosition(position)
        case let .button(sequence, afterButton, action, position):
            data.put(MessageKind.pointerInput.rawValue)
            data.put(Input.button.rawValue)
            data.put(sequence)
            data.put(afterButton)
            data.put(action.rawValue)
            data.putPosition(position)
        case let .scroll(lines):
            data.put(MessageKind.pointerInput.rawValue)
            data.put(Input.scroll.rawValue)
            data.put(lines)
        }
        return data
    }

    init(decoding bytes: Data) throws {
        var data = bytes
        switch MessageKind(rawValue: try data.take(UInt8.self)) {
        case .pointerReady:
            let position = try data.takePosition()
            let width = try data.take(UInt32.self)
            let height = try data.take(UInt32.self)
            guard width > 0, height > 0 else { throw WireFormatError.invalid }
            self = .ready(position: position, width: width, height: height)
        case .pointerInput:
            switch Input(rawValue: try data.take(UInt8.self)) {
            case .move:
                let sequence = try data.take(UInt64.self)
                let afterButton = try data.take(UInt64.self)
                guard sequence > afterButton else { throw WireFormatError.invalid }
                self = .move(sequence: sequence, afterButton: afterButton, position: try data.takePosition())
            case .button:
                let sequence = try data.take(UInt64.self)
                let afterButton = try data.take(UInt64.self)
                guard sequence > afterButton,
                    let button = PointerButton(rawValue: try data.take(UInt8.self))
                else { throw WireFormatError.invalid }
                self = .button(
                    sequence: sequence, afterButton: afterButton, action: button,
                    position: try data.takePosition())
            case .scroll:
                let lines = try data.take(Int32.self)
                guard (-100...100).contains(lines), lines != 0 else { throw WireFormatError.invalid }
                self = .scroll(lines: lines)
            case nil: throw WireFormatError.invalid
            }
        default: throw WireFormatError.invalid
        }
        guard data.isEmpty else { throw WireFormatError.invalid }
    }
}

private extension Data {
    mutating func putPosition(_ point: CGPoint) {
        put(Double(point.x).bitPattern)
        put(Double(point.y).bitPattern)
    }

    mutating func takePosition() throws -> CGPoint {
        let x = Double(bitPattern: try take(UInt64.self))
        let y = Double(bitPattern: try take(UInt64.self))
        guard (0...1).contains(x), (0...1).contains(y) else { throw WireFormatError.invalid }
        return CGPoint(x: x, y: y)
    }
}
