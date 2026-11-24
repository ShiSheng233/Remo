//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation

/// Video and audio settings a client requests during the session handshake.
public struct StreamParameters: Equatable, Hashable, Sendable {
    /// Pixel dimensions, both even and in `2...8192`.
    public struct Size: Equatable, Hashable, Sendable {
        public static let validRange = 2...8192

        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        public var isValid: Bool {
            Self.validRange.contains(width) && width.isMultiple(of: 2)
                && Self.validRange.contains(height) && height.isMultiple(of: 2)
        }
    }

    public static let validFrameRateRange: ClosedRange<Int32> = 1...240
    public static let validBitRateRange: ClosedRange<Int> = 1...Int(Int32.max)
    public static let defaultFramesPerSecond: Int32 = 60
    public static let defaultMaximumVideoBitRate = 5_000_000
    public static let defaultScreenEdge = 1920

    /// Maximum capture dimensions in pixels, or `nil` for the source's default
    /// (1920 pixels on the longest edge for a display, or a custom source's default size).
    public var maximumSize: Size?
    /// Target maximum frame rate (`1...240`). Screen capture runs VFR up to this rate.
    public var framesPerSecond: Int32
    /// Video bit rate ceiling in bits per second (`1...2147483647`).
    public var maximumVideoBitRate: Int
    /// Whether to stream system playback audio alongside video.
    public var streamsAudio: Bool

    public init(
        maximumSize: Size? = nil,
        framesPerSecond: Int32 = Self.defaultFramesPerSecond,
        maximumVideoBitRate: Int = Self.defaultMaximumVideoBitRate,
        streamsAudio: Bool = false
    ) {
        self.maximumSize = maximumSize
        self.framesPerSecond = framesPerSecond
        self.maximumVideoBitRate = maximumVideoBitRate
        self.streamsAudio = streamsAudio
    }

    public var isValid: Bool { validationProblem == nil }

    /// The first reason these parameters cannot be negotiated, or `nil` when valid.
    public var validationProblem: String? {
        if let maximumSize, !maximumSize.isValid {
            return "Video dimensions must be even, from 2 to 8192."
        }
        if !Self.validFrameRateRange.contains(framesPerSecond) {
            return "The frame rate must be 1...240."
        }
        if !Self.validBitRateRange.contains(maximumVideoBitRate) {
            return "The video bit rate must be 1...2147483647 bps."
        }
        return nil
    }
}
