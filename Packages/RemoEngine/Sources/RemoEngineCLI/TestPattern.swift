import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import RemoEngine

/// A moving NV12 pattern laid out on a grid relative to the frame, so a client can check it at
/// any size the server scales it to.
///
/// The top row of cells is a barcode of the frame index. Below it is a checkerboard with one
/// bright column at the index. The lower-left block is noise that changes every frame, so each
/// frame spans several datagrams; it is not checked.
enum TestPattern {
    static let columns = 20
    static let rows = 12
    static let indexModulus: UInt64 = 1 << columns
    private static let noiseColumns = 0..<6
    private static let noiseRows = 8..<12

    enum Level {
        static let one: UInt8 = 220, zero: UInt8 = 30
        static let light: UInt8 = 100, dark: UInt8 = 40, bar: UInt8 = 200
    }

    static func expected(column: Int, row: Int, index: UInt64) -> UInt8? {
        if row == 0 {
            return (index >> UInt64(columns - 1 - column)) & 1 == 1 ? Level.one : Level.zero
        }
        if noiseRows.contains(row) && noiseColumns.contains(column) { return nil }
        if column == Int(index % UInt64(columns)) { return Level.bar }
        return (column + row).isMultiple(of: 2) ? Level.dark : Level.light
    }

    static func render(_ index: UInt64, into pixels: CVPixelBuffer) throws {
        guard CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess else {
            throw CocoaError(.coderInvalidValue)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(
            to: UInt8.self)
        var state = UInt32(truncatingIfNeeded: index % 8 + 1)
        for y in 0..<height {
            let row = y * rows / height
            let line = luma + y * stride
            for column in 0..<columns {
                let start = column * width / columns
                let end = (column + 1) * width / columns
                if let value = expected(column: column, row: row, index: index) {
                    memset(line + start, Int32(value), end - start)
                } else {
                    for x in start..<end {
                        state = state &* 1_664_525 &+ 1_013_904_223
                        line[x] = 40 + UInt8(state >> 25)
                    }
                }
            }
        }
        memset(
            CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!, 128,
            CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * (height / 2))
    }

    /// Returns the frame index if every checked cell's center matches it.
    static func index(of pixels: CVPixelBuffer) -> UInt64? {
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        guard
            CVPixelBufferGetPixelFormatType(pixels)
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width >= columns, height >= rows,
            CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(
            to: UInt8.self)
        func sample(_ column: Int, _ row: Int) -> Int {
            Int(luma[(2 * row + 1) * height / (2 * rows) * stride + (2 * column + 1) * width / (2 * columns)])
        }
        var index: UInt64 = 0
        for column in 0..<columns {
            let value = sample(column, 0)
            // Reject anything too close to the threshold to read reliably.
            guard abs(value - 125) > 45 else { return nil }
            index = index << 1 | (value > 125 ? 1 : 0)
        }
        for row in 1..<rows {
            for column in 0..<columns {
                guard let expected = expected(column: column, row: row, index: index) else {
                    continue
                }
                if abs(sample(column, row) - Int(expected)) > 25 { return nil }
            }
        }
        return index
    }
}

/// Produces the pattern at a fixed rate, like a capture would.
final class TestPatternSource: ScreenFrameSource {
    let width: Int
    let height: Int
    private let framesPerSecond: Int32
    private let pool: CVPixelBufferPool
    private let started = DispatchTime.now().uptimeNanoseconds
    private var frame: ScreenFrame?

    struct InvalidSize: Error, CustomStringConvertible {
        var description: String {
            "The test pattern needs even dimensions from \(TestPattern.columns)x\(TestPattern.rows) to 8192x8192."
        }
    }

    init(width: Int, height: Int, framesPerSecond: Int32) throws {
        guard (TestPattern.columns...8192).contains(width), (TestPattern.rows...8192).contains(height),
            width.isMultiple(of: 2), height.isMultiple(of: 2), framesPerSecond > 0
        else { throw InvalidSize() }
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        self.pool = pool
    }

    func latestFrame() throws -> ScreenFrame? {
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let index = elapsed * UInt64(framesPerSecond) / 1_000_000_000 + 1
        let timestamp = CMTime(value: Int64(index), timescale: framesPerSecond)
        if frame?.timestamp != timestamp {
            var pixels: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixels)
            guard status == kCVReturnSuccess, let pixels else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            try TestPattern.render(index % TestPattern.indexModulus, into: pixels)
            frame = ScreenFrame(pixels: pixels, timestamp: timestamp)
        }
        return frame
    }

    nonisolated(nonsending) func stop() async throws {}
}

/// Checks that decoded frames show the pattern, in the order it was produced.
struct TestPatternVerifier {
    struct Mismatch: Error, CustomStringConvertible {
        let description: String
    }

    private(set) var verified: UInt64 = 0
    private var previous: UInt64?

    mutating func check(_ frame: VideoFrame) throws {
        guard let index = TestPattern.index(of: frame.pixels) else {
            throw Mismatch(description: "decoded image doesn't match the test pattern")
        }
        // A still picture is sent again, so the index may repeat but never go back.
        if let previous {
            let advance = (index &+ TestPattern.indexModulus &- previous) % TestPattern.indexModulus
            guard advance < TestPattern.indexModulus / 2 else {
                throw Mismatch(description: "test pattern went back from #\(previous) to #\(index)")
            }
        }
        previous = index
        verified += 1
    }
}
