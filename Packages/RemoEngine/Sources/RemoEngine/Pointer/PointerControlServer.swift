//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation

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
    private let emit: @MainActor (Event) -> Void
    private var owner: UUID?
    private var position = CGPoint.zero
    private var leftDown = false
    private var latestPosition: UInt64 = 0
    private var latestButton: UInt64 = 0
    private var pendingMove: Move?
    /// Button changes that arrived before the one they follow, keyed by that one's sequence.
    private var pendingButtons: [UInt64: PointerMessage] = [:]

    init(initialState: @escaping () -> PointerMessage?, emit: @escaping @MainActor (Event) -> Void) {
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
    func receive(_ bytes: Data, from peer: UUID) -> Bool {
        guard owner == peer, let input = try? PointerMessage(decoding: bytes) else { return false }
        switch input {
        case let .move(sequence, afterButton, position):
            receiveMove(Move(sequence: sequence, afterButton: afterButton, position: position))
        case let .scroll(lines):
            emit(.scroll(lines: lines))
        case .button:
            receiveButton(input)
        case .ready: return false
        }
        return true
    }

    /// Applies button changes in the order they were made. One that overtook its predecessor
    /// waits for it, which always arrives: button changes are sent until delivered.
    private func receiveButton(_ input: PointerMessage) {
        var next: PointerMessage? = input
        while let current = next, case let .button(sequence, afterButton, action, position) = current {
            next = nil
            guard afterButton >= latestButton, sequence > latestPosition else { return }
            if afterButton > latestButton {
                if pendingButtons.count < 64 { pendingButtons[afterButton] = current }
                return
            }
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
            next = pendingButtons.removeValue(forKey: sequence)
        }
    }

    private func receiveMove(_ move: Move) {
        guard move.sequence > latestPosition, move.afterButton >= latestButton else { return }
        // A move can overtake the button change it follows. Keep only the latest such move.
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
        pendingButtons.removeAll()
    }
}

#if os(macOS)
    import CoreGraphics

    extension PointerControlServer {
        /// `onPost` hears the position of every pointer event posted to the display.
        convenience init(
            displayID: CGDirectDisplayID, onPost: @escaping @MainActor (CGPoint) -> Void = { _ in }
        ) {
            nonisolated(unsafe) let source = CGEventSource(stateID: .hidSystemState)
            self.init(initialState: {
                guard let geometry = DisplayGeometry(displayID: displayID),
                    let width = UInt32(exactly: geometry.bounds.width), width > 0,
                    let height = UInt32(exactly: geometry.bounds.height), height > 0,
                    let location = CGEvent(source: nil)?.location
                else { return nil }
                return .ready(position: geometry.normalize(location), width: width, height: height)
            }, emit: { event in
                guard let geometry = DisplayGeometry(displayID: displayID) else { return }
                let post: @MainActor (CGEventType, CGMouseButton, CGPoint) -> Void = {
                    type, button, position in
                    let event = CGEvent(
                        mouseEventSource: source, mouseType: type,
                        mouseCursorPosition: geometry.location(of: position), mouseButton: button)
                    if type != .mouseMoved && type != .leftMouseDragged {
                        event?.setIntegerValueField(.mouseEventClickState, value: 1)
                    }
                    event?.post(tap: .cghidEventTap)
                    onPost(position)
                }
                switch event {
                case let .move(position, dragging):
                    post(dragging ? .leftMouseDragged : .mouseMoved, .left, position)
                case let .button(action, position):
                    switch action {
                    case .leftClick:
                        post(.leftMouseDown, .left, position)
                        post(.leftMouseUp, .left, position)
                    case .rightClick:
                        post(.rightMouseDown, .right, position)
                        post(.rightMouseUp, .right, position)
                    case .leftDown:
                        post(.leftMouseDown, .left, position)
                    case .leftUp:
                        post(.leftMouseUp, .left, position)
                    }
                case let .scroll(lines):
                    CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                        wheel1: lines, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
                }
            })
        }
    }
#endif
