//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import RemoEngine
import SwiftUI
import UIKit

enum RemoteModifierKey: Hashable, CaseIterable {
    case control, option, command, shift

    var wireFlag: KeyboardModifiers {
        switch self {
        case .control: .control
        case .option: .option
        case .command: .command
        case .shift: .shift
        }
    }

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

enum RemoteModifierState: Equatable {
    case idle, selected, locked
}

/// A Mac-complete on-screen keyboard with a top-rounded Liquid Glass backdrop and plain translucent
/// keycaps styled to sit naturally alongside iOS system controls.
///
/// Modifiers synchronize immediately on state change: single tap selects for one key (white, no
/// dot), a second tap after the double-tap window cancels back to idle, and a quick double-tap
/// locks the modifier (white with a dark dot matching the glyph). Normal keys send an atomic
/// keystroke on short tap, or keyDown/keyUp when held.
struct RemoteKeyboardView: View {
    let modifierStates: [RemoteModifierKey: RemoteModifierState]
    let capsLockActive: Bool
    let onToggleModifier: (RemoteModifierKey) -> Void
    let onKeystroke: (KeyboardKeyCode) -> Void
    let onKeyDown: (KeyboardKeyCode) -> Void
    let onKeyUp: (KeyboardKeyCode) -> Void
    let onScrubStep: (KeyboardKeyCode) -> Void
    let onScrubEnd: () -> Void
    let onDismiss: () -> Void

    @State private var containerWidth: CGFloat = 0
    @State private var symbolMode = false
    @State private var fnMode = false
    @State private var scrubbingCursor = false

    private struct LetterKey: Identifiable {
        let label: String
        let code: KeyboardKeyCode
        var id: String { label }
    }

    private struct DualKey: Identifiable {
        let lower: String
        let upper: String
        let code: KeyboardKeyCode
        var id: String { lower }
    }

    private struct NavKey: Identifiable {
        let id: String
        let label: String?
        let systemImage: String?
        let width: CGFloat
        let code: KeyboardKeyCode
        let isCapsLock: Bool

        init(_ label: String, code: KeyboardKeyCode, width: CGFloat = 38) {
            self.id = label
            self.label = label
            self.systemImage = nil
            self.width = width
            self.code = code
            self.isCapsLock = false
        }

        init(
            id: String, systemImage: String, code: KeyboardKeyCode, width: CGFloat = 32,
            isCapsLock: Bool = false
        ) {
            self.id = id
            self.label = nil
            self.systemImage = systemImage
            self.width = width
            self.code = code
            self.isCapsLock = isCapsLock
        }
    }

    private struct FnKey: Identifiable {
        let label: String
        let code: KeyboardKeyCode
        var id: String { label }
    }

    private static let qwertyRow1: [LetterKey] = [
        .init(label: "q", code: .q), .init(label: "w", code: .w), .init(label: "e", code: .e),
        .init(label: "r", code: .r), .init(label: "t", code: .t), .init(label: "y", code: .y),
        .init(label: "u", code: .u), .init(label: "i", code: .i), .init(label: "o", code: .o),
        .init(label: "p", code: .p),
    ]
    private static let qwertyRow2: [LetterKey] = [
        .init(label: "a", code: .a), .init(label: "s", code: .s), .init(label: "d", code: .d),
        .init(label: "f", code: .f), .init(label: "g", code: .g), .init(label: "h", code: .h),
        .init(label: "j", code: .j), .init(label: "k", code: .k), .init(label: "l", code: .l),
    ]
    private static let qwertyRow3: [LetterKey] = [
        .init(label: "z", code: .z), .init(label: "x", code: .x), .init(label: "c", code: .c),
        .init(label: "v", code: .v), .init(label: "b", code: .b), .init(label: "n", code: .n),
        .init(label: "m", code: .m),
    ]

    /// All 21 non-letter printable keys on a US ANSI Mac keyboard.
    private static let symbolRow1: [DualKey] = [
        .init(lower: "1", upper: "!", code: .digit1), .init(lower: "2", upper: "@", code: .digit2),
        .init(lower: "3", upper: "#", code: .digit3), .init(lower: "4", upper: "$", code: .digit4),
        .init(lower: "5", upper: "%", code: .digit5), .init(lower: "6", upper: "^", code: .digit6),
        .init(lower: "7", upper: "&", code: .digit7), .init(lower: "8", upper: "*", code: .digit8),
        .init(lower: "9", upper: "(", code: .digit9), .init(lower: "0", upper: ")", code: .digit0),
    ]
    private static let symbolRow2: [DualKey] = [
        .init(lower: "`", upper: "~", code: .grave), .init(lower: "-", upper: "_", code: .minus),
        .init(lower: "=", upper: "+", code: .equal),
        .init(lower: "[", upper: "{", code: .leftBracket),
        .init(lower: "]", upper: "}", code: .rightBracket),
        .init(lower: "\\", upper: "|", code: .backslash),
    ]
    private static let symbolRow3: [DualKey] = [
        .init(lower: ";", upper: ":", code: .semicolon),
        .init(lower: "'", upper: "\"", code: .quote),
        .init(lower: ",", upper: "<", code: .comma),
        .init(lower: ".", upper: ">", code: .period),
        .init(lower: "/", upper: "?", code: .slash),
    ]

    /// Placed in physical Mac left-edge order: Esc, Tab, Caps Lock, followed by navigation keys.
    private static let navKeys: [NavKey] = [
        .init("Esc", code: .escape, width: 38),
        .init("Tab", code: .tab, width: 38),
        .init(id: "Caps Lock", systemImage: "capslock", code: .capsLock, width: 34, isCapsLock: true),
        .init(id: "Left", systemImage: "chevron.left", code: .leftArrow),
        .init(id: "Down", systemImage: "chevron.down", code: .downArrow),
        .init(id: "Up", systemImage: "chevron.up", code: .upArrow),
        .init(id: "Right", systemImage: "chevron.right", code: .rightArrow),
        .init("Del", code: .forwardDelete, width: 38),
        .init("Home", code: .home, width: 46),
        .init("End", code: .end, width: 38),
        .init("PgUp", code: .pageUp, width: 46),
        .init("PgDn", code: .pageDown, width: 46),
    ]

    private static let fnKeys: [FnKey] = [
        .init(label: "F1", code: .f1), .init(label: "F2", code: .f2),
        .init(label: "F3", code: .f3), .init(label: "F4", code: .f4),
        .init(label: "F5", code: .f5), .init(label: "F6", code: .f6),
        .init(label: "F7", code: .f7), .init(label: "F8", code: .f8),
        .init(label: "F9", code: .f9), .init(label: "F10", code: .f10),
        .init(label: "F11", code: .f11), .init(label: "F12", code: .f12),
    ]

    private var isCompact: Bool { containerWidth > 0 && containerWidth < 560 }
    private var shiftState: RemoteModifierState { modifierStates[.shift] ?? .idle }
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
                ForEach([RemoteModifierKey.control, .option, .command], id: \.self) { key in
                    ModifierKeyCap(
                        symbolName: key.symbolName,
                        filledSymbolName: key.filledSymbolName,
                        state: modifierStates[key] ?? .idle,
                        compact: isCompact
                    ) {
                        withoutAnimation { onToggleModifier(key) }
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
                        ForEach(Self.fnKeys) { item in
                            UtilityKeyCap(
                                label: item.label,
                                systemImage: nil,
                                active: false,
                                compact: isCompact,
                                onKeystroke: { onKeystroke(item.code) },
                                onKeyDown: { onKeyDown(item.code) },
                                onKeyUp: { onKeyUp(item.code) }
                            )
                            .frame(width: isCompact ? 36 : 42, height: barHeight)
                        }
                    } else {
                        ForEach(Self.navKeys) { item in
                            UtilityKeyCap(
                                label: item.label,
                                systemImage: item.isCapsLock
                                    ? (capsLockActive ? "capslock.fill" : "capslock")
                                    : item.systemImage,
                                active: item.isCapsLock ? capsLockActive : false,
                                compact: isCompact,
                                onKeystroke: { onKeystroke(item.code) },
                                onKeyDown: { onKeyDown(item.code) },
                                onKeyUp: { onKeyUp(item.code) }
                            )
                            .frame(
                                width: isCompact
                                    ? max(item.isCapsLock ? 32 : 30, item.width - 2)
                                    : item.width,
                                height: barHeight
                            )
                            .accessibilityLabel(item.id)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: barHeight)
            .layoutPriority(-1)

            topDivider

            // Right pinned dismiss button.
            TapKeyCap(
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
                            compact: isCompact,
                            onKeystroke: { onKeystroke(key.code) },
                            onKeyDown: { onKeyDown(key.code) },
                            onKeyUp: { onKeyUp(key.code) }
                        )
                        .frame(height: keyHeight)
                    }
                } else {
                    ForEach(Self.qwertyRow1) { key in
                        CharacterKeyCap(
                            label: (shiftActive || capsLockActive) ? key.label.uppercased() : key.label,
                            compact: isCompact,
                            onKeystroke: { onKeystroke(key.code) },
                            onKeyDown: { onKeyDown(key.code) },
                            onKeyUp: { onKeyUp(key.code) }
                        )
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
                            compact: isCompact,
                            onKeystroke: { onKeystroke(key.code) },
                            onKeyDown: { onKeyDown(key.code) },
                            onKeyUp: { onKeyUp(key.code) }
                        )
                        .frame(height: keyHeight)
                    }
                } else {
                    ForEach(Self.qwertyRow2) { key in
                        CharacterKeyCap(
                            label: (shiftActive || capsLockActive) ? key.label.uppercased() : key.label,
                            compact: isCompact,
                            onKeystroke: { onKeystroke(key.code) },
                            onKeyDown: { onKeyDown(key.code) },
                            onKeyUp: { onKeyUp(key.code) }
                        )
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
                    symbolName: RemoteModifierKey.shift.symbolName,
                    filledSymbolName: RemoteModifierKey.shift.filledSymbolName,
                    state: shiftState,
                    compact: isCompact,
                    cornerRadius: isCompact ? 8 : 10
                ) {
                    withoutAnimation { onToggleModifier(.shift) }
                }
                .frame(width: isCompact ? 44 : 88, height: keyHeight)
                .accessibilityLabel("Shift")

                if symbolMode {
                    ForEach(Self.symbolRow3) { key in
                        DualSymbolKeyCap(
                            lower: key.lower,
                            upper: key.upper,
                            shiftActive: shiftActive,
                            compact: isCompact,
                            onKeystroke: { onKeystroke(key.code) },
                            onKeyDown: { onKeyDown(key.code) },
                            onKeyUp: { onKeyUp(key.code) }
                        )
                        .frame(height: keyHeight)
                    }
                } else {
                    ForEach(Self.qwertyRow3) { key in
                        CharacterKeyCap(
                            label: (shiftActive || capsLockActive) ? key.label.uppercased() : key.label,
                            compact: isCompact,
                            onKeystroke: { onKeystroke(key.code) },
                            onKeyDown: { onKeyDown(key.code) },
                            onKeyUp: { onKeyUp(key.code) }
                        )
                        .frame(height: keyHeight)
                    }
                }

                HoldActionKeyCap(
                    label: nil,
                    systemImage: "delete.left",
                    prominent: false,
                    compact: isCompact,
                    onKeystroke: { onKeystroke(.delete) },
                    onKeyDown: { onKeyDown(.delete) },
                    onKeyUp: { onKeyUp(.delete) }
                )
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
                    onTap: { onKeystroke(.space) },
                    onScrubStep: onScrubStep,
                    onScrubEnd: onScrubEnd
                )
                .frame(height: keyHeight)

                HoldActionKeyCap(
                    label: nil,
                    systemImage: "return",
                    prominent: true,
                    compact: isCompact,
                    onKeystroke: { onKeystroke(.return) },
                    onKeyDown: { onKeyDown(.return) },
                    onKeyUp: { onKeyUp(.return) }
                )
                .frame(width: isCompact ? 72 : 112, height: keyHeight)
                .opacity(dimOpacity)
                .animation(.easeOut(duration: 0.16), value: scrubbingCursor)
                .accessibilityLabel("Return")
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

// MARK: - Key Touch Recognition (Short Tap = Keystroke, Hold = KeyDown + KeyUp)

/// Distinguishes a short tap (`onKeystroke`) from a press-and-hold (`onKeyDown` → `onKeyUp`)
/// without blocking multi-touch roll-typing or horizontal scroll gestures in ancestor scroll views.
private struct KeyTouchArea: UIViewRepresentable {
    let onPressChanged: (Bool) -> Void
    let onKeystroke: () -> Void
    let onKeyDown: () -> Void
    let onKeyUp: () -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.configure(self)
        return view
    }

    func updateUIView(_ uiView: TouchView, context: Context) {
        uiView.configure(self)
    }

    final class TouchView: UIView {
        private static let holdThreshold: Duration = .milliseconds(250)

        private var onPressChanged: ((Bool) -> Void)?
        private var onKeystroke: (() -> Void)?
        private var onKeyDown: (() -> Void)?
        private var onKeyUp: (() -> Void)?

        private var activeTouch: UITouch?
        private var holdTask: Task<Void, Never>?
        private var didSendKeyDown = false
        private var isHighlighted = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isMultipleTouchEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        func configure(_ area: KeyTouchArea) {
            onPressChanged = area.onPressChanged
            onKeystroke = area.onKeystroke
            onKeyDown = area.onKeyDown
            onKeyUp = area.onKeyUp
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow == nil {
                cancelActiveTouch()
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard activeTouch == nil, let touch = touches.first else { return }
            activeTouch = touch
            didSendKeyDown = false
            setHighlighted(true)
            holdTask?.cancel()
            holdTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.holdThreshold)
                guard !Task.isCancelled, let self, self.activeTouch != nil, self.isHighlighted else {
                    return
                }
                self.didSendKeyDown = true
                self.onKeyDown?()
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let activeTouch, touches.contains(activeTouch) else { return }
            if didSendKeyDown { return }
            let inside = bounds.insetBy(dx: -16, dy: -16).contains(activeTouch.location(in: self))
            if inside != isHighlighted {
                setHighlighted(inside)
                if !inside {
                    holdTask?.cancel()
                    holdTask = nil
                }
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let activeTouch, touches.contains(activeTouch) else { return }
            let wasHeld = didSendKeyDown
            let inside = bounds.insetBy(dx: -16, dy: -16).contains(activeTouch.location(in: self))
            finishTouch()
            if wasHeld {
                onKeyUp?()
            } else if inside {
                onKeystroke?()
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let activeTouch, touches.contains(activeTouch) else { return }
            cancelActiveTouch()
        }

        private func cancelActiveTouch() {
            guard activeTouch != nil || didSendKeyDown else { return }
            let wasHeld = didSendKeyDown
            finishTouch()
            if wasHeld {
                onKeyUp?()
            }
        }

        private func finishTouch() {
            holdTask?.cancel()
            holdTask = nil
            activeTouch = nil
            didSendKeyDown = false
            setHighlighted(false)
        }

        private func setHighlighted(_ highlighted: Bool) {
            guard isHighlighted != highlighted else { return }
            isHighlighted = highlighted
            onPressChanged?(highlighted)
        }
    }
}

private struct HoldableKeySurface<Label: View>: View {
    let normalFill: Color
    let pressedFill: Color
    let cornerRadius: CGFloat
    let onKeystroke: () -> Void
    let onKeyDown: () -> Void
    let onKeyUp: () -> Void
    @ViewBuilder let label: Label

    @State private var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(pressed ? pressedFill : normalFill, in: shape)
            .contentShape(shape)
            .overlay {
                KeyTouchArea(
                    onPressChanged: { isPressed in
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { pressed = isPressed }
                    },
                    onKeystroke: onKeystroke,
                    onKeyDown: onKeyDown,
                    onKeyUp: onKeyUp
                )
            }
            .transaction { $0.animation = nil }
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
    let onKeystroke: () -> Void
    let onKeyDown: () -> Void
    let onKeyUp: () -> Void

    var body: some View {
        HoldableKeySurface(
            normalFill: .white.opacity(0.20),
            pressedFill: .white.opacity(0.38),
            cornerRadius: compact ? 8 : 10,
            onKeystroke: onKeystroke,
            onKeyDown: onKeyDown,
            onKeyUp: onKeyUp
        ) {
            Text(label)
                .font(.system(size: compact ? 20 : 21, weight: .regular))
                .foregroundStyle(.white)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}

private struct DualSymbolKeyCap: View {
    let lower: String
    let upper: String
    let shiftActive: Bool
    let compact: Bool
    let onKeystroke: () -> Void
    let onKeyDown: () -> Void
    let onKeyUp: () -> Void

    var body: some View {
        HoldableKeySurface(
            normalFill: .white.opacity(0.20),
            pressedFill: .white.opacity(0.38),
            cornerRadius: compact ? 8 : 10,
            onKeystroke: onKeystroke,
            onKeyDown: onKeyDown,
            onKeyUp: onKeyUp
        ) {
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
        .accessibilityElement()
        .accessibilityLabel(shiftActive ? upper : lower)
        .accessibilityAddTraits(.isButton)
    }
}

private struct HoldActionKeyCap: View {
    let label: String?
    let systemImage: String?
    let prominent: Bool
    let compact: Bool
    let onKeystroke: () -> Void
    let onKeyDown: () -> Void
    let onKeyUp: () -> Void

    var body: some View {
        HoldableKeySurface(
            normalFill: .white.opacity(prominent ? 0.28 : 0.12),
            pressedFill: .white.opacity(prominent ? 0.42 : 0.28),
            cornerRadius: compact ? 8 : 10,
            onKeystroke: onKeystroke,
            onKeyDown: onKeyDown,
            onKeyUp: onKeyUp
        ) {
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
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
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
    let onKeystroke: () -> Void
    let onKeyDown: () -> Void
    let onKeyUp: () -> Void

    private static let activeFill = Color(white: 0.96)
    private static let activeInk = Color(white: 0.08)

    var body: some View {
        let ink: Color = active ? Self.activeInk : .white
        HoldableKeySurface(
            normalFill: active ? Self.activeFill : .white.opacity(0.11),
            pressedFill: active ? .white.opacity(0.82) : .white.opacity(0.28),
            cornerRadius: compact ? 8 : 9,
            onKeystroke: onKeystroke,
            onKeyDown: onKeyDown,
            onKeyUp: onKeyUp
        ) {
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
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
    }
}

private struct TapKeyCap: View {
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
    let state: RemoteModifierState
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

/// Spacebar that inserts a space on tap and scrubs left/right arrows on long-press drag.
private struct SpacebarKeyCap: View {
    @Binding var scrubbing: Bool
    let compact: Bool
    let onTap: () -> Void
    let onScrubStep: (KeyboardKeyCode) -> Void
    let onScrubEnd: () -> Void

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
                onScrubStep: onScrubStep,
                onEnded: { wasLongPress in
                    pressed = false
                    if wasLongPress {
                        scrubbing = false
                        onScrubEnd()
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

/// Distinguishes tap from hold-and-drag on the spacebar from touch-down, emitting horizontal arrow
/// steps while scrubbing.
private struct SpacebarTouchArea: UIViewRepresentable {
    let onTouchDown: () -> Void
    let onLongPressBegan: () -> Void
    let onScrubStep: (KeyboardKeyCode) -> Void
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
        private static let scrubStepWidth: CGFloat = 14

        var area: SpacebarTouchArea?
        private let activateFeedback = UIImpactFeedbackGenerator(style: .medium)
        private let stepFeedback = UISelectionFeedbackGenerator()
        private var holdTask: Task<Void, Never>?
        private var isLongPress = false
        private var lastStepX: CGFloat = 0

        @objc func handlePress(_ gesture: UILongPressGestureRecognizer) {
            guard let area, let view = gesture.view else { return }
            let locationX = gesture.location(in: view).x
            switch gesture.state {
            case .began:
                isLongPress = false
                lastStepX = locationX
                activateFeedback.prepare()
                stepFeedback.prepare()
                area.onTouchDown()
                holdTask?.cancel()
                holdTask = Task { @MainActor [weak self, weak gesture] in
                    try? await Task.sleep(for: .milliseconds(280))
                    guard !Task.isCancelled, let self, let gesture, let view = gesture.view else {
                        return
                    }
                    self.isLongPress = true
                    self.lastStepX = gesture.location(in: view).x
                    self.activateFeedback.impactOccurred()
                    self.stepFeedback.prepare()
                    self.area?.onLongPressBegan()
                }
            case .changed:
                guard isLongPress else { return }
                var delta = locationX - lastStepX
                while delta >= Self.scrubStepWidth {
                    stepFeedback.selectionChanged()
                    area.onScrubStep(.rightArrow)
                    lastStepX += Self.scrubStepWidth
                    delta -= Self.scrubStepWidth
                }
                while delta <= -Self.scrubStepWidth {
                    stepFeedback.selectionChanged()
                    area.onScrubStep(.leftArrow)
                    lastStepX -= Self.scrubStepWidth
                    delta += Self.scrubStepWidth
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
        RemoteKeyboardView(
            modifierStates: [:],
            capsLockActive: false,
            onToggleModifier: { _ in },
            onKeystroke: { _ in },
            onKeyDown: { _ in },
            onKeyUp: { _ in },
            onScrubStep: { _ in },
            onScrubEnd: {},
            onDismiss: {}
        )
        .ignoresSafeArea(edges: [.bottom, .horizontal])
    }
}

#Preview("Keyboard — Portrait") {
    ZStack(alignment: .bottom) {
        Color.black.ignoresSafeArea()
        RemoteKeyboardView(
            modifierStates: [:],
            capsLockActive: false,
            onToggleModifier: { _ in },
            onKeystroke: { _ in },
            onKeyDown: { _ in },
            onKeyUp: { _ in },
            onScrubStep: { _ in },
            onScrubEnd: {},
            onDismiss: {}
        )
        .ignoresSafeArea(edges: [.bottom, .horizontal])
    }
}
