// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Native SwiftUI renderer for Mermaid class diagrams
struct ClassDiagramRenderer: View {
    let diagram: ClassDiagram

    private let classWidth: CGFloat = 180
    private let classHeaderHeight: CGFloat = 40
    private let attributeHeight: CGFloat = 20
    private let horizontalSpacing: CGFloat = 100
    private let verticalSpacing: CGFloat = 80

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Render relationships first
                ForEach(diagram.relationships) { relationship in
                    if let fromClass = diagram.classes.first(where: { $0.id == relationship.from }),
                       let toClass = diagram.classes.first(where: { $0.id == relationship.to }) {
                        let fromIndex = diagram.classes.firstIndex(where: { $0.id == fromClass.id }) ?? 0
                        let toIndex = diagram.classes.firstIndex(where: { $0.id == toClass.id }) ?? 0

                        ClassRelationshipView(
                            relationship: relationship,
                            fromPos: classPosition(index: fromIndex, in: geometry.size),
                            toPos: classPosition(index: toIndex, in: geometry.size)
                        )
                    }
                }

                // Render classes on top
                ForEach(Array(diagram.classes.enumerated()), id: \.element.id) { index, classNode in
                    ClassNodeView(classNode: classNode, width: classWidth)
                        .position(classPosition(index: index, in: geometry.size))
                }
            }
        }
        .frame(minHeight: 400)
    }

    private func classPosition(index: Int, in size: CGSize) -> CGPoint {
        let columns = max(2, Int(size.width / (classWidth + horizontalSpacing)))
        let row = index / columns
        let col = index % columns

        let totalWidth = CGFloat(min(columns, diagram.classes.count)) * (classWidth + horizontalSpacing) - horizontalSpacing
        let startX = (size.width - totalWidth) / 2 + classWidth / 2

        let x = startX + CGFloat(col) * (classWidth + horizontalSpacing)
        let y = 100 + CGFloat(row) * (classHeaderHeight + CGFloat(3) * attributeHeight + verticalSpacing)

        return CGPoint(x: x, y: y)
    }
}

struct ClassNodeView: View {
    let classNode: ClassNode
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // Class name
            Text(classNode.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
                .frame(height: 40)
                .frame(maxWidth: .infinity)
                .background(Color.accentColor.opacity(0.2))

            Divider()

            // Attributes
            if !classNode.attributes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(classNode.attributes, id: \.self) { attribute in
                        Text(attribute)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()
            }

            // Methods
            if !classNode.methods.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(classNode.methods, id: \.self) { method in
                        Text(method)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: width)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 2)
        )
        .cornerRadius(8)
    }
}

struct ClassRelationshipView: View {
    let relationship: ClassRelationship
    let fromPos: CGPoint
    let toPos: CGPoint

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: fromPos)
                path.addLine(to: toPos)
            }
            .stroke(Color.accentColor.opacity(0.6), style: strokeStyle)

            // Arrow or symbol at end
            RelationshipSymbol(
                type: relationship.type,
                at: toPos,
                angle: atan2(toPos.y - fromPos.y, toPos.x - fromPos.x)
            )
            .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)
        }
    }

    private var strokeStyle: StrokeStyle {
        switch relationship.type {
        case .dependency, .realization:
            return StrokeStyle(lineWidth: 2, dash: [5, 5])
        default:
            return StrokeStyle(lineWidth: 2)
        }
    }
}

struct RelationshipSymbol: Shape {
    let type: ClassRelationship.RelationType
    let at: CGPoint
    let angle: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size: CGFloat = 12

        switch type {
        case .inheritance, .realization:
            // Triangle
            path.move(to: at)
            path.addLine(to: CGPoint(
                x: at.x - size * cos(angle - .pi / 6),
                y: at.y - size * sin(angle - .pi / 6)
            ))
            path.addLine(to: CGPoint(
                x: at.x - size * cos(angle + .pi / 6),
                y: at.y - size * sin(angle + .pi / 6)
            ))
            path.closeSubpath()

        case .composition:
            // Filled diamond
            let offset = size / 2
            path.move(to: at)
            path.addLine(to: CGPoint(
                x: at.x - offset * cos(angle - .pi / 2),
                y: at.y - offset * sin(angle - .pi / 2)
            ))
            path.addLine(to: CGPoint(
                x: at.x - size * cos(angle),
                y: at.y - size * sin(angle)
            ))
            path.addLine(to: CGPoint(
                x: at.x - offset * cos(angle + .pi / 2),
                y: at.y - offset * sin(angle + .pi / 2)
            ))
            path.closeSubpath()

        case .aggregation:
            // Open diamond (same as composition but not filled)
            let offset = size / 2
            path.move(to: at)
            path.addLine(to: CGPoint(
                x: at.x - offset * cos(angle - .pi / 2),
                y: at.y - offset * sin(angle - .pi / 2)
            ))
            path.addLine(to: CGPoint(
                x: at.x - size * cos(angle),
                y: at.y - size * sin(angle)
            ))
            path.addLine(to: CGPoint(
                x: at.x - offset * cos(angle + .pi / 2),
                y: at.y - offset * sin(angle + .pi / 2)
            ))
            path.closeSubpath()

        case .dependency:
            // Simple arrow
            path.move(to: at)
            path.addLine(to: CGPoint(
                x: at.x - size * cos(angle - .pi / 6),
                y: at.y - size * sin(angle - .pi / 6)
            ))
            path.move(to: at)
            path.addLine(to: CGPoint(
                x: at.x - size * cos(angle + .pi / 6),
                y: at.y - size * sin(angle + .pi / 6)
            ))

        case .association:
            // No arrow, just line (handled by parent)
            break
        }

        return path
    }
}
