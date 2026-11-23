//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import SwiftUI
import UIKit

/// A Mac-complete on-screen keyboard with a top-rounded Liquid Glass backdrop and plain translucent
/// keycaps styled to sit naturally alongside iOS system controls.
///
/// Modifiers follow native iOS shift semantics: a single tap selects for one keystroke (white, no
/// dot), a second tap after the double-tap window cancels back to idle, and a quick double-tap
/// locks the modifier (white with a dark dot matching the glyph).
struct RemoteKeyboardView: View {
    let onDismiss: () -> Void

    @State private var containerWidth: CGFloat = 0
    @State private var symbolMode = false
    @State private var fnMode = false
    @State private var capsLockActive = false
    @State private var scrubbingCursor = false
    @State private var modifiers: [ModifierKey: ModifierState] = [:]
    @State private var lastModifierSelectTime: [ModifierKey: ContinuousClock.Instant] = [:]

    private static let doubleTapWindow: Duration = .milliseconds(350)

    private enum ModifierKey: Hashable, CaseIterable {
        case control, option, command, shift

        var symbolName: String {
            switch self {
            case .control: "control"
            case .option: "option"
            case .command: "command"
            case .shift: "shift"
            }
        }

        var filledSymbolName: String {
            self == .shift ? "shift.fill" : symbolName
        }

        var accessibilityName: String {
            switch self {
            case .control: "Control"
            case .option: "Option"
            case .command: "Command"
            case .shift: "Shift"
            }
        }
    }

    enum ModifierState {
        case idle, selected, locked
    }

    private struct DualKey: Identifiable {
        let lower: String
        let upper: String
        var id: String { lower }
    }

    private struct NavKey: Identifiable {
        let id: String
        let label: String?
        let systemImage: String?
        let width: CGFloat
        let isCapsLock: Bool

        init(_ label: String, width: CGFloat = 38) {
            self.id = label
            self.label = label
            self.systemImage = nil
            self.width = width
            self.isCapsLock = false
        }

        init(id: String, systemImage: String, width: CGFloat = 32, isCapsLock: Bool = false) {
            self.id = id
            self.label = nil
            self.systemImage = systemImage
            self.width = width
            self.isCapsLock = isCapsLock
        }
    }

    private static let qwertyRow1 = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
    private static let qwertyRow2 = ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
    private static let qwertyRow3 = ["z", "x", "c", "v", "b", "n", "m"]

    /// All 21 non-letter printable keys on a US ANSI Mac keyboard.
    private static let symbolRow1: [DualKey] = [
        .init(lower: "1", upper: "!"), .init(lower: "2", upper: "@"),
        .init(lower: "3", upper: "#"), .init(lower: "4", upper: "$"),
        .init(lower: "5", upper: "%"), .init(lower: "6", upper: "^"),
        .init(lower: "7", upper: "&"), .init(lower: "8", upper: "*"),
        .init(lower: "9", upper: "("), .init(lower: "0", upper: ")"),
    ]
    private static let symbolRow2: [DualKey] = [
        .init(lower: "`", upper: "~"), .init(lower: "-", upper: "_"),
        .init(lower: "=", upper: "+"), .init(lower: "[", upper: "{"),
        .init(lower: "]", upper: "}"), .init(lower: "\\", upper: "|"),
    ]
    private static let symbolRow3: [DualKey] = [
        .init(lower: ";", upper: ":"), .init(lower: "'", upper: "\""),
        .init(lower: ",", upper: "<"), .init(lower: ".", upper: ">"),
        .init(lower: "/", upper: "?"),
    ]

    /// Placed in physical Mac left-edge order: Esc, Tab, Caps Lock, followed by navigation keys.
    private static let navKeys: [NavKey] = [
        .init("Esc", width: 38),
        .init("Tab", width: 38),
        .init(id: "Caps Lock", systemImage: "capslock", width: 34, isCapsLock: true),
        .init(id: "Left", systemImage: "chevron.left"),
        .init(id: "Down", systemImage: "chevron.down"),
        .init(id: "Up", systemImage: "chevron.up"),
        .init(id: "Right", systemImage: "chevron.right"),
        .init("Del", width: 38),
        .init("Home", width: 46),
        .init("End", width: 38),
        .init("PgUp", width: 46),
        .init("PgDn", width: 46),
    ]

    private static let fnKeys = (1...12).map { "F\($0)" }

    private var isCompact: Bool { containerWidth > 0 && containerWidth < 560 }
    private var shiftState: ModifierState { modifiers[.shift] ?? .idle }
    private var shiftActive: Bool { shiftState != .idle }

    var body: some View {
        let compact = isCompact
        let cornerRadius: CGFloat = compact ? 24 : 28
        let shellShape = UnevenRoundedRectangle(
            topLeadingRadius: cornerRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: cornerRadius,
            style: .continuous
        )

        VStack(spacing: compact ? 8 : 10) {
            topBar(isCompact: compact)
                .padding(.horizontal, compact ? 8 : 18)
                .opacity(scrubbingCursor ? 0.22 : 1)
                .animation(.easeOut(duration: 0.16), value: scrubbingCursor)

            Rectangle()
                .fill(.white.opacity(0.09))
                .frame(height: 0.5)
                .opacity(scrubbingCursor ? 0.18 : 1)
                .animation(.easeOut(duration: 0.16), value: scrubbingCursor)

            keyGrid(isCompact: compact)
                .padding(.horizontal, compact ? 6 : 30)
        }
        .padding(.top, compact ? 8 : 10)
        .padding(.bottom, compact ? 10 : 14)
        .safeAreaPadding(.horizontal)
        .safeAreaPadding(.bottom)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.tint(.black.opacity(0.45)), in: shellShape)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
    }

    // MARK: - Integrated Top Bar

    private func topBar(isCompact: Bool) -> some View {
        let barHeight: CGFloat = isCompact ? 32 : 34
        let modWidth: CGFloat = isCompact ? 36 : 44

        return HStack(spacing: 0) {
            // Left pinned modifiers (Control, Option, Command; Shift lives in row 3).
            HStack(spacing: isCompact ? 4 : 6) {
                ForEach([ModifierKey.control, .option, .command], id: \.self) { key in
                    ModifierKeyCap(
                        symbolName: key.symbolName,
                        filledSymbolName: key.filledSymbolName,
                        state: modifiers[key] ?? .idle,
                        compact: isCompact
                    ) {
                        toggleModifier(key)
                    }
                    .frame(width: modWidth, height: barHeight)
                    .accessibilityLabel(key.accessibilityName)
                }
            }
            .fixedSize()
            .padding(.trailing, isCompact ? 6 : 10)

            topDivider

            // Center horizontally scrollable compact function strip with soft edge fades.
            FadingHorizontalScrollView(restInset: isCompact ? 7 : 10) {
                HStack(spacing: isCompact ? 4 : 5) {
                    if fnMode {
                        ForEach(Self.fnKeys, id: \.self) { label in
                            UtilityKeyCap(
                                label: label,
                                systemImage: nil,
                                active: false,
                                compact: isCompact
                            ) {
                                handleNonModifierKey()
                            }
                            .frame(width: isCompact ? 36 : 42, height: barHeight)
                        }
                    } else {
                        ForEach(Self.navKeys) { item in
                            if item.isCapsLock {
                                UtilityKeyCap(
                                    label: nil,
                                    systemImage: capsLockActive ? "capslock.fill" : "capslock",
                                    active: capsLockActive,
                                    compact: isCompact
                                ) {
                                    withoutAnimation {
                                        capsLockActive.toggle()
                                    }
                                    handleNonModifierKey()
                                }
                                .frame(
                                    width: isCompact ? max(32, item.width - 2) : item.width,
                                    height: barHeight
                                )
                                .accessibilityLabel(item.id)
                            } else {
                                UtilityKeyCap(
                                    label: item.label,
                                    systemImage: item.systemImage,
                                    active: false,
                                    compact: isCompact
                                ) {
                                    handleNonModifierKey()
                                }
                                .frame(
                                    width: isCompact ? max(30, item.width - 2) : item.width,
                                    height: barHeight
                                )
                                .accessibilityLabel(item.id)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: barHeight)
            .layoutPriority(-1)

            topDivider

            // Right pinned dismiss button.
            UtilityKeyCap(
                label: nil,
                systemImage: "keyboard.chevron.compact.down",
                active: false,
                compact: isCompact,
                action: onDismiss
            )
            .frame(width: isCompact ? 36 : 42, height: barHeight)
            .fixedSize()
            .padding(.leading, isCompact ? 6 : 10)
            .accessibilityLabel("Dismiss keyboard")
        }
    }

    private var topDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(width: 1, height: 20)
    }

    // MARK: - 4-Row Main Keyboard

    private func keyGrid(isCompact: Bool) -> some View {
        let keyHeight: CGFloat = isCompact ? 42 : 46
        let hGap: CGFloat = isCompact ? 5 : 8
        let vGap: CGFloat = isCompact ? 8 : 10
        let dimOpacity: Double = scrubbingCursor ? 0.16 : 1

        return VStack(spacing: vGap) {
            // Row 1
            HStack(spacing: hGap) {
                if symbolMode {
                    ForEach(Self.symbolRow1) { key in
                        DualSymbolKeyCap(
                            lower: key.lower,
                            upper: key.upper,
                            shiftActive: shiftActive,
                            compact: isCompact
                        ) {
                            handleNonModifierKey()
                        }
                        .frame(height: keyHeight)
                    }
                } else {
                    ForEach(Self.qwertyRow1, id: \.self) { letter in
                        CharacterKeyCap(
                            label: (shiftActive || capsLockActive) ? letter.uppercased() : letter,
                            compact: isCompact
                        ) {
                            handleNonModifierKey()
                        }
                        .frame(height: keyHeight)
                    }
                }
            }
            .opacity(dimOpacity)
            .animation(.easeOut(duration: 0.16), value: scrubbingCursor)

            // Row 2
            HStack(spacing: hGap) {
                if symbolMode {
                    ForEach(Self.symbolRow2) { key in
                        DualSymbolKeyCap(
                            lower: key.lower,
                            upper: key.upper,
                            shiftActive: shiftActive,
                            compact: isCompact
                        ) {
                            handleNonModifierKey()
                        }
                        .frame(height: keyHeight)
                    }
                } else {
                    ForEach(Self.qwertyRow2, id: \.self) { letter in
                        CharacterKeyCap(
                            label: (shiftActive || capsLockActive) ? letter.uppercased() : letter,
                            compact: isCompact
                        ) {
                            handleNonModifierKey()
                        }
                        .frame(height: keyHeight)
                    }
                }
            }
            .padding(.horizontal, symbolMode ? (isCompact ? 8 : 34) : (isCompact ? 16 : 40))
            .opacity(dimOpacity)
            .animation(.easeOut(duration: 0.16), value: scrubbingCursor)

            // Row 3 (Shift + Z-M / remaining Mac symbols + Delete)
            HStack(spacing: hGap) {
                ModifierKeyCap(
                    symbolName: ModifierKey.shift.symbolName,
                    filledSymbolName: ModifierKey.shift.filledSymbolName,
                    state: shiftState,
                    compact: isCompact,
                    cornerRadius: isCompact ? 8 : 10
                ) {
                    toggleModifier(.shift)
                }
                .frame(width: isCompact ? 44 : 88, height: keyHeight)
                .accessibilityLabel("Shift")

                if symbolMode {
                    ForEach(Self.symbolRow3) { key in
                        DualSymbolKeyCap(
                            lower: key.lower,
                            upper: key.upper,
                            shiftActive: shiftActive,
                            compact: isCompact
                        ) {
                            handleNonModifierKey()
                        }
                        .frame(height: keyHeight)
                    }
                } else {
                    ForEach(Self.qwertyRow3, id: \.self) { letter in
                        CharacterKeyCap(
                            label: (shiftActive || capsLockActive) ? letter.uppercased() : letter,
                            compact: isCompact
                        ) {
                            handleNonModifierKey()
                        }
                        .frame(height: keyHeight)
                    }
                }

                ActionKeyCap(
                    label: nil,
                    systemImage: "delete.left",
                    prominent: false,
                    compact: isCompact
                ) {
                    handleNonModifierKey()
                }
                .frame(width: isCompact ? 44 : 88, height: keyHeight)
                .accessibilityLabel("Delete")
            }
            .opacity(dimOpacity)
            .animation(.easeOut(duration: 0.16), value: scrubbingCursor)

            // Row 4 (123/ABC, Mac fn/Globe, Spacebar, Return)
            HStack(spacing: hGap) {
                Group {
                    ActionKeyCap(
                        label: symbolMode ? "ABC" : "123",
                        systemImage: nil,
                        prominent: false,
                        compact: isCompact
                    ) {
                        withoutAnimation { symbolMode.toggle() }
                    }
                    .frame(width: isCompact ? 50 : 74, height: keyHeight)

                    MacFnGlobeKeyCap(
                        active: fnMode,
                        compact: isCompact
                    ) {
                        withoutAnimation { fnMode.toggle() }
                    }
                    .frame(width: isCompact ? 50 : 74, height: keyHeight)
                }
                .opacity(dimOpacity)
                .animation(.easeOut(duration: 0.16), value: scrubbingCursor)

                SpacebarKeyCap(
                    scrubbing: $scrubbingCursor,
                    compact: isCompact,
                    onTap: handleNonModifierKey
                )
                .frame(height: keyHeight)

                ActionKeyCap(
                    label: nil,
                    systemImage: "return",
                    prominent: true,
                    compact: isCompact
                ) {
                    handleNonModifierKey()
                }
                .frame(width: isCompact ? 72 : 112, height: keyHeight)
                .opacity(dimOpacity)
                .animation(.easeOut(duration: 0.16), value: scrubbingCursor)
                .accessibilityLabel("Return")
            }
        }
    }

    // MARK: - Local UI State (Zero-Animation Instant Transitions)

    private func toggleModifier(_ key: ModifierKey) {
        let now = ContinuousClock.now
        withoutAnimation {
            switch modifiers[key] ?? .idle {
            case .idle:
                modifiers[key] = .selected
                lastModifierSelectTime[key] = now
            case .selected:
                if let previous = lastModifierSelectTime[key],
                   previous.duration(to: now) <= Self.doubleTapWindow
                {
                    modifiers[key] = .locked
                } else {
                    modifiers[key] = .idle
                }
                lastModifierSelectTime[key] = nil
            case .locked:
                modifiers[key] = .idle
                lastModifierSelectTime[key] = nil
            }
        }
    }

    private func handleNonModifierKey() {
        withoutAnimation {
            for key in ModifierKey.allCases where modifiers[key] == .selected {
                modifiers[key] = .idle
                lastModifierSelectTime[key] = nil
            }
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}

// MARK: - Horizontal Scroll View with Dynamic Soft Edge Fades

/// Horizontal scroll view whose edges always reach zero opacity at the clip boundary while
/// keeping resting end items fully opaque via matching scroll content margins.
private struct FadingHorizontalScrollView<Content: View>: View {
    let restInset: CGFloat
    @ViewBuilder let content: Content

    @State private var leadingFadeWidth: CGFloat = 0
    @State private var trailingFadeWidth: CGFloat = 0

    private let maxFadeWidth: CGFloat = 22

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content
        }
        .contentMargins(.horizontal, restInset, for: .scrollContent)
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .onScrollGeometryChange(for: ScrollEdgeWidths.self) { geo in
            let offset = geo.contentOffset.x + geo.contentInsets.leading
            let scrollableWidth = max(
                0,
                geo.contentSize.width + geo.contentInsets.leading + geo.contentInsets.trailing
                    - geo.containerSize.width
            )
            guard scrollableWidth > 1 else {
                return ScrollEdgeWidths(leading: 0, trailing: 0)
            }
            let leading = min(maxFadeWidth, restInset + max(0, offset))
            let trailing = min(maxFadeWidth, restInset + max(0, scrollableWidth - offset))
            return ScrollEdgeWidths(leading: leading, trailing: trailing)
        } action: { _, widths in
            leadingFadeWidth = widths.leading
            trailingFadeWidth = widths.trailing
        }
        .mask {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let leadingFrac = min(leadingFadeWidth / width, 0.3)
                let trailingFrac = min(trailingFadeWidth / width, 0.3)
                LinearGradient(
                    stops: maskStops(leading: leadingFrac, trailing: trailingFrac),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .clipped()
    }

    private func maskStops(leading: CGFloat, trailing: CGFloat) -> [Gradient.Stop] {
        var stops: [Gradient.Stop] = []
        if leading > 0.001 {
            stops.append(.init(color: .clear, location: 0))
            stops.append(.init(color: .black.opacity(0.35), location: leading * 0.4))
            stops.append(.init(color: .black, location: leading))
        } else {
            stops.append(.init(color: .black, location: 0))
        }
        if trailing > 0.001 {
            stops.append(.init(color: .black, location: 1 - trailing))
            stops.append(.init(color: .black.opacity(0.35), location: 1 - trailing * 0.4))
            stops.append(.init(color: .clear, location: 1))
        } else {
            stops.append(.init(color: .black, location: 1))
        }
        return stops
    }

    private struct ScrollEdgeWidths: Equatable {
        let leading: CGFloat
        let trailing: CGFloat
    }
}

// MARK: - Keycaps (Plain Translucent Views, Instant Highlight Only)

private struct TranslucentKeyStyle: ButtonStyle {
    let normalFill: Color
    let pressedFill: Color
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(configuration.isPressed ? pressedFill : normalFill, in: shape)
            .contentShape(shape)
            .transaction { $0.animation = nil }
    }
}

private struct CharacterKeyCap: View {
    let label: String
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: compact ? 20 : 21, weight: .regular))
                .foregroundStyle(.white)
        }
        .buttonStyle(
            TranslucentKeyStyle(
                normalFill: .white.opacity(0.20),
                pressedFill: .white.opacity(0.38),
                cornerRadius: compact ? 8 : 10
            )
        )
        .transaction { $0.animation = nil }
    }
}

private struct DualSymbolKeyCap: View {
    let lower: String
    let upper: String
    let shiftActive: Bool
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(upper)
                    .font(.system(
                        size: shiftActive ? (compact ? 15 : 17) : (compact ? 10 : 11.5),
                        weight: shiftActive ? .medium : .regular
                    ))
                    .foregroundStyle(shiftActive ? .white : .white.opacity(0.42))
                Spacer(minLength: 0)
                Text(lower)
                    .font(.system(
                        size: shiftActive ? (compact ? 10 : 11.5) : (compact ? 15 : 17),
                        weight: shiftActive ? .regular : .medium
                    ))
                    .foregroundStyle(shiftActive ? .white.opacity(0.42) : .white)
            }
            .padding(.vertical, compact ? 3 : 4)
        }
        .buttonStyle(
            TranslucentKeyStyle(
                normalFill: .white.opacity(0.20),
                pressedFill: .white.opacity(0.38),
                cornerRadius: compact ? 8 : 10
            )
        )
        .transaction { $0.animation = nil }
    }
}

private struct ActionKeyCap: View {
    let label: String?
    let systemImage: String?
    let prominent: Bool
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 16 : 18, weight: .medium))
                    .foregroundStyle(.white)
            } else if let label {
                Text(label)
                    .font(.system(size: compact ? 13 : 14, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(
            TranslucentKeyStyle(
                normalFill: .white.opacity(prominent ? 0.28 : 0.12),
                pressedFill: .white.opacity(prominent ? 0.42 : 0.28),
                cornerRadius: compact ? 8 : 10
            )
        )
        .transaction { $0.animation = nil }
    }
}

private struct UtilityKeyCap: View {
    let label: String?
    let systemImage: String?
    let active: Bool
    let compact: Bool
    let action: () -> Void

    private static let activeFill = Color(white: 0.96)
    private static let activeInk = Color(white: 0.08)

    var body: some View {
        let ink: Color = active ? Self.activeInk : .white
        Button(action: action) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 13 : 14, weight: .medium))
                    .foregroundStyle(ink)
            } else if let label {
                Text(label)
                    .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
                    .foregroundStyle(ink)
                    .lineLimit(1)
            }
        }
        .buttonStyle(
            TranslucentKeyStyle(
                normalFill: active ? Self.activeFill : .white.opacity(0.11),
                pressedFill: active ? .white.opacity(0.82) : .white.opacity(0.28),
                cornerRadius: compact ? 8 : 9
            )
        )
        .transaction { $0.animation = nil }
    }
}

private struct ModifierKeyCap: View {
    let symbolName: String
    let filledSymbolName: String
    let state: RemoteKeyboardView.ModifierState
    let compact: Bool
    var cornerRadius: CGFloat? = nil
    let action: () -> Void

    private static let activeFill = Color(white: 0.96)
    private static let activeInk = Color(white: 0.08)

    private var isActive: Bool { state != .idle }
    private var isLocked: Bool { state == .locked }

    var body: some View {
        let radius = cornerRadius ?? (compact ? 8 : 9)
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: isActive ? filledSymbolName : symbolName)
                    .font(.system(size: compact ? 14 : 15, weight: .medium))
                    .foregroundStyle(isActive ? Self.activeInk : .white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isLocked {
                    Circle()
                        .fill(Self.activeInk)
                        .frame(width: 4.5, height: 4.5)
                        .padding(.top, compact ? 4 : 5)
                        .padding(.trailing, compact ? 4 : 5)
                }
            }
        }
        .buttonStyle(
            TranslucentKeyStyle(
                normalFill: isActive ? Self.activeFill : .white.opacity(0.12),
                pressedFill: isActive ? .white.opacity(0.82) : .white.opacity(0.28),
                cornerRadius: radius
            )
        )
        .transaction { $0.animation = nil }
    }
}

/// Combined Mac-style `fn` + Globe keycap (`fn` top-right, Globe bottom-left).
private struct MacFnGlobeKeyCap: View {
    let active: Bool
    let compact: Bool
    let action: () -> Void

    private static let activeFill = Color(white: 0.96)
    private static let activeInk = Color(white: 0.08)

    var body: some View {
        let ink = active ? Self.activeInk : .white
        Button(action: action) {
            ZStack {
                Text("fn")
                    .font(.system(size: compact ? 13 : 14, weight: .medium))
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, compact ? 4 : 5)
                    .padding(.trailing, compact ? 6 : 8)

                Image(systemName: "globe")
                    .font(.system(size: compact ? 13 : 14, weight: .regular))
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.bottom, compact ? 5 : 6)
                    .padding(.leading, compact ? 6 : 8)
            }
        }
        .buttonStyle(
            TranslucentKeyStyle(
                normalFill: active ? Self.activeFill : .white.opacity(0.12),
                pressedFill: active ? .white.opacity(0.82) : .white.opacity(0.28),
                cornerRadius: compact ? 8 : 10
            )
        )
        .transaction { $0.animation = nil }
        .accessibilityLabel("Function and Globe")
    }
}

/// Spacebar that inserts a space on tap and quietly dims the other keys on long-press.
private struct SpacebarKeyCap: View {
    @Binding var scrubbing: Bool
    let compact: Bool
    let onTap: () -> Void

    @State private var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
        ZStack {
            shape
                .fill(Color.white.opacity(pressed || scrubbing ? 0.34 : 0.20))
                .transaction { $0.animation = nil }
            Text("space")
                .font(.system(size: compact ? 13 : 14, weight: .regular))
                .foregroundStyle(.white.opacity(scrubbing ? 0 : 0.48))
                .animation(.easeOut(duration: 0.16), value: scrubbing)
        }
        .contentShape(shape)
        .overlay {
            SpacebarTouchArea(
                onTouchDown: { pressed = true },
                onLongPressBegan: { scrubbing = true },
                onEnded: { wasLongPress in
                    pressed = false
                    if wasLongPress {
                        scrubbing = false
                    } else {
                        onTap()
                    }
                }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Space")
        .accessibilityAddTraits(.isButton)
    }
}

/// Distinguishes tap from hold-and-drag on the spacebar from touch-down.
private struct SpacebarTouchArea: UIViewRepresentable {
    let onTouchDown: () -> Void
    let onLongPressBegan: () -> Void
    let onEnded: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let press = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handlePress))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.area = self
    }

    final class Coordinator: NSObject {
        var area: SpacebarTouchArea?
        private var holdTask: Task<Void, Never>?
        private var isLongPress = false

        @objc func handlePress(_ gesture: UILongPressGestureRecognizer) {
            guard let area else { return }
            switch gesture.state {
            case .began:
                isLongPress = false
                area.onTouchDown()
                holdTask?.cancel()
                holdTask = Task {
                    try? await Task.sleep(for: .milliseconds(280))
                    guard !Task.isCancelled else { return }
                    isLongPress = true
                    area.onLongPressBegan()
                }
            case .ended, .cancelled, .failed:
                holdTask?.cancel()
                holdTask = nil
                let didLongPress = isLongPress
                isLongPress = false
                area.onEnded(didLongPress)
            default:
                break
            }
        }
    }
}

// MARK: - Previews

#Preview("Keyboard — Landscape", traits: .landscapeLeft) {
    ZStack(alignment: .bottom) {
        Color.black.ignoresSafeArea()
        RemoteKeyboardView(onDismiss: {})
            .ignoresSafeArea(edges: [.bottom, .horizontal])
    }
}

#Preview("Keyboard — Portrait") {
    ZStack(alignment: .bottom) {
        Color.black.ignoresSafeArea()
        RemoteKeyboardView(onDismiss: {})
            .ignoresSafeArea(edges: [.bottom, .horizontal])
    }
}
