//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
// 

import Network
import SwiftUI

struct ContentView: View {
    @AppStorage("serverHost") private var host = ""
    @AppStorage("serverPort") private var port = "7711"
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = StreamPlayer()

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
        .onDisappear { player.disconnect() }
    }

    private var connectionForm: some View {
        Form {
            Section("Server") {
                TextField("Hostname or IP address", text: $host)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(connect)

                LabeledContent("UDP port") {
                    TextField("UDP port", text: $port, prompt: Text("7711"))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }

            if case .failed(let message) = player.phase {
                Text(message)
                    .foregroundStyle(.red)
            }

            Button("Connect", action: connect)
                .disabled(endpoint == nil)
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
        .navigationTitle(host)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Disconnect") { player.disconnect() }
            }
        }
    }

    private var endpoint: NWEndpoint? {
        var address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }
        let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty,
            address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            address.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@[]")) == nil,
            let number = UInt16(portText.isEmpty ? "7711" : portText),
            number > 0, let port = NWEndpoint.Port(rawValue: number)
        else { return nil }
        return .hostPort(host: NWEndpoint.Host(address), port: port)
    }

    private func connect() {
        guard let endpoint else { return }
        player.connect(to: endpoint)
    }
}

#Preview {
    ContentView()
}
