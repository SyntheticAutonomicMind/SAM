// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Native SwiftUI renderer for Mermaid sequence diagrams
struct SequenceDiagramRenderer: View {
    let diagram: SequenceDiagram

    private let participantWidth: CGFloat = 120
    private let participantHeight: CGFloat = 40
    private let messageSpacing: CGFloat = 50
    private let horizontalSpacing: CGFloat = 150

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Boxes (swimlanes) - draw first (background)
                ForEach(diagram.boxes) { box in
                    BoxView(
                        box: box,
                        participants: diagram.participants,
                        geometry: geometry.size,
                        participantWidth: participantWidth,
                        participantHeight: participantHeight,
                        horizontalSpacing: horizontalSpacing,
                        messageCount: diagram.messages.count,
                        messageSpacing: messageSpacing
                    )
                }

                // Participant boxes at top
                ForEach(Array(diagram.participants.enumerated()), id: \.element.id) { index, participant in
                    ParticipantView(participant: participant)
                        .frame(width: participantWidth, height: participantHeight)
                        .position(participantPosition(index: index, in: geometry.size))
                }

                // Lifelines
                ForEach(Array(diagram.participants.enumerated()), id: \.element.id) { index, _ in
                    Path { path in
                        let pos = participantPosition(index: index, in: geometry.size)
                        let startY = pos.y + participantHeight / 2
                        let endY = startY + CGFloat(diagram.messages.count) * messageSpacing + 100

                        path.move(to: CGPoint(x: pos.x, y: startY))
                        path.addLine(to: CGPoint(x: pos.x, y: endY))
                    }
                    .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                }

                // Messages
                ForEach(Array(diagram.messages.enumerated()), id: \.element.id) { index, message in
                    SequenceMessageView(
                        message: message,
                        fromX: participantX(name: message.from, in: geometry.size),
                        toX: participantX(name: message.to, in: geometry.size),
                        y: messageY(index: index, in: geometry.size)
                    )
                }
            }
        }
        .frame(minHeight: CGFloat(diagram.messages.count) * messageSpacing + 200)
    }

    private func participantPosition(index: Int, in size: CGSize) -> CGPoint {
        let totalWidth = CGFloat(diagram.participants.count - 1) * horizontalSpacing
        let startX = (size.width - totalWidth) / 2
        let x = startX + CGFloat(index) * horizontalSpacing
        let y: CGFloat = participantHeight / 2 + 20
        return CGPoint(x: x, y: y)
    }

    private func participantX(name: String, in size: CGSize) -> CGFloat {
        guard let index = diagram.participants.firstIndex(where: { $0.id == name }) else {
            return size.width / 2
        }
        let totalWidth = CGFloat(diagram.participants.count - 1) * horizontalSpacing
        let startX = (size.width - totalWidth) / 2
        return startX + CGFloat(index) * horizontalSpacing
    }

    private func messageY(index: Int, in size: CGSize) -> CGFloat {
        participantHeight + 50 + CGFloat(index) * messageSpacing
    }
}

struct ParticipantView: View {
    let participant: Participant

    var body: some View {
        ZStack {
            if participant.type == .actor {
                // Stick figure for actor
                ActorShape()
                    .stroke(Color.accentColor, lineWidth: 2)
            } else {
                // Rectangle for participant
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)

                Text(participant.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }
        }
    }
}

struct SequenceMessageView: View {
    let message: SequenceMessage
    let fromX: CGFloat
    let toX: CGFloat
    let y: CGFloat

    var body: some View {
        ZStack {
            // Arrow
            Path { path in
                path.move(to: CGPoint(x: fromX, y: y))
                path.addLine(to: CGPoint(x: toX, y: y))
            }
            .stroke(Color.accentColor, style: strokeStyle)

            // Arrowhead
            if toX > fromX {
                SequenceArrowHead(at: CGPoint(x: toX, y: y), angle: 0, filled: isFilled)
                    .fill(Color.accentColor)
            } else {
                SequenceArrowHead(at: CGPoint(x: toX, y: y), angle: .pi, filled: isFilled)
                    .fill(Color.accentColor)
            }

            // Label
            Text(message.text)
                .font(.caption)
                .padding(4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(4)
                .position(x: (fromX + toX) / 2, y: y - 15)
        }
    }

    private var strokeStyle: StrokeStyle {
        switch message.type {
        case .solid, .solidArrow:
            return StrokeStyle(lineWidth: 2)
        case .dotted, .dottedArrow:
            return StrokeStyle(lineWidth: 2, dash: [5, 5])
        case .async:
            return StrokeStyle(lineWidth: 2, dash: [10, 5])
        }
    }

    private var isFilled: Bool {
        switch message.type {
        case .solid, .dotted, .async:
            return true
        case .solidArrow, .dottedArrow:
            return false
        }
    }
}

struct SequenceArrowHead: Shape {
    let at: CGPoint
    let angle: CGFloat
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        let arrowLength: CGFloat = 10
        let arrowAngle: CGFloat = .pi / 6

        var path = Path()
        path.move(to: at)
        path.addLine(to: CGPoint(
            x: at.x - arrowLength * cos(angle - arrowAngle),
            y: at.y - arrowLength * sin(angle - arrowAngle)
        ))

        if filled {
            path.addLine(to: CGPoint(
                x: at.x - arrowLength * cos(angle + arrowAngle),
                y: at.y - arrowLength * sin(angle + arrowAngle)
            ))
            path.closeSubpath()
        } else {
            path.move(to: at)
            path.addLine(to: CGPoint(
                x: at.x - arrowLength * cos(angle + arrowAngle),
                y: at.y - arrowLength * sin(angle + arrowAngle)
            ))
        }

        return path
    }
}

struct ActorShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centerX = rect.midX
        let centerY = rect.midY
        let headRadius: CGFloat = 8

        // Head
        path.addEllipse(in: CGRect(
            x: centerX - headRadius,
            y: rect.minY,
            width: headRadius * 2,
            height: headRadius * 2
        ))

        // Body
        let bodyTop = rect.minY + headRadius * 2
        let bodyBottom = rect.maxY - 10
        path.move(to: CGPoint(x: centerX, y: bodyTop))
        path.addLine(to: CGPoint(x: centerX, y: bodyBottom))

        // Arms
        let armY = bodyTop + (bodyBottom - bodyTop) * 0.3
        path.move(to: CGPoint(x: centerX - 15, y: armY))
        path.addLine(to: CGPoint(x: centerX + 15, y: armY))

        // Legs
        path.move(to: CGPoint(x: centerX, y: bodyBottom))
        path.addLine(to: CGPoint(x: centerX - 10, y: rect.maxY))
        path.move(to: CGPoint(x: centerX, y: bodyBottom))
        path.addLine(to: CGPoint(x: centerX + 10, y: rect.maxY))

        return path
    }
}

/// Renders a box (swimlane) grouping participants
struct BoxView: View {
    let box: Box
    let participants: [Participant]
    let geometry: CGSize
    let participantWidth: CGFloat
    let participantHeight: CGFloat
    let horizontalSpacing: CGFloat
    let messageCount: Int
    let messageSpacing: CGFloat

    var body: some View {
        let boxParticipants = participants.filter { box.participantIds.contains($0.id) }
        guard !boxParticipants.isEmpty else { return AnyView(EmptyView()) }

        // Calculate box bounds
        let participantIndices = boxParticipants.compactMap { p in
            participants.firstIndex(where: { $0.id == p.id })
        }
        guard let minIndex = participantIndices.min(),
              let maxIndex = participantIndices.max() else {
            return AnyView(EmptyView())
        }

        let totalWidth = CGFloat(participants.count - 1) * horizontalSpacing
        let startX = (geometry.width - totalWidth) / 2

        let boxLeft = startX + CGFloat(minIndex) * horizontalSpacing - participantWidth / 2 - 10
        let boxRight = startX + CGFloat(maxIndex) * horizontalSpacing + participantWidth / 2 + 10
        let boxWidth = boxRight - boxLeft
        let boxHeight = participantHeight + CGFloat(messageCount) * messageSpacing + 120

        // Parse color
        let boxColor = parseColor(box.color)

        return AnyView(
            ZStack(alignment: .topLeading) {
                // Box rectangle
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(boxColor, lineWidth: 2, antialiased: true)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(boxColor.opacity(0.05))
                    )
                    .frame(width: boxWidth, height: boxHeight)
                    .position(
                        x: (boxLeft + boxRight) / 2,
                        y: participantHeight / 2 + 20 + boxHeight / 2
                    )

                // Box label
                if let name = box.name, !name.isEmpty {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(boxColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                        .position(
                            x: boxLeft + 10,
                            y: 10
                        )
                }
            }
        )
    }

    /// Parse Mermaid color (CSS name, hex, or rgb)
    private func parseColor(_ colorString: String?) -> Color {
        guard let colorString = colorString else {
            return Color.accentColor
        }

        let trimmed = colorString.trimmingCharacters(in: .whitespaces).lowercased()

        // CSS color names
        switch trimmed {
        case "red": return .red
        case "blue": return .blue
        case "green": return .green
        case "purple": return .purple
        case "yellow": return .yellow
        case "orange": return .orange
        case "pink": return .pink
        case "brown": return .brown
        case "gray", "grey": return .gray
        case "black": return .black
        default: break
        }

        // Hex color
        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            if let color = Color(hex: hex) {
                return color
            }
        }

        // RGB color
        if trimmed.hasPrefix("rgb(") && trimmed.hasSuffix(")") {
            let rgbString = trimmed.dropFirst(4).dropLast()
            let components = rgbString.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .compactMap { Double($0) }

            if components.count == 3 {
                return Color(
                    red: components[0] / 255.0,
                    green: components[1] / 255.0,
                    blue: components[2] / 255.0
                )
            }
        }

        return Color.accentColor
    }
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0

        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let length = hexSanitized.count
        let r, g, b: Double

        if length == 6 {
            r = Double((rgb & 0xFF0000) >> 16) / 255.0
            g = Double((rgb & 0x00FF00) >> 8) / 255.0
            b = Double(rgb & 0x0000FF) / 255.0
        } else if length == 3 {
            r = Double((rgb & 0xF00) >> 8) / 15.0
            g = Double((rgb & 0x0F0) >> 4) / 15.0
            b = Double(rgb & 0x00F) / 15.0
        } else {
            return nil
        }

        self.init(red: r, green: g, blue: b)
    }
}
