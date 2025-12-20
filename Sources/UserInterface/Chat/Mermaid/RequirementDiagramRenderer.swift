// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Native SwiftUI renderer for Mermaid requirement diagrams
struct RequirementDiagramRenderer: View {
    let diagram: RequirementDiagram

    private let nodeWidth: CGFloat = 180
    private let nodeHeight: CGFloat = 60
    private let horizontalSpacing: CGFloat = 100
    private let verticalSpacing: CGFloat = 80

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Render relationships first
                ForEach(diagram.relationships) { relationship in
                    if let fromReq = diagram.requirements.first(where: { $0.id == relationship.from }),
                       let toReq = diagram.requirements.first(where: { $0.id == relationship.to }) {
                        let fromIndex = diagram.requirements.firstIndex(where: { $0.id == fromReq.id }) ?? 0
                        let toIndex = diagram.requirements.firstIndex(where: { $0.id == toReq.id }) ?? 0

                        RequirementRelationshipView(
                            relationship: relationship,
                            fromPos: requirementPosition(index: fromIndex, in: geometry.size),
                            toPos: requirementPosition(index: toIndex, in: geometry.size)
                        )
                    }
                }

                // Render requirements on top
                ForEach(Array(diagram.requirements.enumerated()), id: \.element.id) { index, requirement in
                    RequirementNodeView(requirement: requirement, width: nodeWidth, height: nodeHeight)
                        .position(requirementPosition(index: index, in: geometry.size))
                }
            }
        }
        .frame(minHeight: 400)
    }

    private func requirementPosition(index: Int, in size: CGSize) -> CGPoint {
        let columns = max(2, Int(size.width / (nodeWidth + horizontalSpacing)))
        let row = index / columns
        let col = index % columns

        let totalWidth = CGFloat(min(columns, diagram.requirements.count)) * (nodeWidth + horizontalSpacing) - horizontalSpacing
        let startX = (size.width - totalWidth) / 2 + nodeWidth / 2

        let x = startX + CGFloat(col) * (nodeWidth + horizontalSpacing)
        let y = 100 + CGFloat(row) * (nodeHeight + verticalSpacing)

        return CGPoint(x: x, y: y)
    }
}

struct RequirementNodeView: View {
    let requirement: Requirement
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            // Type header
            Text(typeLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(typeColor)

            // ID and text
            VStack(spacing: 2) {
                Text(requirement.id)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)

                Text(requirement.text)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(width: width, height: height)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(typeColor, lineWidth: 2)
        )
        .cornerRadius(8)
    }

    private var typeLabel: String {
        switch requirement.type {
        case .requirement:
            return "REQ"
        case .functionalRequirement:
            return "FUNC"
        case .performanceRequirement:
            return "PERF"
        case .interfaceRequirement:
            return "INTF"
        case .designConstraint:
            return "CONST"
        }
    }

    private var typeColor: Color {
        switch requirement.type {
        case .requirement:
            return .blue
        case .functionalRequirement:
            return .green
        case .performanceRequirement:
            return .orange
        case .interfaceRequirement:
            return .purple
        case .designConstraint:
            return .red
        }
    }
}

struct RequirementRelationshipView: View {
    let relationship: RequirementRelationship
    let fromPos: CGPoint
    let toPos: CGPoint

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: fromPos)
                path.addLine(to: toPos)
            }
            .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))

            // Arrow head
            Path { path in
                let angle = atan2(toPos.y - fromPos.y, toPos.x - fromPos.x)
                let arrowLength: CGFloat = 10
                let arrowAngle: CGFloat = .pi / 6

                path.move(to: toPos)
                path.addLine(to: CGPoint(
                    x: toPos.x - arrowLength * cos(angle - arrowAngle),
                    y: toPos.y - arrowLength * sin(angle - arrowAngle)
                ))
                path.move(to: toPos)
                path.addLine(to: CGPoint(
                    x: toPos.x - arrowLength * cos(angle + arrowAngle),
                    y: toPos.y - arrowLength * sin(angle + arrowAngle)
                ))
            }
            .stroke(Color.accentColor.opacity(0.5), lineWidth: 2)
        }
    }
}
