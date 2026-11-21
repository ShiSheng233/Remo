//
//  Created by Cyandev on 11/21/26.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Shows a server and edits it in place.
struct ServerDetailView: View {
    let server: RemoteServer
    let thumbnail: UIImage?
    /// The most recent session's log, once there has been a session.
    let sessionLog: URL?
    let isNew: Bool
    let failure: String?
    let canConnect: Bool
    @Binding var editRequest: UUID?
    let onSave: (RemoteServer) -> Bool
    let onConnect: (RemoteServer) -> Void
    let onCancelNew: () -> Void
    let onDelete: (RemoteServer) -> Void

    @State private var isEditing: Bool
    @State private var draft: RemoteServer
    @State private var saveFailed = false
    @State private var isWide = false

    /// Detail width from which Connect sits beside the name instead of spanning the page.
    private static let wideLayoutWidth: CGFloat = 520

    init(
        server: RemoteServer, thumbnail: UIImage?, sessionLog: URL?, isNew: Bool, failure: String?,
        canConnect: Bool,
        editRequest: Binding<UUID?>, onSave: @escaping (RemoteServer) -> Bool,
        onConnect: @escaping (RemoteServer) -> Void, onCancelNew: @escaping () -> Void,
        onDelete: @escaping (RemoteServer) -> Void
    ) {
        self.server = server
        self.thumbnail = thumbnail
        self.sessionLog = sessionLog
        self.isNew = isNew
        self.failure = failure
        self.canConnect = canConnect
        _editRequest = editRequest
        self.onSave = onSave
        self.onConnect = onConnect
        self.onCancelNew = onCancelNew
        self.onDelete = onDelete
        _isEditing = State(initialValue: isNew)
        _draft = State(initialValue: server)
    }

    var body: some View {
        Group {
            if isEditing {
                Form { editor }
            } else {
                summary
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isEditing)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", action: cancel)
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", action: save)
                        .labelStyle(.iconOnly)
                        .disabled(!draft.isValid)
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit", systemImage: "pencil", action: beginEditing)
                        .labelStyle(.iconOnly)
                }
            }
        }
        .task(id: editRequest) {
            guard editRequest == server.id else { return }
            editRequest = nil
            beginEditing()
        }
    }

    // A plain stack rather than Form rows, which clip and inset the heading off the left edge.
    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    ServerThumbnail(image: thumbnail, cornerRadius: 20)
                    if isWide {
                        HStack(spacing: 16) {
                            heading
                            Spacer(minLength: 0)
                            connectButton
                        }
                    } else {
                        heading
                    }
                }

                if !isWide {
                    connectButton
                }

                if let failure {
                    Text(failure)
                        .foregroundStyle(.red)
                }

                VStack(spacing: 0) {
                    LabeledContent("Address") {
                        Text(server.address.displayString).monospaced()
                    }
                    .frame(minHeight: 52)
                    Divider()
                    LabeledContent("Connection", value: server.useWireGuard ? "WireGuard" : "Direct")
                        .frame(minHeight: 52)
                }
                .padding(.horizontal, 16)
                .background(
                    Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))

                if let sessionLog {
                    let file = SessionLogFile(
                        url: sessionLog, name: "Remo \(server.displayName) \(logDate).log")
                    ShareLink(item: file, preview: SharePreview(file.name)) {
                        Label("Export Last Session Log", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                    .background(
                        Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wideLayoutWidth } action: {
            isWide = $0
        }
    }

    /// When the logged session started, in local time, for the exported file's name.
    private var logDate: String {
        let started = sessionLog.flatMap {
            try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate
        }
        let style = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)",
            timeZone: .current, calendar: .current)
        return (started ?? .now).formatted(style)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.displayName)
                .font(.title.bold())
            LastSessionText(date: server.lastSessionAt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// Spans the page when narrow; sized to its label beside the name when wide.
    private var connectButton: some View {
        Button {
            onConnect(server)
        } label: {
            Label("Connect", systemImage: "play.fill")
                .labelStyle(.titleAndIcon)
                .font(.headline)
                .padding(.horizontal, isWide ? 8 : 0)
                .frame(maxWidth: isWide ? nil : .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canConnect || !server.isValid)
    }

    @ViewBuilder private var editor: some View {
        Section {
            HStack(spacing: 16) {
                ServerThumbnail(image: thumbnail, cornerRadius: 12)
                    .frame(width: 120)
                TextField(
                    "Name", text: $draft.name,
                    prompt: Text(draft.address.host.isEmpty ? "Name" : draft.address.host))
                    .font(.title2.bold())
                    .submitLabel(.done)
            }
        }

        Section("Server") {
            TextField(
                draft.useWireGuard ? "Server tunnel IPv4 address" : "Hostname or IP address",
                text: $draft.address.host)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            LabeledContent("UDP port") {
                TextField("UDP port", text: $draft.address.port, prompt: Text(verbatim: RemoteServer.Address.defaultPort))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
        }

        Section("Connection") {
            Toggle("WireGuard", isOn: $draft.useWireGuard)
        }

        if draft.useWireGuard {
            Section("WireGuard peer") {
                TextField("Endpoint (host:port)", text: $draft.wireGuard.endpoint)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Client tunnel IPv4 address", text: $draft.wireGuard.localAddress)
                    .keyboardType(.decimalPad)
                TextField("Peer public key", text: $draft.wireGuard.peerPublicKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Client private key", text: $draft.wireGuard.privateKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Preshared key (optional)", text: $draft.wireGuard.presharedKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }

        if saveFailed {
            Text("Couldn’t save the server.")
                .foregroundStyle(.red)
        }

        if !isNew {
            Section {
                Button("Delete Server", systemImage: "trash", role: .destructive) { onDelete(server) }
            }
        }
    }

    private func beginEditing() {
        draft = server
        saveFailed = false
        withAnimation { isEditing = true }
    }

    private func cancel() {
        if isNew {
            onCancelNew()
            return
        }
        withAnimation { isEditing = false }
    }

    private func save() {
        guard draft.isValid else { return }
        guard onSave(draft) else {
            saveFailed = true
            return
        }
        withAnimation { isEditing = false }
    }
}

/// A session log shared under a readable name instead of the server's identifier.
private struct SessionLogFile: Transferable {
    let url: URL
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .log) { SentTransferredFile($0.url) }
            .suggestedFileName { $0.name }
    }
}
