#if os(macOS)
    import CoreVideo
    import Foundation
    import VideoToolbox

    /// Resize NV12 capture surfaces before encoding when the link cannot sustain the native size.
    final class ScreenScaler {
        let width: Int
        let height: Int
        private let pool: CVPixelBufferPool
        private let transfer: VTPixelTransferSession

        init(width: Int, height: Int) throws {
            self.width = width
            self.height = height
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
            var session: VTPixelTransferSession?
            let result = VTPixelTransferSessionCreate(
                allocator: nil, pixelTransferSessionOut: &session)
            guard result == noErr, let session else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
            }
            self.transfer = session
        }

        deinit { VTPixelTransferSessionInvalidate(transfer) }

        func resize(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
            var pixels: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixels)
            guard status == kCVReturnSuccess, let pixels else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            let result = VTPixelTransferSessionTransferImage(transfer, from: source, to: pixels)
            guard result == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
            }
            return pixels
        }
    }
#endif
