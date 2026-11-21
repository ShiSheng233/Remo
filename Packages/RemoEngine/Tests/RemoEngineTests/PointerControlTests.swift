//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation
import RemoTransport
import Testing

@testable import RemoEngine

@Test func pointerMessagesRoundTripAndRejectInvalidPositions() throws {
    let position = CGPoint(x: 0.125, y: 0.875)
    let messages: [PointerMessage] = [
        .ready(position: position, width: 1512, height: 982),
        .move(sequence: 4, afterButton: 3, position: position),
        .button(sequence: 5, afterButton: 3, action: .rightClick, position: position),
        .scroll(lines: -3),
    ]
    for message in messages {
        let decoded = try PointerMessage(decoding: message.encoded)
        #expect(decoded == message)
        #expect(throws: WireFormatError.self) {
            try PointerMessage(decoding: message.encoded.dropLast())
        }
    }
    let invalid = PointerMessage.button(
        sequence: 1, afterButton: 0, action: .leftClick, position: CGPoint(x: CGFloat.nan, y: 0))
    #expect(throws: WireFormatError.self) { try PointerMessage(decoding: invalid.encoded) }
    let selfReferential = PointerMessage.button(
        sequence: 4, afterButton: 4, action: .leftClick, position: position)
    #expect(throws: WireFormatError.self) { try PointerMessage(decoding: selfReferential.encoded) }
    // Button changes must arrive; a move only matters while it is fresh.
    #expect(messages[2].delivery.retryBudget == .infinity)
    #expect(messages[1].delivery.retryBudget == 0 && messages[1].delivery.firstSendDeadline != nil)
    #expect(messages[1].delivery.replacing != nil && messages[3].delivery.replacing == nil)
}

@Test @MainActor func pointerMovesRespectButtonOrderAndClickPositions() {
    let start = CGPoint(x: 0.1, y: 0.2)
    let dragged = CGPoint(x: 0.5, y: 0.6)
    let end = CGPoint(x: 0.7, y: 0.8)
    let clicked = CGPoint(x: 0.95, y: 0.9)
    let id = UUID()
    var events: [PointerControlServer.Event] = []
    let server = PointerControlServer(
        initialState: { .ready(position: start, width: 1512, height: 982) },
        emit: { events.append($0) })
    #expect(server.begin(for: id) != nil)

    func send(_ input: PointerMessage) {
        server.receive(input.encoded, from: id)
    }
    send(.move(sequence: 4, afterButton: 2, position: dragged))
    send(.move(sequence: 3, afterButton: 2, position: start))
    #expect(events.isEmpty)
    send(.button(sequence: 2, afterButton: 0, action: .leftDown, position: start))
    // The final move at sequence 5 arrives only after the button is released.
    send(.button(sequence: 6, afterButton: 2, action: .leftUp, position: end))
    send(.move(sequence: 5, afterButton: 2, position: dragged))
    send(.button(sequence: 8, afterButton: 6, action: .rightClick, position: clicked))
    send(.button(sequence: 8, afterButton: 6, action: .rightClick, position: clicked))
    send(.scroll(lines: -3))

    #expect(events == [
        .button(.leftDown, start), .move(dragged, dragging: true),
        .move(end, dragging: true), .button(.leftUp, end),
        .button(.rightClick, clicked), .scroll(lines: -3),
    ])
}

@Test @MainActor func buttonChangesApplyInOrderHoweverTheyArrive() {
    let down = CGPoint(x: 0.1, y: 0.2)
    let up = CGPoint(x: 0.3, y: 0.4)
    let clicked = CGPoint(x: 0.5, y: 0.6)
    let id = UUID()
    var events: [PointerControlServer.Event] = []
    let server = PointerControlServer(
        initialState: { .ready(position: .zero, width: 1512, height: 982) },
        emit: { events.append($0) })
    #expect(server.begin(for: id) != nil)
    func send(_ input: PointerMessage) { server.receive(input.encoded, from: id) }

    // A whole drag and the click after it arrive back to front, with a move in between.
    send(.button(sequence: 9, afterButton: 5, action: .rightClick, position: clicked))
    send(.move(sequence: 7, afterButton: 5, position: clicked))
    send(.button(sequence: 5, afterButton: 2, action: .leftUp, position: up))
    #expect(events.isEmpty)
    send(.button(sequence: 2, afterButton: 0, action: .leftDown, position: down))
    #expect(events == [
        .button(.leftDown, down), .move(up, dragging: true), .button(.leftUp, up),
        .move(clicked, dragging: false), .button(.rightClick, clicked),
    ])
    // Duplicates and anything older than what has been applied change nothing.
    send(.button(sequence: 5, afterButton: 2, action: .leftUp, position: up))
    send(.button(sequence: 4, afterButton: 2, action: .leftClick, position: down))
    #expect(events.count == 5)
}

@Test @MainActor func closingPointerSessionReleasesDragAndAllowsNewOwner() {
    let position = CGPoint(x: 0.2, y: 0.3)
    let owner = UUID()
    let viewer = UUID()
    var events: [PointerControlServer.Event] = []
    let server = PointerControlServer(
        initialState: { .ready(position: .zero, width: 1512, height: 982) },
        emit: { events.append($0) })
    #expect(server.begin(for: owner) != nil)
    #expect(server.begin(for: viewer) == nil)
    let input = PointerMessage.button(
        sequence: 1, afterButton: 0, action: .leftDown, position: position
    ).encoded
    server.receive(input, from: viewer)
    #expect(events.isEmpty)
    server.receive(input, from: owner)
    server.end(for: viewer)
    #expect(events == [.button(.leftDown, position)])
    server.end(for: owner)
    #expect(events == [.button(.leftDown, position), .button(.leftUp, position)])
    #expect(server.begin(for: viewer) != nil)
    server.receive(input, from: viewer)
    #expect(events.last == .button(.leftDown, position))
    server.stop()
    #expect(events.last == .button(.leftUp, position))
}

@Test @MainActor func pointerClientOrdersInputForTheServer() throws {
    var client = PointerControlClient()
    let early = [client.move(by: CGVector(dx: 10, dy: 10)), client.press(.leftClick)]
    #expect(early == [nil, nil])

    let start = CGPoint(x: 0.5, y: 0.5)
    var events: [PointerControlServer.Event] = []
    let server = PointerControlServer(
        initialState: { .ready(position: start, width: 1000, height: 500) },
        emit: { events.append($0) })
    let id = UUID()
    let ready = try #require(server.begin(for: id))
    let granted = [client.receiveReady(ready.encoded), client.receiveReady(ready.encoded)]
    #expect(granted == [true, false])
    #expect(client.displaySize == CGSize(width: 1000, height: 500))

    func send(_ message: PointerMessage?) throws {
        let message = try #require(message)
        server.receive(message.encoded, from: id)
    }
    try send(client.move(by: CGVector(dx: 100, dy: -50)))
    try send(client.press(.leftDown))
    // Moves past the edge stop there.
    try send(client.move(by: CGVector(dx: 10_000, dy: 10_000)))
    try send(client.press(.leftUp))
    try send(client.scroll(lines: 1_000))
    let ignored = [client.scroll(lines: 0), client.move(by: .zero)]
    #expect(ignored == [nil, nil])

    let moved = CGPoint(x: 0.6, y: 0.4)
    let corner = CGPoint(x: 1, y: 1)
    #expect(events == [
        .move(moved, dragging: false), .button(.leftDown, moved),
        .move(corner, dragging: true), .button(.leftUp, corner), .scroll(lines: 100),
    ])
}
