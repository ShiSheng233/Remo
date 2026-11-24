//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreMedia
import CoreVideo
import Foundation
import Network
import RemoTransport
import Testing

@testable import RemoEngine

@Test func keyboardMessagesRoundTripAndEnforceReliableDelivery() throws {
    let messages: [KeyboardMessage] = [
        .modifiers(sequence: 1, flags: [.command, .shift]),
        .keystroke(sequence: 2, key: .c),
        .keyDown(sequence: 3, key: .delete),
        .keyUp(sequence: 4, key: .delete),
        .state(sequence: 1, capsLock: true),
    ]
    for message in messages {
        let decoded = try KeyboardMessage(decoding: message.encoded)
        #expect(decoded == message)
        #expect(message.delivery.retryBudget == .infinity)
        #expect(message.delivery.priority == .high)
        #expect(throws: WireFormatError.self) {
            try KeyboardMessage(decoding: message.encoded.dropLast())
        }
        #expect(throws: WireFormatError.self) {
            try KeyboardMessage(decoding: message.encoded + [0])
        }
    }
    // Zero sequence and invalid modifier bits are rejected.
    #expect(throws: WireFormatError.self) {
        try KeyboardMessage(decoding: KeyboardMessage.keystroke(sequence: 0, key: .a).encoded)
    }
    var badModifiers = Data([MessageKind.keyboardInput.rawValue, 1])
    badModifiers.put(UInt64(1))
    badModifiers.put(UInt8(0x80))
    #expect(throws: WireFormatError.self) { try KeyboardMessage(decoding: badModifiers) }
    // Input events are never replaceable; Caps Lock state echo is latest-wins.
    #expect(messages[0].delivery.replacing == nil)
    #expect(messages[1].delivery.replacing == nil)
    #expect(messages[4].delivery.replacing != nil)
}

@Test @MainActor func keyboardServerAppliesEventsInStrictSequenceOrder() {
    let peer = UUID()
    var events: [KeyboardControlServer.Event] = []
    let server = KeyboardControlServer(emit: { events.append($0) })
    #expect(server.begin(for: peer) == false)

    func send(_ message: KeyboardMessage) {
        #expect(server.receive(message.encoded, from: peer))
    }

    // Deliver a full Cmd+C shortcut + hold-and-release sequence completely out of order.
    send(.modifiers(sequence: 5, flags: []))
    send(.keyUp(sequence: 4, key: .delete))
    send(.keyDown(sequence: 3, key: .delete))
    send(.keystroke(sequence: 2, key: .c))
    #expect(events.isEmpty)

    // Sequence 1 unlocks the whole buffered chain in exact order.
    send(.modifiers(sequence: 1, flags: [.command]))
    #expect(events == [
        .modifiers([.command]),
        .keystroke(.c, modifiers: [.command]),
        .keyDown(.delete, modifiers: [.command], isAutoRepeat: false),
        .keyUp(.delete, modifiers: [.command]),
        .modifiers([]),
    ])

    // Duplicates and stale sequences change nothing.
    send(.keystroke(sequence: 2, key: .c))
    send(.modifiers(sequence: 5, flags: []))
    #expect(events.count == 5)
}

@Test @MainActor func keyboardServerRepeatsHeldKeyAndReleasesOnDisconnect() async throws {
    let peer = UUID()
    let other = UUID()
    var events: [KeyboardControlServer.Event] = []
    let server = KeyboardControlServer(
        repeatTiming: { .init(delay: .milliseconds(25), interval: .milliseconds(15)) },
        emit: { events.append($0) })
    #expect(server.begin(for: peer) == false)
    #expect(server.begin(for: other) == nil)

    // Unauthorized peer is ignored.
    #expect(!server.receive(KeyboardMessage.keystroke(sequence: 1, key: .a).encoded, from: other))
    #expect(events.isEmpty)

    // Hold Shift + Delete so server generates auto-repeats.
    #expect(server.receive(KeyboardMessage.modifiers(sequence: 1, flags: [.shift]).encoded, from: peer))
    #expect(server.receive(KeyboardMessage.keyDown(sequence: 2, key: .delete).encoded, from: peer))
    let repeatCount = {
        events.filter {
            if case .keyDown(.delete, modifiers: [.shift], isAutoRepeat: true) = $0 { return true }
            return false
        }.count
    }
    for _ in 0..<100 where repeatCount() < 2 {
        try await Task.sleep(for: .milliseconds(15))
    }
    #expect(repeatCount() >= 2)

    // Ending the session stops repeat and releases held keys + modifiers cleanly.
    server.end(for: peer)
    let countAfterEnd = events.count
    #expect(events.suffix(2) == [.keyUp(.delete, modifiers: [.shift]), .modifiers([])])
    try await Task.sleep(for: .milliseconds(50))
    #expect(events.count == countAfterEnd)

    // A new owner can now take control.
    #expect(server.begin(for: other) == false)
}

@Test @MainActor func capsLockDistinguishesShortPressAndLongPressWithoutRepeat() async throws {
    let peer = UUID()
    var events: [KeyboardControlServer.Event] = []
    let server = KeyboardControlServer(
        repeatTiming: { .init(delay: .milliseconds(10), interval: .milliseconds(10)) },
        emit: { events.append($0) })
    #expect(server.begin(for: peer) == false)

    // Short tap -> capsLockShortPress
    #expect(server.receive(KeyboardMessage.keystroke(sequence: 1, key: .capsLock).encoded, from: peer))
    // Long press -> capsLockLongPress, no auto-repeat, no extra event on keyUp
    #expect(server.receive(KeyboardMessage.keyDown(sequence: 2, key: .capsLock).encoded, from: peer))
    try await Task.sleep(for: .milliseconds(50))
    #expect(server.receive(KeyboardMessage.keyUp(sequence: 3, key: .capsLock).encoded, from: peer))

    #expect(events == [.capsLockShortPress, .capsLockLongPress])
}

@Test @MainActor func keyboardClientDeduplicatesModifiersAndTracksHeldKeys() {
    var client = KeyboardControlClient()
    // Ignored before handshake completes.
    #expect(client.setModifiers([.command]) == nil)
    #expect(client.keystroke(.a) == nil)

    client.begin(capsLock: true)
    #expect(client.capsLock)

    #expect(client.setModifiers([.command]) == .modifiers(sequence: 1, flags: [.command]))
    #expect(client.setModifiers([.command]) == nil)
    #expect(client.keystroke(.c) == .keystroke(sequence: 2, key: .c))
    #expect(client.keyDown(.leftArrow) == .keyDown(sequence: 3, key: .leftArrow))
    #expect(client.keyDown(.leftArrow) == nil)

    // Releasing without modifiers frees held keys while preserving modifiers.
    #expect(client.releaseAll(includingModifiers: false) == [.keyUp(sequence: 4, key: .leftArrow)])
    #expect(client.modifiers == [.command])

    // Releasing with modifiers clears them as well.
    #expect(client.releaseAll(includingModifiers: true) == [.modifiers(sequence: 5, flags: [])])
    #expect(client.modifiers.isEmpty)

    // Caps Lock state echo ignores stale sequence numbers.
    let updated = client.receiveState(KeyboardMessage.state(sequence: 2, capsLock: false).encoded)
    #expect(updated)
    #expect(!client.capsLock)
    let stale = client.receiveState(KeyboardMessage.state(sequence: 1, capsLock: true).encoded)
    #expect(!stale)
    #expect(!client.capsLock)
}

@Test @MainActor func unifiedHandshakeGrantsControlAndDeliversOrderedKeyboardAndCapsLockEcho() async throws {
    final class MinimalFrameSource: ScreenFrameSource {
        let width = 160
        let height = 90
        private var step: Int64 = 0
        func latestFrame() throws -> ScreenFrame? {
            step += 1
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &buffer)
            let pixels = try #require(buffer)
            return ScreenFrame(pixels: pixels, timestamp: CMTime(value: step, timescale: 30))
        }
        nonisolated(nonsending) func stop() async throws {}
    }

    var port: UInt16?
    var receivedEvents: [KeyboardControlServer.Event] = []
    var serverCapsLock = true
    let pointerServer = PointerControlServer(
        initialState: { .init(position: CGPoint(x: 0.5, y: 0.5), width: 1512, height: 982) },
        emit: { _ in })
    let keyboardServer = KeyboardControlServer(
        readCapsLock: { serverCapsLock },
        emit: { receivedEvents.append($0) })

    let server = try await RemoteScreenServer(
        configuration: .init(source: .custom { _ in MinimalFrameSource() }, allowsRemoteControl: true),
        cursor: nil,
        pointer: pointerServer,
        keyboard: keyboardServer
    ) { event in
        if case .listening(let p) = event { port = p }
    }
    let listening = Task { try await server.listen(on: 0) }
    defer { server.stop() }
    while port == nil { try await Task.sleep(for: .milliseconds(10)) }

    var grantedControl: (CGSize, Bool)?
    var capsLockUpdates: [Bool] = []
    let client = RemoteScreenClient(
        configuration: .init(requestsRemoteControl: true),
        onFrame: { _ in },
        onEvent: { event in
            switch event {
            case let .controlAvailable(size, capsLock):
                grantedControl = (size, capsLock)
            case .capsLockChanged(let isOn):
                capsLockUpdates.append(isOn)
            default: break
            }
        })

    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port!)!)
    let runTask = Task { await client.run(.udp(endpoint)) }
    for _ in 0..<200 where client.state != .streaming || client.remoteControlDisplaySize == nil {
        try await Task.sleep(for: .milliseconds(15))
    }
    client.setKeyboardModifiers([.command])
    client.pressKeystroke(.c)
    client.setKeyboardModifiers([])
    client.keyDown(.delete)
    client.keyUp(.delete)
    // Simulate host Mac toggling Caps Lock off.
    serverCapsLock = false
    keyboardServer.notifyCapsLockChanged(false)

    for _ in 0..<200 where receivedEvents.count < 5 || capsLockUpdates.isEmpty {
        try await Task.sleep(for: .milliseconds(15))
    }
    client.disconnect()
    let failure = await runTask.value

    #expect(failure == nil)
    #expect(grantedControl?.0 == CGSize(width: 1512, height: 982))
    #expect(grantedControl?.1 == true)
    #expect(capsLockUpdates == [false])
    #expect(receivedEvents == [
        .modifiers([.command]),
        .keystroke(.c, modifiers: [.command]),
        .modifiers([]),
        .keyDown(.delete, modifiers: [], isAutoRepeat: false),
        .keyUp(.delete, modifiers: []),
    ])

    server.stop()
    try await listening.value
}
