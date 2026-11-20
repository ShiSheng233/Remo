//
//  Created by Cyandev on 11/21/26.
//

import Dispatch
import Foundation
import Network
import RemoTransport

nonisolated final class WireGuardDatagramConnection: DatagramConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let tunnel: OpaquePointer
    private let queue = DispatchQueue(label: "Remo.WireGuard", qos: .userInitiated)

    // Accessed only on queue.
    private var events: AsyncStream<ConnectionEvent>.Continuation?
    private var timer: (any DispatchSourceTimer)?
    private var networkReady = false
    private var tunnelReady = false
    private var receiving = false
    private var wantsDatagram = false

    init(_ configuration: WireGuardConfiguration) {
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
            self.connection.stateUpdateHandler = { [weak self] in self?.update($0) }
            self.connection.start(queue: self.queue)
        }
    }

    func receive() {
        queue.async {
            self.wantsDatagram = true
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
            self.events = nil
            self.timer?.cancel()
            self.timer = nil
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
        guard events != nil, networkReady, !receiving, !tunnelReady || wantsDatagram else { return }
        receiving = true
        connection.receiveMessage { [weak self] data, context, complete, error in
            guard let self, let events = self.events else { return }
            self.receiving = false
            if let error {
                events.yield(.failed(error))
                return
            }
            if complete, let data, !data.isEmpty {
                self.process(data)
            }
            if complete, context?.isFinal == true {
                events.yield(.received(nil, final: true))
                return
            }
            self.receiveIfNeeded()
        }
    }

    private func process(_ data: Data) {
        let result = data.withUnsafeBytes { bytes in
            remo_wg_receive(tunnel, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        if result.operation == RemoWireGuardDeliver, wantsDatagram, let bytes = result.bytes {
            wantsDatagram = false
            events?.yield(.received(Data(bytes: bytes, count: result.length)))
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
