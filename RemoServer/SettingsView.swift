//
//  Created by Cyandev on 11/22/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import AppKit
import ApplicationServices
import RemoEngine
import SwiftUI

/// Every option of `remo-engine server`. Changes are saved at once and take effect on the
/// next start.
struct SettingsView: View {
    @Environment(ServerController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        Form {
            if controller.needsRestart || !controller.settings.problems.isEmpty {
                Section { banner }
            }
            Section("Network") {
                TextField("UDP port", value: $controller.settings.port, format: .number.grouping(.never))
                    .help("remo-engine server [port]")
            }
            Section {
                Picker("Source", selection: $controller.settings.source) {
                    Text("Main display").tag(ServerSettings.Source.screen)
                    Text("Test pattern").tag(ServerSettings.Source.testPattern)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Source")
            } footer: {
                Text("Resolution, virtual display, frame rate, max video bit rate, and audio streaming are requested by each client when it connects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Allow remote control", isOn: $controller.settings.allowsRemoteControl)
                    .help("--control")
                PermissionRow(
                    title: "Screen Recording", check: { CGPreflightScreenCaptureAccess() },
                    request: { _ = CGRequestScreenCaptureAccess() },
                    settingsAnchor: "Privacy_ScreenCapture")
                if controller.settings.allowsRemoteControl {
                    PermissionRow(
                        title: "Accessibility", check: { CGPreflightPostEventAccess() },
                        request: { _ = CGRequestPostEventAccess() },
                        settingsAnchor: "Privacy_Accessibility")
                }
            } header: {
                Text("Screen")
            } footer: {
                if controller.settings.source != .screen {
                    Text("Remote control needs the main display source.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(controller.settings.source != .screen)
            Section("Diagnostics") {
                Toggle("Wire statistics", isOn: $controller.settings.wireStatistics)
                    .help("--wire-stats: outgoing UDP bytes, DATA, ACK and retransmissions once per second")
                Toggle("Trace heartbeats", isOn: $controller.settings.traceHeartbeats)
                    .help("--trace-heartbeats: heartbeat submission, UDP framing, session delivery and timeouts")
                LabeledContent("Audio trace folder") {
                    HStack {
                        if let directory = controller.settings.audioTraceDirectory, !directory.isEmpty {
                            Text((directory as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(directory)
                            Button("Clear") { controller.settings.audioTraceDirectory = nil }
                        } else {
                            Text("Off").foregroundStyle(.secondary)
                        }
                        Button("Choose…", action: chooseTraceDirectory)
                    }
                }
                .help("REMO_AUDIO_TRACE_DIR: records PCM (.f32le) and timing (.csv) at each audio stage")
            }
            Section("Command line") {
                HStack(alignment: .top) {
                    Text(controller.settings.commandLine)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(controller.settings.commandLine, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the equivalent remo-engine command")
                }
                Button("Restore Defaults") { controller.settings = ServerSettings() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private var banner: some View {
        if !controller.settings.problems.isEmpty {
            ForEach(controller.settings.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
        } else {
            HStack {
                Label("The server is running with different settings.", systemImage: "arrow.clockwise.circle.fill")
                Spacer()
                Button("Restart Server") { controller.restart() }
            }
        }
    }

    private func chooseTraceDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Record Here"
        panel.message = "Choose a folder for diagnostic audio traces."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.settings.audioTraceDirectory = url.path
    }
}

/// A privacy permission the server needs, with a way to grant it.
private struct PermissionRow: View {
    let title: String
    let check: () -> Bool
    let request: () -> Void
    let settingsAnchor: String

    @State private var granted = false

    var body: some View {
        content
            .onAppear { granted = check() }
            // Granting happens in System Settings, so look again whenever the app comes back.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                granted = check()
            }
    }

    private var content: some View {
        LabeledContent(title) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            } else {
                HStack {
                    Label("Not allowed", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .foregroundStyle(.secondary)
                    Button("Request") {
                        request()
                        granted = check()
                    }
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }
}
