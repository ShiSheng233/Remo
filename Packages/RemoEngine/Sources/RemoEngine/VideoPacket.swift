import CoreMedia
import Foundation
import RemoCodec

enum PacketError: Error {
    case invalid
    case status(OSStatus)
}

extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func take<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard count >= MemoryLayout<T>.size else { throw PacketError.invalid }
        let value = withUnsafeBytes { T(bigEndian: $0.loadUnaligned(as: T.self)) }
        self = dropFirst(MemoryLayout<T>.size)
        return value
    }

    mutating func takeBytes(_ count: Int) throws -> Data {
        guard count <= self.count else { throw PacketError.invalid }
        let result = prefix(count)
        self = dropFirst(count)
        return result
    }
}

enum VideoMessage: UInt8 {
    case frame = 0x40
    case acknowledgement, refresh
}

/// Big-endian v1 frame header: flags, frame ID, most recent IDR ID, PTS and duration
/// (each value + timescale), optional LTR token, then AVC configuration on IDR and AVCC bytes.
struct VideoPacket {
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
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw PacketError.invalid }
        let token = LongTermReferenceToken(requestedBy: sample)
        var data = Data([VideoMessage.frame.rawValue, kind.rawValue | (token == nil ? 0 : 0x80)])
        data.put(id)
        data.put(epoch)
        for time in [
            CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetDuration(sample),
        ] {
            guard time.isNumeric, time.epoch == 0 else { throw PacketError.invalid }
            data.put(time.value)
            data.put(time.timescale)
        }
        if let token { data.put(token.rawValue) }
        if kind == .idr {
            guard let format = CMSampleBufferGetFormatDescription(sample) else {
                throw PacketError.invalid
            }
            var length: Int32 = 0
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: &length)
                guard status == noErr, let pointer, let count = UInt16(exactly: size), count > 0
                else {
                    throw PacketError.invalid
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
        guard status == noErr else { throw PacketError.status(status) }
        return data
    }

    init(_ message: Data) throws {
        var data = message
        guard try data.take(UInt8.self) == VideoMessage.frame.rawValue else {
            throw PacketError.invalid
        }
        let flags = try data.take(UInt8.self)
        guard let kind = Kind(rawValue: flags & 0x7f) else { throw PacketError.invalid }
        self.kind = kind
        id = try data.take(UInt64.self)
        epoch = try data.take(UInt64.self)
        guard epoch > 0, kind == .idr ? id == epoch : id > epoch else { throw PacketError.invalid }
        func time(_ data: inout Data) throws -> CMTime {
            let value = try data.take(Int64.self)
            let scale = try data.take(Int32.self)
            guard scale > 0 else { throw PacketError.invalid }
            return CMTime(value: value, timescale: scale)
        }
        pts = try time(&data)
        duration = try time(&data)
        token =
            flags & 0x80 == 0 ? nil : LongTermReferenceToken(rawValue: try data.take(Int64.self))
        if kind == .idr {
            let spsSize = try data.take(UInt16.self)
            let sps = try data.takeBytes(Int(spsSize))
            let ppsSize = try data.take(UInt16.self)
            let pps = try data.takeBytes(Int(ppsSize))
            let length = try data.take(UInt8.self)
            guard spsSize > 0, ppsSize > 0, [1, 2, 4].contains(length) else {
                throw PacketError.invalid
            }
            var description: CMFormatDescription?
            let status = sps.withUnsafeBytes { s in
                pps.withUnsafeBytes { p in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: nil, parameterSetCount: 2,
                        parameterSetPointers: [
                            s.bindMemory(to: UInt8.self).baseAddress!,
                            p.bindMemory(to: UInt8.self).baseAddress!,
                        ],
                        parameterSetSizes: [s.count, p.count], nalUnitHeaderLength: Int32(length),
                        formatDescriptionOut: &description)
                }
            }
            guard status == noErr, let description else { throw PacketError.status(status) }
            format = description
        } else {
            format = nil
        }
        guard !data.isEmpty else { throw PacketError.invalid }
        bytes = data
    }

    func sample(format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw PacketError.status(status) }
        status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                dataLength: $0.count)
        }
        guard status == noErr else { throw PacketError.status(status) }
        var timing = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw PacketError.status(status) }
        return sample
    }
}
