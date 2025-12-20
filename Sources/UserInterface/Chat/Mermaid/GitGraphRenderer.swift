// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Native SwiftUI renderer for Mermaid git graphs
struct GitGraphRenderer: View {
    let graph: GitGraph

    private let commitSize: CGFloat = 12
    private let horizontalSpacing: CGFloat = 60
    private let verticalSpacing: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Branch lines
                ForEach(graph.branches) { branch in
                    let branchCommits = graph.commits.filter { $0.branch == branch.name }

                    Path { path in
                        for (index, commit) in branchCommits.enumerated() {
                            let pos = commitPosition(
                                commitIndex: graph.commits.firstIndex(where: { $0.id == commit.id }) ?? 0,
                                branchOrder: branch.order,
                                in: geometry.size
                            )

                            if index == 0 {
                                path.move(to: pos)
                            } else {
                                path.addLine(to: pos)
                            }
                        }
                    }
                    .stroke(branchColor(branch.order), lineWidth: 3)
                }

                // Commits
                ForEach(Array(graph.commits.enumerated()), id: \.element.id) { index, commit in
                    let branchOrder = graph.branches.first(where: { $0.name == commit.branch })?.order ?? 0
                    let pos = commitPosition(commitIndex: index, branchOrder: branchOrder, in: geometry.size)

                    GitCommitView(commit: commit, color: branchColor(branchOrder))
                        .position(pos)
                }
            }
        }
        .frame(minHeight: 300)
    }

    private func commitPosition(commitIndex: Int, branchOrder: Int, in size: CGSize) -> CGPoint {
        let x = 100 + CGFloat(commitIndex) * horizontalSpacing
        let y = 100 + CGFloat(branchOrder) * verticalSpacing
        return CGPoint(x: x, y: y)
    }

    private func branchColor(_ order: Int) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .red, .pink]
        return colors[order % colors.count]
    }
}

struct GitCommitView: View {
    let commit: GitCommit
    let color: Color

    var body: some View {
        ZStack {
            // Commit circle
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)

            Circle()
                .stroke(color.opacity(0.5), lineWidth: 2)
                .frame(width: 20, height: 20)

            // Always show commit ID
            Text(commit.id)
                .font(.system(size: 10, design: .monospaced))
                .padding(4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
                .offset(x: 0, y: -20)

            // Show message or tag below if available
            if let message = commit.message {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(3)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
                    .cornerRadius(3)
                    .offset(x: 0, y: 25)
            } else if let tag = commit.tag {
                Text(tag)
                    .font(.caption2)
                    .padding(3)
                    .background(Color.yellow.opacity(0.3))
                    .cornerRadius(3)
                    .offset(x: 0, y: 25)
            }
        }
    }
}
