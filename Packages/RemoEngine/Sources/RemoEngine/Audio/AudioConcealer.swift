import AVFAudio
import Foundation
import RemoCodec

/// Turns the next slot into PCM: decoded audio, Opus concealment for a gap, or a short fade
/// when concealment fails.
struct AudioConcealer {
    var consecutiveGaps = 0
    private var needsFadeIn = false
    private var lastSamples: [Float] = [0, 0]
    private(set) var decodeFailures = 0
    private(set) var concealedPackets = 0
    private(set) var fadeFallbacks = 0

    mutating func resetHistory() {
        consecutiveGaps = 0
        needsFadeIn = false
        lastSamples = [0, 0]
    }

    mutating func render(_ packet: AudioMessage?, using decoder: OpusDecoder) -> AVAudioPCMBuffer? {
        let pcm: AVAudioPCMBuffer
        if let packet, let decoded = try? decoder.decode(packet.opus) {
            pcm = decoded
            consecutiveGaps = 0
        } else {
            if packet != nil { decodeFailures += 1 }
            consecutiveGaps += 1
            concealedPackets += 1
            if let concealed = try? decoder.concealMissingFrame() {
                pcm = concealed
            } else {
                guard let silence = AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm, frameCapacity: 960)
                else { return nil }
                silence.frameLength = 960
                for channel in 0..<2 {
                    let samples = silence.floatChannelData![channel]
                    samples.update(repeating: 0, count: 960)
                    for i in 0..<120 { samples[i] = lastSamples[channel] * Float(119 - i) / 120 }
                    lastSamples[channel] = 0
                }
                fadeFallbacks += 1
                needsFadeIn = true
                return silence
            }
        }
        for channel in 0..<2 {
            let samples = pcm.floatChannelData![channel]
            if needsFadeIn {
                for i in 0..<120 { samples[i] *= Float(i) / 120 }
            }
            lastSamples[channel] = samples[Int(pcm.frameLength) - 1]
        }
        needsFadeIn = false
        return pcm
    }
}
