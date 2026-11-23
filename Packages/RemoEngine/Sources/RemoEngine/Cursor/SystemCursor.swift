//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

#if os(macOS)
    import AppKit
    import CoreGraphics
    import ImageIO

    /// Maps between a display's global coordinates and the normalized positions on the wire.
    struct DisplayGeometry {
        let bounds: CGRect

        init?(displayID: CGDirectDisplayID) {
            let bounds = CGDisplayBounds(displayID)
            guard !bounds.isEmpty, bounds.width >= 1, bounds.height >= 1 else { return nil }
            self.bounds = bounds
        }

        func normalize(_ location: CGPoint) -> CGPoint {
            CGPoint(
                x: min(1, max(0, (location.x - bounds.minX) / max(1, bounds.width - 1))),
                y: min(1, max(0, (location.y - bounds.minY) / max(1, bounds.height - 1))))
        }

        func location(of position: CGPoint) -> CGPoint {
            CGPoint(
                x: bounds.minX + position.x * max(0, bounds.width - 1),
                y: bounds.minY + position.y * max(0, bounds.height - 1))
        }
    }

    /// Reads the system-wide cursor: where it is and what it looks like.
    ///
    /// Fetching the picture costs up to a few milliseconds, so it is fetched only when the
    /// window server's private cursor seed says it changed.
    @MainActor
    final class SystemCursor {
        private typealias SeedFunction = @convention(c) () -> Int32

        private let displayID: CGDirectDisplayID
        private let seed: SeedFunction?
        private var lastSeed: Int32?
        private var polls = 0
        private var shape: CursorShape?
        private var shapes: [UInt64: CursorShape] = [:]

        init(displayID: CGDirectDisplayID) {
            self.displayID = displayID
            let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSCurrentCursorSeed")
            seed = symbol.map { unsafeBitCast($0, to: SeedFunction.self) }
        }

        func sample() -> CursorSample? {
            guard let geometry = DisplayGeometry(displayID: displayID),
                let location = CGEvent(source: nil)?.location
            else { return nil }
            let bounds = geometry.bounds
            polls += 1
            if let seed {
                let current = seed()
                if current != lastSeed {
                    lastSeed = current
                    shape = currentShape() ?? shape
                }
            } else if shape == nil || polls % 6 == 0 {
                shape = currentShape() ?? shape
            }
            return CursorSample(
                position: geometry.normalize(location),
                visible: location.x >= bounds.minX && location.x < bounds.maxX
                    && location.y >= bounds.minY && location.y < bounds.maxY,
                displaySize: bounds.size, shape: shape)
        }

        private func currentShape() -> CursorShape? {
            guard let cursor = NSCursor.currentSystem else { return nil }
            let image = cursor.image
            let size = image.size
            guard size.width > 0, size.height > 0, size.width <= CursorShape.maximumSize,
                size.height <= CursorShape.maximumSize
            else { return nil }
            let largest = image.representations.map(\.pixelsWide).max() ?? 0
            let scale = max(1, min(4, (CGFloat(largest) / size.width).rounded()))
            let width = Int((size.width * scale).rounded())
            let height = Int((size.height * scale).rounded())
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            guard let pixels = context.data else { return nil }

            // FNV-1a over the pixels and the geometry names the picture.
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            func mix(_ bytes: UnsafeRawBufferPointer) {
                for byte in bytes {
                    hash ^= UInt64(byte)
                    hash &*= 0x100_0000_01b3
                }
            }
            mix(UnsafeRawBufferPointer(start: pixels, count: width * height * 4))
            for value in [size.width, size.height, cursor.hotSpot.x, cursor.hotSpot.y] {
                withUnsafeBytes(of: Double(value).bitPattern) { mix($0) }
            }
            if hash == 0 { hash = 1 }
            if let known = shapes[hash] { return known }

            guard let picture = context.makeImage() else { return nil }
            let png = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    png, "public.png" as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, picture, nil)
            guard CGImageDestinationFinalize(destination), png.length > 0,
                png.length <= CursorShape.maximumPNGBytes
            else { return nil }
            let hotSpot = CGPoint(
                x: min(size.width, max(0, cursor.hotSpot.x)),
                y: min(size.height, max(0, cursor.hotSpot.y)))
            let shape = CursorShape(id: hash, size: size, hotSpot: hotSpot, png: png as Data)
            // Animated cursors cycle through a handful of pictures.
            if shapes.count >= 64 { shapes.removeAll() }
            shapes[hash] = shape
            return shape
        }
    }
#endif
