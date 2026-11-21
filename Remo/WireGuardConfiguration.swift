//
//  Created by Cyandev on 11/21/26.
//

import Foundation
import Network

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
