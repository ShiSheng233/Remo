//
//  Created by Cyandev on 11/22/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import AppKit
import SwiftUI

/// Server events and diagnostic lines, filterable by kind and text.
struct EventLogView: View {
    @Environment(ServerController.self) private var controller
    @AppStorage("LogHiddenKinds") private var hiddenKinds = ""
    @State private var search = ""
    @State private var followsTail = true

    private var entries: [LogEntry] {
        let hidden = Set(hiddenKinds.split(separator: ",").map(String.init))
        return controller.log.filter { entry in
            !hidden.contains(entry.kind.rawValue)
                && (search.isEmpty || entry.message.localizedCaseInsensitiveContains(search)
                    || (entry.peer?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        let entries = entries
        ScrollViewReader { proxy in
            List(entries) { entry in
                LogRow(entry: entry)
                    .id(entry.id)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .font(.system(.callout, design: .monospaced))
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(
                        controller.log.isEmpty ? "No Events" : "No Matching Events",
                        systemImage: "list.bullet.rectangle")
                }
            }
            .onChange(of: entries.last?.id) { _, id in
                if followsTail, let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter")
        .navigationTitle("Event Log")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ForEach(LogEntry.Kind.allCases) { kind in
                        Toggle(kind.title, isOn: visibility(kind))
                    }
                } label: {
                    Label("Kinds", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Choose which kinds of lines to show")
                Toggle(isOn: $followsTail) {
                    Label("Follow", systemImage: "arrow.down.to.line")
                }
                .help("Keep the newest line in view")
                Button {
                    let text = entries.map(\.plainText).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy the shown lines")
                Button {
                    controller.clearLog()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear the log")
            }
        }
    }

    private func visibility(_ kind: LogEntry.Kind) -> Binding<Bool> {
        Binding {
            !hiddenKinds.split(separator: ",").contains(Substring(kind.rawValue))
        } set: { visible in
            var hidden = Set(hiddenKinds.split(separator: ",").map(String.init))
            if visible { hidden.remove(kind.rawValue) } else { hidden.insert(kind.rawValue) }
            hiddenKinds = hidden.sorted().joined(separator: ",")
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3))))
                .foregroundStyle(.secondary)
            Image(systemName: entry.kind.symbol)
                .foregroundStyle(entry.kind == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 16)
                .help(entry.kind.title)
            if let peer = entry.peer {
                Text(peer).foregroundStyle(.secondary)
            }
            Text(entry.message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension LogEntry.Kind {
    var title: String {
        switch self {
        case .event: "Events"
        case .error: "Errors"
        case .info: "Info"
        case .wire: "Wire statistics"
        case .trace: "Heartbeat traces"
        }
    }

    var symbol: String {
        switch self {
        case .event: "circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        case .wire: "network"
        case .trace: "waveform.path.ecg"
        }
    }
}

extension LogEntry {
    var plainText: String {
        let time = time.formatted(.iso8601.time(includingFractionalSeconds: true))
        return "\(time) " + (peer.map { "[\($0)] " } ?? "") + message
    }
}
