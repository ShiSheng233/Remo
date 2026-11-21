//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation

public enum MouseButton: UInt8, Sendable {
    case leftClick = 1, rightClick, leftDown, leftUp
}

/// Positions are normalized to the captured display, with the origin at its upper left.
enum MouseMessage: Equatable {
    typealias Button = MouseButton

    case ready(position: CGPoint, width: UInt32, height: UInt32)
    case move(sequence: UInt64, afterButton: UInt64, position: CGPoint)
    case button(sequence: UInt64, action: Button, position: CGPoint)
    /// Whole lines; positive values move the content down, following the finger.
    case scroll(lines: Int32)

    private enum Input: UInt8 {
        case move = 1, button, scroll
    }

    var encoded: Data {
        var data = Data()
        switch self {
        case let .ready(position, width, height):
            data.put(SessionMessage.mouseReady.rawValue)
            data.putPosition(position)
            data.put(width)
            data.put(height)
        case let .move(sequence, afterButton, position):
            data.put(SessionMessage.mouseInput.rawValue)
            data.put(Input.move.rawValue)
            data.put(sequence)
            data.put(afterButton)
            data.putPosition(position)
        case let .button(sequence, action, position):
            data.put(SessionMessage.mouseInput.rawValue)
            data.put(Input.button.rawValue)
            data.put(sequence)
            data.put(action.rawValue)
            data.putPosition(position)
        case let .scroll(lines):
            data.put(SessionMessage.mouseInput.rawValue)
            data.put(Input.scroll.rawValue)
            data.put(lines)
        }
        return data
    }

    init(decoding bytes: Data) throws {
        var data = bytes
        switch SessionMessage(rawValue: try data.take(UInt8.self)) {
        case .mouseReady:
            let position = try data.takePosition()
            let width = try data.take(UInt32.self)
            let height = try data.take(UInt32.self)
            guard width > 0, height > 0 else { throw PacketError.invalid }
            self = .ready(position: position, width: width, height: height)
        case .mouseInput:
            switch Input(rawValue: try data.take(UInt8.self)) {
            case .move:
                let sequence = try data.take(UInt64.self)
                let afterButton = try data.take(UInt64.self)
                guard sequence > afterButton else { throw PacketError.invalid }
                self = .move(sequence: sequence, afterButton: afterButton, position: try data.takePosition())
            case .button:
                let sequence = try data.take(UInt64.self)
                guard sequence > 0, let button = Button(rawValue: try data.take(UInt8.self))
                else { throw PacketError.invalid }
                self = .button(sequence: sequence, action: button, position: try data.takePosition())
            case .scroll:
                let lines = try data.take(Int32.self)
                guard (-100...100).contains(lines), lines != 0 else { throw PacketError.invalid }
                self = .scroll(lines: lines)
            case nil: throw PacketError.invalid
            }
        default: throw PacketError.invalid
        }
        guard data.isEmpty else { throw PacketError.invalid }
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
        guard (0...1).contains(x), (0...1).contains(y) else { throw PacketError.invalid }
        return CGPoint(x: x, y: y)
    }
}
