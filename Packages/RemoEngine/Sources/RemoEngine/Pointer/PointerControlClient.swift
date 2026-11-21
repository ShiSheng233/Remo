//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation

/// The controlling peer's half of the pointer protocol, which `PointerControlServer` orders.
///
/// Moves and scrolls are unreliable and may overtake a reliable button change, so every move
/// carries the sequence of the last button it follows.
struct PointerControlClient {
    /// The remote display's size in pixels, once the server has granted control.
    private(set) var displaySize: CGSize?
    private var position = CGPoint.zero
    private var sequence: UInt64 = 0
    private var buttonSequence: UInt64 = 0

    /// Accepts the server's grant. Returns false for anything else or a repeated grant.
    mutating func receiveReady(_ message: Data) -> Bool {
        guard displaySize == nil,
            case let .ready(position, width, height) = try? PointerMessage(decoding: message)
        else { return false }
        self.position = position
        displaySize = CGSize(width: Int(width), height: Int(height))
        return true
    }

    /// Moves by a distance in remote display pixels, stopping at the display's edges.
    mutating func move(by delta: CGVector) -> PointerMessage? {
        guard let displaySize, delta != .zero, delta.dx.isFinite, delta.dy.isFinite else {
            return nil
        }
        position = CGPoint(
            x: min(1, max(0, position.x + delta.dx / displaySize.width)),
            y: min(1, max(0, position.y + delta.dy / displaySize.height)))
        sequence += 1
        return .move(sequence: sequence, afterButton: buttonSequence, position: position)
    }

    mutating func press(_ button: PointerButton) -> PointerMessage? {
        guard displaySize != nil else { return nil }
        sequence += 1
        buttonSequence = sequence
        return .button(sequence: sequence, action: button, position: position)
    }

    func scroll(lines: Int) -> PointerMessage? {
        guard displaySize != nil, lines != 0 else { return nil }
        // The server rejects larger steps.
        return .scroll(lines: Int32(min(100, max(-100, lines))))
    }
}
