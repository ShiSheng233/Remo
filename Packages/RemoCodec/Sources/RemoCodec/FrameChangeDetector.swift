import CoreVideo
import Foundation

struct FrameChangeDetector {
    private var previous: [UInt8] = []
    private var lastChange: Double?

    mutating func isMoving(_ pixels: CVPixelBuffer, at time: Double) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixels)
        let isBGRA = format == kCVPixelFormatType_32BGRA
        guard isBGRA || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess
        else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let base = isBGRA ? CVPixelBufferGetBaseAddress(pixels) : CVPixelBufferGetBaseAddressOfPlane(pixels, 0)
        guard let base else { return false }
        let stride = isBGRA ? CVPixelBufferGetBytesPerRow(pixels) : CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let columns = min(width, 64), rows = min(height, 36)
        let count = columns * rows
        let hasPrevious = previous.count == count
        if !hasPrevious { previous = Array(repeating: 0, count: count) }
        var changed = 0
        for y in 0..<rows {
            let line = base.advanced(by: ((2 * y + 1) * height / (2 * rows)) * stride)
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<columns {
                let column = (2 * x + 1) * width / (2 * columns)
                let index = y * columns + x
                let luma: UInt8
                if isBGRA {
                    let pixel = line.advanced(by: 4 * column)
                    luma = UInt8((29 * Int(pixel[0]) + 150 * Int(pixel[1]) + 77 * Int(pixel[2])) >> 8)
                } else {
                    luma = line[column]
                }
                if abs(Int(luma) - Int(previous[index])) >= 12 { changed += 1 }
                previous[index] = luma
            }
        }
        if hasPrevious && changed * 100 >= 4 * count { lastChange = time }
        // Bridge brief gaps in an animation while letting a settled desktop refine.
        return lastChange.map { time >= $0 && time - $0 < 0.12 } ?? false
    }
}
