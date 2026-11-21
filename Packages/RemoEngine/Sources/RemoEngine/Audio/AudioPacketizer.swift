import AVFAudio
import CoreMedia
import Foundation
import RemoCodec

/// Used on the serial audio capture queue.
final class AudioPacketizer {
    private let trace: AudioTrace?
    private let encoder: OpusEncoder
    private let partial = AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm, frameCapacity: OpusFormat.frames)!
    private var nextTimestamp: Int64?
    private var sequence: UInt64 = 0

    init(traceDirectory: URL? = nil) throws {
        encoder = try OpusEncoder()
        trace = AudioTrace.open("before-encode", in: traceDirectory)
    }

    func append(_ sample: CMSampleBuffer, emit: (AudioMessage) -> Void) throws {
        guard let description = sample.formatDescription else { throw OpusFormat.Failure.unsupportedFormat }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let pts = CMTimeConvertScale(sample.presentationTimeStamp, timescale: 48_000, method: .default)
        guard pts.isNumeric, format.commonFormat == .pcmFormatFloat32,
            format.sampleRate == 48_000, format.channelCount == 2,
            let count = UInt32(exactly: sample.numSamples), count > 0,
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)
        else { throw OpusFormat.Failure.unsupportedFormat }
        input.frameLength = count
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(count), into: input.mutableAudioBufferList)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        if let nextTimestamp, abs(Double(pts.value) - Double(nextTimestamp)) > 1 {
            partial.frameLength = 0
        }
        nextTimestamp = pts.value + Int64(count)
        var offset = 0
        while offset < Int(count) {
            let filled = Int(partial.frameLength)
            let length = min(960 - filled, Int(count) - offset)
            for channel in 0..<2 {
                let dest = partial.floatChannelData![channel] + filled
                if format.isInterleaved {
                    for i in 0..<length { dest[i] = input.floatChannelData![0][(offset + i) * 2 + channel] }
                } else {
                    dest.update(from: input.floatChannelData![channel] + offset, count: length)
                }
            }
            offset += length
            partial.frameLength += UInt32(length)
            if partial.frameLength == OpusFormat.frames {
                let timestamp = pts.value + Int64(offset) - 960
                trace?.record(partial, sequence: sequence, timestamp: timestamp, kind: "capture")
                emit(AudioMessage(sequence: sequence, timestamp: timestamp, opus: try encoder.encode(partial)))
                sequence += 1
                partial.frameLength = 0
            }
        }
    }
}
