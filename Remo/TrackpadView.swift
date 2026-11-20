//
//  Created by Cyandev on 11/21/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import RemoEngine
import SwiftUI
import UIKit

enum TrackpadGesture {
    case move(CGPoint)
    case scroll(CGFloat)
    case button(MouseMessage.Button)
}

struct TrackpadView: View {
    let onInput: (TrackpadGesture) -> Void

    var body: some View {
        HStack(spacing: 0) {
            TrackpadRegion(edge: false, onInput: onInput)
            TrackpadRegion(edge: true, onInput: onInput)
                .frame(width: 44)
        }
    }
}

private struct TrackpadRegion: UIViewRepresentable {
    let edge: Bool
    let onInput: (TrackpadGesture) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(edge: edge, onInput: onInput) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let coordinator = context.coordinator
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan))
        pan.maximumNumberOfTouches = 1
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap))
        tap.require(toFail: pan)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        if !edge {
            let hold = UILongPressGestureRecognizer(
                target: coordinator, action: #selector(Coordinator.hold))
            hold.minimumPressDuration = 0.4
            view.addGestureRecognizer(hold)
            pan.require(toFail: hold)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onInput = onInput
    }

    final class Coordinator: NSObject {
        let edge: Bool
        var onInput: (TrackpadGesture) -> Void
        private var dragLocation: CGPoint?

        init(edge: Bool, onInput: @escaping (TrackpadGesture) -> Void) {
            self.edge = edge
            self.onInput = onInput
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .began || gesture.state == .changed || gesture.state == .ended
            else { return }
            let translation = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            onInput(edge ? .scroll(translation.y) : .move(translation))
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            onInput(.button(edge ? .rightClick : .leftClick))
        }

        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            let location = gesture.location(in: gesture.view)
            switch gesture.state {
            case .began:
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
