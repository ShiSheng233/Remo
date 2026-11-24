#if os(macOS)
    import CoreGraphics
    import CoreMedia
    import Foundation
    import ScreenCaptureKit

    /// Captures the main display, and optionally system audio, with ScreenCaptureKit.
    final class DisplayCapture: NotifyingScreenFrameSource, AudioSource {
        /// A resolved display and capture size, made before any client connects.
        struct Configuration {
            enum Failure: Error { case noMainDisplay, invalidConfiguration }
            private let filter: SCContentFilter
            let width: Int
            let height: Int
            let framesPerSecond: Int32

            /// Resolves the main display and screen recording permission, returning its native
            /// pixel dimensions.
            static func discoverMainDisplay() async throws -> (width: Int, height: Int) {
                let (_, pixelSize) = try await resolveMainDisplay()
                return (Int(pixelSize.width.rounded()), Int(pixelSize.height.rounded()))
            }

            /// Resolves the main display and screen recording permission, and scales its pixel
            /// size to fit within the maximum, keeping its aspect ratio.
            static func mainDisplay(
                maximumWidth: Int, maximumHeight: Int, framesPerSecond: Int32
            ) async throws -> Self {
                guard maximumWidth >= 2, maximumHeight >= 2, framesPerSecond > 0 else {
                    throw Failure.invalidConfiguration
                }
                let (filter, pixelSize) = try await resolveMainDisplay()
                let scale = min(
                    1, CGFloat(maximumWidth) / pixelSize.width,
                    CGFloat(maximumHeight) / pixelSize.height)
                func even(_ length: CGFloat) -> Int { max(2, Int(length * scale) / 2 * 2) }
                return Self(
                    filter: filter, width: even(pixelSize.width), height: even(pixelSize.height),
                    framesPerSecond: framesPerSecond)
            }

            private static func resolveMainDisplay() async throws -> (SCContentFilter, CGSize) {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                guard
                    let display = content.displays.first(where: {
                        $0.displayID == CGMainDisplayID()
                    }),
                    display.width > 0, display.height > 0
                else { throw Failure.noMainDisplay }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let pixelSize: CGSize
                if #available(macOS 14.0, *) {
                    let rect = filter.contentRect
                    let backingScale = CGFloat(filter.pointPixelScale)
                    pixelSize = CGSize(
                        width: rect.width * backingScale, height: rect.height * backingScale)
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
                return (filter, pixelSize)
            }

            nonisolated(nonsending) func start(
                capturesAudio: Bool = false, audioTraceDirectory: URL? = nil
            ) async throws -> DisplayCapture {
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
                config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                config.queueDepth = 4
                // Clients draw the cursor themselves from `CursorMessage`s.
                config.showsCursor = false
                if capturesAudio {
                    config.capturesAudio = true
                    config.sampleRate = 48_000
                    config.channelCount = 2
                }
                let output = try Output(
                    capturesAudio: capturesAudio, audioTraceDirectory: audioTraceDirectory)
                let stream = SCStream(filter: filter, configuration: config, delegate: output)
                try stream.addStreamOutput(
                    output, type: .screen,
                    sampleHandlerQueue: DispatchQueue(label: "RemoEngine.screen"))
                if capturesAudio {
                    try stream.addStreamOutput(
                        output, type: .audio,
                        sampleHandlerQueue: DispatchQueue(label: "RemoEngine.audio"))
                }
                try await stream.startCapture()
                return DisplayCapture(stream: stream, output: output, width: width, height: height)
            }
        }

        private let stream: SCStream
        private let output: Output
        let width: Int
        let height: Int

        private init(stream: SCStream, output: Output, width: Int, height: Int) {
            self.stream = stream
            self.output = output
            self.width = width
            self.height = height
        }

        var audioMessages: AsyncThrowingStream<AudioMessage, Error> { output.audioMessages }
        var frameArrivals: AsyncStream<Void> { output.frameArrivals }

        func latestFrame() throws -> ScreenFrame? {
            guard let sample = try output.latest().get(),
                let pixels = CMSampleBufferGetImageBuffer(sample)
            else { return nil }
            return ScreenFrame(
                pixels: pixels, timestamp: CMSampleBufferGetPresentationTimeStamp(sample))
        }

        nonisolated(nonsending) func stop() async throws {
            defer { output.finish() }
            try await stream.stopCapture()
        }

        /// Keeps the newest complete frame and packetizes audio on ScreenCaptureKit's queues.
        private final class Output: NSObject, SCStreamDelegate, SCStreamOutput {
            private let lock = NSLock()
            private var result: Result<CMSampleBuffer?, Error> = .success(nil)

            private let packetizer: AudioPacketizer?
            let audioMessages: AsyncThrowingStream<AudioMessage, Error>
            private let continuation: AsyncThrowingStream<AudioMessage, Error>.Continuation
            let frameArrivals: AsyncStream<Void>
            private let frameContinuation: AsyncStream<Void>.Continuation

            init(capturesAudio: Bool, audioTraceDirectory: URL?) throws {
                packetizer =
                    capturesAudio ? try AudioPacketizer(traceDirectory: audioTraceDirectory) : nil
                var sink: AsyncThrowingStream<AudioMessage, Error>.Continuation!
                audioMessages = AsyncThrowingStream(bufferingPolicy: .bufferingNewest(3)) {
                    sink = $0
                }
                continuation = sink
                var frameSink: AsyncStream<Void>.Continuation!
                frameArrivals = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
                    frameSink = $0
                }
                frameContinuation = frameSink
                super.init()
                if !capturesAudio { continuation.finish() }
            }

            func finish() {
                continuation.finish()
                frameContinuation.finish()
            }

            func latest() -> Result<CMSampleBuffer?, Error> {
                lock.lock()
                defer { lock.unlock() }
                return result
            }

            func stream(_ stream: SCStream, didStopWithError error: Error) {
                lock.lock()
                defer { lock.unlock() }
                result = .failure(error)
                continuation.finish(throwing: error)
                frameContinuation.finish()
            }

            func stream(
                _ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                of type: SCStreamOutputType
            ) {
                if type == .audio, let packetizer {
                    do {
                        try packetizer.append(sample) { continuation.yield($0) }
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }
                guard type == .screen, CMSampleBufferIsValid(sample),
                    let info = CMSampleBufferGetSampleAttachmentsArray(
                        sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                    let raw = info.first?[.status] as? Int,
                    SCFrameStatus(rawValue: raw) == .complete,
                    CMSampleBufferGetImageBuffer(sample) != nil
                else { return }
                lock.lock()
                let updated: Bool
                if case .success = result {
                    result = .success(sample)
                    updated = true
                } else {
                    updated = false
                }
                lock.unlock()
                if updated { frameContinuation.yield(()) }
            }
        }
    }
#endif
