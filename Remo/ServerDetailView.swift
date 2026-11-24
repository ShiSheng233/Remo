//
//  Created by Cyandev on 11/21/26.
//

import RemoEngine
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
    @State private var customWidthText: String
    @State private var customHeightText: String
    @State private var customFrameRate: Bool
    @State private var customFrameRateText: String
    @State private var customBitRate: Bool
    @State private var customBitRateText: String
    @State private var saveFailed = false
    @State private var isWide = false
    @State private var screenLogicalSize = DeviceScreen.logicalSize

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
        _customWidthText = State(initialValue: String(server.stream.customWidth))
        _customHeightText = State(initialValue: String(server.stream.customHeight))
        _customFrameRate = State(
            initialValue: !RemoteServer.StreamSettings.frameRatePresets.contains(
                server.stream.framesPerSecond))
        _customFrameRateText = State(initialValue: String(server.stream.framesPerSecond))
        _customBitRate = State(
            initialValue: !RemoteServer.StreamSettings.bitRatePresets.contains(
                server.stream.maximumVideoBitRate))
        _customBitRateText = State(
            initialValue: Self.megabitsText(for: server.stream.maximumVideoBitRate))
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
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
            screenLogicalSize = DeviceScreen.logicalSize
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

                VStack(spacing: 0) {
                    if server.stream.usesVirtualDisplay {
                        let vd = RemoteServer.StreamSettings.virtualDisplay(
                            for: screenLogicalSize)
                        LabeledContent(
                            "Display", value: "Virtual (\(vd.pixelWidth) × \(vd.pixelHeight))")
                            .frame(minHeight: 52)
                    } else {
                        LabeledContent("Resolution", value: server.stream.resolutionSummary)
                            .frame(minHeight: 52)
                    }
                    Divider()
                    LabeledContent("Frame Rate", value: "\(server.stream.framesPerSecond) fps")
                        .frame(minHeight: 52)
                    Divider()
                    LabeledContent("Max Bit Rate", value: server.stream.bitRateSummary)
                        .frame(minHeight: 52)
                    Divider()
                    LabeledContent("Audio", value: server.stream.streamsAudio ? "On" : "Off")
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

        Section {
            Toggle("Virtual display", isOn: $draft.stream.usesVirtualDisplay)
            if draft.stream.usesVirtualDisplay {
                let vd = RemoteServer.StreamSettings.virtualDisplay(for: screenLogicalSize)
                LabeledContent(
                    "Display size",
                    value: "\(vd.pixelWidth) × \(vd.pixelHeight) (\(vd.logicalWidth) × \(vd.logicalHeight) @2x)"
                )
            } else {
                Picker("Resolution", selection: $draft.stream.resolution) {
                    ForEach(RemoteServer.StreamSettings.Resolution.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                if draft.stream.resolution == .custom {
                    LabeledContent("Width") {
                        HStack(spacing: 6) {
                            TextField("Width", text: customWidthBinding, prompt: Text("1920"))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                            Text("px").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Height") {
                        HStack(spacing: 6) {
                            TextField("Height", text: customHeightBinding, prompt: Text("1080"))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                            Text("px").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Picker("Frame rate", selection: frameRateSelection) {
                ForEach(RemoteServer.StreamSettings.frameRatePresets, id: \.self) { fps in
                    Text("\(fps) fps").tag(Optional(fps))
                }
                Text("Custom").tag(Int?.none)
            }
            if customFrameRate {
                LabeledContent("Custom frame rate") {
                    HStack(spacing: 6) {
                        TextField("Frame rate", text: customFrameRateBinding, prompt: Text("60"))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                        Text("fps").foregroundStyle(.secondary)
                    }
                }
            }

            Picker("Max bit rate", selection: bitRateSelection) {
                ForEach(RemoteServer.StreamSettings.bitRatePresets, id: \.self) { bps in
                    Text(RemoteServer.StreamSettings.formatBitRate(bps)).tag(Optional(bps))
                }
                Text("Custom").tag(Int?.none)
            }
            if customBitRate {
                LabeledContent("Custom bit rate") {
                    HStack(spacing: 6) {
                        TextField("Bit rate", text: customBitRateBinding, prompt: Text("5"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("Mbps").foregroundStyle(.secondary)
                    }
                }
            }

            Toggle("Stream audio", isOn: $draft.stream.streamsAudio)
        } header: {
            Text("Stream")
        } footer: {
            if let problem = draft.stream.validationProblem {
                Text(problem)
                    .foregroundStyle(.red)
            } else if draft.stream.usesVirtualDisplay {
                Text(
                    "Creates a 2× HiDPI virtual display on the Mac matching this device’s logical screen size and streams it at full resolution. Capture runs at a variable frame rate up to the limit."
                )
            } else {
                Text(
                    "The display is scaled to fit the selected resolution while keeping its aspect ratio. Capture runs at a variable frame rate up to the limit."
                )
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

    private var customWidthBinding: Binding<String> {
        Binding {
            customWidthText
        } set: { value in
            customWidthText = value
            draft.stream.customWidth = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }

    private var customHeightBinding: Binding<String> {
        Binding {
            customHeightText
        } set: { value in
            customHeightText = value
            draft.stream.customHeight = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }

    private var frameRateSelection: Binding<Int?> {
        Binding {
            customFrameRate ? nil : draft.stream.framesPerSecond
        } set: { selected in
            if let fps = selected {
                customFrameRate = false
                draft.stream.framesPerSecond = fps
                customFrameRateText = String(fps)
            } else {
                customFrameRate = true
                customFrameRateText =
                    draft.stream.framesPerSecond > 0 ? String(draft.stream.framesPerSecond) : ""
            }
        }
    }

    private var customFrameRateBinding: Binding<String> {
        Binding {
            customFrameRateText
        } set: { value in
            customFrameRateText = value
            draft.stream.framesPerSecond = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }

    private var bitRateSelection: Binding<Int?> {
        Binding {
            customBitRate ? nil : draft.stream.maximumVideoBitRate
        } set: { selected in
            if let bps = selected {
                customBitRate = false
                draft.stream.maximumVideoBitRate = bps
                customBitRateText = Self.megabitsText(for: bps)
            } else {
                customBitRate = true
                customBitRateText =
                    draft.stream.maximumVideoBitRate > 0
                    ? Self.megabitsText(for: draft.stream.maximumVideoBitRate) : ""
            }
        }
    }

    private var customBitRateBinding: Binding<String> {
        Binding {
            customBitRateText
        } set: { value in
            customBitRateText = value
            let trimmed = value.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: ".")
            if let mbps = Double(trimmed), mbps.isFinite, mbps > 0, mbps <= Double(Int32.max) / 1e6
            {
                draft.stream.maximumVideoBitRate = Int((mbps * 1e6).rounded())
            } else {
                draft.stream.maximumVideoBitRate = 0
            }
        }
    }

    private static func megabitsText(for bitsPerSecond: Int) -> String {
        let mbps = Double(bitsPerSecond) / 1e6
        return mbps.formatted(
            .number.grouping(.never).precision(.fractionLength(0...3))
                .locale(Locale(identifier: "en_US_POSIX")))
    }

    private func beginEditing() {
        draft = server
        customWidthText = String(server.stream.customWidth)
        customHeightText = String(server.stream.customHeight)
        customFrameRate = !RemoteServer.StreamSettings.frameRatePresets.contains(
            server.stream.framesPerSecond)
        customFrameRateText = String(server.stream.framesPerSecond)
        customBitRate = !RemoteServer.StreamSettings.bitRatePresets.contains(
            server.stream.maximumVideoBitRate)
        customBitRateText = Self.megabitsText(for: server.stream.maximumVideoBitRate)
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
