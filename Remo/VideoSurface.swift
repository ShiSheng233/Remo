//
//  Created by Cyandev on 11/20/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import CoreImage
import Metal
import QuartzCore
import RemoCodec
import SwiftUI
import UIKit

@MainActor
final class VideoSurface: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var display: CAMetalLayer { layer as! CAMetalLayer }
    private let queue: (any MTLCommandQueue)?
    private let context: CIContext?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init() {
        let device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        context = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
        super.init(frame: .zero)
        backgroundColor = .black
        display.device = device
        display.pixelFormat = .bgra8Unorm
        display.framebufferOnly = false
        display.colorspace = colorSpace
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let screen = window?.windowScene?.screen, !bounds.isEmpty else { return }
        let scale = screen.nativeScale
        if contentScaleFactor != scale { contentScaleFactor = scale }
        display.drawableSize = CGSize(
            width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    func present(_ frame: DecodedVideoFrame) throws -> Bool {
        guard let queue, let context else { throw CocoaError(.featureUnsupported) }
        guard window != nil, !bounds.isEmpty,
            let drawable = display.nextDrawable(), let commands = queue.makeCommandBuffer()
        else { return false }

        let canvas = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
        let image = CIImage(cvPixelBuffer: frame.pixels)
        let extent = image.extent
        let scale = min(canvas.width / extent.width, canvas.height / extent.height)
        let transform = CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: canvas.midX - extent.midX * scale, ty: canvas.midY - extent.midY * scale)
        let fitted = image.transformed(by: transform).composited(over: CIImage(color: .black))
        context.render(
            fitted, to: drawable.texture, commandBuffer: commands, bounds: canvas,
            colorSpace: colorSpace)
        commands.present(drawable)
        commands.commit()
        return true
    }
}

struct VideoSurfaceView: UIViewRepresentable {
    let surface: VideoSurface

    func makeUIView(context: Context) -> VideoSurface { surface }
    func updateUIView(_ uiView: VideoSurface, context: Context) {}
}
