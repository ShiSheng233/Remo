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
        .button(sequence: 5, action: .rightClick, position: position),
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
        sequence: 1, action: .leftClick, position: CGPoint(x: CGFloat.nan, y: 0))
    #expect(throws: WireFormatError.self) { try PointerMessage(decoding: invalid.encoded) }
}

@Test @MainActor func pointerMovesRespectButtonOrderAndReliableClickPositions() {
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

    func send(_ input: PointerMessage, _ channel: MessageTransport.Channel) {
        server.receive(input.encoded, on: channel, from: id)
    }
    send(.move(sequence: 4, afterButton: 2, position: dragged), .unreliable)
    send(.move(sequence: 3, afterButton: 2, position: start), .unreliable)
    #expect(events.isEmpty)
    send(.button(sequence: 2, action: .leftDown, position: start), .reliable)
    // The final unreliable move at sequence 5 never arrives.
    send(.button(sequence: 6, action: .leftUp, position: end), .reliable)
    send(.move(sequence: 5, afterButton: 2, position: dragged), .unreliable)
    send(.button(sequence: 8, action: .rightClick, position: clicked), .unreliable)
    send(.button(sequence: 8, action: .rightClick, position: clicked), .reliable)
    send(.scroll(lines: -3), .unreliable)

    #expect(events == [
        .button(.leftDown, start), .move(dragged, dragging: true),
        .move(end, dragging: true), .button(.leftUp, end),
        .button(.rightClick, clicked), .scroll(lines: -3),
    ])
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
    let input = PointerMessage.button(sequence: 1, action: .leftDown, position: position).encoded
    server.receive(input, on: .reliable, from: viewer)
    #expect(events.isEmpty)
    server.receive(input, on: .reliable, from: owner)
    server.end(for: viewer)
    #expect(events == [.button(.leftDown, position)])
    server.end(for: owner)
    #expect(events == [.button(.leftDown, position), .button(.leftUp, position)])
    #expect(server.begin(for: viewer) != nil)
    server.receive(input, on: .reliable, from: viewer)
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
        let channel: MessageTransport.Channel =
            if case .reliable = message.mode { .reliable } else { .unreliable }
        server.receive(message.encoded, on: channel, from: id)
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
