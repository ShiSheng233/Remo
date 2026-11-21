//
//  Created by Cyandev on 11/21/26.
//

import SwiftUI

/// The remote screen with system chrome hidden and a compact control pill that fades while streaming.
struct PlayerView: View {
    let player: StreamPlayer
    let surface: VideoSurface
    let title: String

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var controlsDimmed = false
    @State private var controlsFrame = CGRect.zero

    var body: some View {
        // Controls and the trackpad stay inside the safe area; only the backdrop and video reach
        // beyond it, from the background so they can’t stretch this stack to the full screen.
        ZStack {
            // Hosts the video as the view it zooms, so it stays up from the moment the session
            // starts: the surface only draws frames while it is in a window. It stays clear of
            // the sensor housing at the sides but uses the full height, like the picture.
            // The trackpad’s UIKit view takes real touches from SwiftUI controls drawn over it.
            TrackpadView(
                onInput: player.handleTrackpad, excludedRects: [controlsFrame],
                showsWheel: player.phase == .streaming && player.mouseAvailable,
                surface: surface, videoSize: player.videoSize)
                .ignoresSafeArea(edges: .vertical)

            if let status {
                ProgressView(status)
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black, ignoresSafeAreaEdges: .all)
        .overlay(alignment: .topLeading) {
            controls
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controlsFrame = $0 }
                .padding()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task(id: player.phase) {
            withAnimation { controlsDimmed = false }
            guard player.phase == .streaming, !voiceOver else { return }
            await fadeOutControls()
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
                    .padding(.trailing, 14)
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.black.opacity(0.45)).interactive(), in: .capsule)
        .opacity(controlsDimmed ? 0.4 : 1)
        .overlay {
            if controlsDimmed {
                Capsule()
                    .fill(.clear)
                    .contentShape(.capsule)
                    .onTapGesture {
                        withAnimation { controlsDimmed = false }
                        Task { await fadeOutControls() }
                    }
            }
        }
        .accessibilityLabel("Disconnect from \(title)")
        .padding(12)
    }
    
    private func fadeOutControls() async {
        try? await Task.sleep(for: .seconds(3))
        withAnimation(.easeOut(duration: 0.6)) { controlsDimmed = true }
    }
}
