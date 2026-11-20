import Dispatch
import Foundation
import Network

public enum ConnectionEvent: Sendable {
    case state(NWConnection.State)
    case received(Data?, final: Bool = false)
    case processed(Int)
    case failed(NWError)
    case timer
}

/// A message-oriented connection driven by a `NetworkMessageSession`'s owning actor.
/// Each receive requests one datagram. Send completions report the original admitted byte count.
public protocol DatagramConnection: AnyObject {
    func start(events: AsyncStream<ConnectionEvent>.Continuation)
    func receive()
    func send(_ datagram: Data)
    func cancel()
}

private final class NetworkDatagramConnection: DatagramConnection {
    let connection: NWConnection
    private var events: AsyncStream<ConnectionEvent>.Continuation?

    init(_ connection: NWConnection) { self.connection = connection }

    func start(events: AsyncStream<ConnectionEvent>.Continuation) {
        self.events = events
        connection.stateUpdateHandler = { events.yield(.state($0)) }
        connection.start(queue: DispatchQueue(label: "RemoTransport.connection"))
    }

    func receive() {
        connection.receiveMessage { [events] data, context, complete, error in
            if let error {
                events?.yield(.failed(error))
            } else {
                events?.yield(
                    .received(complete ? data : nil, final: complete && context?.isFinal == true))
            }
        }
    }

    func send(_ datagram: Data) {
        connection.send(
            content: datagram,
            completion: .contentProcessed { [events, count = datagram.count] error in
                if let error {
                    events?.yield(.failed(error))
                } else {
                    events?.yield(.processed(count))
                }
            })
    }

    func cancel() {
        connection.cancel()
        events = nil
    }
}

/// A datagram session confined to the actor that constructed it.
/// All synchronous operations and application callbacks run on that actor.
public final class NetworkMessageSession {
    public enum SendError: Error { case backpressure, invalidLength, invalidTime, closed }
    public enum SetupError: Error { case invalidDatagramLimit }
    public enum CloseReason {
        case cancelled
        case endOfStream
        case network(NWError)
        case transport(MessageTransport.Failure)
    }

    private unowned let owner: any Actor
    private let connection: any DatagramConnection
    private let events: AsyncStream<ConnectionEvent>.Continuation
    private let timer: any DispatchSourceTimer
    private let datagramLimit: Int
    private var inFlightBytes = 0
    private var closed = false
    private var dataHandler: ((MessageTransport.Channel, Data) -> Void)?
    private var closeHandler: ((CloseReason) -> Void)?
    private lazy var transport = MessageTransport(
        datagramLimit: datagramLimit, clock: Self.now,
        dataHandler: { [weak self] in self?.dataHandler?($0, $1) },
        ioHandler: { [weak self] in self?.perform($0) ?? false }
    )!

    /// Takes ownership of an unstarted datagram connection. The peer must use the same limit.
    /// Returns once the connection is ready and the first receive has been submitted.
    public convenience init(
        connection: NWConnection, datagramLimit: Int = 1200,
        isolation: isolated any Actor = #isolation,
        dataHandler: @escaping (MessageTransport.Channel, Data) -> Void,
        closeHandler: @escaping (CloseReason) -> Void
    ) async throws {
        try await self.init(
            driver: NetworkDatagramConnection(connection), datagramLimit: datagramLimit,
            isolation: isolation, dataHandler: dataHandler, closeHandler: closeHandler)
    }

    /// Takes ownership of an unstarted datagram driver.
    public init(
        driver: any DatagramConnection, datagramLimit: Int = 1200,
        isolation: isolated any Actor = #isolation,
        dataHandler: @escaping (MessageTransport.Channel, Data) -> Void,
        closeHandler: @escaping (CloseReason) -> Void
    ) async throws {
        guard datagramLimit >= 64 else { throw SetupError.invalidDatagramLimit }
        owner = isolation
        connection = driver
        self.datagramLimit = min(1200, datagramLimit)
        self.dataHandler = dataHandler
        self.closeHandler = closeHandler
        let (stream, events) = AsyncStream<ConnectionEvent>.makeStream()
        self.events = events
        timer = DispatchSource.makeTimerSource()
        timer.setEventHandler { events.yield(.timer) }
        timer.activate()

        try Task.checkCancellation()
        driver.start(events: events)
        for await event in stream {
            try Task.checkCancellation()
            switch event {
            case .state(.ready):
                driver.receive()
                Task { [weak self] in
                    isolation.preconditionIsolated()
                    for await event in stream {
                        guard let self, !self.closed else { return }
                        self.handle(event)
                    }
                }
                return
            case .state(.failed(let error)), .failed(let error): throw error
            case .state(.cancelled): throw CancellationError()
            default: continue
            }
        }
        throw CancellationError()
    }

    deinit {
        if !closed {
            events.finish()
            timer.cancel()
            connection.cancel()
        }
    }

    public var statistics: MessageTransport.Statistics {
        owner.preconditionIsolated()
        return transport.statistics
    }

    /// Success means local admission. A network failure can still leave delivery unknown.
    /// Absolute U deadlines use DispatchTime uptime in seconds.
    public func send(_ data: Data, mode: MessageTransport.Mode) throws(SendError) {
        owner.preconditionIsolated()
        guard !closed else { throw .closed }
        switch transport.send(data, mode: mode) {
        case .queued: return
        case .backpressure: throw .backpressure
        case .invalidLength: throw .invalidLength
        case .invalidTime: throw .invalidTime
        case .closed: throw .closed
        }
    }

    /// End the session and release its event loop when its owning actor is done.
    public func cancel() {
        owner.preconditionIsolated()
        finish(.cancelled)
    }

    private static func now() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private func perform(_ request: MessageTransport.IORequest) -> Bool {
        guard !closed else { return false }
        switch request {
        case .sendDatagram(let bytes):
            guard inFlightBytes + bytes.count <= 2 * datagramLimit else { return false }
            inFlightBytes += bytes.count
            connection.send(bytes)
        case .setTimer(let time):
            let ticks = time.flatMap { UInt64(exactly: ($0 * 1_000_000_000).rounded(.up)) }
            timer.schedule(
                deadline: ticks.map(DispatchTime.init(uptimeNanoseconds:)) ?? .distantFuture)
        case .close(let failure): finish(.transport(failure))
        }
        return true
    }

    private func handle(_ event: ConnectionEvent) {
        switch event {
        case .received(let data, let final):
            if let data { transport.handleEvent(.datagram(data)) }
            if final { finish(.endOfStream) } else if !closed { connection.receive() }
        case .processed(let bytes):
            inFlightBytes -= bytes
            transport.handleEvent(.writable)
        case .timer:
            // The core rechecks its clock and rearms even after a stale or early timer event.
            transport.handleEvent(.timer)
        case .failed(let error), .state(.failed(let error)): finish(.network(error))
        case .state(.cancelled): finish(.cancelled)
        case .state: break
        }
    }

    private func finish(_ reason: CloseReason) {
        guard !closed else { return }
        closed = true
        events.finish()
        timer.cancel()
        connection.cancel()
        dataHandler = nil
        transport.handleEvent(.closed)
        let notify = closeHandler
        closeHandler = nil
        notify?(reason)
    }
}
