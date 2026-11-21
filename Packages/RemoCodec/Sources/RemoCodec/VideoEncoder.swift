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
    private let defaultMinimumQP: Int
    private var appliedMinimumQP: Int?
    private var hasEncodedFrame = false
    private let longTermReferences: Bool
    private let session: VTCompressionSession
    private let width: Int
    private let height: Int

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
        self.longTermReferences = enableLongTermReferences
        var properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: framesPerSecond,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
        ]
        if enableLongTermReferences { properties[kVTCompressionPropertyKey_EnableLTR] = true }
        try check(
            VTSessionSetProperties(encoder, propertyDictionary: properties as CFDictionary),
            "configure encoder")
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
    public nonisolated(nonsending) func encode(
        _ pixels: CVPixelBuffer, presentationTime: CMTime, duration: CMTime = .invalid,
        refresh: Refresh, acknowledgedReferences: [LongTermReferenceToken] = []
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
            let applyFloor = changeDetector.isMoving(pixels, at: presentationTime.seconds)
            let minimum = independent || !applyFloor ? defaultMinimumQP : max(34, defaultMinimumQP)
            if minimum != appliedMinimumQP {
                let status = VTSessionSetProperty(
                    session, key: kVTCompressionPropertyKey_MinAllowedFrameQP, value: minimum as CFNumber)
                if status == kVTPropertyNotSupportedErr || status == kVTPropertyReadOnlyErr {
                    self.appliedMinimumQP = nil
                } else {
                    try check(status, "set minimum predicted frame QP")
                    self.appliedMinimumQP = minimum
                }
            }
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
}
