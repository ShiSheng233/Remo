//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

/// Active keyboard modifier state synchronized immediately from client to server.
public struct KeyboardModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    static let validBitMask: UInt8 = 0x0F

    public init(rawValue: UInt8) {
        self.rawValue = rawValue & Self.validBitMask
    }

    public static let control = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let command = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)

    public static let all: Self = [.control, .option, .command, .shift]
}

/// Hardware virtual key codes matching macOS US ANSI (`Carbon.HIToolbox.Events`) values.
public enum KeyboardKeyCode: UInt16, CaseIterable, Hashable, Sendable {
    // Letters
    case a = 0x00
    case s = 0x01
    case d = 0x02
    case f = 0x03
    case h = 0x04
    case g = 0x05
    case z = 0x06
    case x = 0x07
    case c = 0x08
    case v = 0x09
    case b = 0x0B
    case q = 0x0C
    case w = 0x0D
    case e = 0x0E
    case r = 0x0F
    case y = 0x10
    case t = 0x11
    case o = 0x1F
    case u = 0x20
    case i = 0x22
    case p = 0x23
    case l = 0x25
    case j = 0x26
    case k = 0x28
    case n = 0x2D
    case m = 0x2E

    // Numbers
    case digit1 = 0x12
    case digit2 = 0x13
    case digit3 = 0x14
    case digit4 = 0x15
    case digit6 = 0x16
    case digit5 = 0x17
    case digit9 = 0x19
    case digit7 = 0x1A
    case digit8 = 0x1C
    case digit0 = 0x1D

    // Punctuation
    case equal = 0x18
    case minus = 0x1B
    case rightBracket = 0x1E
    case leftBracket = 0x21
    case quote = 0x27
    case semicolon = 0x29
    case backslash = 0x2A
    case comma = 0x2B
    case slash = 0x2C
    case period = 0x2F
    case grave = 0x32

    // Editing & control
    case `return` = 0x24
    case tab = 0x30
    case space = 0x31
    case delete = 0x33
    case escape = 0x35
    case command = 0x37
    case shift = 0x38
    case capsLock = 0x39
    case option = 0x3A
    case control = 0x3B
    case function = 0x3F

    // Function keys
    case f5 = 0x60
    case f6 = 0x61
    case f7 = 0x62
    case f3 = 0x63
    case f8 = 0x64
    case f9 = 0x65
    case f11 = 0x67
    case f10 = 0x6D
    case f12 = 0x6F
    case f4 = 0x76
    case f2 = 0x78
    case f1 = 0x7A

    // Navigation
    case home = 0x73
    case pageUp = 0x74
    case forwardDelete = 0x75
    case end = 0x77
    case pageDown = 0x79
    case leftArrow = 0x7B
    case rightArrow = 0x7C
    case downArrow = 0x7D
    case upArrow = 0x7E

    /// Whether holding this key should trigger server-side auto-repeat while held down.
    var supportsAutoRepeat: Bool {
        switch self {
        case .capsLock, .command, .shift, .option, .control, .function:
            false
        default:
            true
        }
    }
}
