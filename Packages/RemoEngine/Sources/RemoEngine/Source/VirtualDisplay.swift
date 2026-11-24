//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

#if os(macOS)
    import CVirtualDisplay
    import CoreGraphics
    import Dispatch
    import Foundation

    /// Creates and manages a macOS @2x HiDPI virtual display backed by CoreGraphics' private
    /// `CGVirtualDisplay` API.
    ///
    /// Keeping this object alive keeps the display attached; calling `destroy()` releases it inside
    /// an `autoreleasepool` so macOS removes it immediately rather than waiting for an outer pool.
    @MainActor
    final class VirtualDisplay {
        enum Failure: Error, CustomStringConvertible {
            case invalidSize
            case creationFailed
            case applySettingsFailed
            case notReady
            case terminated

            var description: String {
                switch self {
                case .invalidSize:
                    "Virtual display logical size must be 800...3600 × 600...3600 pt."
                case .creationFailed:
                    "Failed to create virtual display."
                case .applySettingsFailed:
                    "Failed to apply virtual display HiDPI settings."
                case .notReady:
                    "Virtual display did not become ready within 3 seconds."
                case .terminated:
                    "Virtual display was terminated by the system."
                }
            }
        }

        private final class WeakBox {
            weak var display: VirtualDisplay?
            init(_ display: VirtualDisplay) { self.display = display }
        }

        /// Fixed vendor and product IDs so macOS remembers display arrangement across reconnects.
        private static let vendorID: UInt32 = 0x5245
        private static let productID: UInt32 = 0x4D4F
        /// Minimum gap between consecutive virtual display create/destroy operations to keep
        /// WindowServer stable.
        private static let lifecycleCooldown: Duration = .seconds(1)
        private static var activeDisplays: [UInt32: WeakBox] = [:]
        private static var lastLifecycleChange: ContinuousClock.Instant?

        private var display: CGVirtualDisplay?
        private let serialNum: UInt32
        let displayID: CGDirectDisplayID
        let logicalWidth: Int
        let logicalHeight: Int
        var pixelWidth: Int { logicalWidth * 2 }
        var pixelHeight: Int { logicalHeight * 2 }
        var onTerminate: (@MainActor () -> Void)?

        private init(
            display: CGVirtualDisplay, serialNum: UInt32, logicalWidth: Int, logicalHeight: Int
        ) {
            self.display = display
            self.serialNum = serialNum
            self.displayID = display.displayID
            self.logicalWidth = logicalWidth
            self.logicalHeight = logicalHeight
        }

        /// Destroys every live virtual display synchronously. Safe to call on app termination.
        static func destroyAll() {
            let live = activeDisplays.values.compactMap(\.display)
            for display in live {
                display.destroy()
            }
            activeDisplays.removeAll()
        }

        /// Creates a @2x HiDPI virtual display and waits until macOS activates its expected mode.
        /// If readiness polling fails or the task is cancelled, the display is destroyed immediately.
        static func create(
            specification: StreamParameters.VirtualDisplay,
            name: String = "Remo Virtual Display"
        ) async throws -> VirtualDisplay {
            guard specification.isValid else { throw Failure.invalidSize }
            if let last = lastLifecycleChange {
                let target = last + lifecycleCooldown
                if ContinuousClock.now < target {
                    try await Task.sleep(until: target, clock: .continuous)
                }
            }
            try Task.checkCancellation()

            // Prune any deallocated entries and pick the lowest available serial starting at 1 so
            // single-client sessions reuse serial 1 and preserve macOS arrangement.
            activeDisplays = activeDisplays.filter { $0.value.display != nil }
            var serial: UInt32 = 1
            while activeDisplays[serial] != nil { serial += 1 }

            // Ensure CoreGraphics has initialized its display subsystem before allocating the class.
            _ = CGMainDisplayID()

            let pixelWidth = specification.pixelWidth
            let pixelHeight = specification.pixelHeight
            let mmPerPixel = 25.4 / 220.0

            let descriptor = CGVirtualDisplayDescriptor()
            descriptor.name = name
            // Dedicated serial queue: using `.main` can deadlock against WindowServer on macOS.
            descriptor.queue = DispatchQueue(label: "RemoEngine.virtual-display.\(serial)")
            descriptor.maxPixelsWide = UInt32(pixelWidth)
            descriptor.maxPixelsHigh = UInt32(pixelHeight)
            descriptor.sizeInMillimeters = CGSize(
                width: Double(pixelWidth) * mmPerPixel,
                height: Double(pixelHeight) * mmPerPixel)
            descriptor.vendorID = vendorID
            descriptor.productID = productID
            descriptor.serialNum = serial

            // Box reference filled right after init so terminationHandler can notify the owner.
            final class CallbackBox: @unchecked Sendable {
                weak var owner: VirtualDisplay?
            }
            let callbackBox = CallbackBox()
            descriptor.terminationHandler = { _, _ in
                Task { @MainActor in
                    callbackBox.owner?.handleSystemTermination()
                }
            }

            var cgDisplay: CGVirtualDisplay? = CGVirtualDisplay(descriptor: descriptor)
            guard let created = cgDisplay, created.displayID != 0 else {
                autoreleasepool { cgDisplay = nil }
                throw Failure.creationFailed
            }

            let settings = CGVirtualDisplaySettings()
            settings.hiDPI = 1
            settings.modes = [
                CGVirtualDisplayMode(
                    width: UInt32(specification.logicalWidth),
                    height: UInt32(specification.logicalHeight),
                    refreshRate: 60)
            ]
            guard created.apply(settings) else {
                autoreleasepool { cgDisplay = nil }
                lastLifecycleChange = .now
                throw Failure.applySettingsFailed
            }

            let instance = VirtualDisplay(
                display: created, serialNum: serial,
                logicalWidth: specification.logicalWidth,
                logicalHeight: specification.logicalHeight)
            cgDisplay = nil
            callbackBox.owner = instance
            activeDisplays[serial] = WeakBox(instance)
            lastLifecycleChange = .now

            do {
                try await instance.waitUntilReady(timeout: .seconds(3))
            } catch {
                instance.destroy()
                throw error
            }
            return instance
        }

        /// Releases the underlying `CGVirtualDisplay` immediately inside an `autoreleasepool`.
        func destroy() {
            guard display != nil else { return }
            onTerminate = nil
            autoreleasepool { display = nil }
            Self.activeDisplays.removeValue(forKey: serialNum)
            Self.lastLifecycleChange = .now
        }

        private func handleSystemTermination() {
            let handler = onTerminate
            destroy()
            handler?()
        }

        private func waitUntilReady(timeout: Duration) async throws {
            let deadline = ContinuousClock.now + timeout
            while true {
                try Task.checkCancellation()
                Self.refreshDisplayCache(displayID)
                if isExpectedMode(CGDisplayCopyDisplayMode(displayID)) {
                    return
                }
                let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
                let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
                if let match = modes.first(where: {
                    isExpectedMode($0) && $0.isUsableForDesktopGUI()
                }) {
                    var config: CGDisplayConfigRef?
                    if CGBeginDisplayConfiguration(&config) == .success, let config {
                        CGConfigureDisplayWithDisplayMode(config, displayID, match, nil)
                        CGCompleteDisplayConfiguration(config, .permanently)
                    }
                    if isExpectedMode(CGDisplayCopyDisplayMode(displayID)) {
                        return
                    }
                }
                if ContinuousClock.now >= deadline {
                    throw Failure.notReady
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        private func isExpectedMode(_ mode: CGDisplayMode?) -> Bool {
            guard let mode else { return false }
            return mode.width == logicalWidth
                && mode.height == logicalHeight
                && mode.pixelWidth == pixelWidth
                && mode.pixelHeight == pixelHeight
        }

        /// Submits a no-op origin configuration so this process refreshes its CoreGraphics display
        /// cache and can observe the newly created virtual display.
        private static func refreshDisplayCache(_ id: CGDirectDisplayID) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
            let origin = CGDisplayBounds(id).origin
            CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
            CGCompleteDisplayConfiguration(config, .permanently)
        }
    }
#endif
