//
//  Created by Cyandev on 11/21/26.
//

import CoreGraphics
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

    struct StreamSettings: Codable, Hashable, Sendable {
        enum Resolution: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
            case automatic
            case hd720
            case hd1080
            case qhd1440
            case uhd4k
            case native
            case custom

            var id: Self { self }

            var title: String {
                switch self {
                case .automatic: "Default (1920px)"
                case .hd720: "720p (1280 × 720)"
                case .hd1080: "1080p (1920 × 1080)"
                case .qhd1440: "1440p (2560 × 1440)"
                case .uhd4k: "4K (3840 × 2160)"
                case .native: "Native"
                case .custom: "Custom"
                }
            }

            var shortTitle: String {
                switch self {
                case .automatic: "Default (1920px)"
                case .hd720: "720p"
                case .hd1080: "1080p"
                case .qhd1440: "1440p"
                case .uhd4k: "4K"
                case .native: "Native"
                case .custom: "Custom"
                }
            }
        }

        static let frameRatePresets = [30, 60, 120]
        static let bitRatePresets = [2_000_000, 5_000_000, 10_000_000, 20_000_000, 50_000_000]

        var usesVirtualDisplay = false
        var resolution = Resolution.automatic
        var customWidth = 1920
        var customHeight = 1080
        var framesPerSecond = Int(StreamParameters.defaultFramesPerSecond)
        var maximumVideoBitRate = StreamParameters.defaultMaximumVideoBitRate
        var streamsAudio = false

        init(
            usesVirtualDisplay: Bool = false,
            resolution: Resolution = .automatic,
            customWidth: Int = 1920,
            customHeight: Int = 1080,
            framesPerSecond: Int = Int(StreamParameters.defaultFramesPerSecond),
            maximumVideoBitRate: Int = StreamParameters.defaultMaximumVideoBitRate,
            streamsAudio: Bool = false
        ) {
            self.usesVirtualDisplay = usesVirtualDisplay
            self.resolution = resolution
            self.customWidth = customWidth
            self.customHeight = customHeight
            self.framesPerSecond = framesPerSecond
            self.maximumVideoBitRate = maximumVideoBitRate
            self.streamsAudio = streamsAudio
        }

        init(from decoder: any Decoder) throws {
            self.init()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func decode<Value: Decodable>(_ key: CodingKeys, into value: inout Value) {
                if let decoded = try? container.decode(Value.self, forKey: key) { value = decoded }
            }
            decode(.usesVirtualDisplay, into: &usesVirtualDisplay)
            decode(.resolution, into: &resolution)
            decode(.customWidth, into: &customWidth)
            decode(.customHeight, into: &customHeight)
            decode(.framesPerSecond, into: &framesPerSecond)
            decode(.maximumVideoBitRate, into: &maximumVideoBitRate)
            decode(.streamsAudio, into: &streamsAudio)
        }

        var maximumSize: StreamParameters.Size? {
            switch resolution {
            case .automatic: nil
            case .hd720: .init(width: 1280, height: 720)
            case .hd1080: .init(width: 1920, height: 1080)
            case .qhd1440: .init(width: 2560, height: 1440)
            case .uhd4k: .init(width: 3840, height: 2160)
            case .native: .init(width: 8192, height: 8192)
            case .custom: .init(width: customWidth, height: customHeight)
            }
        }

        var validationProblem: String? {
            guard let fps = Int32(exactly: framesPerSecond) else {
                return "The frame rate must be 1...240."
            }
            return StreamParameters(
                maximumSize: usesVirtualDisplay ? nil : maximumSize,
                framesPerSecond: fps,
                maximumVideoBitRate: maximumVideoBitRate,
                streamsAudio: streamsAudio
            ).validationProblem
        }

        func parameters(screenLogicalSize: CGSize) -> StreamParameters? {
            guard let fps = Int32(exactly: framesPerSecond) else { return nil }
            let virtualDisplay =
                usesVirtualDisplay ? Self.virtualDisplay(for: screenLogicalSize) : nil
            let parameters = StreamParameters(
                maximumSize: usesVirtualDisplay ? nil : maximumSize,
                virtualDisplay: virtualDisplay,
                framesPerSecond: fps,
                maximumVideoBitRate: maximumVideoBitRate,
                streamsAudio: streamsAudio)
            return parameters.isValid ? parameters : nil
        }

        static func virtualDisplay(for screenLogicalSize: CGSize) -> StreamParameters.VirtualDisplay {
            StreamParameters.VirtualDisplay.fitting(
                logicalWidth: Int(screenLogicalSize.width.rounded()),
                logicalHeight: Int(screenLogicalSize.height.rounded()))
        }

        var resolutionSummary: String {
            resolution == .custom ? "\(customWidth) × \(customHeight)" : resolution.shortTitle
        }

        var bitRateSummary: String {
            Self.formatBitRate(maximumVideoBitRate)
        }

        static func formatBitRate(_ bitsPerSecond: Int) -> String {
            if bitsPerSecond >= 1_000_000 {
                let mbps = Double(bitsPerSecond) / 1_000_000
                return "\(mbps.formatted(.number.precision(.fractionLength(0...2)))) Mbps"
            }
            let kbps = Double(bitsPerSecond) / 1_000
            return "\(kbps.formatted(.number.precision(.fractionLength(0...1)))) kbps"
        }
    }

    var id = UUID()
    var name = ""
    var useWireGuard = false
    var direct = Address()
    var wireGuard = WireGuard()
    var stream = StreamSettings()
    var lastSessionAt: Date?

    init(
        id: UUID = UUID(), name: String = "", useWireGuard: Bool = false,
        direct: Address = Address(), wireGuard: WireGuard = WireGuard(),
        stream: StreamSettings = StreamSettings(), lastSessionAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.useWireGuard = useWireGuard
        self.direct = direct
        self.wireGuard = wireGuard
        self.stream = stream
        self.lastSessionAt = lastSessionAt
    }

    /// Decodes missing keys as their defaults so servers saved by earlier builds still load.
    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        useWireGuard = try container.decodeIfPresent(Bool.self, forKey: .useWireGuard) ?? false
        direct = try container.decodeIfPresent(Address.self, forKey: .direct) ?? Address()
        wireGuard = try container.decodeIfPresent(WireGuard.self, forKey: .wireGuard) ?? WireGuard()
        stream = try container.decodeIfPresent(StreamSettings.self, forKey: .stream) ?? StreamSettings()
        lastSessionAt = try container.decodeIfPresent(Date.self, forKey: .lastSessionAt)
    }

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
        (useWireGuard ? wireGuard.configuration != nil : direct.endpoint != nil)
            && stream.validationProblem == nil
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
