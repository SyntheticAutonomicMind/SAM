// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Native SwiftUI renderer for Mermaid state diagrams
struct StateDiagramRenderer: View {
    let diagram: StateDiagram

    private let stateWidth: CGFloat = 120
    private let stateHeight: CGFloat = 50
    private let horizontalSpacing: CGFloat = 80
    private let verticalSpacing: CGFloat = 60

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Render transitions first
                ForEach(diagram.transitions) { transition in
                    if let fromState = diagram.states.first(where: { $0.id == transition.from }),
                       let toState = diagram.states.first(where: { $0.id == transition.to }) {
                        let fromIndex = diagram.states.firstIndex(where: { $0.id == fromState.id }) ?? 0
                        let toIndex = diagram.states.firstIndex(where: { $0.id == toState.id }) ?? 0

                        StateTransitionView(
                            transition: transition,
                            fromPos: statePosition(index: fromIndex, in: geometry.size),
                            toPos: statePosition(index: toIndex, in: geometry.size)
                        )
                    }
                }

                // Render states on top
                ForEach(Array(diagram.states.enumerated()), id: \.element.id) { index, state in
                    StateNodeView(state: state, width: stateWidth, height: stateHeight)
                        .position(statePosition(index: index, in: geometry.size))
                }
            }
        }
        .frame(minHeight: 400)
    }

    private func statePosition(index: Int, in size: CGSize) -> CGPoint {
        let columns = max(2, Int(size.width / (stateWidth + horizontalSpacing)))
        let row = index / columns
        let col = index % columns

        let totalWidth = CGFloat(min(columns, diagram.states.count)) * (stateWidth + horizontalSpacing) - horizontalSpacing
        let startX = (size.width - totalWidth) / 2 + stateWidth / 2

        let x = startX + CGFloat(col) * (stateWidth + horizontalSpacing)
        let y = 100 + CGFloat(row) * (stateHeight + verticalSpacing)

        return CGPoint(x: x, y: y)
    }
}

struct StateNodeView: View {
    let state: StateNode
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            switch state.type {
            case .start:
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 20, height: 20)

            case .end:
                ZStack {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 3)
                        .frame(width: 25, height: 25)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 15, height: 15)
                }

            case .choice:
                DiamondShape()
                    .fill(Color.accentColor.opacity(0.1))
                DiamondShape()
                    .stroke(Color.accentColor, lineWidth: 2)
                Text(state.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)

            case .normal:
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(NSColor.controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                    Text(state.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                }
            }
        }
        .frame(width: width, height: height)
    }
}

struct StateTransitionView: View {
    let transition: StateTransition
    let fromPos: CGPoint
    let toPos: CGPoint

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: fromPos)

                // Curved path for better aesthetics
                let control1 = CGPoint(
                    x: fromPos.x + (toPos.x - fromPos.x) * 0.5,
                    y: fromPos.y
                )
                let control2 = CGPoint(
                    x: fromPos.x + (toPos.x - fromPos.x) * 0.5,
                    y: toPos.y
                )
                path.addCurve(to: toPos, control1: control1, control2: control2)
            }
            .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)

            // Arrow head
            StateArrowHead(at: toPos, from: fromPos)
                .fill(Color.accentColor.opacity(0.6))

            // Label
            if let label = transition.label {
                Text(label)
                    .font(.caption)
                    .padding(4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
                    .position(midpoint)
            }
        }
    }

    private var midpoint: CGPoint {
        CGPoint(
            x: (fromPos.x + toPos.x) / 2,
            y: (fromPos.y + toPos.y) / 2
        )
    }
}

struct StateArrowHead: Shape {
    let at: CGPoint
    let from: CGPoint

    func path(in rect: CGRect) -> Path {
        let angle = atan2(at.y - from.y, at.x - from.x)
        let arrowLength: CGFloat = 10
        let arrowAngle: CGFloat = .pi / 6

        var path = Path()
        path.move(to: at)
        path.addLine(to: CGPoint(
            x: at.x - arrowLength * cos(angle - arrowAngle),
            y: at.y - arrowLength * sin(angle - arrowAngle)
        ))
        path.move(to: at)
        path.addLine(to: CGPoint(
            x: at.x - arrowLength * cos(angle + arrowAngle),
            y: at.y - arrowLength * sin(angle + arrowAngle)
        ))

        return path
    }
}
