import Foundation
import Network
import Testing

@testable import RemoTransport

private final class SimulatedConnection: DatagramConnection {
    let initialState: NWConnection.State
    var events: AsyncStream<ConnectionEvent>.Continuation?
    var packets: [Data] = []
    var starts = 0
    var receives = 0
    var cancellations = 0
    var onStart: (() -> Void)?
    var onReceive: (() -> Void)?

    init(_ initialState: NWConnection.State = .ready) { self.initialState = initialState }

    func start(events: AsyncStream<ConnectionEvent>.Continuation) {
        starts += 1
        self.events = events
        events.yield(.state(initialState))
        onStart?()
    }

    func receive() {
        receives += 1
        onReceive?()
    }
    func send(_ datagram: Data) { packets.append(datagram) }
    func cancel() { cancellations += 1 }
}

private actor SessionOwner {
    var delivered: [Data] = []
    var closes = 0
    var session: NetworkMessageSession?

    func roundTrip() async throws {
        let driver = SimulatedConnection()
        let (received, signal) = AsyncStream<Void>.makeStream()
        session = try await NetworkMessageSession(driver: driver) { bytes in
            self.preconditionIsolated()
            self.delivered.append(bytes)
            do { try self.session?.send(bytes, delivery: .untilDelivered()) } catch {
                Issue.record("Reply failed: \(error)")
            }
            signal.yield(())
        } closeHandler: { _ in
            self.closes += 1
        }
        let active = try #require(session)
        #expect(driver.receives == 1)
        // Sent once: with no peer to acknowledge it, a retried message would compete with
        // the reply below whenever this test is starved of CPU.
        try active.send(Data([1]))
        #expect(driver.packets.count == 1)
        let inbound = Data([0, 0, 0, 0, 1, 0, 0, 0, 1, 13])
        driver.events?.yield(.received(inbound))
        var iterator = received.makeAsyncIterator()
        await iterator.next()
        #expect(delivered == [Data([13])])
        #expect(driver.receives == 2)
        #expect(driver.packets.contains(Data([0, 0, 0, 0, 2, 0, 0, 0, 2, 13])))
        active.cancel()
        active.cancel()
        #expect(closes == 1 && driver.cancellations == 1)
    }
}

@Test func sessionUsesConstructingActor() async throws {
    try await SessionOwner().roundTrip()
}

@Test @MainActor func sessionConstructionCancellation() async {
    let driver = SimulatedConnection(.waiting(.posix(.ENETDOWN)))
    let (started, signal) = AsyncStream<Void>.makeStream()
    driver.onStart = { signal.yield(()) }
    let task = Task {
        _ = try await NetworkMessageSession(driver: driver) { _ in
            Issue.record("Unexpected data during setup")
        } closeHandler: { _ in
            Issue.record("Unexpected close during setup")
        }
    }
    var iterator = started.makeAsyncIterator()
    await iterator.next()
    task.cancel()
    do {
        try await task.value
        Issue.record("Cancelled construction succeeded")
    } catch { #expect(error is CancellationError) }
    #expect(driver.cancellations == 1 && driver.receives == 0)
}

@Test @MainActor func sessionSetupFailure() async {
    let error = NWError.posix(.ECONNREFUSED)
    let driver = SimulatedConnection(.failed(error))
    do {
        _ = try await NetworkMessageSession(driver: driver) { _ in
        } closeHandler: { _ in
            Issue.record("Unexpected close during setup")
        }
        Issue.record("Failed connection became ready")
    } catch let actual { #expect(actual as? NWError == error) }
    #expect(driver.cancellations == 1 && driver.receives == 0)
}

@Test @MainActor func sessionBackpressureAndCompletion() async throws {
    let driver = SimulatedConnection()
    let session = try await NetworkMessageSession(driver: driver, datagramLimit: 64) { _ in
    } closeHandler: { _ in
    }
    defer { session.cancel() }
    let full = Data(repeating: 7, count: 55)
    for _ in 0..<256 { try session.send(full, delivery: .untilDelivered()) }
    #expect(throws: NetworkMessageSession.SendError.backpressure) {
        try session.send(full, delivery: .untilDelivered())
    }
    #expect(driver.packets.count == 2)
    #expect(throws: NetworkMessageSession.SendError.invalidLength) {
        try session.send(Data(), delivery: .untilDelivered())
    }
    #expect(throws: NetworkMessageSession.SendError.invalidTime) {
        try session.send(full, delivery: .init(retryBudget: -1))
    }
    let (processed, signal) = AsyncStream<Void>.makeStream()
    driver.onReceive = { signal.yield(()) }
    var iterator = processed.makeAsyncIterator()
    driver.events?.yield(.processed(64))
    driver.events?.yield(.received(nil))
    await iterator.next()
    #expect(driver.packets.count == 3)
    #expect(throws: NetworkMessageSession.SendError.backpressure) {
        try session.send(full, delivery: .untilDelivered())
    }
    driver.events?.yield(.received(Wire.ack(1, 1)))
    await iterator.next()
    try session.send(full, delivery: .untilDelivered())
}

@Test @MainActor func sessionConnectionFailureClosesOnce() async throws {
    let driver = SimulatedConnection()
    let (closed, signal) = AsyncStream<Void>.makeStream()
    var reasons: [NetworkMessageSession.CloseReason] = []
    let session = try await NetworkMessageSession(driver: driver) { _ in
        Issue.record("Message delivered after failure")
    } closeHandler: { reason in
        MainActor.preconditionIsolated()
        reasons.append(reason)
        signal.yield(())
    }
    let error = NWError.posix(.ECONNRESET)
    driver.events?.yield(.failed(error))
    driver.events?.yield(.state(.failed(error)))
    driver.events?.yield(.state(.cancelled))
    driver.events?.yield(.received(Data([0, 0, 0, 0, 1, 0, 0, 0, 1, 13])))
    var iterator = closed.makeAsyncIterator()
    await iterator.next()
    session.cancel()
    #expect(reasons.count == 1)
    guard case .network(let actual) = reasons.first else {
        Issue.record("Missing network close reason")
        return
    }
    #expect(actual == error && driver.cancellations == 1 && driver.receives == 1)
    #expect(throws: NetworkMessageSession.SendError.closed) {
        try session.send(Data([1]), delivery: .untilDelivered())
    }
}

@Test @MainActor func sessionFinalDatagramPrecedesClose() async throws {
    let driver = SimulatedConnection()
    let (closed, signal) = AsyncStream<Void>.makeStream()
    var messages: [Data] = []
    let session = try await NetworkMessageSession(driver: driver) { bytes in
        messages.append(bytes)
    } closeHandler: { reason in
        if case .endOfStream = reason {} else { Issue.record("Expected end of stream") }
        #expect(messages == [Data([42])])
        signal.yield(())
    }
    driver.events?.yield(.received(Data([0, 0, 0, 0, 1, 0, 0, 0, 1, 42]), final: true))
    var iterator = closed.makeAsyncIterator()
    await iterator.next()
    #expect(driver.receives == 1 && driver.cancellations == 1)
    #expect(throws: NetworkMessageSession.SendError.closed) {
        try session.send(Data([1]), delivery: .untilDelivered())
    }
}
