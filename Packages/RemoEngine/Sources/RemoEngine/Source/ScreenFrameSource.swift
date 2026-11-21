/// Frames for a server to stream, such as a display capture. The server polls it at its own
/// frame rate, sends only new pictures and re-sends a still one periodically so a client can
/// recover. The size stays fixed for the whole session.
///
/// A server starts one source per client and calls it only from the main actor.
public protocol ScreenFrameSource: AnyObject {
    var width: Int { get }
    var height: Int { get }
    /// The newest complete picture, or nil before the first. Throwing ends the client's session.
    func latestFrame() throws -> ScreenFrame?
    nonisolated(nonsending) func stop() async throws
}
