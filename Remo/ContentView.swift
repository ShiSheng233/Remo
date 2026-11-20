//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
// 

import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = StreamPlayer()
    @State private var settings = ServerConnectionSettings()
    @State private var settingsLoaded = false
    @State private var persistenceError = false

    var body: some View {
        NavigationStack {
            if let surface = player.surface {
                playerView(surface)
            } else {
                connectionForm
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { player.disconnect() }
        }
        .onAppear {
            guard !settingsLoaded else { return }
            settings = ServerConnectionSettings.load()
            settingsLoaded = true
        }
        .onDisappear { player.disconnect() }
    }

    private var connectionForm: some View {
        Form {
            Section("Server") {
                TextField(
                    settings.useWireGuard ? "Server tunnel IPv4 address" : "Hostname or IP address",
                    text: settings.useWireGuard ? $settings.wireGuard.server.host : $settings.direct.host)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(connect)

                LabeledContent("UDP port") {
                    TextField(
                        "UDP port",
                        text: settings.useWireGuard ? $settings.wireGuard.server.port : $settings.direct.port,
                        prompt: Text("7711"))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Connection") {
                Toggle("WireGuard", isOn: $settings.useWireGuard)
            }

            if settings.useWireGuard {
                Section("WireGuard peer") {
                    TextField("Endpoint (host:port)", text: $settings.wireGuard.endpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Client tunnel IPv4 address", text: $settings.wireGuard.localAddress)
                        .keyboardType(.decimalPad)
                    TextField("Peer public key", text: $settings.wireGuard.peerPublicKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Client private key", text: $settings.wireGuard.privateKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Preshared key (optional)", text: $settings.wireGuard.presharedKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            if persistenceError {
                Text("Couldn’t save the connection settings.")
                    .foregroundStyle(.red)
            } else if case .failed(let message) = player.phase {
                Text(message)
                    .foregroundStyle(.red)
            }

            Button("Connect", action: connect)
                .disabled(settings.useWireGuard ? settings.wireGuard.configuration == nil : settings.direct.endpoint == nil)
        }
        .navigationTitle("Remo")
    }

    private func playerView(_ surface: VideoSurface) -> some View {
        ZStack {
            VideoSurfaceView(surface: surface)
                .accessibilityLabel("Remote video")
            if player.phase == .streaming, player.mouseAvailable {
                TrackpadView(onInput: player.handleTrackpad)
            }
            if player.phase == .connecting {
                ProgressView("Connecting…")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else if player.phase == .waitingForVideo {
                ProgressView("Waiting for video…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle(settings.server.host)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Disconnect") { player.disconnect() }
            }
        }
    }

    private func connect() {
        guard let endpoint = settings.server.endpoint else { return }
        let wireGuard = settings.useWireGuard ? settings.wireGuard.configuration : nil
        guard !settings.useWireGuard || wireGuard != nil else { return }
        persistenceError = !settings.saveConnection()
        if !persistenceError {
            player.connect(to: endpoint, wireGuard: wireGuard)
        }
    }
}

#Preview {
    ContentView()
}
