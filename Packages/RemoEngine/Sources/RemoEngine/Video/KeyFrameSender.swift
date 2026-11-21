import Foundation
import RemoTransport

/// Only one checkpoint is in flight per direction. Limit queued reliable bytes so control and
/// heartbeat traffic still progresses on slow links. The last acknowledgement means decoded.
final class KeyFrameSender {
    let id: UInt64
    let bytes: Data
    private var acknowledged = 0
    private var submitted = 0
    private var chunkSize = 1024
    private var pumping = false

    init(id: UInt64, bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= KeyFrameReceiver.limit else {
            throw WireFormatError.invalid
        }
        self.id = id
        self.bytes = bytes
    }

    func advance(to offset: Int) throws -> Bool {
        guard offset >= acknowledged, offset <= submitted else { throw WireFormatError.invalid }
        acknowledged = offset
        return offset == bytes.count
    }

    func pump(send: (Data, MessageTransport.Mode) throws -> Void) throws {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        while submitted < min(bytes.count, acknowledged + 4096) {
            let start = submitted
            let end = min(bytes.count, start + chunkSize, acknowledged + 4096)
            var chunk = Data([MessageKind.keyFrameChunk.rawValue])
            chunk.put(id)
            chunk.put(UInt32(bytes.count))
            chunk.put(UInt32(start))
            chunk.append(bytes[start..<end])
            submitted = end
            do { try send(chunk, .reliable) } catch NetworkMessageSession.SendError.backpressure {
                submitted = start
                return
            } catch NetworkMessageSession.SendError.invalidLength where chunkSize > 1 {
                submitted = start
                chunkSize /= 2
            }
        }
    }
}
