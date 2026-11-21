//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation
import RemoTransport

/// Serializes remote pointer input from one controlling peer at a time.
@MainActor
final class PointerControlServer {
    enum Event: Equatable {
        case move(CGPoint, dragging: Bool)
        case button(PointerButton, CGPoint)
        case scroll(lines: Int32)
    }

    private struct Move {
        let sequence: UInt64
        let afterButton: UInt64
        let position: CGPoint
    }

    private let initialState: () -> PointerMessage?
    private let emit: (Event) -> Void
    private var owner: UUID?
    private var position = CGPoint.zero
    private var leftDown = false
    private var latestPosition: UInt64 = 0
    private var latestButton: UInt64 = 0
    private var pendingMove: Move?

    init(initialState: @escaping () -> PointerMessage?, emit: @escaping (Event) -> Void) {
        self.initialState = initialState
        self.emit = emit
    }

    func begin(for peer: UUID) -> PointerMessage? {
        guard owner == nil, let message = initialState(),
            case .ready(let position, _, _) = message
        else { return nil }
        owner = peer
        self.position = position
        return message
    }

    @discardableResult
    func receive(_ bytes: Data, on channel: MessageTransport.Channel, from peer: UUID) -> Bool {
        guard owner == peer, let input = try? PointerMessage(decoding: bytes) else { return false }
        switch (channel, input) {
        case let (.unreliable, .move(sequence, afterButton, position)):
            receiveMove(Move(sequence: sequence, afterButton: afterButton, position: position))
        case let (.unreliable, .scroll(lines)):
            emit(.scroll(lines: lines))
        case let (.reliable, .button(sequence, action, position)):
            guard sequence > latestPosition else { return true }
            latestButton = sequence
            latestPosition = sequence
            switch action {
            case .leftDown where !leftDown:
                leftDown = true
                self.position = position
                emit(.button(action, position))
            case .leftUp where leftDown:
                if self.position != position { emit(.move(position, dragging: true)) }
                leftDown = false
                self.position = position
                emit(.button(action, position))
            case .leftClick, .rightClick:
                if !leftDown {
                    self.position = position
                    emit(.button(action, position))
                }
            default: break
            }
            if let pendingMove, pendingMove.afterButton <= sequence {
                self.pendingMove = nil
                receiveMove(pendingMove)
            }
        default: return false
        }
        return true
    }

    private func receiveMove(_ move: Move) {
        guard move.sequence > latestPosition, move.afterButton >= latestButton else { return }
        // A move can overtake its reliable button transition. Keep only the latest such move.
        if move.afterButton > latestButton {
            if move.sequence > (pendingMove?.sequence ?? 0) { pendingMove = move }
            return
        }
        latestPosition = move.sequence
        position = move.position
        emit(.move(position, dragging: leftDown))
    }

    func end(for peer: UUID) {
        if owner == peer { stop() }
    }

    func stop() {
        if leftDown { emit(.button(.leftUp, position)) }
        leftDown = false
        owner = nil
        latestPosition = 0
        latestButton = 0
        pendingMove = nil
    }
}

#if os(macOS)
    import CoreGraphics

    extension PointerControlServer {
        convenience init(displayID: CGDirectDisplayID) {
            let source = CGEventSource(stateID: .hidSystemState)
            self.init(initialState: {
                let bounds = CGDisplayBounds(displayID)
                guard !bounds.isEmpty,
                    let width = UInt32(exactly: bounds.width), width > 0,
                    let height = UInt32(exactly: bounds.height), height > 0,
                    let location = CGEvent(source: nil)?.location
                else { return nil }
                let position = CGPoint(
                    x: min(1, max(0, (location.x - bounds.minX) / max(1, bounds.width - 1))),
                    y: min(1, max(0, (location.y - bounds.minY) / max(1, bounds.height - 1))))
                return .ready(position: position, width: width, height: height)
            }, emit: { event in
                let bounds = CGDisplayBounds(displayID)
                guard !bounds.isEmpty else { return }
                func post(_ type: CGEventType, _ button: CGMouseButton, at position: CGPoint) {
                    let location = CGPoint(
                        x: bounds.minX + position.x * max(0, bounds.width - 1),
                        y: bounds.minY + position.y * max(0, bounds.height - 1))
                    let event = CGEvent(
                        mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
                        mouseButton: button)
                    if type != .mouseMoved && type != .leftMouseDragged {
                        event?.setIntegerValueField(.mouseEventClickState, value: 1)
                    }
                    event?.post(tap: .cghidEventTap)
                }
                switch event {
                case let .move(position, dragging):
                    post(dragging ? .leftMouseDragged : .mouseMoved, .left, at: position)
                case let .button(action, position):
                    switch action {
                    case .leftClick:
                        post(.leftMouseDown, .left, at: position)
                        post(.leftMouseUp, .left, at: position)
                    case .rightClick:
                        post(.rightMouseDown, .right, at: position)
                        post(.rightMouseUp, .right, at: position)
                    case .leftDown:
                        post(.leftMouseDown, .left, at: position)
                    case .leftUp:
                        post(.leftMouseUp, .left, at: position)
                    }
                case let .scroll(lines):
                    CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                        wheel1: lines, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
                }
            })
        }
    }
#endif
