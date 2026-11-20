import AVFAudio
import AudioToolbox
import Foundation

/// The desktop audio profile uses one 20 ms stereo Opus packet per message.
public enum OpusFormat {
    public static let frames: AVAudioFrameCount = 960
    public static let pcm = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    public enum Failure: Error { case unsupportedFormat, invalidPacket, conversion }

    fileprivate static func compressed() throws -> AVAudioFormat {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: frames, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let format = AVAudioFormat(streamDescription: &description) else {
            throw Failure.unsupportedFormat
        }
        return format
    }
}

public final class OpusEncoder {
    private let converter: AVAudioConverter
    private let output: AVAudioCompressedBuffer

    public init() throws {
        let format = try OpusFormat.compressed()
        guard let converter = AVAudioConverter(from: OpusFormat.pcm, to: format) else {
            throw OpusFormat.Failure.unsupportedFormat
        }
        converter.bitRate = 96_000
        converter.primeMethod = .none
        self.converter = converter
        output = AVAudioCompressedBuffer(
            format: format, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize)
    }

    public func encode(_ pcm: AVAudioPCMBuffer) throws -> Data {
        guard pcm.format == OpusFormat.pcm, pcm.frameLength == OpusFormat.frames else {
            throw OpusFormat.Failure.unsupportedFormat
        }
        output.packetCount = 0
        output.byteLength = 0
        try convert(converter, input: pcm, output: output)
        guard output.packetCount == 1, output.byteLength > 0 else {
            throw OpusFormat.Failure.conversion
        }
        return Data(bytes: output.data, count: Int(output.byteLength))
    }
}

public final class OpusDecoder {
    private let converter: AVAudioConverter
    private var firstPacket = true
    private var lossPacket: Data?
    private let input: AVAudioCompressedBuffer

    public init() throws {
        let format = try OpusFormat.compressed()
        guard let converter = AVAudioConverter(from: format, to: OpusFormat.pcm) else {
            throw OpusFormat.Failure.unsupportedFormat
        }
        converter.primeMethod = .none
        self.converter = converter
        input = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: 1275)
    }

    /// Advance the same decoder by one missing 20 ms slot using its last decoded configuration.
    public func concealMissingFrame() throws -> AVAudioPCMBuffer {
        guard let lossPacket else { throw OpusFormat.Failure.invalidPacket }
        return try decodePacket(lossPacket)
    }

    public func decode(_ bytes: Data) throws -> AVAudioPCMBuffer {
        guard let toc = bytes.first else { throw OpusFormat.Failure.invalidPacket }
        let count: UInt8
        switch toc & 3 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard let flags = bytes.dropFirst().first else { throw OpusFormat.Failure.invalidPacket }
            count = flags & 63
        }
        // RFC 6716 frame durations in 48 kHz samples for SILK, hybrid, and CELT.
        let config = Int(toc >> 3)
        let samplesPerFrame: Int
        switch config {
        case 0..<12: samplesPerFrame = [480, 960, 1920, 2880][config % 4]
        case 12..<16: samplesPerFrame = [480, 960][config % 2]
        default: samplesPerFrame = 120 << (config % 4)
        }
        guard samplesPerFrame * Int(count) == OpusFormat.frames else {
            throw OpusFormat.Failure.invalidPacket
        }
        let pcm = try decodePacket(bytes)
        // RFC 7845 section 4.1: preserve the configuration with zero-byte CBR frames.
        let base = toc & 0xfc
        switch count {
        case 1: lossPacket = Data([base])
        case 2: lossPacket = Data([base | 1])
        default: lossPacket = Data([base | 3, count])
        }
        return pcm
    }

    private func decodePacket(_ bytes: Data) throws -> AVAudioPCMBuffer {
        guard (1...1275).contains(bytes.count),
            let pcm = AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm, frameCapacity: OpusFormat.frames)
        else { throw OpusFormat.Failure.invalidPacket }
        bytes.copyBytes(to: input.data.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        input.byteLength = UInt32(bytes.count)
        input.packetCount = 1
        input.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: OpusFormat.frames, mDataByteSize: UInt32(bytes.count))
        try convert(converter, input: input, output: pcm)
        // Core Audio trims the codec delay from the first decoded packet.
        if firstPacket, pcm.frameLength > 0, pcm.frameLength < OpusFormat.frames {
            let missing = Int(OpusFormat.frames - pcm.frameLength)
            for channel in 0..<2 {
                let samples = pcm.floatChannelData![channel]
                memmove(samples + missing, samples, Int(pcm.frameLength) * MemoryLayout<Float>.size)
                samples.update(repeating: 0, count: missing)
            }
            pcm.frameLength = OpusFormat.frames
        }
        firstPacket = false
        guard pcm.frameLength == OpusFormat.frames else { throw OpusFormat.Failure.invalidPacket }
        return pcm
    }
}

private func convert(_ converter: AVAudioConverter, input: AVAudioBuffer, output: AVAudioBuffer) throws {
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, status in
        status.pointee = supplied ? .noDataNow : .haveData
        if supplied { return nil }
        supplied = true
        return input
    }
    if let error { throw error }
    guard status != .error else { throw OpusFormat.Failure.conversion }
}
