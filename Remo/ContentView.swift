//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
// 

import Network
import SwiftUI

struct ContentView: View {
    @AppStorage("serverHost") private var host = ""
    @AppStorage("serverPort") private var port = "7711"
    @AppStorage("useWireGuard") private var useWireGuard = false
    @AppStorage("wireGuardServerHost") private var wireGuardHost = ""
    @AppStorage("wireGuardServerPort") private var wireGuardPort = "7711"
    @AppStorage("wireGuardEndpoint") private var wireGuardEndpoint = ""
    @AppStorage("wireGuardLocalAddress") private var wireGuardLocalAddress = ""
    @AppStorage("wireGuardPeerPublicKey") private var peerPublicKey = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = StreamPlayer()
    @State private var privateKey = ""
    @State private var presharedKey = ""
    @State private var keychainError = false

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
        .task {
            if let keys = WireGuardKeychain.load() {
                privateKey = keys.privateKey
                presharedKey = keys.presharedKey
            }
        }
        .onDisappear { player.disconnect() }
    }

    private var connectionForm: some View {
        Form {
            Section("Server") {
                TextField(
                    useWireGuard ? "Server tunnel IPv4 address" : "Hostname or IP address",
                    text: useWireGuard ? $wireGuardHost : $host)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(connect)

                LabeledContent("UDP port") {
                    TextField("UDP port", text: useWireGuard ? $wireGuardPort : $port, prompt: Text("7711"))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section("Connection") {
                Toggle("WireGuard", isOn: $useWireGuard)
            }

            if useWireGuard {
                Section("WireGuard peer") {
                    TextField("Endpoint (host:port)", text: $wireGuardEndpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Client tunnel IPv4 address", text: $wireGuardLocalAddress)
                        .keyboardType(.decimalPad)
                    TextField("Peer public key", text: $peerPublicKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Client private key", text: $privateKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Preshared key (optional)", text: $presharedKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            if keychainError, useWireGuard {
                Text("Couldn’t save the WireGuard keys to Keychain.")
                    .foregroundStyle(.red)
            } else if case .failed(let message) = player.phase {
                Text(message)
                    .foregroundStyle(.red)
            }

            Button("Connect", action: connect)
                .disabled(useWireGuard ? wireGuardConfiguration == nil : endpoint == nil)
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
        .navigationTitle(useWireGuard ? wireGuardHost : host)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Disconnect") { player.disconnect() }
            }
        }
    }

    private var endpoint: NWEndpoint? {
        Self.endpoint(
            host: useWireGuard ? wireGuardHost : host,
            port: useWireGuard ? wireGuardPort : port, defaultPort: "7711")
    }

    private var wireGuardConfiguration: WireGuardConfiguration? {
        guard let endpoint, let separator = wireGuardEndpoint.lastIndex(of: ":") else { return nil }
        let peerHost = wireGuardEndpoint[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peerHost.contains(":") || (peerHost.hasPrefix("[") && peerHost.hasSuffix("]")) else {
            return nil
        }
        let peerPort = String(wireGuardEndpoint[wireGuardEndpoint.index(after: separator)...])
        guard let peer = Self.endpoint(host: peerHost, port: peerPort, defaultPort: "") else { return nil }
        return WireGuardConfiguration(
            endpoint: peer, localAddress: wireGuardLocalAddress, remote: endpoint,
            privateKey: privateKey, peerPublicKey: peerPublicKey, presharedKey: presharedKey)
    }

    private static func endpoint(host: String, port: String, defaultPort: String) -> NWEndpoint? {
        var address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }
        let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty,
            address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            address.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@[]")) == nil,
            let number = UInt16(portText.isEmpty ? defaultPort : portText),
            number > 0, let port = NWEndpoint.Port(rawValue: number)
        else { return nil }
        return .hostPort(host: NWEndpoint.Host(address), port: port)
    }

    private func connect() {
        guard let endpoint else { return }
        keychainError = false
        if useWireGuard {
            guard let wireGuardConfiguration else { return }
            guard WireGuardKeychain.save(wireGuardConfiguration) else {
                keychainError = true
                return
            }
            player.connect(to: endpoint, wireGuard: wireGuardConfiguration)
        } else {
            player.connect(to: endpoint)
        }
    }
}

#Preview {
    ContentView()
}
