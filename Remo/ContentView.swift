//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ServerStore()
    @State private var player = StreamPlayer()
    @State private var selection: UUID?
    @State private var newServer: RemoteServer?
    @State private var editRequest: UUID?
    @State private var pendingDeletion: RemoteServer?
    @State private var activeServer: RemoteServer?
    @State private var deletionFailed = false
    // The list is the home screen, so keep it beside the detail on the unfolded display.
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ServerListView(
                store: store, selection: $selection, onAdd: addServer,
                onEdit: { server in
                    selection = server.id
                    editRequest = server.id
                },
                onDelete: { pendingDeletion = $0 })
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .fullScreenCover(isPresented: playerPresented) {
            if let surface = player.surface {
                PlayerView(player: player, surface: surface, title: activeServer?.displayName ?? "")
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.displayName ?? "")”?",
            isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible, presenting: pendingDeletion
        ) { server in
            Button("Delete Server", role: .destructive) { delete(server) }
        } message: { _ in
            Text("Its connection settings and preview will be removed from this device.")
        }
        .alert("Couldn’t delete the server.", isPresented: $deletionFailed) {}
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { player.disconnect() }
        }
        .onAppear {
            store.load()
        }
        .onDisappear { player.disconnect() }
    }

    @ViewBuilder private var detail: some View {
        if let id = selection, let server = store.server(id) {
            ServerDetailView(
                server: server, thumbnail: store.thumbnails[id], isNew: false,
                failure: activeServer?.id == id ? failure : nil, canConnect: player.surface == nil,
                editRequest: $editRequest, onSave: store.save, onConnect: connect, onCancelNew: {},
                onDelete: { pendingDeletion = $0 }
            )
            .id(id)
        } else if let draft = newServer, selection == draft.id {
            // Once saved, the server comes from the store and the branch above takes over.
            ServerDetailView(
                server: draft, thumbnail: nil, isNew: true, failure: nil, canConnect: false,
                editRequest: $editRequest, onSave: store.save, onConnect: connect,
                onCancelNew: {
                    newServer = nil
                    selection = nil
                },
                onDelete: { _ in })
        } else if !store.servers.isEmpty {
            ContentUnavailableView("Select a Server", systemImage: "display")
        }
    }

    private var failure: String? {
        if case .failed(let message) = player.phase { message } else { nil }
    }

    private var playerPresented: Binding<Bool> {
        Binding(get: { player.surface != nil }, set: { if !$0 { player.disconnect() } })
    }

    private func addServer() {
        let server = RemoteServer()
        newServer = server
        selection = server.id
    }

    private func connect(_ server: RemoteServer) {
        guard let endpoint = server.address.endpoint else { return }
        let wireGuard = server.useWireGuard ? server.wireGuard.configuration : nil
        guard !server.useWireGuard || wireGuard != nil else { return }
        activeServer = server
        let id = server.id
        player.connect(to: endpoint, wireGuard: wireGuard) { [store] frame in
            store.recordSession(id, finalFrame: frame)
        }
    }

    private func delete(_ server: RemoteServer) {
        guard store.delete(server.id) else {
            deletionFailed = true
            return
        }
        if selection == server.id { selection = nil }
    }
}

#Preview {
    ContentView()
}
