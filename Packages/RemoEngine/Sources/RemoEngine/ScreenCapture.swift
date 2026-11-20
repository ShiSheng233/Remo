import CoreMedia
import Foundation

#if os(macOS)
    import CoreGraphics
    import ScreenCaptureKit
#endif

/// A bounded source of screen frames. The consumer may poll at its own encoding cadence.
public protocol ScreenFrameSource: AnyObject {
    var width: Int { get }
    var height: Int { get }
    func latestSample() throws -> CMSampleBuffer?
    nonisolated(nonsending) func stop() async throws
}

#if os(macOS)
    @available(macOS 12.3, *)
    public struct ScreenCaptureConfiguration {
        public enum Failure: Error { case noMainDisplay, invalidConfiguration }
        private let filter: SCContentFilter
        public let width: Int
        public let height: Int
        public let framesPerSecond: Int32

        /// Resolves the main display and screen recording permission before accepting clients.
        public static func mainDisplay(maximumDimension: Int = 1920, framesPerSecond: Int32 = 30)
            async throws -> Self
        {
            try await mainDisplay(
                maximumWidth: maximumDimension, maximumHeight: maximumDimension,
                framesPerSecond: framesPerSecond)
        }

        public static func mainDisplay(
            maximumWidth: Int, maximumHeight: Int, framesPerSecond: Int32
        )
            async throws -> Self
        {
            guard maximumWidth >= 2, maximumHeight >= 2, framesPerSecond > 0 else {
                throw Failure.invalidConfiguration
            }
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard
                let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }),
                display.width > 0, display.height > 0
            else { throw Failure.noMainDisplay }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let pixelSize: CGSize
            if #available(macOS 14.0, *) {
                let rect = filter.contentRect
                let backingScale = CGFloat(filter.pointPixelScale)
                pixelSize = CGSize(width: rect.width * backingScale, height: rect.height * backingScale)
            } else {
                let mode = CGDisplayCopyDisplayMode(display.displayID)
                let backingScale: CGFloat
                if let mode, mode.width > 0, mode.pixelWidth > 0 {
                    backingScale = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
                } else {
                    backingScale = 1
                }
                pixelSize = CGSize(
                    width: CGFloat(display.width) * backingScale,
                    height: CGFloat(display.height) * backingScale)
            }
            guard pixelSize.width.isFinite, pixelSize.height.isFinite,
                pixelSize.width >= 2, pixelSize.height >= 2
            else { throw Failure.invalidConfiguration }
            let scale = min(
                1, CGFloat(maximumWidth) / pixelSize.width, CGFloat(maximumHeight) / pixelSize.height)
            func even(_ length: CGFloat) -> Int { max(2, Int(length * scale) / 2 * 2) }
            return Self(
                filter: filter, width: even(pixelSize.width), height: even(pixelSize.height),
                framesPerSecond: framesPerSecond)
        }

        public nonisolated(nonsending) func start() async throws -> any ScreenFrameSource {
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.queueDepth = 4
            config.showsCursor = true
            let output = ScreenOutput()
            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            try stream.addStreamOutput(
                output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "RemoEngine.screen")
            )
            try await stream.startCapture()
            return Capture(stream: stream, output: output, width: width, height: height)
        }
    }

    @available(macOS 12.3, *)
    private final class Capture: ScreenFrameSource {
        let stream: SCStream
        let output: ScreenOutput
        let width: Int
        let height: Int

        init(stream: SCStream, output: ScreenOutput, width: Int, height: Int) {
            self.stream = stream
            self.output = output
            self.width = width
            self.height = height
        }

        func latestSample() throws -> CMSampleBuffer? { try output.latest().get() }
        nonisolated(nonsending) func stop() async throws { try await stream.stopCapture() }
    }

    @available(macOS 12.3, *)
    private final class ScreenOutput: NSObject, SCStreamDelegate, SCStreamOutput {
        private let lock = NSLock()
        private var result: Result<CMSampleBuffer?, Error> = .success(nil)

        func latest() -> Result<CMSampleBuffer?, Error> {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            lock.lock()
            defer { lock.unlock() }
            result = .failure(error)
        }

        func stream(
            _ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {
            guard type == .screen, CMSampleBufferIsValid(sample),
                let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                CMSampleBufferGetImageBuffer(sample) != nil
            else { return }
            lock.lock()
            defer { lock.unlock() }
            if case .success = result { result = .success(sample) }
        }
    }
#endif
