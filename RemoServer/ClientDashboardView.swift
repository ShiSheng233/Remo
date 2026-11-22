//
//  Created by Cyandev on 11/22/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Charts
import RemoEngine
import SwiftUI

/// How much history the charts show.
enum ChartWindow: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600

    var id: Self { self }

    var title: String {
        switch self {
        case .oneMinute: "1 min"
        case .fiveMinutes: "5 min"
        case .tenMinutes: "10 min"
        }
    }
}

/// Everything known about one client's session: a health verdict, the headline numbers and
/// their history.
struct ClientDashboardView: View {
    let client: ClientMonitor
    /// The settings the session runs with, for drawing the configured limits.
    let settings: ServerSettings?

    @AppStorage("ChartWindow") private var window = ChartWindow.oneMinute

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if client.samples.isEmpty {
                    DashboardCard {
                        Label(
                            client.status.isActive
                                ? "Waiting for the first statistics report…"
                                : "This client disconnected before reporting statistics.",
                            systemImage: "hourglass"
                        )
                        .foregroundStyle(.secondary)
                    }
                } else {
                    content
                }
            }
            .padding(20)
        }
        .navigationTitle(client.peer)
        .toolbar {
            ToolbarItem {
                Picker("History", selection: $window) {
                    ForEach(ChartWindow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("How much history the charts show")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(client.peer)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    ClientStatusLabel(status: client.status)
                    Text("·").foregroundStyle(.tertiary)
                    sessionDuration
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var sessionDuration: some View {
        if let end = client.disconnectedAt {
            Text("Session lasted \(Duration.seconds(end.timeIntervalSince(client.connectedAt)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))")
        } else {
            Text("Connected \(client.connectedAt, style: .relative) ago")
        }
    }

    // MARK: - Content

    private var visibleSamples: [StatisticsSample] {
        guard let end = client.samples.last?.time else { return [] }
        let start = end.addingTimeInterval(-Double(window.rawValue))
        return client.samples.filter { $0.time >= start }
    }

    private var domain: ClosedRange<Date> {
        let end = client.samples.last?.time ?? .now
        return end.addingTimeInterval(-Double(window.rawValue))...end
    }

    @ViewBuilder
    private var content: some View {
        let samples = visibleSamples
        let latest = client.samples.last!
        HealthCard(health: ConnectionHealth(samples: client.samples))
        metricTiles(latest)
        section("Link") {
            chartGrid {
                throughputChart(samples)
                latencyChart(samples)
                lossChart(samples)
                frameRateChart(samples)
            }
        }
        section("Video pipeline") {
            chartGrid {
                droppedFramesChart(samples)
                redundancyChart(samples)
            }
        }
        if !client.wireSamples.isEmpty {
            section("UDP (--wire-stats)") {
                chartGrid { wireCharts }
            }
        }
        if let audio = latest.statistics.audio {
            section("Audio") {
                audioTiles(audio, latest)
                chartGrid { audioQueueChart(samples) }
            }
        }
        section("Totals") {
            CountersTable(statistics: latest.statistics)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.top, 6)
            content()
        }
    }

    private func chartGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)], spacing: 14) {
            content()
        }
    }

    // MARK: Tiles

    private func metricTiles(_ latest: StatisticsSample) -> some View {
        let statistics = latest.statistics
        let link = statistics.link
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            MetricTile(
                title: "Round trip",
                value: link.roundTripTime.map { Format.milliseconds($0.milliseconds) } ?? "—",
                detail: link.minimumRoundTripTime.map { "min \(Format.milliseconds($0.milliseconds))" },
                level: latest.roundTripMilliseconds.map { ConnectionHealth.roundTripScale.level($0) })
            MetricTile(
                title: "Packet loss", value: Format.percent(link.lossRatio),
                detail: "link \(Format.percent(link.linkLossRatio))",
                level: ConnectionHealth.lossScale.level(link.lossRatio))
            MetricTile(
                title: "Send queue", value: Format.milliseconds(latest.queueDelayMilliseconds),
                detail: statistics.blocked ? "blocked" : statistics.probing ? "probing" : nil,
                level: ConnectionHealth.queueDelayScale.level(latest.queueDelayMilliseconds))
            MetricTile(
                title: "Video", value: Format.megabits(statistics.videoBitsPerSecond),
                detail: "encoder \(Format.megabits(Double(statistics.encoderBitRate)))")
            MetricTile(
                title: "Send budget", value: Format.megabits(link.bitsPerSecond),
                detail: "estimated link rate")
            MetricTile(
                title: "Frame rate", value: Format.fps(statistics.framesPerSecond),
                detail: settings.map { "up to \($0.framesPerSecond) fps" })
            MetricTile(
                title: "Repair", value: Format.percent(statistics.videoRedundancy, digits: 0),
                detail: "of predicted frames")
            MetricTile(
                title: "Last new ACK",
                value: statistics.newAckAge.map { Format.milliseconds($0.milliseconds) } ?? "—",
                detail: "\(statistics.dataPacketsAccepted) DATA last report",
                level: statistics.newAckAge.map {
                    $0.milliseconds >= 3000 ? .critical : $0.milliseconds >= 1000 ? .poor : .good
                })
        }
    }

    private func audioTiles(_ audio: ServerStatistics.Audio, _ latest: StatisticsSample) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            MetricTile(title: "Packets queued", value: audio.packetsQueued.formatted(), detail: nil)
            MetricTile(
                title: "Source gaps", value: audio.sourceGaps.formatted(),
                detail: "+\(latest.audioSourceGaps) last report",
                level: latest.audioSourceGaps > 0 ? .fair : .good)
            MetricTile(
                title: "Backpressure drops", value: audio.backpressureDrops.formatted(),
                detail: "+\(latest.audioBackpressureDrops) last report",
                level: latest.audioBackpressureDrops > 0 ? .fair : .good)
            MetricTile(
                title: "Expired before send",
                value: latest.link.audioExpiredBeforeFirstSend.formatted(), detail: nil)
        }
    }

    // MARK: Charts

    private func points(_ samples: [StatisticsSample], _ value: (StatisticsSample) -> Double?) -> [ChartPoint] {
        samples.compactMap { sample in value(sample).map { ChartPoint(time: sample.time, value: $0) } }
    }

    private func throughputChart(_ samples: [StatisticsSample]) -> some View {
        TimeSeriesChart(
            title: "Throughput",
            series: [
                ChartSeries(name: "Video sent", color: ChartPalette.blue, points: points(samples) { $0.statistics.videoBitsPerSecond / 1e6 }),
                ChartSeries(name: "Encoder target", color: ChartPalette.orange, points: points(samples) { Double($0.statistics.encoderBitRate) / 1e6 }),
                ChartSeries(name: "Send budget", color: ChartPalette.aqua, points: points(samples) { $0.link.bitsPerSecond / 1e6 }),
            ],
            domain: domain, format: { Format.megabits($0 * 1e6) },
            reference: settings.map { ChartReference(label: "Max \(Format.megabits(Double($0.maximumVideoBitRate)))", value: Double($0.maximumVideoBitRate) / 1e6) },
            minimumUpperBound: 1)
    }

    private func latencyChart(_ samples: [StatisticsSample]) -> some View {
        TimeSeriesChart(
            title: "Latency",
            series: [
                ChartSeries(name: "Round trip", color: ChartPalette.blue, points: points(samples, \.roundTripMilliseconds)),
                ChartSeries(name: "Min round trip", color: ChartPalette.orange, points: points(samples, \.minimumRoundTripMilliseconds)),
                ChartSeries(name: "Send queue", color: ChartPalette.aqua, points: points(samples) { $0.queueDelayMilliseconds }),
            ],
            domain: domain, format: Format.milliseconds, minimumUpperBound: 20)
    }

    private func lossChart(_ samples: [StatisticsSample]) -> some View {
        TimeSeriesChart(
            title: "Packet loss",
            series: [
                ChartSeries(name: "Total", color: ChartPalette.blue, points: points(samples) { $0.link.lossRatio * 100 }),
                ChartSeries(name: "Link (not from congestion)", color: ChartPalette.orange, points: points(samples) { $0.link.linkLossRatio * 100 }),
            ],
            domain: domain, format: { Format.percent($0 / 100) }, style: .area,
            reference: ChartReference(label: "Degraded", value: ConnectionHealth.lossScale.poor * 100),
            minimumUpperBound: 2)
    }

    private func frameRateChart(_ samples: [StatisticsSample]) -> some View {
        TimeSeriesChart(
            title: "Frame rate",
            series: [
                ChartSeries(name: "Frames sent", color: ChartPalette.blue, points: points(samples) { $0.statistics.framesPerSecond })
            ],
            domain: domain, format: Format.fps,
            reference: settings.map { ChartReference(label: "Target \($0.framesPerSecond) fps", value: Double($0.framesPerSecond)) },
            minimumUpperBound: 10)
    }

    private func droppedFramesChart(_ samples: [StatisticsSample]) -> some View {
        TimeSeriesChart(
            title: "Frames not sent",
            series: [
                ChartSeries(name: "Backpressure", color: ChartPalette.blue, points: points(samples) { Double($0.backpressureDrops) }),
                ChartSeries(name: "Capture skips", color: ChartPalette.orange, points: points(samples) { Double($0.captureSkips) }),
                ChartSeries(name: "Key-frame waits & codec drops", color: ChartPalette.aqua, points: points(samples) { Double($0.keyFrameWaits + $0.codecDrops) }),
            ],
            domain: domain, format: Format.count, style: .bars, minimumUpperBound: 5)
    }

    private func redundancyChart(_ samples: [StatisticsSample]) -> some View {
        TimeSeriesChart(
            title: "Repair redundancy",
            series: [
                ChartSeries(name: "FEC", color: ChartPalette.violet, points: points(samples) { $0.statistics.videoRedundancy * 100 })
            ],
            domain: domain, format: { Format.percent($0 / 100, digits: 0) }, style: .area,
            minimumUpperBound: 10)
    }

    @ViewBuilder
    private var wireCharts: some View {
        let start = domain.lowerBound
        let wire = client.wireSamples.filter { $0.time >= start }
        TimeSeriesChart(
            title: "UDP sent",
            series: [
                ChartSeries(name: "UDP", color: ChartPalette.blue, points: wire.map { ChartPoint(time: $0.time, value: $0.megabitsPerSecond) })
            ],
            domain: domain, format: { Format.megabits($0 * 1e6) }, minimumUpperBound: 1)
        TimeSeriesChart(
            title: "Retransmissions",
            series: [
                ChartSeries(name: "Retries", color: ChartPalette.orange, points: wire.map { ChartPoint(time: $0.time, value: Double($0.newRetries)) })
            ],
            domain: domain, format: Format.count, style: .bars, minimumUpperBound: 5)
    }

    private func audioQueueChart(_ samples: [StatisticsSample]) -> some View {
        TimeSeriesChart(
            title: "Audio peak queue delay",
            series: [
                ChartSeries(name: "Peak queue", color: ChartPalette.blue, points: points(samples) { $0.statistics.audio?.peakQueueDelay.milliseconds })
            ],
            domain: domain, format: Format.milliseconds, minimumUpperBound: 20)
    }
}

// MARK: - Pieces

struct ClientStatusLabel: View {
    let status: ClientMonitor.Status

    var body: some View {
        switch status {
        case .connected:
            Label("Connected", systemImage: "circle.dotted").foregroundStyle(.secondary)
        case .streaming:
            Label("Streaming", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.secondary)
        case .disconnected(let reason, let failed):
            Label(
                "Disconnected: \(reason)",
                systemImage: failed ? "exclamationmark.triangle" : "xmark.circle"
            )
            .foregroundStyle(.secondary)
        }
    }
}

struct HealthCard: View {
    let health: ConnectionHealth

    var body: some View {
        DashboardCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: health.level.symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(health.level.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connection \(health.level.title.lowercased())")
                        .font(.title3.weight(.semibold))
                    if health.findings.isEmpty {
                        Text("Low loss, short queues and steady acknowledgements over the last few seconds.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(health.findings) { finding in
                            Label {
                                Text(finding.message)
                            } icon: {
                                Image(systemName: finding.level.symbol)
                                    .foregroundStyle(finding.level.color)
                            }
                            .help(finding.level.title)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let detail: String?
    var level: ConnectionHealth.Level?

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let level, level > .good {
                        Image(systemName: level.symbol)
                            .font(.caption)
                            .foregroundStyle(level.color)
                            .help(level.title)
                    }
                }
                Text(value)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(detail ?? " ")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// The server's running totals for a session.
struct CountersTable: View {
    let statistics: ServerStatistics

    private var rows: [(String, String)] {
        [
            ("Frames generated", statistics.framesGenerated.formatted()),
            ("Frames queued", statistics.framesQueued.formatted()),
            ("Backpressure drops", statistics.backpressureDrops.formatted()),
            ("Codec drops", statistics.codecDrops.formatted()),
            ("Capture skips", statistics.captureSkips.formatted()),
            ("Key-frame waits", statistics.keyFrameWaits.formatted()),
            ("Long-term reference ACKs", statistics.acknowledgedReferences.formatted()),
            ("Controls queued", statistics.controlsSent.formatted()),
            ("Heartbeats received", statistics.heartbeatsReceived.formatted()),
            ("Transport", statistics.blocked ? "Blocked" : statistics.probing ? "Probing" : "Normal"),
        ]
    }

    var body: some View {
        DashboardCard {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                ForEach(Array(stride(from: 0, to: rows.count, by: 2)), id: \.self) { index in
                    GridRow {
                        cell(rows[index])
                        if index + 1 < rows.count { cell(rows[index + 1]) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ row: (String, String)) -> some View {
        Text(row.0).foregroundStyle(.secondary)
        Text(row.1).monospacedDigit().gridColumnAlignment(.trailing)
    }
}

enum Format {
    static func megabits(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1e6 || bitsPerSecond == 0
            ? String(format: "%.2f Mbps", bitsPerSecond / 1e6)
            : String(format: "%.0f kbps", bitsPerSecond / 1e3)
    }

    static func milliseconds(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f ms", value) : String(format: "%.1f ms", value)
    }

    static func percent(_ ratio: Double) -> String { percent(ratio, digits: 1) }

    static func percent(_ ratio: Double, digits: Int) -> String {
        String(format: "%.\(digits)f%%", ratio * 100)
    }

    static func fps(_ value: Double) -> String { String(format: "%.1f fps", value) }

    static func count(_ value: Double) -> String { String(format: "%.0f", value) }
}
