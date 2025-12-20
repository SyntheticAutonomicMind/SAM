// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// FlowLayout.swift SAM Custom wrapping layout for responsive UI components.

import SwiftUI

/// A layout that arranges its children in a flowing pattern, wrapping to new lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 12
    var alignment: HorizontalAlignment = .leading

    struct Cache {
        var sizes: [CGSize] = []
        var totalHeight: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        cache.sizes = sizes

        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity

        for size in sizes {
            if currentX + size.width > maxWidth && currentX > 0 {
                /// Move to next line.
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        currentY += lineHeight
        cache.totalHeight = currentY

        return CGSize(width: maxWidth, height: currentY)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        var lineViews: [(subview: LayoutSubview, x: CGFloat, size: CGSize)] = []

        let maxWidth = bounds.width

        for (index, subview) in subviews.enumerated() {
            let size = cache.sizes[index]

            if currentX - bounds.minX + size.width > maxWidth && currentX > bounds.minX {
                /// Place the current line.
                placeLine(lineViews, y: currentY, lineHeight: lineHeight, bounds: bounds)

                /// Move to next line.
                lineViews.removeAll()
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            lineViews.append((subview, currentX, size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        /// Place the last line.
        if !lineViews.isEmpty {
            placeLine(lineViews, y: currentY, lineHeight: lineHeight, bounds: bounds)
        }
    }

    private func placeLine(_ views: [(subview: LayoutSubview, x: CGFloat, size: CGSize)], y: CGFloat, lineHeight: CGFloat, bounds: CGRect) {
        for (subview, x, size) in views {
            /// Center vertically within the line.
            let yOffset = y + (lineHeight - size.height) / 2
            subview.place(at: CGPoint(x: x, y: yOffset), proposal: ProposedViewSize(size))
        }
    }
}
