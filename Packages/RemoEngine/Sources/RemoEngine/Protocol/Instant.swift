/// A point on the engine's clock: monotonic and paused while the device sleeps, the same
/// uptime that RemoTransport measures.
typealias Instant = SuspendingClock.Instant

extension Instant {
    /// Whether `interval` has passed since `earlier`, or `earlier` never happened.
    func hasElapsed(_ interval: Duration, since earlier: Instant?) -> Bool {
        earlier.map { self - $0 >= interval } ?? true
    }
}
