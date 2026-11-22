//
//  Created by Cyandev on 11/22/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation
import RemoEngine
import SwiftUI

/// How well a client's link is doing, judged from its most recent reports.
struct ConnectionHealth: Equatable {
    enum Level: Int, Comparable {
        case good, fair, poor, critical

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .good: "Healthy"
            case .fair: "Fair"
            case .poor: "Degraded"
            case .critical: "Critical"
            }
        }

        var symbol: String {
            switch self {
            case .good: "checkmark.circle.fill"
            case .fair: "exclamationmark.circle.fill"
            case .poor: "exclamationmark.triangle.fill"
            case .critical: "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .good: .green
            case .fair: .yellow
            case .poor: .orange
            case .critical: .red
            }
        }
    }

    struct Finding: Equatable, Identifiable {
        let level: Level
        let message: String
        var id: String { message }
    }

    let level: Level
    /// What lowered the level, worst first. Empty when healthy.
    let findings: [Finding]

    /// Thresholds for one metric: the value from which each level starts.
    struct Scale {
        let fair: Double, poor: Double, critical: Double

        func level(_ value: Double) -> Level {
            value >= critical ? .critical : value >= poor ? .poor : value >= fair ? .fair : .good
        }
    }

    static let lossScale = Scale(fair: 0.01, poor: 0.05, critical: 0.15)
    static let roundTripScale = Scale(fair: 60, poor: 120, critical: 250)
    static let queueDelayScale = Scale(fair: 25, poor: 80, critical: 200)

    /// Judges the last few seconds so one bad report does not swing the verdict.
    init(samples: some Collection<StatisticsSample>) {
        let recent = Array(samples.suffix(5))
        guard let latest = recent.last else {
            level = .good
            findings = []
            return
        }
        var findings: [Finding] = []
        func check(_ value: Double, _ scale: Scale, _ message: String) {
            let level = scale.level(value)
            if level > .good { findings.append(Finding(level: level, message: message)) }
        }
        let loss = recent.map(\.link.lossRatio).reduce(0, +) / Double(recent.count)
        check(loss, Self.lossScale, String(format: "Packet loss %.1f%%", loss * 100))
        let roundTrips = recent.compactMap(\.roundTripMilliseconds)
        if !roundTrips.isEmpty {
            let roundTrip = roundTrips.reduce(0, +) / Double(roundTrips.count)
            check(roundTrip, Self.roundTripScale, String(format: "Round trip %.0f ms", roundTrip))
        }
        let queue = recent.map(\.queueDelayMilliseconds).reduce(0, +) / Double(recent.count)
        check(queue, Self.queueDelayScale, String(format: "Send queue %.0f ms", queue))
        if let age = latest.statistics.newAckAge?.milliseconds, age >= 1000 {
            findings.append(
                Finding(
                    level: age >= 3000 ? .critical : .poor,
                    message: String(format: "No new acknowledgement for %.1f s", age / 1000)))
        }
        if latest.statistics.blocked {
            findings.append(Finding(level: .poor, message: "Transport blocked by the send window"))
        }
        let dropped = recent.map(\.droppedFrames).reduce(0, +)
        if dropped > 0 {
            findings.append(
                Finding(level: dropped > 10 ? .poor : .fair, message: "\(dropped) frames dropped in the last \(recent.count) s"))
        }
        if recent.contains(where: { $0.audioBackpressureDrops > 0 }) {
            findings.append(Finding(level: .fair, message: "Audio packets dropped under backpressure"))
        }
        findings.sort { $0.level > $1.level }
        self.findings = findings
        level = findings.first?.level ?? .good
    }
}
