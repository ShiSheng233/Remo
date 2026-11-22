//
//  Created by Cyandev on 11/22/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import RemoEngine
import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case settings
    case log
    case client(UUID)
}

struct ContentView: View {
    @Environment(ServerController.self) private var controller
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Server") {
                    Label("Overview", systemImage: "gauge.with.dots.needle.67percent")
                        .tag(SidebarItem.overview)
                    Label("Settings", systemImage: "slider.horizontal.3")
                        .badge(controller.needsRestart ? Text("Restart") : nil)
                        .tag(SidebarItem.settings)
                    Label("Event Log", systemImage: "list.bullet.rectangle")
                        .tag(SidebarItem.log)
                }
                if !controller.clients.isEmpty {
                    Section("Clients") {
                        ForEach(controller.clients) { client in
                            ClientSidebarRow(client: client)
                                .tag(SidebarItem.client(client.id))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                if controller.clients.contains(where: { !$0.status.isActive }) {
                    Button("Clear Disconnected Clients") {
                        if case .client(let id) = selection,
                            controller.clients.first(where: { $0.id == id })?.status.isActive == false
                        {
                            selection = .overview
                        }
                        controller.clearDisconnectedClients()
                    }
                    .buttonStyle(.borderless)
                    .padding(10)
                }
            }
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ServerControlButton()
            }
        }
        .onChange(of: controller.clients.first?.id) { _, id in
            // Follow the first client that connects while looking at the overview.
            if let id, selection == .overview, controller.activeClients.count == 1 {
                selection = .client(id)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .settings:
            SettingsView()
        case .log:
            EventLogView()
        case .client(let id):
            if let client = controller.clients.first(where: { $0.id == id }) {
                ClientDashboardView(client: client, settings: controller.activeSettings)
                    .id(client.id)
            } else {
                ContentUnavailableView("Client Gone", systemImage: "person.crop.circle.badge.xmark")
            }
        case .overview, nil:
            OverviewView(selection: $selection)
        }
    }
}

private struct ClientSidebarRow: View {
    let client: ClientMonitor

    var body: some View {
        let health = ConnectionHealth(samples: client.samples)
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(client.peer).lineLimit(1).truncationMode(.middle)
                if let latest = client.latest, client.status.isActive {
                    Text(
                        "\(latest.link.roundTripTime.map { Format.milliseconds($0.milliseconds) } ?? "—") · \(Format.megabits(latest.statistics.videoBitsPerSecond))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if !client.status.isActive {
                    Text("Disconnected").font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            if !client.status.isActive {
                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            } else if client.latest == nil {
                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
            } else {
                Image(systemName: health.level.symbol).foregroundStyle(health.level.color)
            }
        }
        .help(client.status.isActive ? health.level.title : "Disconnected")
    }
}
