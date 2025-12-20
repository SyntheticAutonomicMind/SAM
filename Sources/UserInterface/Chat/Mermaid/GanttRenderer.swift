// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Native SwiftUI renderer for Mermaid Gantt charts
struct GanttRenderer: View {
    let chart: GanttChart

    private let rowHeight: CGFloat = 40
    private let labelWidth: CGFloat = 150
    private let dayWidth: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = chart.title {
                Text(title)
                    .font(.headline)
                    .padding(.bottom, 12)
            }

            HStack(alignment: .top, spacing: 0) {
                // Task labels
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chart.tasks.enumerated()), id: \.element.id) { index, task in
                        Text(task.name)
                            .font(.system(size: 13))
                            .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                            .padding(.leading, 8)

                        if index < chart.tasks.count - 1 {
                            Divider()
                        }
                    }
                }
                .frame(width: labelWidth)

                Divider()

                // Timeline bars
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(chart.tasks.enumerated()), id: \.element.id) { index, task in
                            GanttTaskBar(task: task, dayWidth: dayWidth, index: index)
                                .frame(height: rowHeight)

                            if index < chart.tasks.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .frame(minWidth: CGFloat(chart.tasks.count) * dayWidth * 5)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
    }
}

struct GanttTaskBar: View {
    let task: GanttTask
    let dayWidth: CGFloat
    let index: Int

    var body: some View {
        HStack(spacing: 0) {
            // Start offset
            Rectangle()
                .fill(Color.clear)
                .frame(width: CGFloat(index) * dayWidth * 2)

            // Task bar
            RoundedRectangle(cornerRadius: 4)
                .fill(taskColor)
                .frame(width: taskWidth, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(taskColor.opacity(0.8), lineWidth: 1)
                )

            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var taskWidth: CGFloat {
        let duration = task.duration ?? 5
        return CGFloat(duration) * dayWidth
    }

    private var taskColor: Color {
        switch task.status {
        case .active:
            return Color.blue.opacity(0.6)
        case .done:
            return Color.green.opacity(0.6)
        case .crit:
            return Color.red.opacity(0.6)
        case .milestone:
            return Color.purple.opacity(0.6)
        }
    }
}
