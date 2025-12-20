// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Native SwiftUI renderer for Mermaid user journey diagrams
struct JourneyRenderer: View {
    let journey: UserJourney

    private let taskHeight: CGFloat = 60
    private let taskWidth: CGFloat = 120
    private let sectionSpacing: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let title = journey.title {
                Text(title)
                    .font(.headline)
                    .padding(.bottom, 8)
            }

            ForEach(journey.sections) { section in
                VStack(alignment: .leading, spacing: 12) {
                    Text(section.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(section.tasks) { task in
                                JourneyTaskView(task: task)
                            }
                        }
                    }
                }
            }
        }
        .padding()
    }
}

struct JourneyTaskView: View {
    let task: JourneyTask

    var body: some View {
        VStack(spacing: 8) {
            // Emotion indicator
            ZStack {
                Circle()
                    .fill(emotionColor.opacity(0.2))
                    .frame(width: 50, height: 50)

                Text(emotionEmoji)
                    .font(.title2)
            }

            // Task name
            Text(task.name)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 100)

            // Score
            Text("\(task.score)/5")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)

            // Actors
            if !task.actors.isEmpty {
                Text(task.actors.joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: 100)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(emotionColor.opacity(0.3), lineWidth: 2)
        )
    }

    private var emotionColor: Color {
        switch task.score {
        case 5:
            return .green
        case 4:
            return .blue
        case 3:
            return .orange
        case 2:
            return .red
        default:
            return .gray
        }
    }

    private var emotionEmoji: String {
        switch task.score {
        case 5:
            return "😀"
        case 4:
            return "🙂"
        case 3:
            return "😐"
        case 2:
            return "☹️"
        default:
            return "😞"
        }
    }
}
