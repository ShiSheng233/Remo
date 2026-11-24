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

    /// Logical dimensions in points for a @2x HiDPI virtual display created on the server.
    ///
    /// macOS requires at least 800×600 pt to activate a desktop mode, and sizes above 3600 pt
    /// can destabilize WindowServer, so logical dimensions are restricted to 800...3600 × 600...3600.
    public struct VirtualDisplay: Equatable, Hashable, Sendable {
        public static let validWidthRange = 800...3600
        public static let validHeightRange = 600...3600

        public var logicalWidth: Int
        public var logicalHeight: Int

        public init(logicalWidth: Int, logicalHeight: Int) {
            self.logicalWidth = logicalWidth
            self.logicalHeight = logicalHeight
        }

        /// Physical pixel width at @2x scale.
        public var pixelWidth: Int { logicalWidth * 2 }
        /// Physical pixel height at @2x scale.
        public var pixelHeight: Int { logicalHeight * 2 }

        public var isValid: Bool {
            Self.validWidthRange.contains(logicalWidth)
                && Self.validHeightRange.contains(logicalHeight)
        }

        /// Fits a device's logical screen dimensions (in points) into the supported virtual display
        /// range while preserving the aspect ratio whenever scaling is needed. Sizes already inside
        /// the range are returned unchanged.
        public static func fitting(logicalWidth: Int, logicalHeight: Int) -> Self {
            guard logicalWidth > 0, logicalHeight > 0 else {
                return Self(logicalWidth: 1920, logicalHeight: 1080)
            }
            var w = Double(logicalWidth)
            var h = Double(logicalHeight)
            let upScale = max(
                1.0,
                Double(validWidthRange.lowerBound) / w,
                Double(validHeightRange.lowerBound) / h)
            w *= upScale
            h *= upScale
            let downScale = min(
                1.0,
                Double(validWidthRange.upperBound) / w,
                Double(validHeightRange.upperBound) / h)
            w *= downScale
            h *= downScale
            let finalWidth = min(
                validWidthRange.upperBound, max(validWidthRange.lowerBound, Int(w.rounded())))
            let finalHeight = min(
                validHeightRange.upperBound, max(validHeightRange.lowerBound, Int(h.rounded())))
            return Self(logicalWidth: finalWidth, logicalHeight: finalHeight)
        }
    }

    public static let validFrameRateRange: ClosedRange<Int32> = 1...240
    public static let validBitRateRange: ClosedRange<Int> = 1...Int(Int32.max)
    public static let defaultFramesPerSecond: Int32 = 60
    public static let defaultMaximumVideoBitRate = 5_000_000
    public static let defaultScreenEdge = 1920

    /// Maximum capture dimensions in pixels, or `nil` for the source's default
    /// (1920 pixels on the longest edge for the main display, full @2x resolution for a virtual
    /// display, or a custom source's default size).
    public var maximumSize: Size?
    /// When set, the server creates a @2x HiDPI virtual display with these logical point dimensions
    /// and streams it instead of the main display.
    public var virtualDisplay: VirtualDisplay?
    /// Target maximum frame rate (`1...240`). Screen capture runs VFR up to this rate.
    public var framesPerSecond: Int32
    /// Video bit rate ceiling in bits per second (`1...2147483647`).
    public var maximumVideoBitRate: Int
    /// Whether to stream system playback audio alongside video.
    public var streamsAudio: Bool

    public init(
        maximumSize: Size? = nil,
        virtualDisplay: VirtualDisplay? = nil,
        framesPerSecond: Int32 = Self.defaultFramesPerSecond,
        maximumVideoBitRate: Int = Self.defaultMaximumVideoBitRate,
        streamsAudio: Bool = false
    ) {
        self.maximumSize = maximumSize
        self.virtualDisplay = virtualDisplay
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
        if let virtualDisplay, !virtualDisplay.isValid {
            return "Virtual display logical size must be 800...3600 × 600...3600 pt."
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
