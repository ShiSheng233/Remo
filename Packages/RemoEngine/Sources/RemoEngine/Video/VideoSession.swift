import CoreMedia
import Foundation
import RemoCodec
import RemoTransport

/// A single stream per direction. Confine the session, callbacks and transport to one actor.
/// Forward application messages to receive; a false return leaves the message to the application.
///
/// A predicted frame is worth sending only for a moment, so it gets a short retry budget. A key
/// frame is what everything after it depends on, so it is retried until it arrives and nothing
/// else is encoded in the meantime.
final class VideoSession {
    enum Failure: Error { case closed, encoderUnavailable, encoderBusy }
    enum Event {
        case acknowledged(frame: UInt64, token: LongTermReferenceToken)
        case requestedRecovery(after: UInt64, firstAvailable: UInt64, request: VideoRecoveryRequest)
        case sentKeyFrame(frame: UInt64, bytes: Int)
        case settledKeyFrame(frame: UInt64, delivered: Bool)
        case encodedRefresh(frame: UInt64, reference: LongTermReferenceToken?)
        case decodedRefresh(frame: UInt64, idr: Bool)
    }

    /// Admits one message and returns its handle, if the link tracks messages.
    typealias Send = (
        Data, MessageTransport.Delivery, ((MessageTransport.Outcome) -> Void)?
    ) throws -> MessageTransport.MessageID?

    private var encoder: VideoEncoder?
    private let send: Send
    private let cancel: (MessageTransport.MessageID) -> Void
    private let onFrame: (UInt64, DecodedVideoFrame, Int) -> Void
    private let onEvent: (Event) -> Void
    private let onFailure: (Error) -> Void
    private var closed = false
    private var encoding = false
    private var nextID: UInt64 = 1
    private var sentEpoch: UInt64 = 0
    private var acknowledged: (frame: UInt64, token: LongTermReferenceToken)?
    private var newAcknowledgement = false
    private var refresh: VideoEncoder.Refresh = .none
    private var decoder: VideoDecoder?
    private var format: CMVideoFormatDescription?
    private var receivedEpoch: UInt64 = 0
    private var lastDecoded: UInt64 = 0
    private var lastRequest: UInt64?
    private var lastRequestTime = SuspendingClock.Instant.now
    private var recoveryRequests: UInt64 = 0
    private var requestedLevel: VideoRecoveryRequest.Level = .ltr
    private var receivedRecovery: VideoRecoveryRequest?
    private var confirmedDecodedFrame: UInt64 = 0
    /// The key frame still on its way. Frames encoded now would only depend on it.
    private var keyFrameInFlight: UInt64?
    /// The newest key frame the peer has in full. Its requests from before that are stale.
    private var deliveredEpoch: UInt64 = 0
    /// Recent frames that may still be queued, to withdraw when a refresh supersedes them.
    private var recentFrames: [MessageTransport.MessageID] = []
    private var pendingAck: Data?
    private var queue: [VideoFrameMessage] = []
    private var decoding = false

    init(
        encoder: VideoEncoder? = nil, send: @escaping Send,
        cancel: @escaping (MessageTransport.MessageID) -> Void = { _ in },
        onFrame: @escaping (UInt64, DecodedVideoFrame, Int) -> Void,
        onEvent: @escaping (Event) -> Void = { _ in }, onFailure: @escaping (Error) -> Void
    ) {
        self.encoder = encoder
        self.send = send
        self.cancel = cancel
        self.onFrame = onFrame
        self.onEvent = onEvent
        self.onFailure = onFailure
    }

    func close() {
        closed = true
        queue.removeAll()
        decoder = nil
        format = nil
        keyFrameInFlight = nil
        recentFrames.removeAll()
    }

    /// Re-encode the source independently on the next submission, including an unchanged desktop.
    func requestKeyFrame() {
        if !closed { refresh = .keyFrame }
    }

    /// Returns admitted video bytes, or zero while a key frame is still on its way to the peer.
    /// Encode one source frame at a time, in PTS order.
    nonisolated(nonsending) func sendFrame(
        _ pixels: CVPixelBuffer, presentationTime: CMTime,
        duration: CMTime, retryFor retryBudget: Duration = .milliseconds(80),
        sendWithin firstSendLimit: Duration? = nil
    ) async throws -> Int {
        guard !closed else { throw Failure.closed }
        guard let encoder else { throw Failure.encoderUnavailable }
        guard keyFrameInFlight == nil else { return 0 }
        guard !encoding else { throw Failure.encoderBusy }
        guard presentationTime.isNumeric, presentationTime.epoch == 0, duration.isNumeric,
            duration.epoch == 0, duration.value > 0
        else { throw VideoCodecError.invalidFrame }
        encoding = true
        defer { encoding = false }
        let request = refresh
        let tokens =
            newAcknowledgement || request == .recover ? acknowledged.map { [$0.token] } ?? [] : []
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
        let kind: VideoFrameMessage.Kind = sync ? .idr : request == .recover ? .ltrRefresh : .predicted
        if sync {
            sentEpoch = id
            acknowledged = nil
            newAcknowledgement = false
        }
        let packet = try VideoFrameMessage.serialize(sample, id: id, epoch: sentEpoch, kind: kind)
        if kind != .predicted {
            // Whatever is still queued belongs to the chain this frame replaces.
            recentFrames.forEach(cancel)
            recentFrames.removeAll()
        }
        let message: MessageTransport.MessageID?
        if sync {
            keyFrameInFlight = id
            do {
                message = try send(packet, .untilDelivered()) { [weak self] outcome in
                    self?.settleKeyFrame(id, delivered: outcome == .delivered)
                }
            } catch {
                // The encoder has moved on to this key frame, so the next frame must be one too.
                keyFrameInFlight = nil
                refresh = .keyFrame
                throw error
            }
            onEvent(.sentKeyFrame(frame: id, bytes: packet.count))
        } else {
            message = try send(
                packet, .retrying(for: retryBudget, sendWithin: firstSendLimit), nil)
        }
        if let message {
            recentFrames.append(message)
            if recentFrames.count > 8 { recentFrames.removeFirst() }
        }
        if request != .none {
            onEvent(.encodedRefresh(frame: id, reference: sync ? nil : tokens.first))
        }
        return packet.count
    }

    private func settleKeyFrame(_ id: UInt64, delivered: Bool) {
        guard !closed, keyFrameInFlight == id else { return }
        keyFrameInFlight = nil
        if delivered {
            deliveredEpoch = id
        } else {
            refresh = .keyFrame
        }
        onEvent(.settledKeyFrame(frame: id, delivered: delivered))
    }

    @discardableResult
    func receive(_ message: Data, isolation: isolated any Actor = #isolation) -> Bool {
        let type = message.first.flatMap(MessageKind.init(rawValue:)).flatMap { $0.isVideo ? $0 : nil }
        guard !closed else { return type != nil }
        do {
            guard let type else {
                // Other application traffic can drive recovery between video frames.
                if let lastRequest, SuspendingClock.Instant.now - lastRequestTime >= .seconds(1) {
                    try requestRecovery(lastRequest, allowLTR: decoder != nil, repeatRequest: true)
                }
                return false
            }
            var ready: VideoFrameMessage?
            switch type {
            case .videoFrame:
                ready = try VideoFrameMessage(message)
            case .videoAcknowledgement:
                var body = message.dropFirst()
                let epoch = try body.take(UInt64.self)
                let frame = try body.take(UInt64.self)
                let token = LongTermReferenceToken(rawValue: try body.take(Int64.self))
                guard body.isEmpty, epoch == sentEpoch, frame >= epoch,
                    frame > (acknowledged?.frame ?? 0), frame < nextID
                else {
                    return false
                }
                confirmedDecodedFrame = max(confirmedDecodedFrame, frame)
                acknowledged = (frame, token)
                newAcknowledgement = true
                onEvent(.acknowledged(frame: frame, token: token))
            case .videoRecoveryRequest:
                let request = try VideoRecoveryRequest(message)
                // A request from before the peer had the latest key frame asks for what it
                // has since been given.
                guard request.round > confirmedDecodedFrame, request.round <= nextID,
                    request.epoch >= deliveredEpoch, request.supersedes(receivedRecovery)
                else { return false }
                receivedRecovery = request
                guard keyFrameInFlight == nil else { return true }
                switch request.level {
                case .ltr where request.epoch == sentEpoch && acknowledged != nil:
                    if refresh != .keyFrame { refresh = .recover }
                case .ltr, .idr: refresh = .keyFrame
                }
            default: throw WireFormatError.invalid
            }
            if let packet = ready {
                guard packet.id > lastDecoded else { return true }
                // Bound pending decode work. A discarded dependency is detected by the ID gap.
                // A key frame goes last: the sender waited for it and won't offer it again.
                if queue.count == 4 {
                    let discard =
                        queue.firstIndex { $0.kind == .predicted }
                        ?? queue.firstIndex { $0.kind != .idr } ?? queue.startIndex
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
        try requestRecovery(
            lastRequest ?? lastDecoded, allowLTR: decoder != nil, repeatRequest: true)
    }

    private func requestRecovery(_ id: UInt64, allowLTR: Bool, repeatRequest: Bool = false) throws {
        // Retry on subsequent frame arrivals if a U refresh frame itself was lost.
        let now = SuspendingClock.Instant.now
        if let lastRequest {
            guard id > lastRequest || repeatRequest else { return }
            let elapsed = now - lastRequestTime
            if elapsed < .milliseconds(80) || (id - lastRequest < 8 && elapsed < .milliseconds(500)) {
                return
            }
            if recoveryRequests >= 3 && elapsed < .milliseconds(500) { return }
        }
        let attempt = recoveryRequests + 1
        if !allowLTR || attempt >= 3 { requestedLevel = .idr }
        // Every successful decode advances the identity of the next recovery round.
        let request = VideoRecoveryRequest(
            round: lastDecoded + 1, attempt: attempt, epoch: receivedEpoch, level: requestedLevel)
        lastRequest = id
        lastRequestTime = now
        do {
            _ = try send(
                request.encoded,
                .retrying(sendWithin: .milliseconds(250), replacing: .videoRecoveryRequest), nil)
        } catch NetworkMessageSession.SendError.backpressure {
            return
        }
        recoveryRequests = attempt
        onEvent(.requestedRecovery(after: lastDecoded, firstAvailable: id, request: request))
    }

    private nonisolated(nonsending) func decode(_ packet: VideoFrameMessage) async throws {
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
        recoveryRequests = 0
        requestedLevel = .ltr
        lastRequest = nil
        if let token = packet.token {
            var ack = MessageKind.videoAcknowledgement.encoded
            ack.put(packet.epoch)
            ack.put(packet.id)
            ack.put(token.rawValue)
            pendingAck = ack
        }
        if let pendingAck {
            do {
                _ = try send(pendingAck, .retrying(replacing: .videoAcknowledgement), nil)
                self.pendingAck = nil
            } catch NetworkMessageSession.SendError.backpressure {
                // Retry the latest usable reference on the next decoded frame.
            }
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
        case .requestedRecovery(let last, let available, let request):
            "recovery requested lastDecoded=\(last) nextAvailable=\(available)"
                + " round=\(request.round) attempt=\(request.attempt) level=\(request.level)"
        case .sentKeyFrame(let id, let bytes): "key frame=\(id) bytes=\(bytes) sent until delivered"
        case .settledKeyFrame(let id, let delivered):
            "key frame=\(id) \(delivered ? "delivered" : "abandoned")"
        case .encodedRefresh(let id, let reference):
            "recovery encoded frame=\(id) kind=\(reference.map { "LTR-P ackToken=\($0.rawValue)" } ?? "IDR")"
        case .decodedRefresh(let id, let idr):
            "recovery decoded frame=\(id) kind=\(idr ? "IDR" : "LTR-P")"
        }
    }
}
