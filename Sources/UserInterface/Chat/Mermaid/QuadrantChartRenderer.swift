// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Native SwiftUI renderer for Mermaid quadrant charts
struct QuadrantChartRenderer: View {
    let chart: QuadrantChart

    private let chartSize: CGFloat = 400

    var body: some View {
        VStack(spacing: 20) {
            if let title = chart.title {
                Text(title)
                    .font(.headline)
            }

            ZStack {
                // Quadrant background
                QuadrantBackground(chart: chart, size: chartSize)

                // Data points
                ForEach(chart.points) { point in
                    QuadrantPointView(point: point, chartSize: chartSize)
                }
            }
            .frame(width: chartSize, height: chartSize)
        }
        .padding()
    }
}

struct QuadrantBackground: View {
    let chart: QuadrantChart
    let size: CGFloat

    var body: some View {
        ZStack {
            // Four quadrants
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    QuadrantCell(label: "Quadrant 2", color: .blue)
                    QuadrantCell(label: "Quadrant 1", color: .green)
                }
                HStack(spacing: 0) {
                    QuadrantCell(label: "Quadrant 3", color: .orange)
                    QuadrantCell(label: "Quadrant 4", color: .purple)
                }
            }

            // Axes
            Path { path in
                // Vertical axis
                path.move(to: CGPoint(x: size / 2, y: 0))
                path.addLine(to: CGPoint(x: size / 2, y: size))

                // Horizontal axis
                path.move(to: CGPoint(x: 0, y: size / 2))
                path.addLine(to: CGPoint(x: size, y: size / 2))
            }
            .stroke(Color.primary.opacity(0.3), lineWidth: 2)

            // Axis labels
            if let xLabel = chart.xAxisLabel {
                Text(xLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .position(x: size - 50, y: size / 2 + 20)
            }

            if let yLabel = chart.yAxisLabel {
                Text(yLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(-90))
                    .position(x: size / 2 - 20, y: 50)
            }
        }
    }
}

struct QuadrantCell: View {
    let label: String
    let color: Color

    var body: some View {
        ZStack {
            color.opacity(0.1)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .opacity(0.5)
        }
    }
}

struct QuadrantPointView: View {
    let point: QuadrantPoint
    let chartSize: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)

            Text(point.label)
                .font(.caption)
                .padding(4)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.9))
                .cornerRadius(4)
                .offset(x: 0, y: -15)
        }
        .position(pointPosition)
    }

    private var pointPosition: CGPoint {
        // Map [0, 1] to chart coordinates
        let x = chartSize / 2 + (point.x - 0.5) * chartSize
        let y = chartSize / 2 - (point.y - 0.5) * chartSize // Inverted Y
        return CGPoint(x: x, y: y)
    }
}
