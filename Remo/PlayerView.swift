//
//  Created by Cyandev on 11/21/26.
//

import SwiftUI
import UIKit

/// The remote screen with system chrome hidden and a compact control pill that fades while streaming.
struct PlayerView: View {
    let player: StreamPlayer
    let surface: VideoSurface
    let title: String

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var controlsDimmed = false
    @State private var controlsFrame = CGRect.zero
    @State private var keyboardVisible = false
    @State private var keyboardFrame = CGRect.zero
    @State private var fadeTask: Task<Void, Never>?

    var body: some View {
        // Controls and the trackpad stay inside the safe area; only the backdrop and video reach
        // beyond it, from the background so they can’t stretch this stack to the full screen.
        ZStack {
            // Hosts the video as the view it zooms, so it stays up from the moment the session
            // starts: the surface only draws frames while it is in a window. It stays clear of
            // the sensor housing at the sides but uses the full height, like the picture.
            // The trackpad’s UIKit view takes real touches from SwiftUI controls drawn over it.
            TrackpadView(
                onInput: player.handleTrackpad,
                excludedRects: [controlsFrame] + (keyboardVisible ? [keyboardFrame] : []),
                showsWheel: player.phase == .streaming && player.mouseAvailable,
                surface: surface, videoSize: player.videoSize,
                bottomInset: keyboardVisible ? keyboardFrame.height : 0)
                .ignoresSafeArea(edges: .vertical)

            if let status {
                ProgressView(status)
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black, ignoresSafeAreaEdges: .all)
        .overlay {
            if keyboardVisible {
                ZStack(alignment: .bottom) {
                    Color.clear.allowsHitTesting(false)
                    RemoteKeyboardView {
                        setKeyboardVisible(false)
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { keyboardFrame = $0 }
                }
                .ignoresSafeArea(edges: [.bottom, .horizontal])
                .transition(.move(edge: .bottom))
            }
        }
        .overlay(alignment: .topLeading) {
            controls
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controlsFrame = $0 }
                .padding()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Watching or driving the remote screen doesn’t touch the phone’s own screen often enough
        // to keep it awake, so auto-lock is off for as long as the player is up.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            fadeTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .task(id: player.phase) {
            withAnimation { controlsDimmed = false }
            guard player.phase == .streaming, !voiceOver else { return }
            scheduleFadeOut()
        }
    }

    private var status: String? {
        switch player.phase {
        case .connecting: String(localized: "Connecting…")
        case .waitingForVideo: String(localized: "Waiting for video…")
        default: nil
        }
    }

    private var controls: some View {
        let showKeyboardButton = !controlsDimmed || keyboardVisible

        return HStack(spacing: 0) {
            Button {
                player.disconnect()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.trailing, showKeyboardButton ? 10 : 14)
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Disconnect from \(title)")

            if showKeyboardButton {
                Rectangle()
                    .fill(.white.opacity(0.2))
                    .frame(width: 1, height: 18)

                Button {
                    setKeyboardVisible(!keyboardVisible)
                } label: {
                    Image(systemName: "keyboard")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(keyboardVisible ? Color(white: 0.08) : .white)
                        .frame(width: 34, height: 34)
                        .background(
                            keyboardVisible ? Color(white: 0.96) : .white.opacity(0.14),
                            in: .circle)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .padding(.trailing, 5)
                .accessibilityLabel(keyboardVisible ? "Hide keyboard" : "Show keyboard")
            }
        }
        .glassEffect(.regular.tint(.black.opacity(0.45)).interactive(), in: .capsule)
        .opacity(controlsDimmed && !keyboardVisible ? 0.4 : 1)
        .overlay {
            if controlsDimmed && !keyboardVisible {
                Capsule()
                    .fill(.clear)
                    .contentShape(.capsule)
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.32, bounce: 0.1)) {
                            controlsDimmed = false
                        }
                        scheduleFadeOut()
                    }
            }
        }
        .padding(12)
    }

    private func setKeyboardVisible(_ visible: Bool) {
        withAnimation(.spring) {
            keyboardVisible = visible
            if visible {
                controlsDimmed = false
            }
        }
        if visible {
            fadeTask?.cancel()
        } else {
            scheduleFadeOut()
        }
    }

    private func scheduleFadeOut() {
        fadeTask?.cancel()
        guard player.phase == .streaming, !voiceOver, !keyboardVisible else { return }
        fadeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !keyboardVisible else { return }
            withAnimation(.easeOut(duration: 0.6)) { controlsDimmed = true }
        }
    }
}
