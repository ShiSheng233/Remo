import CoreMedia
import CoreVideo
import RemoCodec

/// A decoded picture handed to the application for display.
public struct VideoFrame {
    public let pixels: CVPixelBuffer
    public let presentationTime: CMTime
    public let duration: CMTime

    init(_ frame: DecodedVideoFrame) {
        pixels = frame.pixels
        presentationTime = frame.presentationTime
        duration = frame.duration
    }
}
