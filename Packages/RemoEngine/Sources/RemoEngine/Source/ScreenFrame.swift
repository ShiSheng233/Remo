import CoreMedia
import CoreVideo

/// One picture from a `ScreenFrameSource`.
public struct ScreenFrame {
    /// 4:2:0 bi-planar video-range pixels (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`)
    /// at the source's size.
    public let pixels: CVPixelBuffer
    /// When the picture was produced. A new picture must have a new timestamp.
    public let timestamp: CMTime

    public init(pixels: CVPixelBuffer, timestamp: CMTime) {
        self.pixels = pixels
        self.timestamp = timestamp
    }
}
