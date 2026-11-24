//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation

/// Serializes remote keyboard input from one controlling peer at a time, enforcing strict
/// sequence ordering, server-side key repeat while keys are held, and stuck-key cleanup on exit.
@MainActor
final class KeyboardControlServer {
    enum Event: Equatable {
        case modifiers(KeyboardModifiers)
        case keystroke(KeyboardKeyCode, modifiers: KeyboardModifiers)
        case keyDown(KeyboardKeyCode, modifiers: KeyboardModifiers, isAutoRepeat: Bool)
        case keyUp(KeyboardKeyCode, modifiers: KeyboardModifiers)
        case capsLockShortPress
        case capsLockLongPress
    }

    struct RepeatTiming: Sendable {
        let delay: Duration
        let interval: Duration
    }

    private let readCapsLock: () -> Bool
    private let repeatTiming: () -> RepeatTiming?
    private let emit: @MainActor (Event) -> Void
    private let teardown: () -> Void

    private var owner: UUID?
    private var nextSequence: UInt64 = 1
    private var pending: [UInt64: KeyboardMessage] = [:]
    private var heldKeys: Set<KeyboardKeyCode> = []
    private var repeatingKey: KeyboardKeyCode?
    private var repeatTask: Task<Void, Never>?
    private var capsLockObserver: (@MainActor (Bool) -> Void)?

    /// Active remote modifiers, shared with `PointerControlServer` so modified mouse clicks work.
    private(set) var activeModifiers: KeyboardModifiers = []

    /// Current system Caps Lock indicator state.
    var capsLockState: Bool { readCapsLock() }

    init(
        readCapsLock: @escaping () -> Bool = { false },
        repeatTiming: @escaping () -> RepeatTiming? = { nil },
        emit: @escaping @MainActor (Event) -> Void,
        teardown: @escaping () -> Void = {}
    ) {
        self.readCapsLock = readCapsLock
        self.repeatTiming = repeatTiming
        self.emit = emit
        self.teardown = teardown
    }

    deinit {
        repeatTask?.cancel()
    }

    /// Grants keyboard control to `peer` if currently unowned, returning the initial Caps Lock state.
    func begin(for peer: UUID, onCapsLockChanged: (@MainActor (Bool) -> Void)? = nil) -> Bool? {
        guard owner == nil else { return nil }
        owner = peer
        nextSequence = 1
        pending.removeAll()
        heldKeys.removeAll()
        activeModifiers = []
        capsLockObserver = onCapsLockChanged
        return readCapsLock()
    }

    /// Notifies the controlling client when the host Mac's Caps Lock indicator changes.
    func notifyCapsLockChanged(_ isOn: Bool) {
        capsLockObserver?(isOn)
    }

    @discardableResult
    func receive(_ bytes: Data, from peer: UUID) -> Bool {
        guard owner == peer, let message = try? KeyboardMessage(decoding: bytes) else { return false }
        let sequence: UInt64
        switch message {
        case .modifiers(let seq, _), .keystroke(let seq, _), .keyDown(let seq, _), .keyUp(let seq, _):
            sequence = seq
        case .state:
            return false
        }
        guard sequence >= nextSequence else { return true }
        if sequence > nextSequence {
            if pending.count < 256 { pending[sequence] = message }
            return true
        }
        var current: KeyboardMessage? = message
        while let next = current {
            apply(next)
            nextSequence += 1
            current = pending.removeValue(forKey: nextSequence)
        }
        return true
    }

    func end(for peer: UUID) {
        if owner == peer { releaseSession() }
    }

    func stop() {
        releaseSession()
        teardown()
    }

    private func releaseSession() {
        stopRepeat()
        for key in heldKeys.sorted(by: { $0.rawValue < $1.rawValue }) where key != .capsLock {
            emit(.keyUp(key, modifiers: activeModifiers))
        }
        heldKeys.removeAll()
        if !activeModifiers.isEmpty {
            activeModifiers = []
            emit(.modifiers([]))
        }
        owner = nil
        capsLockObserver = nil
        nextSequence = 1
        pending.removeAll()
    }

    private func apply(_ message: KeyboardMessage) {
        switch message {
        case .modifiers(_, let flags):
            guard flags != activeModifiers else { return }
            activeModifiers = flags
            emit(.modifiers(flags))
        case .keystroke(_, let key):
            stopRepeat()
            if key == .capsLock {
                emit(.capsLockShortPress)
            } else {
                emit(.keystroke(key, modifiers: activeModifiers))
            }
        case .keyDown(_, let key):
            guard heldKeys.insert(key).inserted else { return }
            stopRepeat()
            if key == .capsLock {
                emit(.capsLockLongPress)
            } else {
                emit(.keyDown(key, modifiers: activeModifiers, isAutoRepeat: false))
                if key.supportsAutoRepeat { startRepeat(for: key) }
            }
        case .keyUp(_, let key):
            guard heldKeys.remove(key) != nil else { return }
            if repeatingKey == key { stopRepeat() }
            if key != .capsLock {
                emit(.keyUp(key, modifiers: activeModifiers))
            }
        case .state:
            break
        }
    }

    private func startRepeat(for key: KeyboardKeyCode) {
        stopRepeat()
        guard let timing = repeatTiming(), timing.interval > .zero else { return }
        repeatingKey = key
        repeatTask = Task { [weak self] in
            do {
                if timing.delay > .zero {
                    try await Task.sleep(for: timing.delay)
                }
                while !Task.isCancelled {
                    guard let self, self.repeatingKey == key, self.heldKeys.contains(key) else {
                        return
                    }
                    self.emit(.keyDown(key, modifiers: self.activeModifiers, isAutoRepeat: true))
                    try await Task.sleep(for: timing.interval)
                }
            } catch {}
        }
    }

    private func stopRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
        repeatingKey = nil
    }
}

#if os(macOS)
    import AppKit
    import Carbon.HIToolbox
    import CoreGraphics
    import IOKit
    import IOKit.hidsystem

    extension KeyboardModifiers {
        var cgEventFlags: CGEventFlags {
            var flags: CGEventFlags = []
            if contains(.control) { flags.insert(.maskControl) }
            if contains(.option) { flags.insert(.maskAlternate) }
            if contains(.command) { flags.insert(.maskCommand) }
            if contains(.shift) { flags.insert(.maskShift) }
            return flags
        }
    }

    extension KeyboardControlServer {
        /// Creates a macOS keyboard server that injects `CGEvent`s, emulates native Caps Lock
        /// short-press input switching vs long-press lock toggling, and monitors the host LED.
        convenience init(system: Void = ()) {
            let driver = MacOSKeyboardDriver()
            var serverRef: KeyboardControlServer?
            self.init(
                readCapsLock: { driver.readCapsLock() },
                repeatTiming: { driver.repeatTiming() },
                emit: { event in
                    driver.handle(event)
                },
                teardown: {
                    driver.stopMonitoring()
                })
            serverRef = self
            driver.startMonitoring { [weak serverRef] isOn in
                serverRef?.notifyCapsLockChanged(isOn)
            }
        }
    }

    @MainActor
    private final class MacOSKeyboardDriver {
        private static let modifierOrder: [(KeyboardModifiers, KeyboardKeyCode)] = [
            (.control, .control),
            (.option, .option),
            (.command, .command),
            (.shift, .shift),
        ]

        nonisolated(unsafe) private let eventSource = CGEventSource(stateID: .hidSystemState)
        private var hidConnect: io_connect_t = 0
        private var postedModifiers: KeyboardModifiers = []
        private var lastKnownCapsLock = false
        private var lastNonASCIISourceID: String?
        private var globalMonitor: Any?
        private var localMonitor: Any?
        private var onCapsLockChanged: (@MainActor (Bool) -> Void)?

        init() {
            let service = IOServiceGetMatchingService(
                kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
            if service != 0 {
                _ = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &hidConnect)
                IOObjectRelease(service)
            }
            lastKnownCapsLock = readCapsLock()
        }

        deinit {
            if hidConnect != 0 {
                IOServiceClose(hidConnect)
            }
        }

        func startMonitoring(onCapsLockChanged: @escaping @MainActor (Bool) -> Void) {
            self.onCapsLockChanged = onCapsLockChanged
            lastKnownCapsLock = readCapsLock()
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
                [weak self] _ in
                Task { @MainActor in self?.pollCapsLockChange() }
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
                [weak self] event in
                self?.pollCapsLockChange()
                return event
            }
        }

        func stopMonitoring() {
            if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }
            globalMonitor = nil
            localMonitor = nil
            onCapsLockChanged = nil
        }

        func readCapsLock() -> Bool {
            if hidConnect != 0 {
                var state = false
                if IOHIDGetModifierLockState(hidConnect, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS {
                    return state
                }
            }
            return CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
        }

        func repeatTiming() -> KeyboardControlServer.RepeatTiming? {
            let interval = NSEvent.keyRepeatInterval
            let delay = NSEvent.keyRepeatDelay
            // macOS reports huge/invalid delays when Key Repeat is disabled in System Settings.
            guard interval > 0, interval < 5, delay >= 0, delay < 5 else { return nil }
            // The iOS client already waited ~250 ms to classify a hold; trim that off the initial
            // server delay so holding Delete or arrows begins repeating promptly.
            let adjustedDelay = max(interval, delay - 0.25)
            return .init(delay: .seconds(adjustedDelay), interval: .seconds(interval))
        }

        func handle(_ event: KeyboardControlServer.Event) {
            switch event {
            case .modifiers(let next):
                syncModifiers(to: next)
            case .keystroke(let key, let modifiers):
                postKey(key, down: true, modifiers: modifiers, isAutoRepeat: false)
                postKey(key, down: false, modifiers: modifiers, isAutoRepeat: false)
            case .keyDown(let key, let modifiers, let isAutoRepeat):
                postKey(key, down: true, modifiers: modifiers, isAutoRepeat: isAutoRepeat)
            case .keyUp(let key, let modifiers):
                postKey(key, down: false, modifiers: modifiers, isAutoRepeat: false)
            case .capsLockShortPress:
                handleCapsLock(isLongPress: false)
            case .capsLockLongPress:
                handleCapsLock(isLongPress: true)
            }
        }

        private func combinedFlags(for modifiers: KeyboardModifiers) -> CGEventFlags {
            var flags = modifiers.cgEventFlags
            if readCapsLock() { flags.insert(.maskAlphaShift) }
            return flags
        }

        private func syncModifiers(to next: KeyboardModifiers) {
            let changed = postedModifiers.symmetricDifference(next)
            guard !changed.isEmpty else { return }
            for (bit, keyCode) in Self.modifierOrder where changed.contains(bit) {
                let isDown = next.contains(bit)
                if isDown {
                    postedModifiers.insert(bit)
                } else {
                    postedModifiers.remove(bit)
                }
                guard
                    let cgEvent = CGEvent(
                        keyboardEventSource: eventSource, virtualKey: keyCode.rawValue,
                        keyDown: isDown)
                else { continue }
                cgEvent.type = .flagsChanged
                cgEvent.flags = combinedFlags(for: postedModifiers)
                cgEvent.post(tap: .cghidEventTap)
            }
        }

        private func postKey(
            _ key: KeyboardKeyCode, down: Bool, modifiers: KeyboardModifiers, isAutoRepeat: Bool
        ) {
            guard
                let cgEvent = CGEvent(
                    keyboardEventSource: eventSource, virtualKey: key.rawValue, keyDown: down)
            else { return }
            cgEvent.flags = combinedFlags(for: modifiers)
            if isAutoRepeat {
                cgEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            }
            cgEvent.post(tap: .cghidEventTap)
        }

        private func handleCapsLock(isLongPress: Bool) {
            let capsOn = readCapsLock()
            // Native macOS: if Caps Lock is already on, any press turns it off.
            if capsOn {
                setCapsLock(false)
                return
            }
            if isCapsLockInputSwitchEnabled() {
                if !isLongPress {
                    // Short tap switches between non-Latin (e.g. Chinese Pinyin) and Latin (ABC)
                    // without lighting Caps Lock.
                    if toggleLatinAndNonLatinInputSource() { return }
                } else {
                    // Long press from a non-Latin input source switches to Latin (ABC) and engages
                    // Caps Lock, matching native macOS behavior.
                    switchToASCIIInputSourceIfNeeded()
                }
            }
            setCapsLock(true)
        }

        private func setCapsLock(_ enabled: Bool) {
            if hidConnect != 0 {
                _ = IOHIDSetModifierLockState(hidConnect, Int32(kIOHIDCapsLockState), enabled)
            } else if let cgEvent = CGEvent(
                keyboardEventSource: eventSource, virtualKey: KeyboardKeyCode.capsLock.rawValue,
                keyDown: enabled)
            {
                cgEvent.type = .flagsChanged
                var flags = postedModifiers.cgEventFlags
                if enabled { flags.insert(.maskAlphaShift) }
                cgEvent.flags = flags
                cgEvent.post(tap: .cghidEventTap)
            }
            pollCapsLockChange()
        }

        private func pollCapsLockChange() {
            let current = readCapsLock()
            guard current != lastKnownCapsLock else { return }
            lastKnownCapsLock = current
            onCapsLockChanged?(current)
        }

        private func isCapsLockInputSwitchEnabled() -> Bool {
            CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
            if let value = CFPreferencesCopyAppValue(
                "TISRomanSwitchState" as CFString, kCFPreferencesAnyApplication)
            {
                return (value as? NSNumber)?.boolValue == true
            }
            // macOS enables "Use the Caps Lock key to switch to and from ABC" by default whenever
            // a non-ASCII input source is installed, only writing `TISRomanSwitchState` if toggled.
            return true
        }

        private func switchToASCIIInputSourceIfNeeded() {
            guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                !isASCIICapable(current)
            else { return }
            lastNonASCIISourceID = inputSourceID(of: current)
            guard let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue()
            else { return }
            _ = TISSelectInputSource(ascii)
        }

        /// Mirrors macOS's native Caps Lock short-press: switches between the active non-ASCII
        /// input source (e.g. Pinyin) and the most recently used ASCII-capable layout (e.g. ABC).
        private func toggleLatinAndNonLatinInputSource() -> Bool {
            guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
                return false
            }
            let filter: [CFString: Any] = [
                kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
                kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue as Any,
            ]
            guard
                let list = TISCreateInputSourceList(filter as CFDictionary, false)?
                    .takeRetainedValue() as? [TISInputSource]
            else { return false }
            let nonASCIISources = list.filter { !isASCIICapable($0) }
            guard !nonASCIISources.isEmpty else { return false }

            if !isASCIICapable(current) {
                lastNonASCIISourceID = inputSourceID(of: current)
                guard
                    let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue()
                else { return false }
                return TISSelectInputSource(ascii) == noErr
            } else {
                let target =
                    lastNonASCIISourceID.flatMap { remembered in
                        nonASCIISources.first { inputSourceID(of: $0) == remembered }
                    } ?? nonASCIISources[0]
                return TISSelectInputSource(target) == noErr
            }
        }

        private func isASCIICapable(_ source: TISInputSource) -> Bool {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable)
            else { return false }
            return Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue() == kCFBooleanTrue
        }

        private func inputSourceID(of source: TISInputSource) -> String? {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
                return nil
            }
            return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        }
    }
#endif
