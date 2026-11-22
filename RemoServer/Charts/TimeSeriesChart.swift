//
//  Created by Cyandev on 11/22/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import AppKit
import Charts
import SwiftUI

/// Categorical series colors, stepped separately for light and dark appearances. Slots are
/// assigned in order and never cycled; no chart here plots more than three series.
enum ChartPalette {
    static let blue = dynamic(light: 0x2A78D6, dark: 0x3987E5)
    static let orange = dynamic(light: 0xEB6834, dark: 0xD95926)
    static let aqua = dynamic(light: 0x1BAF7A, dark: 0x199E70)
    static let violet = dynamic(light: 0x6250D6, dark: 0x9085E9)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let hex = isDark ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            })
    }
}

struct ChartPoint: Sendable {
    let time: Date
    let value: Double
}

struct ChartSeries: Identifiable {
    let name: String
    let color: Color
    let points: [ChartPoint]
    var id: String { name }
}

/// A dashed horizontal line marking a limit, such as the configured maximum.
struct ChartReference {
    let label: String
    let value: Double
}

/// A card with a titled line chart over time, with a hover crosshair that reads out every
/// series at the pointer.
struct TimeSeriesChart: View {
    enum Style {
        case line
        /// Lines over a faint fill, for quantities whose size matters, such as loss.
        case area
        /// Stacked bars, for counts per report.
        case bars
    }

    let title: String
    let series: [ChartSeries]
    let domain: ClosedRange<Date>
    let format: (Double) -> String
    var style = Style.line
    var reference: ChartReference?
    /// The smallest top of the value axis, so a quiet link does not magnify noise.
    var minimumUpperBound: Double = 0

    @State private var selection: Date?

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                header
                chart
                    .frame(height: 160)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if series.count == 1, let latest = series[0].points.last {
                    Text(format(latest.value))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if series.count > 1 { legend }
        }
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendItems }
            VStack(alignment: .leading, spacing: 3) { legendItems }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var legendItems: some View {
        ForEach(series) { series in
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(series.color)
                    .frame(width: 12, height: style == .bars ? 8 : 3)
                Text(series.name)
                    .foregroundStyle(.secondary)
                if let latest = series.points.last {
                    Text(format(latest.value))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
    }

    private var upperBound: Double {
        let values = series.flatMap { $0.points.map(\.value) } + [reference?.value ?? 0]
        let top: Double
        if style == .bars {
            // Stacked: the tallest column is the sum at one time.
            var sums: [Date: Double] = [:]
            for series in series { for point in series.points { sums[point.time, default: 0] += point.value } }
            top = sums.values.max() ?? 0
        } else {
            top = values.max() ?? 0
        }
        return max(minimumUpperBound, top * 1.1)
    }

    private var chart: some View {
        Chart {
            if let reference {
                RuleMark(y: .value("Limit", reference.value))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text(reference.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
            ForEach(series) { series in
                ForEach(series.points, id: \.time) { point in
                    marks(series, point)
                }
            }
            if let selection {
                RuleMark(x: .value("Selected", selection))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top, spacing: 0,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        tooltip(at: selection)
                    }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max(upperBound, .leastNonzeroMagnitude))
        .chartXSelection(value: $selection)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel(format: .dateTime.hour().minute().second())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                AxisValueLabel {
                    if let number = value.as(Double.self) { Text(format(number)) }
                }
            }
        }
        .overlay {
            if series.allSatisfy(\.points.isEmpty) {
                Text("No data yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ChartContentBuilder
    private func marks(_ series: ChartSeries, _ point: ChartPoint) -> some ChartContent {
        switch style {
        case .line:
            LineMark(
                x: .value("Time", point.time), y: .value(title, point.value),
                series: .value("Series", series.name)
            )
            .foregroundStyle(series.color)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
        case .area:
            AreaMark(
                x: .value("Time", point.time), yStart: .value(title, 0), yEnd: .value(title, point.value),
                series: .value("Series", series.name)
            )
            .foregroundStyle(series.color.opacity(0.12))
            .interpolationMethod(.monotone)
            LineMark(
                x: .value("Time", point.time), y: .value(title, point.value),
                series: .value("Series", series.name)
            )
            .foregroundStyle(series.color)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
        case .bars:
            BarMark(
                x: .value("Time", point.time, unit: .second), y: .value(title, point.value)
            )
            .foregroundStyle(series.color)
        }
    }

    private func tooltip(at time: Date) -> some View {
        let readings = series.compactMap { series -> (ChartSeries, ChartPoint)? in
            guard let point = series.points.min(by: {
                abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time))
            }), abs(point.time.timeIntervalSince(time)) < 2.5 else { return nil }
            return (series, point)
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text((readings.first?.1.time ?? time).formatted(.dateTime.hour().minute().second()))
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(readings, id: \.0.id) { series, point in
                HStack(spacing: 5) {
                    Circle().fill(series.color).frame(width: 7, height: 7)
                    Text(series.name).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(format(point.value)).monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .frame(minWidth: 140)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
    }
}

/// The rounded panel every dashboard section sits in.
struct DashboardCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))
    }
}
