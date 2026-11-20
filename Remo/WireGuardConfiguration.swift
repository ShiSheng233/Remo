//
//  Created by Cyandev on 11/21/26.
//

import Foundation
import Network
import Security

nonisolated struct WireGuardConfiguration: Sendable {
    let endpoint: NWEndpoint
    let localAddress: IPv4Address
    let remoteAddress: IPv4Address
    let remotePort: UInt16
    let privateKey: [UInt8]
    let peerPublicKey: [UInt8]
    let presharedKey: [UInt8]

    init?(
        endpoint: NWEndpoint, localAddress: String, remote: NWEndpoint,
        privateKey: String, peerPublicKey: String, presharedKey: String
    ) {
        guard let local = IPv4Address(localAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
            case .hostPort(.ipv4(let remoteAddress), let remotePort) = remote,
            let privateKey = Self.keyBytes(privateKey), privateKey.contains(where: { $0 != 0 }),
            let peerPublicKey = Self.keyBytes(peerPublicKey), peerPublicKey.contains(where: { $0 != 0 })
        else { return nil }
        let psk = presharedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let presharedKey = psk.isEmpty ? [] : Self.keyBytes(psk) else { return nil }
        self.endpoint = endpoint
        self.localAddress = local
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort.rawValue
        self.privateKey = privateKey
        self.peerPublicKey = peerPublicKey
        self.presharedKey = presharedKey
    }

    private static func keyBytes(_ key: String) -> [UInt8]? {
        guard let data = Data(base64Encoded: key.trimmingCharacters(in: .whitespacesAndNewlines)),
            data.count == 32
        else { return nil }
        return Array(data)
    }
}

enum WireGuardKeychain {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "me.cyandev.Remo.WireGuard",
        ]
    }

    static func load() -> (privateKey: String, presharedKey: String)? {
        var item: CFTypeRef?
        var request = query
        request[kSecReturnData as String] = true
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data, data.count == 32 || data.count == 64
        else { return nil }
        return (Data(data.prefix(32)).base64EncodedString(), Data(data.dropFirst(32)).base64EncodedString())
    }

    static func save(_ configuration: WireGuardConfiguration) -> Bool {
        let data = Data(configuration.privateKey + configuration.presharedKey)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status != errSecItemNotFound { return status == errSecSuccess }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
