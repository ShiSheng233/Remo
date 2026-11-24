#if os(macOS)
    import CoreGraphics
    import CoreMedia
    import Foundation
    import ScreenCaptureKit

    /// Captures a macOS display (the main display or a virtual display), and optionally system
    /// audio, with ScreenCaptureKit.
    final class DisplayCapture: NotifyingScreenFrameSource, AudioSource, DisplayScreenFrameSource {
        /// A resolved display and capture size.
        struct Configuration {
            enum Failure: Error { case displayNotFound, invalidConfiguration }
            private let filter: SCContentFilter
            let displayID: CGDirectDisplayID
            let width: Int
            let height: Int
            let framesPerSecond: Int32

            /// Resolves the main display and screen recording permission, returning its native
            /// pixel dimensions.
            static func discoverMainDisplay() async throws -> (width: Int, height: Int) {
                let (_, pixelSize) = try await resolveDisplay(displayID: CGMainDisplayID())
                return (Int(pixelSize.width.rounded()), Int(pixelSize.height.rounded()))
            }

            /// Resolves the main display and scales its pixel size to fit within the maximum,
            /// keeping its aspect ratio.
            static func mainDisplay(
                maximumWidth: Int, maximumHeight: Int, framesPerSecond: Int32
            ) async throws -> Self {
                try await display(
                    displayID: CGMainDisplayID(),
                    maximumWidth: maximumWidth, maximumHeight: maximumHeight,
                    framesPerSecond: framesPerSecond)
            }

            /// Resolves a specific display (such as a newly created virtual display, retrying until
            /// ScreenCaptureKit lists it) and optionally scales its pixel size to fit within a cap.
            static func display(
                displayID: CGDirectDisplayID,
                maximumWidth: Int?, maximumHeight: Int?,
                framesPerSecond: Int32,
                retryAttempts: Int = 1,
                retryDelay: Duration = .milliseconds(250)
            ) async throws -> Self {
                guard framesPerSecond > 0 else { throw Failure.invalidConfiguration }
                if let maximumWidth, maximumWidth < 2 { throw Failure.invalidConfiguration }
                if let maximumHeight, maximumHeight < 2 { throw Failure.invalidConfiguration }
                let (filter, pixelSize) = try await resolveDisplay(
                    displayID: displayID, retryAttempts: retryAttempts, retryDelay: retryDelay)
                let capWidth = CGFloat(maximumWidth ?? StreamParameters.Size.validRange.upperBound)
                let capHeight = CGFloat(maximumHeight ?? StreamParameters.Size.validRange.upperBound)
                let scale = min(1, capWidth / pixelSize.width, capHeight / pixelSize.height)
                func even(_ length: CGFloat) -> Int { max(2, Int(length * scale) / 2 * 2) }
                return Self(
                    filter: filter, displayID: displayID,
                    width: even(pixelSize.width), height: even(pixelSize.height),
                    framesPerSecond: framesPerSecond)
            }

            private static func resolveDisplay(
                displayID: CGDirectDisplayID,
                retryAttempts: Int = 1,
                retryDelay: Duration = .milliseconds(250)
            ) async throws -> (SCContentFilter, CGSize) {
                let attempts = max(1, retryAttempts)
                var display: SCDisplay?
                for attempt in 0..<attempts {
                    try Task.checkCancellation()
                    let content = try await SCShareableContent.excludingDesktopWindows(
                        false, onScreenWindowsOnly: true)
                    if let match = content.displays.first(where: {
                        $0.displayID == displayID && $0.width > 0 && $0.height > 0
                    }) {
                        display = match
                        break
                    }
                    if attempt + 1 < attempts {
                        try await Task.sleep(for: retryDelay)
                    }
                }
                guard let display else { throw Failure.displayNotFound }
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

            @MainActor
            func start(
                capturesAudio: Bool = false, audioTraceDirectory: URL? = nil,
                virtualDisplay: VirtualDisplay? = nil
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
                virtualDisplay?.onTerminate = { [weak output] in
                    output?.fail(VirtualDisplay.Failure.terminated)
                }
                return DisplayCapture(
                    stream: stream, output: output, displayID: displayID,
                    width: width, height: height, virtualDisplay: virtualDisplay)
            }
        }

        private let stream: SCStream
        private let output: Output
        private let virtualDisplay: VirtualDisplay?
        let displayID: CGDirectDisplayID
        let width: Int
        let height: Int
        var isVirtualDisplay: Bool { virtualDisplay != nil }

        private init(
            stream: SCStream, output: Output, displayID: CGDirectDisplayID,
            width: Int, height: Int, virtualDisplay: VirtualDisplay?
        ) {
            self.stream = stream
            self.output = output
            self.displayID = displayID
            self.width = width
            self.height = height
            self.virtualDisplay = virtualDisplay
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
            do {
                try await stream.stopCapture()
            } catch {
                if let virtualDisplay {
                    await virtualDisplay.destroy()
                }
                throw error
            }
            if let virtualDisplay {
                await virtualDisplay.destroy()
            }
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

            func fail(_ error: Error) {
                lock.lock()
                result = .failure(error)
                lock.unlock()
                continuation.finish(throwing: error)
                frameContinuation.finish()
            }

            func stream(_ stream: SCStream, didStopWithError error: Error) {
                fail(error)
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
