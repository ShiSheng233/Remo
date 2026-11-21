import Foundation

/// A message that doesn't follow its wire format.
enum WireFormatError: Error {
    case invalid
    case status(OSStatus)
}
