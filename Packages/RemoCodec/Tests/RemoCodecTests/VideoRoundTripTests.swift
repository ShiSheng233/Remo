import CoreMedia
import CoreVideo
import RemoCodec
import Testing

private let width = 320
private let height = 240

/// Moves a bright vertical bar over a dark background, with distinct chroma on both sides.
private func fill(_ pixels: CVPixelBuffer, index: Int) throws {
    #expect(CVPixelBufferGetPlaneCount(pixels) == 2)
    try #require(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    let left = 16 + (index % 28) * 8
    for plane in 0..<2 {
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, plane))
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane)
        for y in 0..<CVPixelBufferGetHeightOfPlane(pixels, plane) {
            let row = base.advanced(by: y * stride)
            for x in 0..<width {
                let inside = (left..<(left + 64)).contains(x)
                if plane == 0 {
                    row[x] = inside ? 192 : 48
                } else if x.isMultiple(of: 2) {
                    row[x] = inside ? 96 : 144
                } else {
                    row[x] = inside ? 160 : 112
                }
            }
        }
    }
}

private func makePixels() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    let status = CVPixelBufferCreate(
        nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attributes, &buffer)
    try #require(status == kCVReturnSuccess)
    return try #require(buffer)
}

private func meanError(_ input: CVPixelBuffer, _ output: CVPixelBuffer, plane: Int) throws -> Double
{
    try #require(CVPixelBufferLockBaseAddress(input, .readOnly) == kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(input, .readOnly) }
    try #require(CVPixelBufferLockBaseAddress(output, .readOnly) == kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    let a = try #require(CVPixelBufferGetBaseAddressOfPlane(input, plane)).assumingMemoryBound(
        to: UInt8.self)
    let b = try #require(CVPixelBufferGetBaseAddressOfPlane(output, plane)).assumingMemoryBound(
        to: UInt8.self)
    let rows = CVPixelBufferGetHeightOfPlane(input, plane)
    var error = 0
    for y in 0..<rows {
        let source = a.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(input, plane))
        let decoded = b.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(output, plane))
        for x in 0..<width { error += abs(Int(source[x]) - Int(decoded[x])) }
    }
    return Double(error) / Double(width * rows)
}

@Test(arguments: [false, true])
func syntheticVideoRoundTrip(skipSourceFrame: Bool) async throws {
    let encoder = try VideoEncoder(
        width: width, height: height, framesPerSecond: 30, bitRate: 1_000_000)
    var decoder: VideoDecoder?
    let duration = CMTime(value: 1, timescale: 30)
    var predictedFrames = 0
    for index in 0..<16 {
        if skipSourceFrame && index == 5 { continue }
        let pixels = try makePixels()
        try fill(pixels, index: index)
        let pts = CMTime(value: Int64(index), timescale: 30)
        if index == 8 { try encoder.setBitRate(800_000) }
        let sample = try await encoder.encode(
            pixels, presentationTime: pts, duration: duration, forceKeyFrame: index == 8)
        let format = try #require(CMSampleBufferGetFormatDescription(sample))
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        #expect(CMSampleBufferGetTotalSampleSize(sample) > 0)
        #expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), pts) == 0)
        let attachments =
            CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[String: Any]]
        let isKey = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
        if index == 0 || index == 8 {
            try #require(isKey)
            decoder = try VideoDecoder(format: format)
        } else if !isKey {
            predictedFrames += 1
        }
        let frame = try await #require(decoder).decode(sample)
        try #require(
            CVPixelBufferGetWidth(frame.pixels) == width
                && CVPixelBufferGetHeight(frame.pixels) == height)
        try #require(
            CVPixelBufferGetPixelFormatType(frame.pixels)
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(CMTimeCompare(frame.presentationTime, pts) == 0)
        #expect(CMTimeCompare(frame.duration, duration) == 0)
        #expect(try meanError(pixels, frame.pixels, plane: 0) < 3)
        #expect(try meanError(pixels, frame.pixels, plane: 1) < 3)
    }
    #expect(predictedFrames > 0)
}

private struct Slice {
    let isIDR: Bool
    let isReference: Bool
    let isPredictive: Bool
}

private struct HeaderBits {
    let bytes: [UInt8]
    private var offset = 0

    init(_ payload: some Collection<UInt8>) {
        var rbsp: [UInt8] = []
        var zeros = 0
        for byte in payload {
            if zeros == 2 && byte == 3 {
                zeros = 0
                continue
            }
            rbsp.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        bytes = rbsp
    }

    mutating func read(_ count: Int) throws -> Int {
        guard offset + count <= bytes.count * 8 else { throw VideoCodecError.invalidFrame }
        var value = 0
        for _ in 0..<count {
            value = value * 2 + Int((bytes[offset / 8] >> (7 - offset % 8)) & 1)
            offset += 1
        }
        return value
    }

    mutating func unsignedGolomb() throws -> Int {
        var zeros = 0
        while try read(1) == 0 {
            zeros += 1
            guard zeros <= 16 else { throw VideoCodecError.invalidFrame }
        }
        return try (1 << zeros) - 1 + read(zeros)
    }
}

/// Inspect the first VCL NAL of the picture, skipping HEVC length prefixes and non-VCL units.
private func firstSlice(in sample: CMSampleBuffer) throws -> Slice {
    let format = try #require(CMSampleBufferGetFormatDescription(sample))
    var prefix: Int32 = 0
    try #require(
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: &prefix) == noErr)
    try #require((1...4).contains(prefix))
    let block = try #require(CMSampleBufferGetDataBuffer(sample))
    var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
    try #require(
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
            == noErr)
    var offset = 0
    while offset + Int(prefix) < bytes.count {
        let length = bytes[offset..<offset + Int(prefix)].reduce(0) { ($0 << 8) | Int($1) }
        offset += Int(prefix)
        try #require(length > 0 && length <= bytes.count - offset)
        let type = (bytes[offset] >> 1) & 0x3f
        if type <= 31 {
            try #require(length >= 3)
            let irap = (16...23).contains(type)
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            try #require(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 2, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr)
            let pps = try #require(pointer)
            try #require(size > 2)
            var ppsBits = HeaderBits(UnsafeBufferPointer(start: pps + 2, count: size - 2))
            let ppsID = try ppsBits.unsignedGolomb()
            _ = try ppsBits.unsignedGolomb()
            _ = try ppsBits.read(2)
            let extra = try ppsBits.read(3)
            var slice = HeaderBits(bytes[(offset + 2)..<(offset + length)])
            let firstSegment = try slice.read(1)
            try #require(firstSegment == 1)
            if irap { _ = try slice.read(1) }
            let slicePPS = try slice.unsignedGolomb()
            try #require(slicePPS == ppsID)
            _ = try slice.read(extra)
            let predictive = try slice.unsignedGolomb() == 1
            return Slice(isIDR: type == 19 || type == 20, isReference: irap || type % 2 == 1,
                isPredictive: predictive)
        }
        offset += length
    }
    throw VideoCodecError.invalidFrame
}

@Test(arguments: [true, false])
func recoveryAfterLostReference(acknowledge: Bool) async throws {
    let encoder = try VideoEncoder(
        width: width, height: height, framesPerSecond: 30,
        bitRate: 1_000_000, enableLongTermReferences: true)
    var intact: VideoDecoder?
    var impaired: VideoDecoder?
    var pending: [LongTermReferenceToken] = []
    var lastToken: LongTermReferenceToken?
    var droppedAt: Int?
    var verified = 0
    for index in 0..<120 {
        let pixels = try makePixels()
        try fill(pixels, index: index)
        let pts = CMTime(value: Int64(index), timescale: 30)
        let refresh = droppedAt.map { index == $0 + 1 } ?? false
        let sample = try await encoder.encode(
            pixels, presentationTime: pts, duration: CMTime(value: 1, timescale: 30),
            refresh: refresh ? .recover : .none,
            acknowledgedReferences: refresh && acknowledge ? [try #require(lastToken)] : pending)
        pending.removeAll()
        let slice = try firstSlice(in: sample)
        if index == 0 {
            let format = try #require(CMSampleBufferGetFormatDescription(sample))
            intact = try VideoDecoder(format: format)
            impaired = try VideoDecoder(format: format)
        }
        let reference = try await #require(intact).decode(sample)
        if lastToken != nil && droppedAt == nil && slice.isPredictive && slice.isReference {
            droppedAt = index
            continue
        }
        if refresh {
            try #require(acknowledge ? slice.isPredictive && !slice.isIDR : slice.isIDR)
            if !acknowledge {
                impaired = try VideoDecoder(
                    format: #require(CMSampleBufferGetFormatDescription(sample)))
            }
        }
        let received = try await #require(impaired).decode(sample)
        if let token = LongTermReferenceToken(requestedBy: sample) {
            lastToken = token
            if acknowledge { pending = [token] }
        }
        if droppedAt != nil {
            #expect(CMTimeCompare(received.presentationTime, pts) == 0)
            #expect(try meanError(reference.pixels, received.pixels, plane: 0) == 0)
            #expect(try meanError(reference.pixels, received.pixels, plane: 1) == 0)
            #expect(try meanError(pixels, received.pixels, plane: 0) < 3)
            verified += 1
            if verified == 4 { break }
        }
    }
    #expect(lastToken != nil)
    #expect(droppedAt != nil)
    #expect(verified == 4)
}

@Test func changingBitRateChangesPayloadSize() async throws {
    let encoder = try VideoEncoder(
        width: width, height: height, framesPerSecond: 30, bitRate: 2_000_000)
    // Repeat an identical cycle of detailed images in each measurement window.
    var inputs: [CVPixelBuffer] = []
    for index in 0..<8 {
        let pixels = try makePixels()
        try fill(pixels, index: index)
        try #require(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, 0)).assumingMemoryBound(
            to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        var noise = UInt32(index + 1)
        for y in 0..<height {
            for x in 0..<width {
                noise = noise &* 1_664_525 &+ 1_013_904_223
                base[y * stride + x] = 16 + UInt8(noise >> 25)
            }
        }
        inputs.append(pixels)
    }
    var sizes: [Int] = []
    var decoder: VideoDecoder?
    for (window, target) in [2_000_000, 400_000, 2_000_000].enumerated() {
        try encoder.setBitRate(target)
        var bytes = 0
        for frame in 0..<72 {
            let index = window * 72 + frame
            let pts = CMTime(value: Int64(index), timescale: 30)
            let sample: CMSampleBuffer
            do {
                sample = try await encoder.encode(
                    inputs[frame % inputs.count], presentationTime: pts,
                    duration: CMTime(value: 1, timescale: 30))
            } catch VideoCodecError.frameDropped {
                // A source interval with no output contributes zero bytes to the rate.
                continue
            }
            if decoder == nil {
                decoder = try VideoDecoder(
                    format: #require(CMSampleBufferGetFormatDescription(sample)))
            }
            let decoded = try await #require(decoder).decode(sample)
            #expect(CMTimeCompare(decoded.presentationTime, pts) == 0)
            if frame >= 24 { bytes += CMSampleBufferGetTotalSampleSize(sample) }
        }
        sizes.append(bytes)
    }
    #expect(sizes[1] > 0)
    #expect(sizes[1] * 2 < sizes[0])
    #expect(sizes[1] * 2 < sizes[2])
}
