// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Native SwiftUI renderer for Mermaid ER diagrams
struct ERDiagramRenderer: View {
    let diagram: ERDiagram

    private let entityWidth: CGFloat = 160
    private let entityHeight: CGFloat = 80
    private let horizontalSpacing: CGFloat = 120
    private let verticalSpacing: CGFloat = 100

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Render relationships first
                ForEach(diagram.relationships) { relationship in
                    if let fromEntity = diagram.entities.first(where: { $0.id == relationship.from }),
                       let toEntity = diagram.entities.first(where: { $0.id == relationship.to }) {
                        let fromIndex = diagram.entities.firstIndex(where: { $0.id == fromEntity.id }) ?? 0
                        let toIndex = diagram.entities.firstIndex(where: { $0.id == toEntity.id }) ?? 0

                        ERRelationshipView(
                            relationship: relationship,
                            fromPos: entityPosition(index: fromIndex, in: geometry.size),
                            toPos: entityPosition(index: toIndex, in: geometry.size)
                        )
                    }
                }

                // Render entities on top
                ForEach(Array(diagram.entities.enumerated()), id: \.element.id) { index, entity in
                    EREntityView(entity: entity, width: entityWidth)
                        .position(entityPosition(index: index, in: geometry.size))
                }
            }
        }
        .frame(minHeight: 400)
    }

    private func entityPosition(index: Int, in size: CGSize) -> CGPoint {
        let columns = max(2, Int(size.width / (entityWidth + horizontalSpacing)))
        let row = index / columns
        let col = index % columns

        let totalWidth = CGFloat(min(columns, diagram.entities.count)) * (entityWidth + horizontalSpacing) - horizontalSpacing
        let startX = (size.width - totalWidth) / 2 + entityWidth / 2

        let x = startX + CGFloat(col) * (entityWidth + horizontalSpacing)
        let y = 100 + CGFloat(row) * (entityHeight + verticalSpacing)

        return CGPoint(x: x, y: y)
    }
}

struct EREntityView: View {
    let entity: Entity
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // Entity name
            Text(entity.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
                .frame(height: 40)
                .frame(maxWidth: .infinity)
                .background(Color.accentColor.opacity(0.2))

            if !entity.attributes.isEmpty {
                Divider()

                // Attributes
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entity.attributes) { attribute in
                        HStack(spacing: 4) {
                            if attribute.isKey {
                                Text("*")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.accentColor)
                            }
                            Text(attribute.name)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                            if let type = attribute.type {
                                Text(":")
                                    .foregroundColor(.secondary)
                                Text(type)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.7))
                            }
                        }
                        .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
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

struct ERRelationshipView: View {
    let relationship: ERRelationship
    let fromPos: CGPoint
    let toPos: CGPoint

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: fromPos)
                path.addLine(to: toPos)
            }
            .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)

            // Relationship label
            Text(relationship.label)
                .font(.caption)
                .padding(4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
                .position(midpoint)

            // Cardinality labels
            Text(relationship.fromCardinality)
                .font(.caption2)
                .foregroundColor(.secondary)
                .position(CGPoint(
                    x: fromPos.x + (toPos.x - fromPos.x) * 0.2,
                    y: fromPos.y + (toPos.y - fromPos.y) * 0.2 - 15
                ))

            Text(relationship.toCardinality)
                .font(.caption2)
                .foregroundColor(.secondary)
                .position(CGPoint(
                    x: fromPos.x + (toPos.x - fromPos.x) * 0.8,
                    y: fromPos.y + (toPos.y - fromPos.y) * 0.8 - 15
                ))
        }
    }

    private var midpoint: CGPoint {
        CGPoint(
            x: (fromPos.x + toPos.x) / 2,
            y: (fromPos.y + toPos.y) / 2
        )
    }
}
