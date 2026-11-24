//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation

/// The controlling peer's half of the keyboard protocol, which `KeyboardControlServer` orders.
///
/// Every outbound event carries a strictly increasing sequence number and is sent reliably so the
/// server can apply modifier changes and key transitions in exact order without drops.
struct KeyboardControlClient {
    private(set) var isReady = false
    /// Active modifier mask last emitted to the server.
    private(set) var modifiers: KeyboardModifiers = []
    /// Keys currently held down via `keyDown` and awaiting `keyUp`.
    private(set) var heldKeys: Set<KeyboardKeyCode> = []
    /// Latest Caps Lock indicator state reported by the server.
    private(set) var capsLock = false

    private var sequence: UInt64 = 0
    private var latestStateSequence: UInt64 = 0

    /// Accepts the initial control grant from `SessionHandshake.ready`.
    mutating func begin(capsLock: Bool) {
        isReady = true
        self.capsLock = capsLock
    }

    /// Applies an authoritative Caps Lock indicator update from the server.
    /// Returns true if the indicator state changed.
    mutating func receiveState(_ message: Data) -> Bool {
        guard case let .state(seq, value) = try? KeyboardMessage(decoding: message),
            seq > latestStateSequence
        else { return false }
        latestStateSequence = seq
        guard value != capsLock else { return false }
        capsLock = value
        return true
    }

    /// Emits a modifier update immediately if the modifier mask changed.
    mutating func setModifiers(_ next: KeyboardModifiers) -> KeyboardMessage? {
        guard isReady, next != modifiers else { return nil }
        modifiers = next
        sequence += 1
        return .modifiers(sequence: sequence, flags: next)
    }

    /// Emits an atomic press + release event for a short tap.
    mutating func keystroke(_ key: KeyboardKeyCode) -> KeyboardMessage? {
        guard isReady else { return nil }
        sequence += 1
        return .keystroke(sequence: sequence, key: key)
    }

    /// Emits a `keyDown` event for a held key. Duplicate downs for an already-held key are ignored.
    mutating func keyDown(_ key: KeyboardKeyCode) -> KeyboardMessage? {
        guard isReady, heldKeys.insert(key).inserted else { return nil }
        sequence += 1
        return .keyDown(sequence: sequence, key: key)
    }

    /// Emits a `keyUp` event for a previously held key.
    mutating func keyUp(_ key: KeyboardKeyCode) -> KeyboardMessage? {
        guard isReady, heldKeys.remove(key) != nil else { return nil }
        sequence += 1
        return .keyUp(sequence: sequence, key: key)
    }

    /// Produces ordered release messages for all currently held keys and optionally all modifiers.
    mutating func releaseAll(includingModifiers: Bool) -> [KeyboardMessage] {
        guard isReady else { return [] }
        var messages: [KeyboardMessage] = []
        for key in heldKeys.sorted(by: { $0.rawValue < $1.rawValue }) {
            heldKeys.remove(key)
            sequence += 1
            messages.append(.keyUp(sequence: sequence, key: key))
        }
        if includingModifiers, !modifiers.isEmpty {
            modifiers = []
            sequence += 1
            messages.append(.modifiers(sequence: sequence, flags: []))
        }
        return messages
    }
}
