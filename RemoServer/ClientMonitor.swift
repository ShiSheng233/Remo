//
//  Created by Cyandev on 11/22/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation
import Observation
import RemoEngine

/// One statistics report, with the counters that the server accumulates turned into changes
/// since the previous report.
struct StatisticsSample: Identifiable, Sendable {
    let id: Int
    let time: Date
    let statistics: ServerStatistics
    /// Seconds since the previous report, or zero for the first.
    let interval: Double
    let backpressureDrops: UInt64
    let codecDrops: UInt64
    let captureSkips: Int
    let keyFrameWaits: UInt64
    let audioSourceGaps: UInt64
    let audioBackpressureDrops: Int

    var link: LinkStatistics { statistics.link }
    var roundTripMilliseconds: Double? { statistics.link.roundTripTime.map(\.milliseconds) }
    var minimumRoundTripMilliseconds: Double? {
        statistics.link.minimumRoundTripTime.map(\.milliseconds)
    }
    var queueDelayMilliseconds: Double { statistics.link.queueDelay.milliseconds }
    /// Frames the server could not send during this interval, for any reason.
    var droppedFrames: UInt64 { backpressureDrops + codecDrops + UInt64(captureSkips) }
}

/// One `--wire-stats` line.
struct WireSample: Identifiable, Sendable {
    let id: Int
    let time: Date
    let megabitsPerSecond: Double
    let bytes: Int
    let dataPackets: Int
    let acks: Int
    let retries: Int
    /// Retransmissions since the previous line.
    let newRetries: Int

    /// Parses `UDP tx 4.812 Mbps  bytes=… DATA=… ACK=… retries=…`.
    static func parse(_ message: String) -> (mbps: Double, bytes: Int, data: Int, acks: Int, retries: Int)? {
        let tokens = message.split(separator: " ")
        guard tokens.count >= 4, tokens[0] == "UDP", tokens[1] == "tx",
            let mbps = Double(tokens[2])
        else { return nil }
        var fields: [Substring: Int] = [:]
        for token in tokens.dropFirst(4) {
            let pair = token.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let value = Int(pair[1]) { fields[pair[0]] = value }
        }
        guard let bytes = fields["bytes"], let data = fields["DATA"], let acks = fields["ACK"],
            let retries = fields["retries"]
        else { return nil }
        return (mbps, bytes, data, acks, retries)
    }
}

/// A client's session as the server sees it, with a rolling history of its reports.
@MainActor
@Observable
final class ClientMonitor: Identifiable {
    enum Status: Equatable {
        case connected
        case streaming
        case disconnected(reason: String, failed: Bool)

        var isActive: Bool {
            if case .disconnected = self { return false }
            return true
        }
    }

    /// Ten minutes at one report per second.
    static let historyLimit = 600

    let id = UUID()
    let peer: String
    let connectedAt = Date.now
    private(set) var status = Status.connected
    private(set) var session: RemoteScreenServer.SessionInfo?
    private(set) var streamingSince: Date?
    private(set) var disconnectedAt: Date?
    private(set) var samples: [StatisticsSample] = []
    private(set) var wireSamples: [WireSample] = []
    private var nextSampleID = 0

    init(peer: String) {
        self.peer = peer
    }

    var latest: StatisticsSample? { samples.last }
    var latestWire: WireSample? { wireSamples.last }

    func startStreaming(session: RemoteScreenServer.SessionInfo? = nil) {
        if let session { self.session = session }
        status = .streaming
        streamingSince = .now
    }

    func disconnect(reason: String, failed: Bool) {
        status = .disconnected(reason: reason, failed: failed)
        disconnectedAt = .now
    }

    func record(_ statistics: ServerStatistics) {
        let now = Date.now
        let previous = samples.last
        let sample = StatisticsSample(
            id: nextSampleID, time: now, statistics: statistics,
            interval: previous.map { now.timeIntervalSince($0.time) } ?? 0,
            backpressureDrops: Self.delta(statistics.backpressureDrops, previous?.statistics.backpressureDrops),
            codecDrops: Self.delta(statistics.codecDrops, previous?.statistics.codecDrops),
            captureSkips: Int(Self.delta(UInt64(statistics.captureSkips), previous.map { UInt64($0.statistics.captureSkips) })),
            keyFrameWaits: Self.delta(statistics.keyFrameWaits, previous?.statistics.keyFrameWaits),
            audioSourceGaps: Self.delta(statistics.audio?.sourceGaps ?? 0, previous?.statistics.audio?.sourceGaps),
            audioBackpressureDrops: Int(
                Self.delta(
                    UInt64(statistics.audio?.backpressureDrops ?? 0),
                    previous?.statistics.audio.map { UInt64($0.backpressureDrops) })))
        nextSampleID += 1
        samples.append(sample)
        if samples.count > Self.historyLimit { samples.removeFirst(samples.count - Self.historyLimit) }
        if status == .connected { startStreaming() }
    }

    func recordWire(_ message: String) {
        guard let parsed = WireSample.parse(message) else { return }
        let previousRetries = wireSamples.last?.retries ?? 0
        wireSamples.append(
            WireSample(
                id: nextSampleID, time: .now, megabitsPerSecond: parsed.mbps, bytes: parsed.bytes,
                dataPackets: parsed.data, acks: parsed.acks, retries: parsed.retries,
                newRetries: max(0, parsed.retries - previousRetries)))
        nextSampleID += 1
        if wireSamples.count > Self.historyLimit {
            wireSamples.removeFirst(wireSamples.count - Self.historyLimit)
        }
    }

    /// The change in a counter that only grows during a session.
    private static func delta<Value: BinaryInteger>(_ current: Value, _ previous: Value?) -> Value {
        guard let previous else { return 0 }
        return current >= previous ? current - previous : 0
    }
}

extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
