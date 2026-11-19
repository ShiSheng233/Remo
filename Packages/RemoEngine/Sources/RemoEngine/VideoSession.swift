import CoreMedia
import Foundation
import RemoCodec
import RemoTransport

/// A single stream per direction. Confine the session, callbacks and transport to one actor.
/// Forward application messages to receive; a false return leaves the message to the application.
public final class VideoSession {
    public enum Failure: Error { case closed, encoderUnavailable, encoderBusy }
    public enum Event {
        case acknowledged(frame: UInt64, token: LongTermReferenceToken)
        case requestedRecovery(after: UInt64, firstAvailable: UInt64)
        case encodedRefresh(frame: UInt64, reference: LongTermReferenceToken?)
        case decodedRefresh(frame: UInt64, idr: Bool)
    }

    private let encoder: VideoEncoder?
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
    private var pendingAck: Data?
    private var queue: [VideoPacket] = []
    private var decoding = false

    public init(
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

    public func close() {
        closed = true
        queue.removeAll()
        decoder = nil
        format = nil
    }

    /// Returns admitted message bytes. Encode one source frame at a time, in PTS order.
    public nonisolated(nonsending) func sendFrame(
        _ pixels: CVPixelBuffer, presentationTime: CMTime,
        duration: CMTime, retryBudget: TimeInterval = 0.08, firstSendDeadline: TimeInterval? = nil
    ) async throws -> Int {
        guard !closed else { throw Failure.closed }
        guard let encoder else { throw Failure.encoderUnavailable }
        guard !encoding else { throw Failure.encoderBusy }
        guard presentationTime.isNumeric, presentationTime.epoch == 0, duration.isNumeric,
            duration.epoch == 0, duration.value > 0
        else { throw VideoCodecError.invalidFrame }
        encoding = true
        defer { encoding = false }
        let request = refresh
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
        try send(
            packet, .unreliable(retryBudget: retryBudget, firstSendDeadline: firstSendDeadline))
        if request != .none {
            onEvent(.encodedRefresh(frame: id, reference: sync ? nil : tokens.first))
        }
        return packet.count
    }

    @discardableResult
    public func receive(
        _ channel: MessageTransport.Channel, _ message: Data,
        isolation: isolated any Actor = #isolation
    ) -> Bool {
        guard let first = message.first, let type = VideoMessage(rawValue: first) else {
            return false
        }
        guard !closed else { return true }
        do {
            switch (channel, type) {
            case (.unreliable, .frame):
                let packet = try VideoPacket(message)
                guard packet.id > lastDecoded else { return true }
                // Bound pending decode work. A discarded dependency is detected by the ID gap.
                if queue.count == 4 { queue.removeFirst() }
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
                refresh =
                    epoch == sentEpoch && allowLTR == 1 && acknowledged != nil
                        && refresh != .keyFrame
                    ? .recover : .keyFrame
            default: throw PacketError.invalid
            }
        } catch {
            close()
            onFailure(error)
        }
        return true
    }

    private func requestRecovery(_ id: UInt64, allowLTR: Bool) throws {
        // Retry on subsequent frame arrivals if a U refresh frame itself was lost.
        if let lastRequest, id <= lastRequest || id - lastRequest < 8 { return }
        var request = Data([VideoMessage.refresh.rawValue])
        request.put(receivedEpoch)
        request.put(UInt8(allowLTR ? 1 : 0))
        lastRequest = id
        do { try send(request, .reliable) } catch NetworkMessageSession.SendError.backpressure {
            return
        }
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
            // Decoder state may be damaged. Only a fresh IDR is safe now.
            self.decoder = nil
            self.format = nil
            lastRequest = nil
            try requestRecovery(packet.id, allowLTR: false)
            return
        }
        guard !closed else { return }
        lastDecoded = packet.id
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
        if recovering { onEvent(.decodedRefresh(frame: packet.id, idr: packet.kind == .idr)) }
        onFrame(packet.id, frame, packet.bytes.count)
    }
}
