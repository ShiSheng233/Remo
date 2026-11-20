//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

/// Application messages shared by the streaming server and its clients.
public enum SessionMessage: UInt8 {
    case hello = 1
    case heartbeat = 2
    case goodbye = 3
    case control = 5
    case screenHello = 6
    case modeMismatch = 7
}
