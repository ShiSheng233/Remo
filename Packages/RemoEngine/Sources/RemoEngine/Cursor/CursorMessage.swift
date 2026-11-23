//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation
import RemoTransport

/// A cursor picture, in the display's points. Its id names its content, so a client caches it
/// and the server sends each picture to a client once.
struct CursorShape: Equatable, Sendable {
    static let maximumSize: CGFloat = 512
    static let maximumPNGBytes = 256 * 1024

    let id: UInt64
    let size: CGSize
    /// Measured from the picture's upper left.
    let hotSpot: CGPoint
    let png: Data
}

/// The cursor as the server last saw it.
struct CursorState: Equatable, Sendable {
    /// Positions are normalized to the captured display, with the origin at its upper left.
    var position: CGPoint
    /// False while the cursor is off the captured display.
    var visible: Bool
    var displaySize: CGSize
    var shapeID: UInt64?
    /// Counts moves the controlling client didn't make, such as the Mac's own mouse or an app
    /// warping the cursor. A client that sees it change takes the server's position.
    var externalMoves: UInt32
}

enum CursorMessage: Equatable {
    case shape(CursorShape)
    case state(sequence: UInt64, CursorState)

    /// A shape must arrive before the states that show it are worth anything. Of the states
    /// only the newest matters, and it must arrive or the client shows a stale cursor.
    var delivery: MessageTransport.Delivery {
        switch self {
        case .shape: .essential
        case .state:
            .untilDelivered(priority: .high, replacing: ReplaceableMessage.cursorState.rawValue)
        }
    }

    var encoded: Data {
        var data = Data()
        switch self {
        case let .shape(shape):
            data.put(MessageKind.cursorShape.rawValue)
            data.put(shape.id)
            data.putDouble(shape.size.width)
            data.putDouble(shape.size.height)
            data.putDouble(shape.hotSpot.x)
            data.putDouble(shape.hotSpot.y)
            data.append(shape.png)
        case let .state(sequence, state):
            data.put(MessageKind.cursorState.rawValue)
            data.put(sequence)
            data.putDouble(state.position.x)
            data.putDouble(state.position.y)
            data.put(UInt8(state.visible ? 1 : 0))
            data.put(UInt32(state.displaySize.width))
            data.put(UInt32(state.displaySize.height))
            data.put(state.shapeID ?? 0)
            data.put(state.externalMoves)
        }
        return data
    }

    init(decoding bytes: Data) throws {
        var data = bytes
        switch MessageKind(rawValue: try data.take(UInt8.self)) {
        case .cursorShape:
            let id = try data.take(UInt64.self)
            let size = CGSize(width: try data.takeDouble(), height: try data.takeDouble())
            let hotSpot = CGPoint(x: try data.takeDouble(), y: try data.takeDouble())
            let limit = CursorShape.maximumSize
            guard id != 0, size.width > 0, size.width <= limit, size.height > 0,
                size.height <= limit, (0...size.width).contains(hotSpot.x),
                (0...size.height).contains(hotSpot.y), !data.isEmpty,
                data.count <= CursorShape.maximumPNGBytes
            else { throw WireFormatError.invalid }
            self = .shape(CursorShape(id: id, size: size, hotSpot: hotSpot, png: Data(data)))
            return
        case .cursorState:
            let sequence = try data.take(UInt64.self)
            let position = CGPoint(x: try data.takeDouble(), y: try data.takeDouble())
            let visible = try data.take(UInt8.self)
            let width = try data.take(UInt32.self)
            let height = try data.take(UInt32.self)
            let shapeID = try data.take(UInt64.self)
            let externalMoves = try data.take(UInt32.self)
            guard sequence > 0, (0...1).contains(position.x), (0...1).contains(position.y),
                visible <= 1, width > 0, height > 0
            else { throw WireFormatError.invalid }
            self = .state(
                sequence: sequence,
                CursorState(
                    position: position, visible: visible == 1,
                    displaySize: CGSize(width: Int(width), height: Int(height)),
                    shapeID: shapeID == 0 ? nil : shapeID, externalMoves: externalMoves))
        default: throw WireFormatError.invalid
        }
        guard data.isEmpty else { throw WireFormatError.invalid }
    }
}

extension Data {
    mutating func putDouble(_ value: CGFloat) {
        put(Double(value).bitPattern)
    }

    /// Rejects anything that isn't a finite number.
    mutating func takeDouble() throws -> CGFloat {
        let value = Double(bitPattern: try take(UInt64.self))
        guard value.isFinite else { throw WireFormatError.invalid }
        return CGFloat(value)
    }
}
