import CoreVideo
import Foundation

/// NV12 checkerboard with a moving vertical bar. The receiver can verify it from its PTS.
enum SimulatedVideo {
    static let width = 640, height = 360
    private static let patchWidth = 160, patchHeight = 96
    // Changing texture produces multi-datagram access units even when the bar moves smoothly.
    private static let patches: [[UInt8]] = (1...8).map { seed in
        var state = UInt32(seed)
        return (0..<(patchWidth * patchHeight)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return 40 + UInt8(state >> 25)
        }
    }

    static func bar(_ index: UInt64) -> Int { Int(index % 34) * 16 }

    static func pixels(_ index: UInt64) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard
            CVPixelBufferCreate(
                nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attrs, &result) == kCVReturnSuccess, let result,
            CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess
        else { throw CocoaError(.coderInvalidValue) }
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let left = bar(index)
        let base = CVPixelBufferGetBaseAddressOfPlane(result, 0)!
        for y in 0..<height {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(result, 0))
            for x in stride(from: 0, to: width, by: 32) {
                memset(row.advanced(by: x), ((x / 32 + y / 32) % 2 == 0) ? 48 : 72, 32)
            }
            memset(row.advanced(by: left), 200, 96)
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(result, 0)
        patches[Int(index % UInt64(patches.count))].withUnsafeBytes { patch in
            for y in 0..<patchHeight {
                memcpy(
                    base.advanced(by: y * stride), patch.baseAddress!.advanced(by: y * patchWidth),
                    patchWidth)
            }
        }
        memset(
            CVPixelBufferGetBaseAddressOfPlane(result, 1)!, 128,
            CVPixelBufferGetBytesPerRowOfPlane(result, 1) * (height / 2))
        return result
    }

    static func matches(_ pixels: CVPixelBuffer, index: UInt64) -> Bool {
        guard CVPixelBufferGetWidth(pixels) == width, CVPixelBufferGetHeight(pixels) == height,
            CVPixelBufferGetPixelFormatType(pixels)
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess
        else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let left = bar(index)
        let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(
            to: UInt8.self)
        let patch = patches[Int(index % UInt64(patches.count))]
        var patchError = 0
        var patchSamples = 0
        for y in stride(from: 8, to: height, by: 32) {
            for x in stride(from: 8, to: width, by: 16) {
                let actual = Int(base[y * CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) + x])
                if x < patchWidth && y < patchHeight {
                    patchError += abs(actual - Int(patch[y * patchWidth + x]))
                    patchSamples += 1
                    continue
                }
                let expected =
                    (left..<(left + 96)).contains(x) ? 200 : ((x / 32 + y / 32) % 2 == 0 ? 48 : 72)
                if abs(actual - expected) > 20 {
                    return false
                }
            }
        }
        return patchError < 24 * patchSamples
    }
}
