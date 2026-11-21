//
//  Created by Cyandev on 11/21/26.
//

import Foundation
import Network
import RemoEngine

nonisolated struct RemoteServer: Codable, Identifiable, Hashable, Sendable {
    struct Address: Codable, Hashable, Sendable {
        var host = ""
        var port = Self.defaultPort

        static let defaultPort = String(RemoProtocol.defaultPort)

        var endpoint: NWEndpoint? {
            Self.endpoint(host: host, port: port, defaultPort: Self.defaultPort)
        }

        /// The address as it would be typed, with IPv6 hosts bracketed.
        var displayString: String {
            let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
            let bracketed = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
            return "\(bracketed):\(portText.isEmpty ? Self.defaultPort : portText)"
        }

        static func endpoint(host: String, port: String, defaultPort: String) -> NWEndpoint? {
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
    }

    struct WireGuard: Codable, Hashable, Sendable {
        var server = Address()
        var endpoint = ""
        var localAddress = ""
        var peerPublicKey = ""
        var privateKey = ""
        var presharedKey = ""

        var configuration: WireGuardConfiguration? {
            guard let remote = server.endpoint, let separator = endpoint.lastIndex(of: ":") else {
                return nil
            }
            let peerHost = endpoint[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !peerHost.contains(":") || (peerHost.hasPrefix("[") && peerHost.hasSuffix("]")) else {
                return nil
            }
            let peerPort = String(endpoint[endpoint.index(after: separator)...])
            guard let peer = Address.endpoint(host: peerHost, port: peerPort, defaultPort: "") else {
                return nil
            }
            return WireGuardConfiguration(
                endpoint: peer, localAddress: localAddress, remote: remote,
                privateKey: privateKey, peerPublicKey: peerPublicKey, presharedKey: presharedKey)
        }
    }

    var id = UUID()
    var name = ""
    var useWireGuard = false
    var direct = Address()
    var wireGuard = WireGuard()
    var lastSessionAt: Date?

    /// The Remo server address for the selected transport.
    var address: Address {
        get { useWireGuard ? wireGuard.server : direct }
        set {
            if useWireGuard { wireGuard.server = newValue } else { direct = newValue }
        }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let host = address.host.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? String(localized: "New Server") : host
    }

    var isValid: Bool {
        useWireGuard ? wireGuard.configuration != nil : direct.endpoint != nil
    }

    /// Orders servers by name, falling back to their identifiers so equal names never reshuffle.
    static func displayOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        switch lhs.displayName.localizedStandardCompare(rhs.displayName) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

// MARK: - Settings saved before the server list

extension RemoteServer {
    private struct LegacyPreferences: Codable {
        var useWireGuard: Bool
        var direct: Address
    }

    private static let legacyPreferencesKey = "lastServerConnection"
    private static let legacyWireGuardService = "me.cyandev.Remo.WireGuard"
    private static let legacyDefaultsKeys = [
        legacyPreferencesKey, "useWireGuard", "serverHost", "serverPort", "wireGuardServerHost",
        "wireGuardServerPort", "wireGuardEndpoint", "wireGuardLocalAddress", "wireGuardPeerPublicKey",
    ]

    /// The single connection that earlier versions remembered, if one was saved.
    static func legacy(from defaults: UserDefaults) -> RemoteServer? {
        let preferences: LegacyPreferences
        if let data = defaults.data(forKey: legacyPreferencesKey),
            let decoded = try? JSONDecoder().decode(LegacyPreferences.self, from: data)
        {
            preferences = decoded
        } else {
            preferences = LegacyPreferences(
                useWireGuard: defaults.bool(forKey: "useWireGuard"),
                direct: Address(
                    host: defaults.string(forKey: "serverHost") ?? "",
                    port: defaults.string(forKey: "serverPort") ?? Address.defaultPort))
        }
        let wireGuard = legacyWireGuard(from: defaults)
        var server = RemoteServer(
            useWireGuard: preferences.useWireGuard, direct: preferences.direct, wireGuard: wireGuard)
        if server.address.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Keep whichever transport actually has an address.
            server.useWireGuard.toggle()
        }
        return server.address.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : server
    }

    static func removeLegacy(from defaults: UserDefaults) {
        legacyDefaultsKeys.forEach(defaults.removeObject(forKey:))
        _ = Keychain.delete(service: legacyWireGuardService)
    }

    private static func legacyWireGuard(from defaults: UserDefaults) -> WireGuard {
        let data = Keychain.data(service: legacyWireGuardService)
        if let data, let settings = try? JSONDecoder().decode(WireGuard.self, from: data) {
            return settings
        }

        // Older versions stored addresses in preferences and raw keys in Keychain.
        var settings = WireGuard(
            server: Address(
                host: defaults.string(forKey: "wireGuardServerHost") ?? "",
                port: defaults.string(forKey: "wireGuardServerPort") ?? Address.defaultPort),
            endpoint: defaults.string(forKey: "wireGuardEndpoint") ?? "",
            localAddress: defaults.string(forKey: "wireGuardLocalAddress") ?? "",
            peerPublicKey: defaults.string(forKey: "wireGuardPeerPublicKey") ?? "")
        if let data, data.count == 32 || data.count == 64 {
            settings.privateKey = data.prefix(32).base64EncodedString()
            settings.presharedKey = data.dropFirst(32).base64EncodedString()
        }
        return settings
    }
}
