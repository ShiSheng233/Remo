import AVFAudio
import Foundation
import CoreMedia
import RemoCodec
import Testing

@testable import RemoEngine

private func captureSample(offset: Int, length: Int) throws -> CMSampleBuffer {
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm, frameCapacity: UInt32(length)))
    pcm.frameLength = UInt32(length)
    for i in 0..<length {
        let value = Float(sin(Double(offset + i) * 0.1)) * 0.4
        for channel in 0..<2 { pcm.floatChannelData![channel][i] = value }
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: CMTime(value: Int64(offset), timescale: 48_000),
        decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    try #require(CMSampleBufferCreate(
        allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
        refcon: nil, formatDescription: pcm.format.formatDescription, sampleCount: length,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
        sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
    let result = try #require(sample)
    try #require(CMSampleBufferSetDataBufferFromAudioBufferList(
        result, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
        bufferList: pcm.audioBufferList) == noErr)
    return result
}

@Test func captureToOpusWithReorderingAndLoss() throws {
    let packetizer = try AudioPacketizer()
    var packets: [AudioMessage] = []
    for block in 0..<9 {
        try packetizer.append(captureSample(offset: block * 512, length: 512)) { packets.append($0) }
    }
    // A capture discontinuity discards the incomplete frame.
    try packetizer.append(captureSample(offset: 9000, length: 960)) { packets.append($0) }
    #expect(packets.map(\.timestamp) == [0, 960, 1920, 2880, 9000])
    try #require(packets.count == 5)
    var queue = AudioJitterBuffer()
    for i in [1, 0, 1, 3, 4] {
        let received = try AudioMessage(decoding: packets[i].encoded)
        let inserted = queue.insert(received)
        #expect(inserted)
    }
    let decoder = try OpusDecoder()
    for index in 0..<5 {
        if index == 2 {
            #expect(queue.pop() == nil)
            continue
        }
        if index == 4 {
            for _ in 0..<5 {
                let gap = queue.pop()
                #expect(gap == nil)
            }
        }
        let popped = queue.pop()
        let packet = try #require(popped)
        #expect(packet.sequence == UInt64(index))
        #expect(try decoder.decode(packet.opus).frameLength == 960)
    }
    let late = queue.insert(packets[2])
    #expect(!late)
    #expect(queue.isEmpty)
    #expect(throws: WireFormatError.self) { try AudioMessage(decoding: MessageKind.audio.encoded) }
}

@Test @MainActor func receivedAudioRendersWithoutOutputDevice() async throws {
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: OpusFormat.pcm, maximumFrameCount: 960)
    let player = AudioPlayback(engine: engine) { Issue.record("Playback failed: \($0)") }
    defer { player.stop() }
    let packetizer = try AudioPacketizer()
    try packetizer.append(captureSample(offset: 0, length: 2880)) { player.receive($0) }
    for _ in 0..<100 where !engine.isRunning { try await Task.sleep(nanoseconds: 5_000_000) }
    try #require(engine.isRunning)
    let rendered = try #require(AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm, frameCapacity: 960))
    var energy: Float = 0
    for _ in 0..<3 {
        if try engine.renderOffline(960, to: rendered) == .success {
            for i in 0..<Int(rendered.frameLength) {
                let value = rendered.floatChannelData![0][i]
                energy += value * value
            }
        }
        await Task.yield()
    }
    #expect(energy > 1)
}

@Test func audioDeadlinesTolerateVideoBurstsAndReordering() throws {
    // Serialize a 48 KB video burst every 200 ms at 5 Mbps, then vary network delay.
    var wireFreeMs = 0.0
    var arrivals: [(Int, AudioMessage)] = []
    for index in 0..<250 {
        let captureMs = index * 20
        wireFreeMs = max(wireFreeMs, Double(captureMs))
        if index.isMultiple(of: 10) { wireFreeMs += 48_000 * 8 / 5000 }
        wireFreeMs += 300 * 8 / 5000
        let jitterMs = index.isMultiple(of: 7) ? 35 : 4
        arrivals.append((Int(wireFreeMs.rounded(.up)) + jitterMs,
            AudioMessage(sequence: UInt64(index), timestamp: Int64(index * 960), opus: Data())))
    }
    arrivals.sort { $0.0 < $1.0 }
    var queue = AudioJitterBuffer()
    var arrival = 0
    for index in 0..<250 {
        // Allow two buffers of scheduling lead inside the 180 ms startup cushion.
        let deadline = 140 + index * 20
        while arrival < arrivals.count, arrivals[arrival].0 <= deadline {
            let accepted = queue.insert(arrivals[arrival].1)
            #expect(accepted)
            arrival += 1
        }
        let played = queue.pop()
        #expect(played?.sequence == UInt64(index))
    }
    #expect(queue.latePackets == 0)
}

@Test func emptyAudioSlotAdvancesClockAndRecovers() {
    var queue = AudioJitterBuffer()
    func packet(_ id: UInt64) -> AudioMessage {
        AudioMessage(sequence: id, timestamp: Int64(id) * 960, opus: Data())
    }
    _ = queue.insert(packet(0))
    _ = queue.pop()
    for _ in 0..<3 {
        let missing = queue.pop()
        #expect(missing == nil)
    }
    let late = queue.insert(packet(2))
    #expect(!late)
    _ = queue.insert(packet(4))
    let resumed = queue.pop()
    #expect(resumed?.sequence == 4)
    queue.reanchor()
    _ = queue.insert(packet(200))
    let afterPause = queue.pop()
    #expect(afterPause?.sequence == 200)
}

@Test(arguments: [1, 2]) @MainActor
func playbackUsesPLCAndReturnsToDecodedAudio(losses: Int) throws {
    var player = AudioConcealer()
    let decoder = try OpusDecoder()
    let reference = try OpusDecoder()
    let packetizer = try AudioPacketizer()
    var packets: [AudioMessage] = []
    try packetizer.append(captureSample(offset: 0, length: 960 * 16)) { packets.append($0) }
    for packet in packets {
        let lost = (10..<(10 + losses)).contains(Int(packet.sequence))
        let actualBuffer = player.render(lost ? nil : packet, using: decoder)
        let actual = try #require(actualBuffer)
        let expected = try lost ? reference.concealMissingFrame() : reference.decode(packet.opus)
        for channel in 0..<2 {
            let diff = (0..<960).map {
                abs(actual.floatChannelData![channel][$0] - expected.floatChannelData![channel][$0])
            }.max()!
            #expect(diff < 0.0001)
        }
    }
    #expect(player.concealedPackets == losses)
    #expect(player.fadeFallbacks == 0)
}

@Test @MainActor func playbackFadesWhenPLCIsUnavailable() throws {
    var player = AudioConcealer()
    let packetizer = try AudioPacketizer()
    var packets: [AudioMessage] = []
    try packetizer.append(captureSample(offset: 0, length: 2880)) { packets.append($0) }
    let decoder = try OpusDecoder()
    _ = player.render(packets[0], using: decoder)
    let beforeBuffer = player.render(packets[1], using: decoder)
    let before = try #require(beforeBuffer)
    let fresh = try OpusDecoder()
    let gapBuffer = player.render(nil, using: fresh)
    let gap = try #require(gapBuffer)
    let resumedBuffer = player.render(packets[2], using: decoder)
    let resumed = try #require(resumedBuffer)
    for channel in 0..<2 {
        let end = before.floatChannelData![channel][959]
        #expect(abs(end) > 0.001)
        #expect(abs(gap.floatChannelData![channel][0] - end * 119 / 120) < 0.00001)
        #expect(gap.floatChannelData![channel][120] == 0)
        #expect(resumed.floatChannelData![channel][0] == 0)
    }
    #expect(player.concealedPackets == 1)
    #expect(player.fadeFallbacks == 1)
}

@Test @MainActor func playbackRemainsContinuousWhileMainThreadIsBlocked() async throws {
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: OpusFormat.pcm, maximumFrameCount: 960)
    let player = AudioPlayback(engine: engine) { Issue.record("Playback failed: \($0)") }
    defer { player.stop() }
    let packetizer = try AudioPacketizer()
    try packetizer.append(captureSample(offset: 0, length: 960 * 18)) { player.receive($0) }
    for _ in 0..<150 where !engine.isRunning { try await Task.sleep(nanoseconds: 5_000_000) }
    try #require(engine.isRunning)
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm, frameCapacity: 960))

    // Advance the device at real-time speed without yielding the main actor. The initial
    // three scheduled buffers cannot cover all nine render quanta.
    for block in 0..<9 {
        usleep(20_000)
        try #require(engine.renderOffline(960, to: pcm) == .success)
        if block >= 3 {
            let samples = pcm.floatChannelData![0]
            let energy = (0..<960).reduce(Float.zero) { $0 + samples[$1] * samples[$1] }
            #expect(energy > 1)
        }
    }
    #expect(player.concealedPackets == 0)
    #expect(player.rebufferCount == 0)
}

@Test @MainActor func stoppingDuringAudioStartupCancelsPendingPlayback() async throws {
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: OpusFormat.pcm, maximumFrameCount: 960)
    let player = AudioPlayback(engine: engine) { Issue.record("Playback failed: \($0)") }
    let packetizer = try AudioPacketizer()
    try packetizer.append(captureSample(offset: 0, length: 960)) { player.receive($0) }
    player.stop()
    try await Task.sleep(nanoseconds: 250_000_000)
    #expect(!engine.isRunning)
}
