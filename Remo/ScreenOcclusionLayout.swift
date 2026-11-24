//
//  Created by Cyandev on 11/24/26.
//  Copyright (c) 2026 Cyandev. All rights reserved.
//

import SwiftUI

/// Computes per-control edge insets from exact hardware/system occlusion regions and container
/// corner insets, so an asymmetric cutout (such as iPhone Duo's corner camera) only pushes
/// controls that actually intersect it instead of insetting an entire edge.
@available(iOS 27.1, *)
struct ScreenOcclusionLayout {
    struct Occlusion {
        /// Reserved rect in the container's coordinate space, already including system margins.
        let frame: CGRect
        /// Interactive margins already included inside `frame`.
        let margins: EdgeInsets
    }

    let size: CGSize
    let occlusions: [Occlusion]
    let cornerInsets: RectangleCornerInsets

    init(proxy: GeometryProxy) {
        self.size = proxy.size
        self.occlusions = proxy.reservedRegions(kind: .occlusion).map {
            Occlusion(frame: $0.frame, margins: $0.margins)
        }
        self.cornerInsets = proxy.containerCornerInsets
    }

    /// Trailing inset for a control centered vertically in the space above `bottomInset`.
    func trailingInset(
        forCenteredHeight height: CGFloat,
        width controlWidth: CGFloat,
        bottomInset: CGFloat,
        baseMargin: CGFloat = 16,
        minimumCutoutGap: CGFloat = 12
    ) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return baseMargin }

        let availableHeight = max(0, size.height - bottomInset)
        let minY = max(0, (availableHeight - height) / 2)
        let maxY = minY + height

        var trailing = baseMargin

        if minY < cornerInsets.topTrailing.height {
            trailing = max(trailing, cornerInsets.topTrailing.width)
        }
        if maxY > size.height - cornerInsets.bottomTrailing.height {
            trailing = max(trailing, cornerInsets.bottomTrailing.width)
        }

        let sortedOcclusions =
            occlusions
            .filter { !$0.frame.isEmpty }
            .sorted { $0.frame.maxX > $1.frame.maxX }

        for occlusion in sortedOcclusions {
            let avoid = expandedRect(for: occlusion, minimumGap: minimumCutoutGap)
            guard avoid.maxY > minY, avoid.minY < maxY else { continue }
            guard avoid.midX > size.width / 2 else { continue }
            if avoid.maxX > size.width - trailing - controlWidth {
                trailing = max(trailing, size.width - avoid.minX)
            }
        }

        return trailing
    }

    /// Leading and top insets for a control anchored to the top-leading corner.
    ///
    /// `innerPadding` is the transparent hit-exclusion padding around the visible control inside
    /// `controlSize`, so collision avoidance aligns the visible control itself against occlusions
    /// without double-padding.
    func topLeadingInsets(
        for controlSize: CGSize,
        innerPadding: CGFloat,
        baseMargin: CGFloat = 16,
        minimumCutoutGap: CGFloat = 12
    ) -> (leading: CGFloat, top: CGFloat) {
        guard size.width > 0, size.height > 0 else { return (baseMargin, baseMargin) }

        let measuredWidth = controlSize.width > 0 ? controlSize.width : 180
        let measuredHeight = controlSize.height > 0 ? controlSize.height : 68
        let visibleWidth = max(0, measuredWidth - innerPadding * 2)
        let visibleHeight = max(0, measuredHeight - innerPadding * 2)

        var leading = baseMargin
        var top = baseMargin

        if top + innerPadding < cornerInsets.topLeading.height, cornerInsets.topLeading.width > 0 {
            leading = max(leading, cornerInsets.topLeading.width)
        }

        let sortedOcclusions =
            occlusions
            .filter { !$0.frame.isEmpty }
            .sorted { $0.frame.minX < $1.frame.minX }

        for occlusion in sortedOcclusions {
            let avoid = expandedRect(for: occlusion, minimumGap: minimumCutoutGap)
            let isAnchoredLeading = occlusion.frame.minX <= size.width * 0.25
            let isTopCentered =
                !isAnchoredLeading
                && occlusion.frame.maxX < size.width * 0.75
                && avoid.minY <= top + innerPadding

            // Keep the pill consistently below a top-center cutout (e.g. portrait Dynamic Island)
            // so its vertical position doesn't jump when the keyboard button appears or fades.
            if isTopCentered {
                top = max(top, avoid.maxY - innerPadding)
                continue
            }

            let visibleRect = CGRect(
                x: leading + innerPadding,
                y: top + innerPadding,
                width: visibleWidth,
                height: visibleHeight)
            guard visibleRect.intersects(avoid) else { continue }

            let pushedLeading = max(leading, avoid.maxX - innerPadding)
            let fitsHorizontally =
                pushedLeading + innerPadding + visibleWidth + baseMargin <= size.width

            if isAnchoredLeading && fitsHorizontally {
                leading = pushedLeading
            } else {
                top = max(top, avoid.maxY - innerPadding)
            }
        }

        return (leading, top)
    }

    private func expandedRect(for occlusion: Occlusion, minimumGap: CGFloat) -> CGRect {
        let frame = occlusion.frame
        let extraLeading = max(0, minimumGap - occlusion.margins.leading)
        let extraTrailing = max(0, minimumGap - occlusion.margins.trailing)
        let extraTop = max(0, minimumGap - occlusion.margins.top)
        let extraBottom = max(0, minimumGap - occlusion.margins.bottom)
        return CGRect(
            x: frame.minX - extraLeading,
            y: frame.minY - extraTop,
            width: frame.width + extraLeading + extraTrailing,
            height: frame.height + extraTop + extraBottom)
    }
}
