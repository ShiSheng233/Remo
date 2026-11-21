import Foundation

/// Orders received audio by sequence and releases one 20 ms slot at a time on the playback clock.
struct AudioJitterBuffer {
    private var packets: [UInt64: AudioMessage] = [:]
    private static let capacity = 24
    private var nextTimestamp: Double?
    private var lastPlayed: UInt64?
    private(set) var latePackets = 0
    var isEmpty: Bool { packets.isEmpty }

    mutating func insert(_ packet: AudioMessage) -> Bool {
        if let lastPlayed, packet.sequence <= lastPlayed {
            latePackets += 1
            return false
        }
        if let nextTimestamp, Double(packet.timestamp) < nextTimestamp - 480 {
            latePackets += 1
            return false
        }
        packets[packet.sequence] = packet
        if packets.count > Self.capacity, let oldest = packets.keys.min() {
            packets.removeValue(forKey: oldest)
        }
        return true
    }

    /// The audio device advances this clock by one 20 ms slot per rendered buffer.
    mutating func pop() -> AudioMessage? {
        let first = packets.keys.min().flatMap { packets[$0] }
        guard let timestamp = nextTimestamp ?? first.map({ Double($0.timestamp) }) else { return nil }
        nextTimestamp = timestamp + 960
        guard let first, Double(first.timestamp) < timestamp + 480 else { return nil }
        packets.removeValue(forKey: first.sequence)
        lastPlayed = first.sequence
        nextTimestamp = Double(first.timestamp) + 960
        return first
    }

    var hasNextPacket: Bool {
        guard let id = packets.keys.min(), let packet = packets[id] else { return false }
        return nextTimestamp.map { Double(packet.timestamp) < $0 + 480 } ?? true
    }

    mutating func reanchor() { nextTimestamp = nil }
}
