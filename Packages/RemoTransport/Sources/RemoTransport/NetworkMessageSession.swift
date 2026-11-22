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

/// A message-oriented connection driven by a `NetworkMessageSession`.
/// Each receive requests one datagram. Send completions report the original admitted byte count.
public protocol DatagramConnection: AnyObject {
    func start(events: AsyncStream<ConnectionEvent>.Continuation)
    func receive()
    func send(_ datagram: Data)
    func cancel()
}

private final class NetworkDatagramConnection: DatagramConnection, @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private var events: AsyncStream<ConnectionEvent>.Continuation?
    private var directHandler: ((ConnectionEvent) -> Void)?
    private var terminalEvent: ConnectionEvent?

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start(events: AsyncStream<ConnectionEvent>.Continuation) {
        self.events = events
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let event = ConnectionEvent.state(state)
            if case .failed = state { self.terminalEvent = event }
            if case .cancelled = state { self.terminalEvent = event }
            self.dispatch(event)
        }
        connection.start(queue: queue)
    }

    /// Switches hot-path delivery directly onto `queue`, bypassing the setup `AsyncStream`.
    /// Must be called on `queue`.
    func attachDirectHandler(_ handler: @escaping (ConnectionEvent) -> Void) {
        directHandler = handler
        events = nil
        if let terminalEvent {
            self.terminalEvent = nil
            handler(terminalEvent)
        }
    }

    private func dispatch(_ event: ConnectionEvent) {
        if let directHandler {
            directHandler(event)
        } else {
            events?.yield(event)
        }
    }

    func receive() {
        connection.receiveMessage { [weak self] data, context, complete, error in
            guard let self else { return }
            if let error {
                self.dispatch(.failed(error))
            } else {
                self.dispatch(
                    .received(complete ? data : nil, final: complete && context?.isFinal == true))
            }
        }
    }

    func send(_ datagram: Data) {
        let count = datagram.count
        connection.send(
            content: datagram,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.dispatch(.failed(error))
                } else {
                    self.dispatch(.processed(count))
                }
            })
    }

    func cancel() {
        connection.cancel()
        events = nil
        directHandler = nil
    }
}

/// A datagram session whose owning actor calls synchronous operations and receives complete
/// application callbacks, while all packet I/O, pacing timers, ACKs, FEC and rate control run on
/// a dedicated high-priority serial queue off the owning actor.
public final class NetworkMessageSession {
    public enum SendError: Error { case backpressure, invalidLength, invalidTime, closed }
    public enum SetupError: Error { case invalidDatagramLimit }
    public enum CloseReason: Sendable {
        case cancelled
        case endOfStream
        case network(NWError)
        case transport(MessageTransport.Failure)
    }

    /// Default number of datagrams allowed in flight to the underlying socket before applying
    /// write backpressure. Large enough to absorb 5 Mbps+ frame bursts without per-packet stalls.
    public static let defaultMaxInFlightDatagrams = 16

    private enum OwnerEvent: Sendable {
        case data(Data)
        case deliveryConfirmed
        case outcome(UInt64, MessageTransport.Outcome)
        case closed(CloseReason)
    }

    /// Transport state confined exclusively to `queue`.
    private final class Core: @unchecked Sendable {
        let queue: DispatchQueue
        private let connection: any DatagramConnection
        private let inboundEvents: AsyncStream<ConnectionEvent>.Continuation
        private let ownerEvents: AsyncStream<OwnerEvent>.Continuation
        private let timer: any DispatchSourceTimer
        private let maxInFlightBytes: Int
        private var inFlightBytes = 0
        private var closed = false
        private var notifiesDelivery = false
        private var pumpTask: Task<Void, Never>?
        private var transport: MessageTransport!

        init(
            queue: DispatchQueue,
            connection: any DatagramConnection,
            datagramLimit: Int,
            maxInFlightDatagrams: Int,
            inboundEvents: AsyncStream<ConnectionEvent>.Continuation,
            ownerEvents: AsyncStream<OwnerEvent>.Continuation
        ) {
            self.queue = queue
            self.connection = connection
            self.inboundEvents = inboundEvents
            self.ownerEvents = ownerEvents
            self.maxInFlightBytes = max(2, maxInFlightDatagrams) * datagramLimit
            timer = DispatchSource.makeTimerSource(queue: queue)
            transport = MessageTransport(
                datagramLimit: datagramLimit, clock: Self.now,
                dataHandler: { [weak self] bytes in self?.ownerEvents.yield(.data(bytes)) },
                ioHandler: { [weak self] request in self?.perform(request) ?? false }
            )!
            timer.setEventHandler { [weak self] in self?.handleOnQueue(.timer) }
            timer.activate()
        }

        private static func now() -> TimeInterval {
            Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        }

        func startRunning(stream: AsyncStream<ConnectionEvent>) {
            queue.sync {
                guard !closed else { return }
                if let network = connection as? NetworkDatagramConnection {
                    network.attachDirectHandler { [weak self] event in
                        self?.handleOnQueue(event)
                    }
                    inboundEvents.finish()
                    if !closed { connection.receive() }
                } else {
                    connection.receive()
                    pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
                        for await event in stream {
                            guard let self else { return }
                            self.queue.async { self.handleOnQueue(event) }
                        }
                    }
                }
            }
        }

        func setNotifiesDelivery(_ enabled: Bool) {
            queue.sync {
                guard !closed else { return }
                notifiesDelivery = enabled
                transport.onDeliveryConfirmed =
                    enabled
                    ? { [weak self] in self?.ownerEvents.yield(.deliveryConfirmed) }
                    : nil
            }
        }

        var dataSendIdleTime: TimeInterval {
            queue.sync { transport.dataSendIdleTime }
        }

        var statistics: MessageTransport.Statistics {
            queue.sync { transport.statistics }
        }

        func send(
            _ data: Data, delivery: MessageTransport.Delivery, outcomeToken: UInt64?
        ) -> MessageTransport.SendResult {
            queue.sync {
                guard !closed else { return .closed }
                let handler: ((MessageTransport.Outcome) -> Void)? = outcomeToken.map { token in
                    { [weak self] outcome in
                        self?.ownerEvents.yield(.outcome(token, outcome))
                    }
                }
                return transport.send(data, delivery: delivery, onOutcome: handler)
            }
        }

        func cancelMessage(_ id: MessageTransport.MessageID) {
            queue.sync {
                guard !closed else { return }
                transport.cancelMessage(id)
            }
        }

        func closeFromOwnerSync() {
            queue.sync { finishOnQueue(nil) }
        }

        func closeFromDeinitAsync() {
            queue.async { self.finishOnQueue(nil) }
        }

        private func perform(_ request: MessageTransport.IORequest) -> Bool {
            guard !closed else { return false }
            switch request {
            case .sendDatagram(let bytes):
                guard inFlightBytes + bytes.count <= maxInFlightBytes else { return false }
                inFlightBytes += bytes.count
                connection.send(bytes)
            case .setTimer(let time):
                let ticks = time.flatMap { UInt64(exactly: ($0 * 1_000_000_000).rounded(.up)) }
                timer.schedule(
                    deadline: ticks.map(DispatchTime.init(uptimeNanoseconds:)) ?? .distantFuture)
            case .close(let failure):
                finishOnQueue(.transport(failure))
            }
            return true
        }

        private func handleOnQueue(_ event: ConnectionEvent) {
            guard !closed else { return }
            switch event {
            case .received(let data, let final):
                if let data { transport.handleEvent(.datagram(data)) }
                if final { finishOnQueue(.endOfStream) } else if !closed { connection.receive() }
            case .processed(let bytes):
                inFlightBytes = max(0, inFlightBytes - bytes)
                transport.handleEvent(.writable)
            case .timer:
                // The core rechecks its clock and rearms even after a stale or early timer event.
                transport.handleEvent(.timer)
            case .failed(let error), .state(.failed(let error)):
                finishOnQueue(.network(error))
            case .state(.cancelled):
                finishOnQueue(.cancelled)
            case .state: break
            }
        }

        private func finishOnQueue(_ reason: CloseReason?) {
            guard !closed else { return }
            closed = true
            pumpTask?.cancel()
            pumpTask = nil
            inboundEvents.finish()
            timer.cancel()
            connection.cancel()
            transport.onDeliveryConfirmed = nil
            transport.handleEvent(.closed)
            if let reason { ownerEvents.yield(.closed(reason)) }
            ownerEvents.finish()
        }
    }

    private unowned let owner: any Actor
    private let core: Core
    private var ownerClosed = false
    private var dataHandler: ((Data) -> Void)?
    private var closeHandler: ((CloseReason) -> Void)?
    private var deliveryConfirmedHandler: (() -> Void)?
    private var nextOutcomeToken: UInt64 = 1
    private var pendingOutcomes: [UInt64: (MessageTransport.Outcome) -> Void] = [:]

    /// Takes ownership of an unstarted datagram connection. The peer must use the same limit.
    /// Returns once the connection is ready and the first receive has been submitted.
    public convenience init(
        connection: NWConnection, datagramLimit: Int = MessageTransport.defaultDatagramLimit,
        maxInFlightDatagrams: Int = NetworkMessageSession.defaultMaxInFlightDatagrams,
        isolation: isolated any Actor = #isolation,
        dataHandler: @escaping (Data) -> Void,
        closeHandler: @escaping (CloseReason) -> Void
    ) async throws {
        let queue = DispatchQueue(label: "RemoTransport.session", qos: .userInitiated)
        try await self.init(
            driver: NetworkDatagramConnection(connection, queue: queue),
            queue: queue,
            datagramLimit: datagramLimit,
            maxInFlightDatagrams: maxInFlightDatagrams,
            isolation: isolation, dataHandler: dataHandler, closeHandler: closeHandler)
    }

    /// Takes ownership of an unstarted datagram driver.
    public convenience init(
        driver: any DatagramConnection, datagramLimit: Int = MessageTransport.defaultDatagramLimit,
        maxInFlightDatagrams: Int = NetworkMessageSession.defaultMaxInFlightDatagrams,
        isolation: isolated any Actor = #isolation,
        dataHandler: @escaping (Data) -> Void,
        closeHandler: @escaping (CloseReason) -> Void
    ) async throws {
        let queue = DispatchQueue(label: "RemoTransport.session", qos: .userInitiated)
        try await self.init(
            driver: driver, queue: queue, datagramLimit: datagramLimit,
            maxInFlightDatagrams: maxInFlightDatagrams,
            isolation: isolation, dataHandler: dataHandler, closeHandler: closeHandler)
    }

    private init(
        driver: any DatagramConnection,
        queue: DispatchQueue,
        datagramLimit: Int,
        maxInFlightDatagrams: Int,
        isolation: isolated any Actor,
        dataHandler: @escaping (Data) -> Void,
        closeHandler: @escaping (CloseReason) -> Void
    ) async throws {
        guard datagramLimit >= 64 else { throw SetupError.invalidDatagramLimit }
        owner = isolation
        let clampedLimit = min(1200, datagramLimit)
        self.dataHandler = dataHandler
        self.closeHandler = closeHandler
        let (inboundStream, inboundEvents) = AsyncStream<ConnectionEvent>.makeStream()
        let (ownerStream, ownerEvents) = AsyncStream<OwnerEvent>.makeStream()
        core = Core(
            queue: queue, connection: driver, datagramLimit: clampedLimit,
            maxInFlightDatagrams: maxInFlightDatagrams,
            inboundEvents: inboundEvents, ownerEvents: ownerEvents)

        do {
            try Task.checkCancellation()
            driver.start(events: inboundEvents)
            for await event in inboundStream {
                try Task.checkCancellation()
                switch event {
                case .state(.ready):
                    core.startRunning(stream: inboundStream)
                    Task { [weak self] in
                        isolation.preconditionIsolated()
                        for await event in ownerStream {
                            guard let self, !self.ownerClosed else { return }
                            self.handleOwnerEvent(event)
                        }
                    }
                    return
                case .state(.failed(let error)), .failed(let error): throw error
                case .state(.cancelled): throw CancellationError()
                default: continue
                }
            }
            throw CancellationError()
        } catch {
            ownerClosed = true
            self.dataHandler = nil
            self.closeHandler = nil
            core.closeFromOwnerSync()
            throw error
        }
    }

    deinit {
        if !ownerClosed {
            core.closeFromDeinitAsync()
        }
    }

    /// Called on the owning actor when an ACK newly confirms a transmitted data packet.
    public var onDeliveryConfirmed: (() -> Void)? {
        get {
            owner.preconditionIsolated()
            return deliveryConfirmedHandler
        }
        set {
            owner.preconditionIsolated()
            deliveryConfirmedHandler = newValue
            if !ownerClosed { core.setNotifiesDelivery(newValue != nil) }
        }
    }

    public var dataSendIdleTime: TimeInterval {
        owner.preconditionIsolated()
        return core.dataSendIdleTime
    }

    public var statistics: MessageTransport.Statistics {
        owner.preconditionIsolated()
        return core.statistics
    }

    /// Success means local admission. `onOutcome` runs on the owning actor when the message is
    /// delivered, expires or is cancelled; it never runs once the session has closed.
    /// Absolute first-send deadlines use DispatchTime uptime in seconds.
    @discardableResult
    public func send(
        _ data: Data, delivery: MessageTransport.Delivery = .init(),
        onOutcome: ((MessageTransport.Outcome) -> Void)? = nil
    ) throws(SendError) -> MessageTransport.MessageID {
        owner.preconditionIsolated()
        guard !ownerClosed else { throw .closed }
        var token: UInt64?
        if let onOutcome {
            let assigned = nextOutcomeToken
            nextOutcomeToken &+= 1
            pendingOutcomes[assigned] = onOutcome
            token = assigned
        }
        let result = core.send(data, delivery: delivery, outcomeToken: token)
        switch result {
        case .queued(let id): return id
        case .backpressure:
            if let token { pendingOutcomes.removeValue(forKey: token) }
            throw .backpressure
        case .invalidLength:
            if let token { pendingOutcomes.removeValue(forKey: token) }
            throw .invalidLength
        case .invalidTime:
            if let token { pendingOutcomes.removeValue(forKey: token) }
            throw .invalidTime
        case .closed:
            if let token { pendingOutcomes.removeValue(forKey: token) }
            throw .closed
        }
    }

    /// Stops sending a message that has not finished. The peer can still receive it if its
    /// datagrams were already on their way.
    public func cancelMessage(_ id: MessageTransport.MessageID) {
        owner.preconditionIsolated()
        guard !ownerClosed else { return }
        core.cancelMessage(id)
    }

    /// End the session and release its event loop when its owning actor is done.
    public func cancel() {
        owner.preconditionIsolated()
        guard !ownerClosed else { return }
        ownerClosed = true
        pendingOutcomes.removeAll()
        dataHandler = nil
        deliveryConfirmedHandler = nil
        core.closeFromOwnerSync()
        let notify = closeHandler
        closeHandler = nil
        notify?(.cancelled)
    }

    private func handleOwnerEvent(_ event: OwnerEvent) {
        switch event {
        case .data(let bytes):
            dataHandler?(bytes)
        case .deliveryConfirmed:
            deliveryConfirmedHandler?()
        case .outcome(let token, let outcome):
            pendingOutcomes.removeValue(forKey: token)?(outcome)
        case .closed(let reason):
            guard !ownerClosed else { return }
            ownerClosed = true
            pendingOutcomes.removeAll()
            dataHandler = nil
            deliveryConfirmedHandler = nil
            let notify = closeHandler
            closeHandler = nil
            notify?(reason)
        }
    }
}
