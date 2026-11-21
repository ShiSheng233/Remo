import CoreMedia
import Foundation
import RemoCodec

/// Big-endian v1 frame header: flags, frame ID, most recent IDR ID, PTS and duration
/// (each value + timescale), optional LTR token, then VPS, SPS and PPS on IDR and length-prefixed HEVC NAL units.
struct VideoFrameMessage {
    enum Kind: UInt8 { case predicted, idr, ltrRefresh }
    let kind: Kind
    let id: UInt64
    let epoch: UInt64
    let pts: CMTime
    let duration: CMTime
    let token: LongTermReferenceToken?
    let format: CMVideoFormatDescription?
    let bytes: Data

    static func serialize(_ sample: CMSampleBuffer, id: UInt64, epoch: UInt64, kind: Kind) throws
        -> Data
    {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw WireFormatError.invalid }
        let token = LongTermReferenceToken(requestedBy: sample)
        var data = Data([MessageKind.videoFrame.rawValue, kind.rawValue | (token == nil ? 0 : 0x80)])
        data.put(id)
        data.put(epoch)
        for time in [
            CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetDuration(sample),
        ] {
            guard time.isNumeric, time.epoch == 0 else { throw WireFormatError.invalid }
            data.put(time.value)
            data.put(time.timescale)
        }
        if let token { data.put(token.rawValue) }
        if kind == .idr {
            guard let format = CMSampleBufferGetFormatDescription(sample) else {
                throw WireFormatError.invalid
            }
            var length: Int32 = 0
            for index in 0..<3 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format,
                    parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: &length)
                guard status == noErr, let pointer, let count = UInt16(exactly: size), count > 0
                else {
                    throw WireFormatError.invalid
                }
                data.put(count)
                data.append(pointer, count: size)
            }
            data.put(UInt8(length))
        }
        let offset = data.count
        let size = CMBlockBufferGetDataLength(block)
        data.count += size
        let status = data.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: size,
                destination: buffer.baseAddress!.advanced(by: offset))
        }
        guard status == noErr else { throw WireFormatError.status(status) }
        return data
    }

    init(_ message: Data) throws {
        var data = message
        guard try data.take(UInt8.self) == MessageKind.videoFrame.rawValue else {
            throw WireFormatError.invalid
        }
        let flags = try data.take(UInt8.self)
        guard let kind = Kind(rawValue: flags & 0x7f) else { throw WireFormatError.invalid }
        self.kind = kind
        id = try data.take(UInt64.self)
        epoch = try data.take(UInt64.self)
        guard epoch > 0, kind == .idr ? id == epoch : id > epoch else { throw WireFormatError.invalid }
        func time(_ data: inout Data) throws -> CMTime {
            let value = try data.take(Int64.self)
            let scale = try data.take(Int32.self)
            guard scale > 0 else { throw WireFormatError.invalid }
            return CMTime(value: value, timescale: scale)
        }
        pts = try time(&data)
        duration = try time(&data)
        token =
            flags & 0x80 == 0 ? nil : LongTermReferenceToken(rawValue: try data.take(Int64.self))
        if kind == .idr {
            // Offsets refer to the original message so all parameter pointers share one lifetime.
            var offsets: [Int] = []
            var sizes: [Int] = []
            for type in 32...34 {
                let size = Int(try data.take(UInt16.self))
                offsets.append(message.count - data.count)
                let parameter = try data.takeBytes(size)
                guard size >= 2, (parameter[parameter.startIndex] >> 1) & 0x3f == type else {
                    throw WireFormatError.invalid
                }
                sizes.append(size)
            }
            let length = try data.take(UInt8.self)
            guard [1, 2, 4].contains(length) else { throw WireFormatError.invalid }
            var description: CMFormatDescription?
            let status = message.withUnsafeBytes { buffer in
                let base = buffer.bindMemory(to: UInt8.self).baseAddress!
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: sizes.count,
                    parameterSetPointers: offsets.map { base.advanced(by: $0) },
                    parameterSetSizes: sizes, nalUnitHeaderLength: Int32(length),
                    extensions: nil, formatDescriptionOut: &description)
            }
            guard status == noErr, let description else { throw WireFormatError.status(status) }
            format = description
        } else {
            format = nil
        }
        guard !data.isEmpty else { throw WireFormatError.invalid }
        bytes = data
    }

    func sample(format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw WireFormatError.status(status) }
        status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                dataLength: $0.count)
        }
        guard status == noErr else { throw WireFormatError.status(status) }
        var timing = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw WireFormatError.status(status) }
        return sample
    }
}
