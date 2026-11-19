import Foundation
import VideoToolbox

public struct DecodedVideoFrame {
    public let pixels: CVPixelBuffer
    public let presentationTime: CMTime
    public let duration: CMTime
}

/// Create a decoder from the stream's H.264 format description and start at a keyframe.
public final class VideoDecoder {
    private let session: VTDecompressionSession

    public init(format: CMVideoFormatDescription) throws {
        guard CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264 else {
            throw VideoCodecError.invalidConfiguration
        }
        let attributes =
            [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            as CFDictionary
        var decoder: VTDecompressionSession?
        try check(
            VTDecompressionSessionCreate(
                allocator: nil, formatDescription: format,
                decoderSpecification: nil, imageBufferAttributes: attributes,
                outputCallback: nil, decompressionSessionOut: &decoder), "create decoder")
        guard let decoder else { throw VideoCodecError.invalidConfiguration }
        session = decoder
        try check(
            VTSessionSetProperty(
                decoder, key: kVTDecompressionPropertyKey_RealTime,
                value: kCFBooleanTrue), "configure decoder")
    }

    deinit { VTDecompressionSessionInvalidate(session) }

    /// Accepts one compressed access unit per call in decode order.
    public nonisolated(nonsending) func decode(_ sample: CMSampleBuffer) async throws
        -> DecodedVideoFrame
    {
        guard CMSampleBufferGetNumSamples(sample) == 1, CMSampleBufferGetDataBuffer(sample) != nil
        else {
            throw VideoCodecError.invalidFrame
        }
        return try await withCheckedThrowingContinuation { continuation in
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
            ) { status, flags, pixels, pts, duration in
                if status != noErr {
                    continuation.resume(
                        throwing: VideoCodecError.videoToolbox(operation: "decode", status: status))
                } else if let pixels, !flags.contains(.frameDropped) {
                    // The completed image is retained across the callback handoff.
                    nonisolated(unsafe) let output = DecodedVideoFrame(
                        pixels: pixels, presentationTime: pts, duration: duration)
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: VideoCodecError.frameDropped)
                }
            }
            if status != noErr {
                continuation.resume(
                    throwing: VideoCodecError.videoToolbox(
                        operation: "submit to decoder", status: status))
            }
        }
    }
}
