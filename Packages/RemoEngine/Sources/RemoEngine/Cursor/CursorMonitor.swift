//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import Foundation

/// One reading of the system cursor.
struct CursorSample: Equatable {
    /// Normalized to the captured display, with the origin at its upper left.
    var position: CGPoint
    var visible: Bool
    /// The captured display's size in points.
    var displaySize: CGSize
    var shape: CursorShape?
}

/// Watches the cursor for every client of a server while any is subscribed, and tells moves
/// the server made for the controlling client apart from moves made by anything else.
@MainActor
final class CursorMonitor {
    typealias Handler = @MainActor (CursorState, CursorShape?) -> Void

    /// How long a posted pointer event may take to show up in the cursor's position.
    static let settleTime = Duration.milliseconds(120)
    /// A still cursor is published again this often, in case a client missed it.
    static let republishInterval = Duration.milliseconds(500)

    private let interval: Duration
    private let sample: @MainActor () -> CursorSample?
    private var handlers: [UUID: Handler] = [:]
    private var task: Task<Void, Never>?
    private var state: CursorState?
    private var shape: CursorShape?
    private var publishedAt: Instant?
    /// Where the cursor should be if nothing but the server moves it.
    private var anchor: CGPoint?
    private var postedAt: Instant?
    private var externalMoves: UInt32 = 0

    init(interval: Duration, sample: @escaping @MainActor () -> CursorSample?) {
        self.interval = interval
        self.sample = sample
    }

    /// The handler hears the current cursor right away, then every change.
    func subscribe(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        handlers[id] = handler
        if let state { handler(state, shape) }
        if task == nil {
            task = Task { [weak self] in
                while let monitor = self, !Task.isCancelled {
                    monitor.poll(now: .now)
                    let interval = monitor.interval
                    try? await Task.sleep(for: interval)
                }
            }
        }
        return id
    }

    func unsubscribe(_ id: UUID) {
        handlers[id] = nil
        guard handlers.isEmpty else { return }
        task?.cancel()
        task = nil
    }

    /// The server posted a pointer event at this position for the controlling client.
    func notePosted(_ position: CGPoint, now: Instant = .now) {
        anchor = position
        postedAt = now
    }

    func poll(now: Instant) {
        guard let reading = sample() else { return }
        if now.hasElapsed(Self.settleTime, since: postedAt) {
            if let anchor, distance(anchor, reading.position, in: reading.displaySize) > 1 {
                externalMoves &+= 1
            }
            anchor = reading.position
        }
        let state = CursorState(
            position: reading.position, visible: reading.visible,
            displaySize: reading.displaySize, shapeID: reading.shape?.id ?? self.state?.shapeID,
            externalMoves: externalMoves)
        if let shape = reading.shape { self.shape = shape }
        guard state != self.state || now.hasElapsed(Self.republishInterval, since: publishedAt)
        else { return }
        self.state = state
        publishedAt = now
        for handler in handlers.values { handler(state, shape) }
    }

    /// In points.
    private func distance(_ a: CGPoint, _ b: CGPoint, in size: CGSize) -> CGFloat {
        hypot((a.x - b.x) * size.width, (a.y - b.y) * size.height)
    }
}
