import CoreMedia
import CoreVideo
import Testing
import VideoToolbox

@testable import RemoEngineCLI

private func scaled(_ source: CVPixelBuffer, width: Int, height: Int) throws -> CVPixelBuffer {
    var target: CVPixelBuffer?
    CVPixelBufferCreate(
        nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &target)
    var session: VTPixelTransferSession?
    VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
    let transfer = try #require(session)
    defer { VTPixelTransferSessionInvalidate(transfer) }
    let pixels = try #require(target)
    #expect(VTPixelTransferSessionTransferImage(transfer, from: source, to: pixels) == noErr)
    return pixels
}

/// The server scales a source down on slow links, so the pattern must read at any size.
@Test(arguments: [1, 2, 4]) func patternReadsAtEveryAdaptedSize(divisor: Int) throws {
    let source = try TestPatternSource(width: 640, height: 360, framesPerSecond: 30)
    let frame = try #require(try source.latestFrame())
    let pixels =
        divisor == 1
        ? frame.pixels : try scaled(frame.pixels, width: 640 / divisor, height: 360 / divisor)
    let index = try #require(TestPattern.index(of: pixels))
    #expect(CMTime(value: Int64(index), timescale: 30) == frame.timestamp)
}

@Test func patternRejectsAnotherPicture() throws {
    let source = try TestPatternSource(width: 640, height: 360, framesPerSecond: 30)
    let frame = try #require(try source.latestFrame())
    CVPixelBufferLockBaseAddress(frame.pixels, [])
    // Flip one checker cell in the middle.
    let stride = CVPixelBufferGetBytesPerRowOfPlane(frame.pixels, 0)
    let luma = CVPixelBufferGetBaseAddressOfPlane(frame.pixels, 0)!.assumingMemoryBound(to: UInt8.self)
    for y in 150..<180 { for x in 304..<336 { luma[y * stride + x] = 255 } }
    CVPixelBufferUnlockBaseAddress(frame.pixels, [])
    #expect(TestPattern.index(of: frame.pixels) == nil)
    #expect(throws: (any Error).self) {
        try TestPatternSource(width: 641, height: 360, framesPerSecond: 30)
    }
}
