//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

public enum PointerButton: UInt8, Sendable {
    case leftClick = 1, rightClick, leftDown, leftUp
    /// Secondary-button holds, which only a grant echoing the extended-pointer flag accepts.
    case rightDown, rightUp

    /// Needs the counted-button wire format, so a server must advertise `extendedButtons`.
    var isExtended: Bool { self == .rightDown || self == .rightUp }
}
