//
//  Created by Cyandev on 11/21/26.
//

import Dispatch
import Foundation
import Network
import RemoTransport

nonisolated final class WireGuardDatagramConnection: DatagramConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let log: SessionLog?
    private let tunnel: OpaquePointer
    private let queue = DispatchQueue(label: "Remo.WireGuard", qos: .userInitiated)

    private static let maxPendingInbound = 128

    // Accessed only on queue.
    private var events: AsyncStream<ConnectionEvent>.Continuation?
    private var timer: (any DispatchSourceTimer)?
    private var networkReady = false
    private var tunnelReady = false
    private var receiving = false
    private var wantsDatagram = false
    private var pendingInbound: [Data] = []
    private var pendingHead = 0
    private var pendingCount: Int { pendingInbound.count - pendingHead }

    private var reportTimer: (any DispatchSourceTimer)?
    private var outerRx = 0
    private var deliveredRx = 0
    private var lastSuccessfulDataIndex: UInt32?
    private var loggedMissingSession = false
    private var receiveReasons: [String: Int] = [:]

    init(_ configuration: WireGuardConfiguration, log: SessionLog?) {
        self.log = log
        connection = NWConnection(to: configuration.endpoint, using: .udp)
        let peer = configuration.peerPublicKey
        let local = Array(configuration.localAddress.rawValue)
        let remote = Array(configuration.remoteAddress.rawValue)
        let localPort = UInt16.random(in: 49152...65535)
        let index = UInt32.random(in: 0...0x00ff_ffff)
        tunnel = configuration.presharedKey.withUnsafeBufferPointer { psk in
            remo_wg_new(
                configuration.privateKey, peer, psk.isEmpty ? nil : psk.baseAddress, local, remote,
                localPort, configuration.remotePort, index)
        }
    }

    deinit { remo_wg_free(tunnel) }

    func start(events: AsyncStream<ConnectionEvent>.Continuation) {
        queue.async { [self] in
            self.events = events
            if let log {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    var line = "WireGuard outerUdpRx=\(self.outerRx) remoDatagramsRx=\(self.deliveredRx)"
                    if let index = self.lastSuccessfulDataIndex {
                        line += String(format: " lastSuccessfulDataReceiverIndex=0x%08X", index)
                    }
                    for (reason, count) in self.receiveReasons.sorted(by: { $0.key < $1.key }) {
                        line += " \(reason)=\(count)"
                    }
                    log.write(line)
                    self.receiveReasons.removeAll(keepingCapacity: true)
                    self.outerRx = 0
                    self.deliveredRx = 0
                }
                reportTimer = timer
                timer.activate()
            }
            self.connection.stateUpdateHandler = { [weak self] in self?.update($0) }
            self.connection.start(queue: self.queue)
        }
    }

    func receive() {
        queue.async {
            self.wantsDatagram = true
            self.deliverIfReady()
            self.receiveIfNeeded()
        }
    }

    func send(_ datagram: Data) {
        queue.async {
            guard let events = self.events else { return }
            let result = datagram.withUnsafeBytes { bytes in
                remo_wg_send(self.tunnel, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
            if result.operation == RemoWireGuardSend, let bytes = result.bytes {
                self.sendOuter(Data(bytes: bytes, count: result.length), processed: datagram.count)
            } else {
                // BoringTun can hold datagrams in its bounded queue while renewing a session.
                events.yield(.processed(datagram.count))
            }
        }
    }

    func cancel() {
        queue.async {
            self.reportTimer?.cancel()
            self.reportTimer = nil
            self.events = nil
            self.timer?.cancel()
            self.timer = nil
            self.pendingInbound.removeAll()
            self.pendingHead = 0
            self.connection.cancel()
        }
    }

    private func update(_ state: NWConnection.State) {
        guard let events else { return }
        if case .ready = state {
            networkReady = true
            if timer == nil {
                sendControl(remo_wg_handshake(tunnel))
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(
                    deadline: .now() + .milliseconds(250), repeating: .milliseconds(250),
                    leeway: .milliseconds(50))
                timer.setEventHandler { [weak self] in
                    guard let self, self.networkReady else { return }
                    self.sendControl(remo_wg_tick(self.tunnel))
                }
                self.timer = timer
                timer.activate()
            }
            receiveIfNeeded()
        } else {
            networkReady = false
            events.yield(.state(state))
        }
    }

    private func receiveIfNeeded() {
        // Keep draining outer UDP datagrams continuously (up to a bounded queue) so WireGuard
        // handshakes, rekeys, keepalives and incoming bursts never stall waiting on the consumer.
        guard events != nil, networkReady, !receiving, pendingCount < Self.maxPendingInbound else {
            return
        }
        receiving = true
        connection.receiveMessage { [weak self] data, context, complete, error in
            guard let self, let events = self.events else { return }
            self.receiving = false
            if let error {
                events.yield(.failed(error))
                return
            }
            if complete, let data {
                self.outerRx += 1
                if data.isEmpty {
                    self.receiveReasons["outerEmpty", default: 0] += 1
                } else {
                    self.process(data)
                }
            }
            if complete, context?.isFinal == true {
                events.yield(.received(nil, final: true))
                return
            }
            self.receiveIfNeeded()
        }
    }

    private func deliverIfReady() {
        guard wantsDatagram, pendingHead < pendingInbound.count else { return }
        let datagram = pendingInbound[pendingHead]
        pendingHead += 1
        if pendingHead == pendingInbound.count {
            pendingInbound.removeAll(keepingCapacity: true)
            pendingHead = 0
        } else if pendingHead >= 64 {
            pendingInbound.removeFirst(pendingHead)
            pendingHead = 0
        }
        wantsDatagram = false
        if case .enqueued = events?.yield(.received(datagram)) {
            deliveredRx += 1
        } else {
            receiveReasons["deliveryNotEnqueued", default: 0] += 1
        }
    }

    private func process(_ data: Data) {
        let result = data.withUnsafeBytes { bytes in
            remo_wg_receive(tunnel, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        switch result.index_event {
        case RemoWireGuardSessionEstablished:
            log?.write(String(format: "WireGuard session established localReceiverIndex=0x%08X", result.local_receiver_index))
        case RemoWireGuardDataAccepted:
            lastSuccessfulDataIndex = result.local_receiver_index
        case RemoWireGuardMissingSession where !loggedMissingSession:
            loggedMissingSession = true
            let previous = lastSuccessfulDataIndex.map { String(format: "0x%08X", $0) } ?? "none"
            log?.write(String(format: "WireGuard first NoCurrentSession receiverIndex=0x%08X", result.local_receiver_index)
                + " lastSuccessfulDataReceiverIndex=\(previous)")
        default: break
        }
        if let reason = result.receive_reason {
            receiveReasons[String(cString: reason), default: 0] += 1
        }
        if result.operation == RemoWireGuardDeliver, let bytes = result.bytes {
            let datagram = Data(bytes: bytes, count: result.length)
            if wantsDatagram {
                wantsDatagram = false
                if case .enqueued = events?.yield(.received(datagram)) {
                    deliveredRx += 1
                } else {
                    receiveReasons["deliveryNotEnqueued", default: 0] += 1
                }
            } else if pendingCount < Self.maxPendingInbound {
                pendingInbound.append(datagram)
            } else {
                receiveReasons["inboundQueueFull", default: 0] += 1
            }
        } else if result.operation == RemoWireGuardSend {
            sendControl(result)
            var queued = remo_wg_receive(tunnel, nil, 0)
            while queued.operation == RemoWireGuardSend {
                sendControl(queued)
                queued = remo_wg_receive(tunnel, nil, 0)
            }
        }
        if !tunnelReady, remo_wg_is_ready(tunnel) {
            tunnelReady = true
            events?.yield(.state(.ready))
        }
    }

    private func sendControl(_ result: RemoWireGuardResult) {
        guard result.operation == RemoWireGuardSend, let bytes = result.bytes else { return }
        sendOuter(Data(bytes: bytes, count: result.length), processed: nil)
    }

    private func sendOuter(_ data: Data, processed: Int?) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let events = self?.events else { return }
            if let error {
                events.yield(.failed(error))
            } else if let processed {
                events.yield(.processed(processed))
            }
        })
    }
}
