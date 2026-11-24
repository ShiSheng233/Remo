//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation
import RemoTransport

/// Strictly sequenced keyboard input and Caps Lock indicator state messages.
enum KeyboardMessage: Equatable {
    /// Replaces the remote modifier mask (`Control`, `Option`, `Command`, `Shift`).
    case modifiers(sequence: UInt64, flags: KeyboardModifiers)
    /// Atomic press and release of one key.
    case keystroke(sequence: UInt64, key: KeyboardKeyCode)
    /// Key pressed and held until a matching `keyUp`.
    case keyDown(sequence: UInt64, key: KeyboardKeyCode)
    /// Key released after `keyDown`.
    case keyUp(sequence: UInt64, key: KeyboardKeyCode)
    /// Server → client Caps Lock indicator state.
    case state(sequence: UInt64, capsLock: Bool)

    var delivery: MessageTransport.Delivery {
        switch self {
        case .modifiers, .keystroke, .keyDown, .keyUp:
            .essential
        case .state:
            .untilDelivered(priority: .high, replacing: ReplaceableMessage.keyboardState.rawValue)
        }
    }

    private enum Input: UInt8 {
        case modifiers = 1, keystroke, keyDown, keyUp
    }

    var encoded: Data {
        var data = Data()
        switch self {
        case let .modifiers(sequence, flags):
            data.put(MessageKind.keyboardInput.rawValue)
            data.put(Input.modifiers.rawValue)
            data.put(sequence)
            data.put(flags.rawValue)
        case let .keystroke(sequence, key):
            data.put(MessageKind.keyboardInput.rawValue)
            data.put(Input.keystroke.rawValue)
            data.put(sequence)
            data.put(key.rawValue)
        case let .keyDown(sequence, key):
            data.put(MessageKind.keyboardInput.rawValue)
            data.put(Input.keyDown.rawValue)
            data.put(sequence)
            data.put(key.rawValue)
        case let .keyUp(sequence, key):
            data.put(MessageKind.keyboardInput.rawValue)
            data.put(Input.keyUp.rawValue)
            data.put(sequence)
            data.put(key.rawValue)
        case let .state(sequence, capsLock):
            data.put(MessageKind.keyboardState.rawValue)
            data.put(sequence)
            data.put(UInt8(capsLock ? 1 : 0))
        }
        return data
    }

    init(decoding bytes: Data) throws {
        var data = bytes
        switch MessageKind(rawValue: try data.take(UInt8.self)) {
        case .keyboardInput:
            let input = Input(rawValue: try data.take(UInt8.self))
            let sequence = try data.take(UInt64.self)
            guard sequence > 0 else { throw WireFormatError.invalid }
            switch input {
            case .modifiers:
                let raw = try data.take(UInt8.self)
                guard raw & ~KeyboardModifiers.all.rawValue == 0 else {
                    throw WireFormatError.invalid
                }
                self = .modifiers(sequence: sequence, flags: KeyboardModifiers(rawValue: raw))
            case .keystroke:
                guard let key = KeyboardKeyCode(rawValue: try data.take(UInt16.self)) else {
                    throw WireFormatError.invalid
                }
                self = .keystroke(sequence: sequence, key: key)
            case .keyDown:
                guard let key = KeyboardKeyCode(rawValue: try data.take(UInt16.self)) else {
                    throw WireFormatError.invalid
                }
                self = .keyDown(sequence: sequence, key: key)
            case .keyUp:
                guard let key = KeyboardKeyCode(rawValue: try data.take(UInt16.self)) else {
                    throw WireFormatError.invalid
                }
                self = .keyUp(sequence: sequence, key: key)
            case nil:
                throw WireFormatError.invalid
            }
        case .keyboardState:
            let sequence = try data.take(UInt64.self)
            let raw = try data.take(UInt8.self)
            guard sequence > 0, raw <= 1 else { throw WireFormatError.invalid }
            self = .state(sequence: sequence, capsLock: raw == 1)
        default:
            throw WireFormatError.invalid
        }
        guard data.isEmpty else { throw WireFormatError.invalid }
    }
}
