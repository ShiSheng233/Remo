//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import RemoEngine
import SwiftUI
import UIKit

enum TrackpadGesture {
    case move(CGPoint)
    /// Whole lines; positive values move the content down, following the finger.
    case scroll(lines: Int)
    case button(MouseMessage.Button)
}

struct TrackpadView: View {
    let onInput: (TrackpadGesture) -> Void
    /// Window-space frames of SwiftUI controls drawn over the trackpad.
    var excludedRects: [CGRect] = []

    @State private var wheelFrame = CGRect.zero

    var body: some View {
        // The trackpad’s UIKit view would otherwise take real touches meant for the wheel.
        TrackpadRegion(onInput: onInput, excludedRects: excludedRects + [wheelFrame])
            .overlay(alignment: .trailing) {
                ScrollWheel(onInput: onInput)
                    .containerRelativeFrame(.vertical) { height, _ in min(height * 0.6, 120) }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        wheelFrame = $0
                    }
                    .padding(.trailing, 16)
            }
    }
}

/// A detented wheel: each step of finger travel scrolls one line with a haptic tick.
///
/// SwiftUI only draws it. Touches are tracked by `WheelTouchArea`, because a SwiftUI gesture laid
/// over the trackpad’s UIKit view stopped every other button on the screen from responding.
private struct ScrollWheel: View {
    let onInput: (TrackpadGesture) -> Void

    /// Finger travel for one detent.
    private static let step: CGFloat = 6
    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    /// Where the ticks sit; follows the finger and springs onto a detent when it lifts.
    @State private var travel: CGFloat = 0
    @State private var dragBase: CGFloat = 0
    @State private var sentSteps = 0
    @State private var detents = 0
    @State private var pressed = false

    var body: some View {
        ZStack {
            Self.shape.fill(.black.opacity(0.35))
            Ticks(offset: travel, step: Self.step)
                .fill(.white.opacity(0.7))
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0), .init(color: .black, location: 0.25),
                            .init(color: .black, location: 0.75), .init(color: .clear, location: 1),
                        ], startPoint: .top, endPoint: .bottom))
            Self.shape.strokeBorder(.white.opacity(0.25), lineWidth: 1)
        }
        .clipShape(Self.shape)
        .frame(width: 36)
        .scaleEffect(pressed ? 1.12 : 1)
        .opacity(pressed ? 1 : 0.45)
        .animation(.spring(duration: 0.35, bounce: 0.45), value: pressed)
        .allowsHitTesting(false)
        .padding(.horizontal, 4)
        .overlay {
            WheelTouchArea(onBegan: { pressed = true }, onMoved: moved, onEnded: ended)
        }
        .sensoryFeedback(.selection, trigger: detents)
        .accessibilityElement()
        .accessibilityLabel("Scroll wheel")
        .accessibilityHint("Swipe up or down to scroll one line. Double-tap to right-click.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onInput(.scroll(lines: -1))
            case .decrement: onInput(.scroll(lines: 1))
            @unknown default: break
            }
        }
        .accessibilityAction { onInput(.button(.rightClick)) }
    }

    private func moved(_ translation: CGFloat) {
        travel = dragBase + translation
        let steps = Int((translation / Self.step).rounded(.towardZero))
        let delta = steps - sentSteps
        guard delta != 0 else { return }
        sentSteps = steps
        // One command per detent, never a batched count.
        for _ in 0..<abs(delta) { onInput(.scroll(lines: delta.signum())) }
        detents += abs(delta)
    }

    /// A touch that barely moved is a right-click.
    private func ended(_ translation: CGSize, cancelled: Bool) {
        pressed = false
        if !cancelled, sentSteps == 0, abs(translation.width) < 4, abs(translation.height) < 4 {
            onInput(.button(.rightClick))
        }
        let settled = dragBase + CGFloat(sentSteps) * Self.step
        dragBase = settled
        sentSteps = 0
        withAnimation(.spring(duration: 0.4, bounce: 0.35)) { travel = settled }
    }
}

/// Follows one finger from the moment it lands, reporting its travel to the wheel.
private struct WheelTouchArea: UIViewRepresentable {
    let onBegan: () -> Void
    let onMoved: (CGFloat) -> Void
    let onEnded: (CGSize, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        // A zero-duration long press tracks the touch from touch-down, unlike a pan.
        let press = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.press))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.area = self
    }

    final class Coordinator: NSObject {
        var area: WheelTouchArea?
        private var start = CGPoint.zero

        @objc func press(_ gesture: UILongPressGestureRecognizer) {
            guard let area else { return }
            let location = gesture.location(in: gesture.view)
            let translation = CGSize(width: location.x - start.x, height: location.y - start.y)
            switch gesture.state {
            case .began:
                start = location
                area.onBegan()
            case .changed:
                area.onMoved(translation.height)
            case .ended:
                area.onEnded(translation, false)
            case .cancelled, .failed:
                area.onEnded(translation, true)
            default: break
            }
        }
    }
}

/// Evenly spaced tick marks shifted by `offset`, animatable so they can spring between detents.
private struct Ticks: Shape {
    var offset: CGFloat
    let step: CGFloat

    var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let phase = (offset.truncatingRemainder(dividingBy: step) + step)
            .truncatingRemainder(dividingBy: step)
        let width: CGFloat = 14
        var y = rect.minY + phase - step / 2
        while y < rect.maxY + step {
            path.addRoundedRect(
                in: CGRect(x: rect.midX - width / 2, y: y - 1, width: width, height: 2),
                cornerSize: CGSize(width: 1, height: 1))
            y += step
        }
        return path
    }
}

/// Leaves touches inside `excludedRects` (window space) to the SwiftUI controls drawn over it.
///
/// Taps are read from raw touches rather than a `UITapGestureRecognizer`: SwiftUI makes buttons
/// drawn over this view wait for such a recognizer to fail, which it never does for touches it
/// isn’t given, so those buttons stopped responding.
private final class TouchSurface: UIView {
    var excludedRects: [CGRect] = []
    var onTap: (() -> Void)?
    private var tapStart: (location: CGPoint, time: TimeInterval)?

    func excludes(windowPoint: CGPoint) -> Bool {
        excludedRects.contains { $0.contains(windowPoint) }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !excludes(windowPoint: convert(point, to: nil)) && super.point(inside: point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard event?.allTouches?.count == 1, let touch = touches.first else {
            tapStart = nil
            return
        }
        tapStart = (touch.location(in: self), touch.timestamp)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let start = tapStart, let touch = touches.first else { return }
        tapStart = nil
        // The pan and hold recognizers cancel the touch once they begin, so a drag never ends here.
        let location = touch.location(in: self)
        if touch.timestamp - start.time < 0.35,
            hypot(location.x - start.location.x, location.y - start.location.y) < 10
        {
            onTap?()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        tapStart = nil
    }
}

private struct TrackpadRegion: UIViewRepresentable {
    let onInput: (TrackpadGesture) -> Void
    let excludedRects: [CGRect]

    func makeCoordinator() -> Coordinator { Coordinator(onInput: onInput) }

    func makeUIView(context: Context) -> TouchSurface {
        let view = TouchSurface()
        let coordinator = context.coordinator
        coordinator.surface = view
        view.onTap = { [weak coordinator] in coordinator?.onInput(.button(.leftClick)) }
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan))
        pan.maximumNumberOfTouches = 1
        let hold = UILongPressGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.hold))
        hold.minimumPressDuration = 0.4
        pan.require(toFail: hold)
        for recognizer in [pan, hold] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ uiView: TouchSurface, context: Context) {
        context.coordinator.onInput = onInput
        uiView.excludedRects = excludedRects
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onInput: (TrackpadGesture) -> Void
        weak var surface: TouchSurface?
        private var dragLocation: CGPoint?
        private var touchDown = CGPoint.zero
        private var panIgnored = false

        init(onInput: @escaping (TrackpadGesture) -> Void) {
            self.onInput = onInput
        }

        // Touches on the controls drawn over the trackpad still reach these recognizers. Refusing
        // them would leave the recognizers pending, and SwiftUI buttons wait on them, so they are
        // taken and later ignored instead.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchDown = touch.location(in: nil)
            return true
        }

        private var startedOnControl: Bool {
            surface?.excludes(windowPoint: touchDown) ?? false
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { panIgnored = startedOnControl }
            guard !panIgnored,
                gesture.state == .began || gesture.state == .changed || gesture.state == .ended
            else { return }
            let translation = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            onInput(.move(translation))
        }

        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            let location = gesture.location(in: gesture.view)
            switch gesture.state {
            case .began:
                guard !startedOnControl else { return }
                dragLocation = location
                onInput(.button(.leftDown))
            case .changed, .ended:
                guard let previous = dragLocation else { return }
                dragLocation = location
                onInput(.move(CGPoint(x: location.x - previous.x, y: location.y - previous.y)))
                if gesture.state == .ended { endDrag() }
            case .cancelled, .failed:
                endDrag()
            default: break
            }
        }

        private func endDrag() {
            guard dragLocation != nil else { return }
            dragLocation = nil
            onInput(.button(.leftUp))
        }
    }
}
