import Foundation
import VideoToolbox

/// An opaque identifier scoped to a single encoder session. Carry it alongside the encoded frame.
/// Acknowledge it only after the receiver has decoded the frame with a valid reference chain.
public struct LongTermReferenceToken: RawRepresentable, Hashable, Sendable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public init?(requestedBy sample: CMSampleBuffer) {
        let attachments =
            CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]]
        guard
            let number = attachments?.first?[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken]
                as? NSNumber
        else { return nil }
        self.init(rawValue: number.int64Value)
    }
}
