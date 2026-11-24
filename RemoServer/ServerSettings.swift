//
//  Created by Cyandev on 11/22/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation
import RemoEngine

/// Everything `remo-engine server` takes on its command line, kept between launches.
struct ServerSettings: Codable, Equatable, Sendable {
    enum Source: String, Codable, CaseIterable, Identifiable, Sendable {
        /// `--screen`: the main display.
        case screen
        /// The moving test pattern the CLI streams without `--screen`.
        case testPattern

        var id: Self { self }
    }

    var port = Int(RemoProtocol.defaultPort)
    var source = Source.screen
    /// `--control`.
    var allowsRemoteControl = false
    /// `--wire-stats`.
    var wireStatistics = false
    /// `--trace-heartbeats`.
    var traceHeartbeats = false
    /// `REMO_AUDIO_TRACE_DIR`.
    var audioTraceDirectory: String?

    /// The problems that would keep the server from starting, in the CLI's words.
    var problems: [String] {
        var problems: [String] = []
        if !(1...65535).contains(port) { problems.append("The UDP port must be 1...65535.") }
        return problems
    }

    /// The options that apply to the chosen source. Remote control needs the screen.
    var effective: ServerSettings {
        var settings = self
        if source != .screen {
            settings.allowsRemoteControl = false
        }
        return settings
    }

    /// The equivalent CLI invocation, for reference and for reproducing a session in a terminal.
    var commandLine: String {
        let settings = effective
        var parts = ["remo-engine", "server", String(settings.port)]
        if settings.source == .screen { parts.append("--screen") }
        if settings.allowsRemoteControl { parts.append("--control") }
        if settings.wireStatistics { parts.append("--wire-stats") }
        if settings.traceHeartbeats { parts.append("--trace-heartbeats") }
        let command = parts.joined(separator: " ")
        guard let directory = settings.audioTraceDirectory, !directory.isEmpty else { return command }
        return "REMO_AUDIO_TRACE_DIR=\(shellQuoted(directory)) " + command
    }

    private func shellQuoted(_ text: String) -> String {
        guard text.contains(where: { !$0.isLetter && !$0.isNumber && !"/._-".contains($0) }) else {
            return text
        }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Persistence

extension ServerSettings {
    private static let defaultsKey = "ServerSettings"

    static func load(from defaults: UserDefaults = .standard) -> ServerSettings {
        guard let data = defaults.data(forKey: defaultsKey),
            let settings = try? JSONDecoder().decode(ServerSettings.self, from: data)
        else { return ServerSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Decodes missing keys as their defaults, so settings saved by an older build still load.
    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decode<Value: Decodable>(_ key: CodingKeys, into value: inout Value) {
            if let decoded = try? container.decode(Value.self, forKey: key) { value = decoded }
        }
        decode(.port, into: &port)
        decode(.source, into: &source)
        decode(.allowsRemoteControl, into: &allowsRemoteControl)
        decode(.wireStatistics, into: &wireStatistics)
        decode(.traceHeartbeats, into: &traceHeartbeats)
        audioTraceDirectory = try? container.decodeIfPresent(String.self, forKey: .audioTraceDirectory)
    }
}
