//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

/// Values a client and server must agree on outside the session itself.
public enum RemoProtocol {
    /// The UDP port a server listens on unless configured otherwise.
    public static let defaultPort: UInt16 = 7711
}
