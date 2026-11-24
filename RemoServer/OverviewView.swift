//
//  Created by Cyandev on 11/22/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Charts
import Darwin
import RemoEngine
import SwiftUI

/// The server at a glance: whether it runs, where clients can reach it, and how each client
/// is doing.
struct OverviewView: View {
    @Environment(ServerController.self) private var controller
    @Binding var selection: SidebarItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                if controller.state.isRunning, case .listening(let port) = controller.state {
                    addressesCard(port: port)
                }
                if !controller.clients.isEmpty {
                    Text("Clients")
                        .font(.title3.weight(.semibold))
                        .padding(.top, 6)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(controller.clients) { client in
                            Button {
                                selection = .client(client.id)
                            } label: {
                                ClientSummaryCard(client: client)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Overview")
    }

    private var statusCard: some View {
        DashboardCard {
            HStack(alignment: .top, spacing: 14) {
                ServerStateIcon(state: controller.state)
                    .font(.system(size: 34))
                VStack(alignment: .leading, spacing: 6) {
                    Text(stateTitle)
                        .font(.title3.weight(.semibold))
                    Text(stateDetail)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let settings = controller.activeSettings ?? (controller.state.isRunning ? nil : controller.settings.effective) {
                        Text(settings.commandLine)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                ServerControlButton()
                    .controlSize(.large)
            }
        }
    }

    private var stateTitle: String {
        switch controller.state {
        case .stopped: "Server stopped"
        case .starting: "Starting…"
        case .listening:
            controller.activeClients.isEmpty
                ? "Waiting for clients"
                : "Streaming to \(controller.activeClients.count) client\(controller.activeClients.count == 1 ? "" : "s")"
        case .stopping: "Stopping…"
        case .failed: "Server failed"
        }
    }

    private var stateDetail: String {
        switch controller.state {
        case .stopped: return "Start the server to accept Remo clients."
        case .starting: return "Checking permissions and preparing the source."
        case .listening(let port):
            var parts = ["UDP port \(port)"]
            if let size = controller.screenSize {
                parts.append("main display \(size.width) × \(size.height)")
            } else if controller.activeSettings?.source == .testPattern {
                parts.append("test pattern")
            }
            if let startedAt = controller.startedAt {
                parts.append("up since \(startedAt.formatted(date: .omitted, time: .shortened))")
            }
            return parts.joined(separator: " · ")
        case .stopping: return "Ending every session."
        case .failed(let message): return message
        }
    }

    private func addressesCard(port: UInt16) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect from Remo to")
                    .font(.headline)
                let addresses = NetworkAddress.current()
                if addresses.isEmpty {
                    Text("No network interface has an address.").foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(addresses) { address in
                        GridRow {
                            Text(address.interface).foregroundStyle(.secondary)
                            Text(address.endpoint(port: port))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

/// A compact card for one client with its health and a throughput sparkline.
struct ClientSummaryCard: View {
    let client: ClientMonitor

    var body: some View {
        let health = ConnectionHealth(samples: client.samples)
        let latest = client.latest
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if client.status.isActive, latest != nil {
                        Image(systemName: health.level.symbol)
                            .foregroundStyle(health.level.color)
                            .help(health.level.title)
                    }
                    Text(client.peer)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    ClientStatusLabel(status: client.status)
                    if let session = client.session {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(session.width) × \(session.height) · \(session.framesPerSecond) fps")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                if let latest {
                    HStack(spacing: 16) {
                        reading("RTT", latest.link.roundTripTime.map { Format.milliseconds($0.milliseconds) } ?? "—")
                        reading("Loss", Format.percent(latest.link.lossRatio))
                        reading("Video", Format.megabits(latest.statistics.videoBitsPerSecond))
                        reading("FPS", String(format: "%.0f", latest.statistics.framesPerSecond))
                    }
                    Chart(client.samples.suffix(60)) { sample in
                        AreaMark(
                            x: .value("Time", sample.time),
                            y: .value("Mbps", sample.statistics.videoBitsPerSecond / 1e6)
                        )
                        .foregroundStyle(ChartPalette.blue.opacity(0.15))
                        .interpolationMethod(.monotone)
                        LineMark(
                            x: .value("Time", sample.time),
                            y: .value("Mbps", sample.statistics.videoBitsPerSecond / 1e6)
                        )
                        .foregroundStyle(ChartPalette.blue)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 40)
                    .accessibilityLabel("Video throughput over the last minute")
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func reading(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}

struct ServerStateIcon: View {
    let state: ServerController.State

    var body: some View {
        switch state {
        case .stopped:
            Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        case .starting, .stopping:
            Image(systemName: "ellipsis.circle.fill").foregroundStyle(.secondary)
        case .listening:
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

/// Starts or stops the server, whichever applies.
struct ServerControlButton: View {
    @Environment(ServerController.self) private var controller

    var body: some View {
        if controller.state.isRunning {
            Button {
                controller.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(controller.state == .stopping)
            .help("Stop the server and end every session")
        } else {
            Button {
                controller.start()
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .disabled(!controller.settings.problems.isEmpty)
            .help(controller.settings.problems.first ?? "Start accepting clients")
        }
    }
}

/// A local interface address a client could connect to.
struct NetworkAddress: Identifiable, Hashable {
    let interface: String
    let address: String
    let isIPv6: Bool
    var id: String { interface + address }

    func endpoint(port: UInt16) -> String {
        isIPv6 ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    /// The up, non-loopback addresses, IPv4 first. Link-local IPv6 addresses are left out.
    static func current() -> [NetworkAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var addresses: [NetworkAddress] = []
        for pointer in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let socket = entry.ifa_addr, flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let family = Int32(socket.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                    NI_NUMERICHOST) == 0
            else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if family == AF_INET6 && (address.hasPrefix("fe80") || address.contains("%")) { continue }
            addresses.append(
                NetworkAddress(interface: String(cString: entry.ifa_name), address: address, isIPv6: family == AF_INET6))
        }
        return addresses.sorted { ($0.isIPv6 ? 1 : 0, $0.interface) < ($1.isIPv6 ? 1 : 0, $1.interface) }
    }
}
