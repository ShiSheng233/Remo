//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreGraphics
import Foundation
import ImageIO

/// The remote cursor, for the application to draw over the picture, which no longer shows it.
/// Everything is measured in shares of the picture, so it holds at any size or zoom.
public struct RemoteCursor {
    /// The hot spot, normalized to the picture, with the origin at its upper left.
    public var position: CGPoint
    /// Whether to draw it; false while it is off the captured display or before its picture
    /// has arrived.
    public var visible: Bool
    public var image: CGImage?
    /// The image's size as a share of the picture's width and height.
    public var size: CGSize
    /// Where the hot spot sits in the image, as a share of its width and height.
    public var hotSpot: CGPoint

    /// The image's frame in a picture drawn in `rect`, in the same upper-left-origin space.
    public func frame(in rect: CGRect) -> CGRect {
        let width = size.width * rect.width
        let height = size.height * rect.height
        return CGRect(
            x: rect.minX + position.x * rect.width - hotSpot.x * width,
            y: rect.minY + position.y * rect.height - hotSpot.y * height,
            width: width, height: height)
    }
}

extension RemoteCursor: Equatable {
    public static func == (a: Self, b: Self) -> Bool {
        a.position == b.position && a.visible == b.visible && a.image === b.image
            && a.size == b.size && a.hotSpot == b.hotSpot
    }
}

/// The client's view of the server's cursor: the newest state, and the shapes it has seen.
struct CursorTracker {
    struct Shape {
        let image: CGImage
        let size: CGSize
        let hotSpot: CGPoint
        var lastUse: UInt64
    }

    /// More than the server assumes a client holds, so a shape it doesn't send again is here.
    static let capacity = 256

    private(set) var state: CursorState?
    private var sequence: UInt64 = 0
    private var shapes: [UInt64: Shape] = [:]
    private var uses: UInt64 = 0
    /// The shape last shown, kept while the newest one is still on its way.
    private var shown: Shape?
    private var adoptedExternalMoves: UInt32?

    /// Returns false for a picture that doesn't decode.
    mutating func receive(_ shape: CursorShape) -> Bool {
        guard shapes[shape.id] == nil else { return true }
        guard let source = CGImageSourceCreateWithData(shape.png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        if shapes.count >= Self.capacity,
            let oldest = shapes.min(by: { $0.value.lastUse < $1.value.lastUse })?.key
        {
            shapes[oldest] = nil
        }
        uses += 1
        shapes[shape.id] = Shape(
            image: image, size: shape.size, hotSpot: shape.hotSpot, lastUse: uses)
        refreshShown()
        return true
    }

    /// Returns the position to adopt when something other than this client moved the
    /// cursor, or nil. Older states than one already seen change nothing.
    mutating func receive(sequence: UInt64, _ state: CursorState) -> CGPoint? {
        guard sequence > self.sequence else { return nil }
        self.sequence = sequence
        self.state = state
        refreshShown()
        guard adoptedExternalMoves != state.externalMoves else { return nil }
        adoptedExternalMoves = state.externalMoves
        return state.position
    }

    private mutating func refreshShown() {
        guard let id = state?.shapeID, var shape = shapes[id] else { return }
        uses += 1
        shape.lastUse = uses
        shapes[id] = shape
        shown = shape
    }

    /// The cursor to draw, at `position` when this client is driving it.
    func cursor(at position: CGPoint?, forceVisible: Bool) -> RemoteCursor? {
        guard let state else { return nil }
        let display = state.displaySize
        return RemoteCursor(
            position: position ?? state.position,
            visible: shown != nil && (state.visible || forceVisible),
            image: shown?.image,
            size: shown.map {
                CGSize(width: $0.size.width / display.width, height: $0.size.height / display.height)
            } ?? .zero,
            hotSpot: shown.map {
                CGPoint(x: $0.hotSpot.x / $0.size.width, y: $0.hotSpot.y / $0.size.height)
            } ?? .zero)
    }
}
