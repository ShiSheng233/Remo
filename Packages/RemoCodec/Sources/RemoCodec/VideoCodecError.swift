import VideoToolbox

public enum VideoCodecError: Error {
    case invalidConfiguration
    case invalidFrame
    case frameDropped
    case videoToolbox(operation: String, status: OSStatus)
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw VideoCodecError.videoToolbox(operation: operation, status: status)
    }
}
