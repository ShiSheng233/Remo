#if os(macOS)
    import AppKit
    import AVFoundation
    import CoreMedia

    @MainActor
    private final class VideoView: NSView {
        let display = AVSampleBufferDisplayLayer()
        override func makeBackingLayer() -> CALayer { display }
    }

    @MainActor
    final class VideoWindow: NSObject, NSWindowDelegate {
        private let view = VideoView()
        private let window: NSWindow
        private let onClose: () -> Void
        private var loggedFirstFrame = false
        private var lastMetrics: SuspendingClock.Instant?

        init(title: String, onClose: @escaping () -> Void) {
            self.onClose = onClose
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                defer: false)
            super.init()
            window.title = title
            window.isReleasedWhenClosed = false
            window.delegate = self
            view.wantsLayer = true
            view.display.videoGravity = .resizeAspect
            view.display.backgroundColor = NSColor.black.cgColor
            window.contentView = view
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        func present(_ pixels: CVPixelBuffer, duration: CMTime) throws -> Bool {
            let layer = view.display
            if layer.status == .failed || layer.requiresFlushToResumeDecoding { layer.flush() }
            guard layer.isReadyForMoreMediaData else { return false }
            var format: CMVideoFormatDescription?
            var status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
            guard status == noErr, let format else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            // The capture host and display host have independent uptime clocks.
            let pts = CMClockGetTime(CMClockGetHostTimeClock())
            var timing = CMSampleTimingInfo(
                duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            status = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: nil, imageBuffer: pixels, formatDescription: format,
                sampleTiming: &timing, sampleBufferOut: &sample)
            guard status == noErr, let sample,
                let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sample, createIfNecessary: true)
            else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            let dict = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            layer.enqueue(sample)
            if !loggedFirstFrame, layer.status == .rendering {
                log(
                    "Displaying decoded video: \(CVPixelBufferGetWidth(pixels)) × \(CVPixelBufferGetHeight(pixels))"
                )
                loggedFirstFrame = true
            }
            let now = SuspendingClock.Instant.now
            if #available(macOS 14.4, *), lastMetrics.map({ now - $0 >= .seconds(5) }) ?? true {
                lastMetrics = now
                Task { @MainActor in
                    if let metrics = await layer.sampleBufferRenderer.videoPerformanceMetrics {
                        log(
                            "Renderer frames=\(metrics.totalNumberOfFrames) dropped=\(metrics.numberOfDroppedFrames)"
                        )
                    }
                }
            }
            return true
        }

        func windowWillClose(_ notification: Notification) { onClose() }

        func close() {
            window.delegate = nil
            view.display.flushAndRemoveImage()
            window.close()
        }
    }
#endif
