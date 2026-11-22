import Foundation
import VideoToolbox

/// A low-latency HEVC encoder. Submit frames in increasing presentation-time order.
public final class VideoEncoder {
    public enum Refresh {
        case none
        case keyFrame
        /// Recover using the supplied acknowledgements, or force an IDR if the list is empty.
        case recover
    }

    private var changeDetector = FrameChangeDetector()
    private static let unlimitedQP = 51
    private let defaultMinimumQP: Int
    private var appliedMinimumQP: Int?
    private var appliedMaximumQP = VideoEncoder.unlimitedQP
    /// Whether `encode` can honor a `maximumQP`.
    public private(set) var supportsQuantizerLimit = false
    private var supportsDataRateLimits = true
    private var hasEncodedFrame = false
    private let longTermReferences: Bool
    private let session: VTCompressionSession
    private let width: Int
    private let height: Int
    private var bitRate: Int

    /// Key frames are the largest thing a session sends, and a lost or slow one freezes the
    /// picture. They stay conservatively quantized on slower links and relax only when there is
    /// ample headroom, letting subsequent frames sharpen fine detail.
    static func keyFrameMinimumQP(for bitRate: Int) -> Int {
        switch bitRate {
        case ..<3_000_000: 34
        case ..<8_000_000: 32
        default: 30
        }
    }

    /// Motion quantizer floor trades moving-frame sharpness for fluid frame rate on constrained
    /// links (e.g. 5 Mbps, where 1920×1200 @ 60 fps averages ~10 KB/frame) and relaxes on higher
    /// bandwidth LAN links. Still pictures sharpen afterwards via `maximumQP`.
    public static func motionMinimumQP(for bitRate: Int) -> Int {
        switch bitRate {
        case ..<2_500_000: 36
        case ..<6_000_000: 34
        case ..<10_000_000: 30
        case ..<16_000_000: 26
        default: 22
        }
    }

    public init(
        width: Int, height: Int, framesPerSecond: Int, bitRate: Int,
        enableLongTermReferences: Bool = false
    ) throws {
        guard let w = Int32(exactly: width), let h = Int32(exactly: height),
            w > 0, h > 0, framesPerSecond > 0, bitRate > 0
        else { throw VideoCodecError.invalidConfiguration }

        var encoder: VTCompressionSession?
        let specification =
            [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        try check(
            VTCompressionSessionCreate(
                allocator: nil, width: w, height: h, codecType: kCMVideoCodecType_HEVC,
                encoderSpecification: specification, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                compressionSessionOut: &encoder), "create encoder")
        guard let encoder else { throw VideoCodecError.invalidConfiguration }
        self.session = encoder
        self.width = width
        self.height = height
        self.bitRate = bitRate
        self.longTermReferences = enableLongTermReferences
        var properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: framesPerSecond,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
            // Key frames are driven explicitly via recovery / LTR; suppress unsolicited periodic IDRs.
            kVTCompressionPropertyKey_MaxKeyFrameInterval: max(framesPerSecond * 3600, 100_000),
        ]
        if enableLongTermReferences { properties[kVTCompressionPropertyKey_EnableLTR] = true }
        try check(
            VTSessionSetProperties(encoder, propertyDictionary: properties as CFDictionary),
            "configure encoder")
        supportsDataRateLimits = try Self.setDataRateLimits(on: encoder, bitRate: bitRate)
        try check(VTCompressionSessionPrepareToEncodeFrames(encoder), "prepare encoder")
        // A negative initial value denotes automatic control. Restore a valid floor
        // explicitly when motion settles so the encoder can refine fine detail.
        var floor = 0
        if #available(macOS 13.0, iOS 16.0, *) {
            var value: Unmanaged<CFTypeRef>?
            if VTSessionCopyProperty(
                encoder, key: kVTCompressionPropertyKey_MinAllowedFrameQP,
                allocator: nil, valueOut: &value) == noErr,
                let number = value?.takeRetainedValue() as? NSNumber
            {
                floor = max(0, number.intValue)
                appliedMinimumQP = floor
                supportsQuantizerLimit = true
            }
        }
        defaultMinimumQP = floor
    }

    deinit { VTCompressionSessionInvalidate(session) }

    public func setBitRate(_ bitRate: Int) throws {
        guard bitRate > 0 else { throw VideoCodecError.invalidConfiguration }
        try check(
            VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_AverageBitRate,
                value: bitRate as CFNumber), "set encoder bit rate")
        self.bitRate = bitRate
        if supportsDataRateLimits {
            supportsDataRateLimits = try Self.setDataRateLimits(on: session, bitRate: bitRate)
        }
    }

    public func setExpectedFrameRate(_ framesPerSecond: Int) throws {
        guard framesPerSecond > 0 else { throw VideoCodecError.invalidConfiguration }
        try check(
            VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                value: framesPerSecond as CFNumber), "set encoder frame rate")
    }

    /// Best-effort peak bitrate guardrail (2.0x average over a 1.0 s window) to curb runaway VBV
    /// explosions after long still periods without forcing VideoToolbox to drop frames during short
    /// UI animations (such as opening a Dock grid or switching spaces).
    private static func setDataRateLimits(on session: VTCompressionSession, bitRate: Int) throws -> Bool {
        let period = 1.0
        let bytes = max(65_536, Int(Double(bitRate) * 2.0 / 8.0 * period))
        let limits = [NSNumber(value: bytes), NSNumber(value: period)] as CFArray
        let status = VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        if status == kVTPropertyNotSupportedErr || status == kVTPropertyReadOnlyErr {
            return false
        }
        try check(status, "set encoder data rate limits")
        return true
    }

    /// Returns one compressed access unit with its timing and HEVC format description.
    /// Keep the input pixels unchanged until this call completes.
    public nonisolated(nonsending) func encode(
        _ pixels: CVPixelBuffer, presentationTime: CMTime, duration: CMTime = .invalid,
        forceKeyFrame: Bool = false
    ) async throws -> CMSampleBuffer {
        try await encode(
            pixels, presentationTime: presentationTime, duration: duration,
            refresh: forceKeyFrame ? .keyFrame : .none)
    }

    /// Pass new acknowledgements on normal submissions. For recovery, supply tokens the receiver
    /// can still use in the current prediction chain, even if they were acknowledged previously.
    ///
    /// `minimumQP` optionally raises the quantizer floor (for example, under send-queue pressure)
    /// to keep frames small and fluid instead of skipping them. `maximumQP` makes a predicted
    /// frame of a still picture at least that fine, which sharpens what a coarser frame left
    /// behind; it is ignored for key frames, moving pictures, and when `minimumQP` is raised.
    public nonisolated(nonsending) func encode(
        _ pixels: CVPixelBuffer, presentationTime: CMTime, duration: CMTime = .invalid,
        refresh: Refresh, acknowledgedReferences: [LongTermReferenceToken] = [],
        minimumQP: Int? = nil, maximumQP: Int? = nil
    ) async throws -> CMSampleBuffer {
        guard longTermReferences || acknowledgedReferences.isEmpty else {
            throw VideoCodecError.invalidConfiguration
        }
        guard CVPixelBufferGetWidth(pixels) == width, CVPixelBufferGetHeight(pixels) == height,
            presentationTime.isNumeric
        else { throw VideoCodecError.invalidFrame }
        var options: [CFString: Any] = [:]
        switch refresh {
        case .none: break
        case .keyFrame: options[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
        case .recover:
            let key =
                acknowledgedReferences.isEmpty
                ? kVTEncodeFrameOptionKey_ForceKeyFrame : kVTEncodeFrameOptionKey_ForceLTRRefresh
            options[key] = true
        }
        if !acknowledgedReferences.isEmpty {
            options[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = acknowledgedReferences.map {
                NSNumber(value: $0.rawValue)
            }
        }
        if #available(macOS 13.0, iOS 16.0, *), let appliedMinimumQP {
            let independent = options[kVTEncodeFrameOptionKey_ForceKeyFrame] != nil || !hasEncodedFrame
            let moving = changeDetector.isMoving(pixels, at: presentationTime.seconds)
            let targetFloor =
                independent
                ? Self.keyFrameMinimumQP(for: bitRate)
                : Self.motionMinimumQP(for: bitRate)
            let coarse = max(targetFloor, defaultMinimumQP)
            let baseMinimum = independent || moving ? coarse : defaultMinimumQP
            let minimum = min(Self.unlimitedQP, max(baseMinimum, minimumQP ?? defaultMinimumQP))
            let maximum =
                independent || moving || minimumQP != nil
                ? Self.unlimitedQP : max(minimum, maximumQP ?? Self.unlimitedQP)
            // Keep the floor at or below the ceiling at every step.
            if maximum >= appliedMaximumQP { try limit(maximum: maximum) }
            if minimum != appliedMinimumQP {
                let status = VTSessionSetProperty(
                    session, key: kVTCompressionPropertyKey_MinAllowedFrameQP, value: minimum as CFNumber)
                if status == kVTPropertyNotSupportedErr || status == kVTPropertyReadOnlyErr {
                    self.appliedMinimumQP = nil
                    supportsQuantizerLimit = false
                } else {
                    try check(status, "set minimum predicted frame QP")
                    self.appliedMinimumQP = minimum
                }
            }
            if maximum < appliedMaximumQP { try limit(maximum: maximum) }
        }
        let sample: CMSampleBuffer = try await withCheckedThrowingContinuation { continuation in
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixels,
                presentationTimeStamp: presentationTime, duration: duration,
                frameProperties: options.isEmpty ? nil : options as CFDictionary,
                infoFlagsOut: nil
            ) { status, flags, sample in
                if status != noErr {
                    continuation.resume(
                        throwing: VideoCodecError.videoToolbox(operation: "encode", status: status))
                } else if let sample, !flags.contains(.frameDropped) {
                    // VideoToolbox has finished writing this sample; only the awaiting caller uses it.
                    nonisolated(unsafe) let output = sample
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: VideoCodecError.frameDropped)
                }
            }
            if status != noErr {
                continuation.resume(
                    throwing: VideoCodecError.videoToolbox(
                        operation: "submit to encoder", status: status))
            }
        }
        hasEncodedFrame = true
        return sample
    }

    @available(macOS 13.0, iOS 16.0, *)
    private func limit(maximum: Int) throws {
        guard supportsQuantizerLimit, maximum != appliedMaximumQP else { return }
        let status = VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: maximum as CFNumber)
        if status == kVTPropertyNotSupportedErr || status == kVTPropertyReadOnlyErr {
            supportsQuantizerLimit = false
        } else {
            try check(status, "set maximum frame QP")
            appliedMaximumQP = maximum
        }
    }
}
