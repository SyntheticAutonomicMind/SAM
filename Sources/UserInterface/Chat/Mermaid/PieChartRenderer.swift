// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Native SwiftUI renderer for Mermaid pie charts
struct PieChartRenderer: View {
    let chart: PieChart

    private let chartSize: CGFloat = 300
    private let legendSpacing: CGFloat = 20

    var body: some View {
        let total = chart.slices.reduce(0.0) { $0 + $1.value }

        HStack(spacing: 40) {
            // Pie chart
            ZStack {
                ForEach(Array(chart.slices.enumerated()), id: \.element.id) { index, slice in
                    let startAngle = startAngle(for: index, total: total)
                    let endAngle = endAngle(for: index, total: total)
                    let percentage = (slice.value / total) * 100

                    PieSliceShape(
                        startAngle: startAngle,
                        endAngle: endAngle
                    )
                    .fill(sliceColor(index: index))

                    // Percentage label
                    if percentage > 5 {
                        Text(String(format: "%.1f%%", percentage))
                            .font(.caption)
                            .foregroundColor(.white)
                            .position(labelPosition(startAngle: startAngle, endAngle: endAngle))
                    }
                }
            }
            .frame(width: chartSize, height: chartSize)

            // Legend
            VStack(alignment: .leading, spacing: 8) {
                if let title = chart.title {
                    Text(title)
                        .font(.headline)
                        .padding(.bottom, 8)
                }

                ForEach(Array(chart.slices.enumerated()), id: \.element.id) { index, slice in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(sliceColor(index: index))
                            .frame(width: 20, height: 20)

                        Text(slice.label)
                            .font(.system(size: 13))

                        Spacer()

                        Text(String(format: "%.0f", slice.value))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: 200)
        }
        .padding()
    }

    private func startAngle(for index: Int, total: Double) -> Angle {
        let previousSum = chart.slices.prefix(index).reduce(0.0) { $0 + $1.value }
        return Angle(degrees: (previousSum / total) * 360 - 90)
    }

    private func endAngle(for index: Int, total: Double) -> Angle {
        let currentSum = chart.slices.prefix(index + 1).reduce(0.0) { $0 + $1.value }
        return Angle(degrees: (currentSum / total) * 360 - 90)
    }

    private func labelPosition(startAngle: Angle, endAngle: Angle) -> CGPoint {
        let midAngle = (startAngle.radians + endAngle.radians) / 2
        let radius = chartSize * 0.35

        return CGPoint(
            x: chartSize / 2 + radius * CGFloat(cos(midAngle)),
            y: chartSize / 2 + radius * CGFloat(sin(midAngle))
        )
    }

    private func sliceColor(index: Int) -> Color {
        let colors: [Color] = [
            .blue, .green, .orange, .red, .purple,
            .pink, .yellow, .cyan, .indigo, .mint
        ]
        return colors[index % colors.count]
    }
}

struct PieSliceShape: Shape {
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        path.closeSubpath()

        return path
    }
}
