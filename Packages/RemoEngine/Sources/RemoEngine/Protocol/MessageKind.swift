//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation

/// The first byte of every application message. All kinds share this one namespace.
enum MessageKind: UInt8, CaseIterable {
    /// Asks for video, from clients that predate `screenHello`.
    case hello = 1
    case heartbeat = 2
    case goodbye = 3
    /// `ControlMessage`.
    case control = 5
    /// Asks for the server's video.
    case screenHello = 6
    /// Retired: refused a `hello`. Not to be reused.
    case modeMismatch = 7
    case pointerHello = 8
    /// `PointerMessage.ready`.
    case pointerReady = 9
    /// `PointerMessage` input.
    case pointerInput = 10
    /// `AudioMessage`.
    case audio = 11

    /// `VideoFrameMessage`.
    case videoFrame = 0x40
    case videoAcknowledgement = 0x41
    case videoRefresh = 0x42
    case keyFrameRequest = 0x43
    case keyFrameChunk = 0x44
    case keyFrameProgress = 0x45

    /// Kinds that `VideoSession` handles.
    var isVideo: Bool { rawValue & 0xc0 == 0x40 }

    /// The whole message for kinds without a body.
    var encoded: Data { Data([rawValue]) }
}
