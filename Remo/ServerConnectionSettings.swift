//
//  Created by Cyandev on 11/21/26.
//

import Foundation
import Network

nonisolated struct ServerConnectionSettings {
    struct Server: Codable {
        var host = ""
        var port = "7711"

        var endpoint: NWEndpoint? {
            Self.endpoint(host: host, port: port, defaultPort: "7711")
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

    struct WireGuard: Codable {
        var server = Server()
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
            guard let peer = Server.endpoint(host: peerHost, port: peerPort, defaultPort: "") else {
                return nil
            }
            return WireGuardConfiguration(
                endpoint: peer, localAddress: localAddress, remote: remote,
                privateKey: privateKey, peerPublicKey: peerPublicKey, presharedKey: presharedKey)
        }
    }

    var useWireGuard = false
    var direct = Server()
    var wireGuard = WireGuard()

    var server: Server { useWireGuard ? wireGuard.server : direct }

    private struct Preferences: Codable {
        var useWireGuard: Bool
        var direct: Server

        static let key = "lastServerConnection"

        static func load(from defaults: UserDefaults) -> Self {
            if let data = defaults.data(forKey: key),
                let preferences = try? JSONDecoder().decode(Self.self, from: data)
            {
                return preferences
            }
            return Self(
                useWireGuard: defaults.bool(forKey: "useWireGuard"),
                direct: Server(
                    host: defaults.string(forKey: "serverHost") ?? "",
                    port: defaults.string(forKey: "serverPort") ?? "7711"))
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let preferences = Preferences.load(from: defaults)
        return Self(
            useWireGuard: preferences.useWireGuard, direct: preferences.direct,
            wireGuard: loadWireGuard(from: defaults))
    }

    private static func loadWireGuard(from defaults: UserDefaults) -> WireGuard {
        let data = WireGuardKeychain.load()
        if let data, let settings = try? JSONDecoder().decode(WireGuard.self, from: data) {
            return settings
        }

        // Older versions stored addresses in preferences and raw keys in Keychain.
        var settings = WireGuard(
            server: Server(
                host: defaults.string(forKey: "wireGuardServerHost") ?? "",
                port: defaults.string(forKey: "wireGuardServerPort") ?? "7711"),
            endpoint: defaults.string(forKey: "wireGuardEndpoint") ?? "",
            localAddress: defaults.string(forKey: "wireGuardLocalAddress") ?? "",
            peerPublicKey: defaults.string(forKey: "wireGuardPeerPublicKey") ?? "")
        if let data, data.count == 32 || data.count == 64 {
            settings.privateKey = data.prefix(32).base64EncodedString()
            settings.presharedKey = data.dropFirst(32).base64EncodedString()
        }
        return settings
    }

    func saveConnection(to defaults: UserDefaults = .standard) -> Bool {
        var preferences = Preferences.load(from: defaults)
        preferences.useWireGuard = useWireGuard
        if !useWireGuard { preferences.direct = direct }
        guard let data = try? JSONEncoder().encode(preferences) else { return false }
        if useWireGuard {
            guard let profile = try? JSONEncoder().encode(wireGuard),
                WireGuardKeychain.save(profile)
            else { return false }
        }
        defaults.set(data, forKey: Preferences.key)
        return true
    }
}
