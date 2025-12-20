// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Native SwiftUI renderer for Mermaid mindmaps
struct MindmapRenderer: View {
    let mindmap: Mindmap

    private let nodeWidth: CGFloat = 120
    private let nodeHeight: CGFloat = 40
    private let horizontalSpacing: CGFloat = 60
    private let verticalSpacing: CGFloat = 50

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                MindmapNodeView(
                    node: mindmap.root,
                    position: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2),
                    isRoot: true
                )
            }
        }
        .frame(minHeight: 300)
    }
}

struct MindmapNodeView: View {
    let node: MindmapNode
    let position: CGPoint
    let isRoot: Bool

    var body: some View {
        ZStack {
            // Node
            if isRoot {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 140, height: 50)
                    .overlay(
                        Text(node.label)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primary)
                    )
                    .position(position)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 100, height: 35)
                    .overlay(
                        Text(node.label)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                    )
                    .position(position)
            }

            // Children (simplified for now)
            ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                let childPos = CGPoint(
                    x: position.x + 150,
                    y: position.y + CGFloat(index - node.children.count / 2) * 60
                )

                Path { path in
                    path.move(to: position)
                    path.addLine(to: childPos)
                }
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 2)

                MindmapNodeView(node: child, position: childPos, isRoot: false)
            }
        }
    }
}
