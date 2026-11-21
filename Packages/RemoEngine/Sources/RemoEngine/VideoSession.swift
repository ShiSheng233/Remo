import CoreMedia
import Foundation
import RemoCodec
import RemoTransport

/// A single stream per direction. Confine the session, callbacks and transport to one actor.
/// Forward application messages to receive; a false return leaves the message to the application.
final class VideoSession {
    enum Failure: Error { case closed, encoderUnavailable, encoderBusy }
    enum Event {
        case acknowledged(frame: UInt64, token: LongTermReferenceToken)
        case requestedRecovery(after: UInt64, firstAvailable: UInt64)
        case reliableKeyFrame(frame: UInt64, bytes: Int)
        case encodedRefresh(frame: UInt64, reference: LongTermReferenceToken?)
        case decodedRefresh(frame: UInt64, idr: Bool)
    }

    private var encoder: VideoEncoder?
    private let send: (Data, MessageTransport.Mode) throws -> Void
    private let onFrame: (UInt64, DecodedVideoFrame, Int) -> Void
    private let onEvent: (Event) -> Void
    private let onFailure: (Error) -> Void
    private var closed = false
    private var encoding = false
    private var nextID: UInt64 = 1
    private var sentEpoch: UInt64 = 0
    private var acknowledged: LongTermReferenceToken?
    private var newAcknowledgement = false
    private var refresh: VideoEncoder.Refresh = .none
    private var decoder: VideoDecoder?
    private var format: CMVideoFormatDescription?
    private var receivedEpoch: UInt64 = 0
    private var lastDecoded: UInt64 = 0
    private var lastRequest: UInt64?
    private var lastRequestTime: TimeInterval = 0
    private var recoveryRequests = 0
    private var wantsCheckpoint = false
    private var outgoing: RecoverySender?
    private var incoming: RecoveryReceiver?
    private var progress: Data?
    private var pendingAck: Data?
    private var queue: [VideoPacket] = []
    private var decoding = false

    init(
        encoder: VideoEncoder? = nil, send: @escaping (Data, MessageTransport.Mode) throws -> Void,
        onFrame: @escaping (UInt64, DecodedVideoFrame, Int) -> Void,
        onEvent: @escaping (Event) -> Void = { _ in }, onFailure: @escaping (Error) -> Void
    ) {
        self.encoder = encoder
        self.send = send
        self.onFrame = onFrame
        self.onEvent = onEvent
        self.onFailure = onFailure
    }

    func close() {
        closed = true
        queue.removeAll()
        decoder = nil
        format = nil
        outgoing = nil
        incoming = nil
        progress = nil
    }

    /// Re-encode the source independently on the next submission, including an unchanged desktop.
    func requestKeyFrame() {
        if !closed { refresh = .keyFrame }
    }

    /// Switch at a frame boundary. The next IDR carries the new configuration and starts a new epoch.
    /// Returns false while an encode or reliable checkpoint is in progress.
    func replaceEncoder(_ replacement: VideoEncoder) throws -> Bool {
        guard !closed else { throw Failure.closed }
        guard !encoding, outgoing == nil else { return false }
        encoder = replacement
        refresh = .keyFrame
        acknowledged = nil
        newAcknowledgement = false
        sentEpoch = 0
        return true
    }

    /// Returns admitted video bytes, or zero when waiting for a reliable IDR to be decoded.
    /// Encode one source frame at a time, in PTS order.
    nonisolated(nonsending) func sendFrame(
        _ pixels: CVPixelBuffer, presentationTime: CMTime,
        duration: CMTime, retryBudget: TimeInterval = 0.08, firstSendDeadline: TimeInterval? = nil
    ) async throws -> Int {
        guard !closed else { throw Failure.closed }
        guard let encoder else { throw Failure.encoderUnavailable }
        if let outgoing {
            try outgoing.pump(send: send)
            return 0
        }
        guard !encoding else { throw Failure.encoderBusy }
        guard presentationTime.isNumeric, presentationTime.epoch == 0, duration.isNumeric,
            duration.epoch == 0, duration.value > 0
        else { throw VideoCodecError.invalidFrame }
        encoding = true
        defer { encoding = false }
        let checkpoint = wantsCheckpoint
        let request: VideoEncoder.Refresh = checkpoint ? .keyFrame : refresh
        let tokens =
            newAcknowledgement || request == .recover ? acknowledged.map { [$0] } ?? [] : []
        refresh = .none
        newAcknowledgement = false
        let sample: CMSampleBuffer
        do {
            sample = try await encoder.encode(
                pixels, presentationTime: presentationTime, duration: duration,
                refresh: request, acknowledgedReferences: tokens)
        } catch {
            if refresh == .none { refresh = request }
            if !tokens.isEmpty { newAcknowledgement = true }
            throw error
        }
        guard !closed else { throw Failure.closed }
        let id = nextID
        nextID += 1
        let attachments =
            CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[String: Any]]
        let sync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
        let kind: VideoPacket.Kind = sync ? .idr : request == .recover ? .ltrRefresh : .predicted
        if sync {
            sentEpoch = id
            acknowledged = nil
            newAcknowledgement = false
        }
        let packet = try VideoPacket.serialize(sample, id: id, epoch: sentEpoch, kind: kind)
        if checkpoint {
            guard sync else { throw PacketError.invalid }
            let transfer = try RecoverySender(id: id, bytes: packet)
            outgoing = transfer
            wantsCheckpoint = false
            onEvent(.reliableKeyFrame(frame: id, bytes: packet.count))
            try transfer.pump(send: send)
        } else {
            try send(
                packet, .unreliable(retryBudget: retryBudget, firstSendDeadline: firstSendDeadline))
        }
        if request != .none {
            onEvent(.encodedRefresh(frame: id, reference: sync ? nil : tokens.first))
        }
        return packet.count
    }

    @discardableResult
    func receive(
        _ channel: MessageTransport.Channel, _ message: Data,
        isolation: isolated any Actor = #isolation
    ) -> Bool {
        let type = message.first.flatMap(VideoMessage.init(rawValue:))
        guard !closed else { return type != nil }
        do {
            try flushProgress()
            try outgoing?.pump(send: send)
            guard let type else {
                // An active screen session also receives periodic application controls when
                // every U frame, including a refresh, is lost before reassembly.
                if let lastRequest, incoming == nil,
                    ProcessInfo.processInfo.systemUptime - lastRequestTime >= 1
                {
                    try requestRecovery(lastRequest, allowLTR: decoder != nil, repeatRequest: true)
                }
                return false
            }
            var ready: VideoPacket?
            switch (channel, type) {
            case (.unreliable, .frame):
                let packet = try VideoPacket(message)
                if incoming == nil { ready = packet }
            case (.reliable, .acknowledgement):
                var body = message.dropFirst()
                let epoch = try body.take(UInt64.self)
                let frame = try body.take(UInt64.self)
                let token = LongTermReferenceToken(rawValue: try body.take(Int64.self))
                guard body.isEmpty, epoch == sentEpoch, frame >= epoch, frame < nextID else {
                    return true
                }
                acknowledged = token
                newAcknowledgement = true
                onEvent(.acknowledged(frame: frame, token: token))
            case (.reliable, .refresh):
                var body = message.dropFirst()
                let epoch = try body.take(UInt64.self)
                let allowLTR = try body.take(UInt8.self)
                guard body.isEmpty, allowLTR <= 1 else { throw PacketError.invalid }
                guard outgoing == nil && !wantsCheckpoint else { return true }
                refresh =
                    epoch == sentEpoch && allowLTR == 1 && acknowledged != nil
                        && refresh != .keyFrame
                    ? .recover : .keyFrame
            case (.reliable, .keyFrameRequest):
                guard message.count == 1 else { throw PacketError.invalid }
                if outgoing == nil { wantsCheckpoint = true }
            case (.reliable, .keyFrameProgress):
                var body = message.dropFirst()
                let id = try body.take(UInt64.self)
                let offset = Int(try body.take(UInt32.self))
                guard body.isEmpty else { throw PacketError.invalid }
                if let outgoing, outgoing.id == id {
                    if try outgoing.advance(to: offset) {
                        self.outgoing = nil
                    } else {
                        try outgoing.pump(send: send)
                    }
                }
            case (.reliable, .keyFrameChunk):
                var body = message.dropFirst()
                let id = try body.take(UInt64.self)
                let total = Int(try body.take(UInt32.self))
                let offset = Int(try body.take(UInt32.self))
                guard (1...RecoveryReceiver.limit).contains(total) else {
                    throw PacketError.invalid
                }
                if offset == 0 {
                    guard incoming == nil else { throw PacketError.invalid }
                    incoming = RecoveryReceiver(id: id, total: total)
                    queue.removeAll()
                }
                guard incoming?.id == id, incoming?.total == total else {
                    throw PacketError.invalid
                }
                try incoming!.append(body, offset: offset)
                let count = offset + body.count
                if count == total {
                    let packet = try VideoPacket(incoming!.bytes)
                    guard packet.kind == .idr, packet.id == id, id > lastDecoded else {
                        throw PacketError.invalid
                    }
                    ready = packet
                } else {
                    try acknowledgeProgress(id, count)
                }
            default: throw PacketError.invalid
            }
            if let packet = ready {
                guard packet.id > lastDecoded else { return true }
                // Bound pending decode work. A discarded dependency is detected by the ID gap.
                if queue.count == 4 {
                    let discard = queue.firstIndex { $0.kind == .predicted } ?? queue.startIndex
                    queue.remove(at: discard)
                }
                queue.append(packet)
                if !decoding {
                    decoding = true
                    Task {
                        isolation.preconditionIsolated()
                        defer { self.decoding = false }
                        while !self.closed && !self.queue.isEmpty {
                            let packet = self.queue.removeFirst()
                            do { try await self.decode(packet) } catch {
                                self.close()
                                self.onFailure(error)
                            }
                        }
                    }
                }
            }
        } catch {
            close()
            onFailure(error)
        }
        return true
    }

    /// Call when the application expects video but even the tail frame may have been lost.
    /// Repeated calls share the same retry timer and escalation as observed frame gaps.
    func requestRefresh() throws {
        guard !closed else { throw Failure.closed }
        guard incoming == nil else { return }
        try requestRecovery(
            lastRequest ?? lastDecoded, allowLTR: decoder != nil, repeatRequest: true)
    }

    private func acknowledgeProgress(_ id: UInt64, _ offset: Int) throws {
        var message = Data([VideoMessage.keyFrameProgress.rawValue])
        message.put(id)
        message.put(UInt32(offset))
        progress = message
        try flushProgress()
    }

    private func flushProgress() throws {
        guard let message = progress else { return }
        progress = nil
        do { try send(message, .reliable) } catch NetworkMessageSession.SendError.backpressure {
            progress = message
        }
    }

    private func requestRecovery(_ id: UInt64, allowLTR: Bool, repeatRequest: Bool = false) throws {
        // Retry on subsequent frame arrivals if a U refresh frame itself was lost.
        let now = ProcessInfo.processInfo.systemUptime
        if let lastRequest {
            guard id > lastRequest || repeatRequest else { return }
            let elapsed = now - lastRequestTime
            if elapsed < 0.08 || (id - lastRequest < 8 && elapsed < 0.5) { return }
            if recoveryRequests >= 3 && elapsed < 0.5 { return }
        }
        var request = Data([VideoMessage.refresh.rawValue])
        request.put(receivedEpoch)
        // Repeated unanswered LTR refreshes must not leave the receiver on the same chain forever.
        request.put(UInt8(allowLTR && recoveryRequests < 2 ? 1 : 0))
        lastRequest = id
        lastRequestTime = now
        do {
            // Older peers ignore the extension and still handle the ordinary refresh request.
            if recoveryRequests >= 2 {
                try send(Data([VideoMessage.keyFrameRequest.rawValue]), .reliable)
            }
            try send(request, .reliable)
        } catch NetworkMessageSession.SendError.backpressure {
            return
        }
        recoveryRequests += 1
        onEvent(.requestedRecovery(after: lastDecoded, firstAvailable: id))
    }

    private nonisolated(nonsending) func decode(_ packet: VideoPacket) async throws {
        guard packet.id > lastDecoded else { return }
        let recovering = lastRequest != nil || (lastDecoded != 0 && packet.id != lastDecoded + 1)
        if let description = packet.format {
            pendingAck = nil
            decoder = try VideoDecoder(format: description)
            format = description
            receivedEpoch = packet.epoch
        }
        guard let decoder, let format, packet.epoch == receivedEpoch else {
            try requestRecovery(packet.id, allowLTR: false)
            return
        }
        guard !recovering || packet.kind != .predicted else {
            try requestRecovery(packet.id, allowLTR: true)
            return
        }
        let frame: DecodedVideoFrame
        do { frame = try await decoder.decode(packet.sample(format: format)) } catch {
            guard !closed else { return }
            if incoming?.id == packet.id { throw error }
            // Decoder state may be damaged. Only a fresh IDR is safe now.
            self.decoder = nil
            self.format = nil
            lastRequest = nil
            try requestRecovery(packet.id, allowLTR: false)
            return
        }
        guard !closed else { return }
        lastDecoded = packet.id
        recoveryRequests = 0
        lastRequest = nil
        if let token = packet.token {
            var ack = Data([VideoMessage.acknowledgement.rawValue])
            ack.put(packet.epoch)
            ack.put(packet.id)
            ack.put(token.rawValue)
            pendingAck = ack
        }
        if let pendingAck {
            do {
                try send(pendingAck, .reliable)
                self.pendingAck = nil
            } catch NetworkMessageSession.SendError.backpressure {
                // Retry the latest usable reference on the next decoded frame.
            }
        }
        if let transfer = incoming, transfer.id == packet.id {
            incoming = nil
            try acknowledgeProgress(transfer.id, transfer.total)
        }
        if recovering { onEvent(.decodedRefresh(frame: packet.id, idr: packet.kind == .idr)) }
        onFrame(packet.id, frame, packet.bytes.count)
    }
}

extension VideoSession.Event {
    /// A diagnostic line for recovery activity. Acknowledgements are too frequent to describe.
    var diagnostic: String? {
        switch self {
        case .acknowledged: nil
        case .requestedRecovery(let last, let available):
            "recovery requested lastDecoded=\(last) nextAvailable=\(available)"
        case .reliableKeyFrame(let id, let bytes): "reliable IDR frame=\(id) bytes=\(bytes)"
        case .encodedRefresh(let id, let reference):
            "recovery encoded frame=\(id) kind=\(reference.map { "LTR-P ackToken=\($0.rawValue)" } ?? "IDR")"
        case .decodedRefresh(let id, let idr):
            "recovery decoded frame=\(id) kind=\(idr ? "IDR" : "LTR-P")"
        }
    }
}
