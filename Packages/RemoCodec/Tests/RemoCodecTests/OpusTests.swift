import AVFAudio
import Foundation
import RemoCodec
import Testing

@Test func stereoOpusRoundTrip() throws {
    let encoder = try OpusEncoder()
    let decoder = try OpusDecoder()
    var leftEnergy = 0.0
    var rightEnergy = 0.0
    for packet in 0..<10 {
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm, frameCapacity: 960))
        pcm.frameLength = 960
        for i in 0..<960 {
            pcm.floatChannelData![0][i] = Float(sin(Double(packet * 960 + i) * 0.08)) * 0.4
            pcm.floatChannelData![1][i] = 0
        }
        let compressed = try encoder.encode(pcm)
        #expect(compressed.count < 1000)
        let decoded = try decoder.decode(compressed)
        #expect(decoded.frameLength == 960)
        for i in 0..<960 {
            leftEnergy += Double(decoded.floatChannelData![0][i] * decoded.floatChannelData![0][i])
            rightEnergy += Double(decoded.floatChannelData![1][i] * decoded.floatChannelData![1][i])
        }
    }
    #expect(leftEnergy > 100)
    #expect(rightEnergy < leftEnergy * 0.05)
}

@Test(arguments: [1, 2])
func opusConcealsMissingSlotsAndResumes(losses: Int) throws {
    let encoder = try OpusEncoder()
    let decoder = try OpusDecoder()
    #expect(throws: OpusFormat.Failure.self) { try decoder.concealMissingFrame() }
    for index in 0..<(24 + losses) {
        let lost = (20..<(20 + losses)).contains(index)
        let frequency = index < 20 + losses ? 500 : 1000
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm, frameCapacity: 960))
        pcm.frameLength = 960
        for i in 0..<960 {
            let value = Float(sin(Double(i * frequency) * 2 * .pi / 48_000)) * 0.3
            for channel in 0..<2 { pcm.floatChannelData![channel][i] = value }
        }
        let packet = try encoder.encode(pcm)
        let rendered = try lost ? decoder.concealMissingFrame() : decoder.decode(packet)
        #expect(rendered.frameLength == 960)
        if lost || index == 23 + losses {
            for channel in 0..<2 {
                let data = rendered.floatChannelData![channel]
                let crossings = (1..<960).filter { data[$0 - 1] < 0 && data[$0] >= 0 }.count
                #expect(abs(crossings * 50 - frequency) <= 50)
                let energy = (0..<960).reduce(Float.zero) { $0 + data[$1] * data[$1] }
                #expect(energy > 0.1)
            }
        }
    }
}
