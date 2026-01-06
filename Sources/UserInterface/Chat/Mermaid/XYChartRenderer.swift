// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging

/// Renders XY Charts (bar charts, line charts) from xychart-beta syntax
struct XYChartRenderer: View {
    let chart: XYChart
    private let logger = Logger(label: "com.sam.mermaid.xychart")

    // Chart colors for multiple series
    private let seriesColors: [Color] = [
        .blue, .green, .orange, .purple, .red, .cyan, .yellow, .pink
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title
            if let title = chart.title {
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // Chart area
            GeometryReader { geometry in
                let chartWidth = geometry.size.width - 70  // Leave space for y-axis
                let chartHeight = geometry.size.height - 50  // Leave space for x-axis labels

                ZStack(alignment: .topLeading) {
                    // Y-axis labels
                    VStack(alignment: .trailing, spacing: 0) {
                        ForEach(Array(yAxisLabels.reversed().enumerated()), id: \.offset) { _, label in
                            Text(label)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(height: chartHeight / CGFloat(max(yAxisLabels.count - 1, 1)), alignment: .top)
                        }
                    }
                    .frame(width: 50, height: chartHeight, alignment: .topTrailing)

                    // Chart content area
                    chartContent(width: chartWidth, height: chartHeight)
                        .offset(x: 55, y: 0)

                    // X-axis labels at bottom
                    HStack(spacing: 0) {
                        ForEach(Array(xAxisCategories.enumerated()), id: \.offset) { _, category in
                            Text(category)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .frame(width: chartWidth / CGFloat(max(xAxisCategories.count, 1)), alignment: .center)
                        }
                    }
                    .offset(x: 55, y: chartHeight + 5)
                }
            }
            .frame(height: 280)

            // Legend for multiple series
            if chart.dataSeries.count > 1 || (chart.dataSeries.first?.label != nil && chart.dataSeries.first?.label?.isEmpty == false) {
                legendView
            }

            // Axis labels
            HStack {
                if let yLabel = chart.yAxisLabel, !yLabel.isEmpty {
                    Text(yLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let xLabel = chart.xAxisLabel, !xLabel.isEmpty {
                    Text(xLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
    }

    /// Get x-axis categories (from chart or inferred from data)
    private var xAxisCategories: [String] {
        if !chart.xAxisCategories.isEmpty {
            return chart.xAxisCategories
        }
        // Generate numeric labels if no categories provided
        let count = chart.dataSeries.first?.values.count ?? 0
        guard count > 0 else { return ["1"] }  // Fallback for empty data
        return (1...count).map { String($0) }
    }

    /// Calculate y-axis labels based on data range (always starting from 0 for bar charts)
    private var yAxisLabels: [String] {
        let allValues = chart.dataSeries.flatMap { $0.values }
        guard !allValues.isEmpty else { return ["0"] }

        let dataMax = allValues.max() ?? 100
        let dataMin = allValues.min() ?? 0

        // For bar charts, always start at 0 (or below 0 if there are negative values)
        let chartMin: Double = min(dataMin, 0)
        // Add 10% padding above max
        let chartMax: Double = dataMax * 1.1

        let range = chartMax - chartMin
        guard range > 0 else { return ["0"] }

        let step = range / 4

        var labels: [String] = []
        var value = chartMin
        while value <= chartMax + (step * 0.1) {  // Small epsilon for floating point
            if abs(value) < 0.001 {
                labels.append("0")
            } else if abs(value - round(value)) < 0.001 {
                labels.append(String(format: "%.0f", value))
            } else {
                labels.append(String(format: "%.1f", value))
            }
            value += step
        }

        return labels
    }

    /// Calculate max value for scaling (with padding)
    private var maxValue: Double {
        let allValues = chart.dataSeries.flatMap { $0.values }
        let dataMax = allValues.max() ?? 100
        return dataMax * 1.1  // 10% padding
    }

    /// Calculate min value for scaling (always 0 or below for bar charts)
    private var minValue: Double {
        let allValues = chart.dataSeries.flatMap { $0.values }
        let dataMin = allValues.min() ?? 0
        return min(dataMin, 0)  // Always include 0
    }

    /// Draw the chart content (bars and/or lines)
    @ViewBuilder
    private func chartContent(width: CGFloat, height: CGFloat) -> some View {
        let categoryCount = max(xAxisCategories.count, chart.dataSeries.first?.values.count ?? 1)
        let barGroupWidth = width / CGFloat(max(categoryCount, 1))
        let barWidth = barGroupWidth / CGFloat(max(barSeriesCount, 1)) * 0.7
        let valueRange = max(maxValue - minValue, 0.001)  // Prevent division by zero

        // Calculate where 0 is on the y-axis
        let zeroY = height * CGFloat((maxValue - 0) / valueRange)

        ZStack(alignment: .topLeading) {
            // Grid lines
            ForEach(0..<5) { i in
                Path { path in
                    let y = height * CGFloat(i) / 4
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            }

            // Zero line (if visible)
            if minValue < 0 {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: zeroY))
                    path.addLine(to: CGPoint(x: width, y: zeroY))
                }
                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
            }

            // Draw bar series
            ForEach(Array(chart.dataSeries.enumerated()), id: \.element.id) { seriesIndex, series in
                if series.type == .bar {
                    barSeries(
                        series: series,
                        seriesIndex: barSeriesIndex(for: seriesIndex),
                        width: width,
                        height: height,
                        barWidth: barWidth,
                        barGroupWidth: barGroupWidth,
                        valueRange: valueRange,
                        zeroY: zeroY,
                        color: seriesColors[seriesIndex % seriesColors.count]
                    )
                }
            }

            // Draw line series on top
            ForEach(Array(chart.dataSeries.enumerated()), id: \.element.id) { seriesIndex, series in
                if series.type == .line {
                    lineSeries(
                        series: series,
                        width: width,
                        height: height,
                        barGroupWidth: barGroupWidth,
                        valueRange: valueRange,
                        color: seriesColors[seriesIndex % seriesColors.count]
                    )
                }
            }
        }
        .frame(width: width, height: height)
    }

    /// Count of bar series (for grouping)
    private var barSeriesCount: Int {
        chart.dataSeries.filter { $0.type == .bar }.count
    }

    /// Get the bar series index for a given overall series index
    private func barSeriesIndex(for seriesIndex: Int) -> Int {
        var barIndex = 0
        for i in 0..<seriesIndex {
            if chart.dataSeries[i].type == .bar {
                barIndex += 1
            }
        }
        return barIndex
    }

    /// Draw a bar series with value labels
    @ViewBuilder
    private func barSeries(series: XYDataSeries, seriesIndex: Int, width: CGFloat, height: CGFloat, barWidth: CGFloat, barGroupWidth: CGFloat, valueRange: Double, zeroY: CGFloat, color: Color) -> some View {
        ForEach(0..<series.values.count, id: \.self) { index in
            let value = series.values[index]
            // Calculate bar height: from 0 line to value
            let valueY = height * CGFloat((maxValue - value) / valueRange)
            let barHeight = abs(zeroY - valueY)

            // Position bar: center in its group, accounting for multiple series
            let groupStartX = barGroupWidth * CGFloat(index)
            let totalBarsWidth = barWidth * CGFloat(barSeriesCount)
            let groupPadding = (barGroupWidth - totalBarsWidth) / 2
            let barX = groupStartX + groupPadding + (barWidth * CGFloat(seriesIndex))

            // Bar starts at 0 line for positive values, at value for negative
            let barY = value >= 0 ? valueY : zeroY

            ZStack {
                // The bar
                Rectangle()
                    .fill(color.gradient)
                    .frame(width: barWidth, height: max(barHeight, 1))
                    .position(x: barX + barWidth / 2, y: barY + barHeight / 2)

                // Value label above/below bar
                Text(formatValue(value))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.primary)
                    .position(
                        x: barX + barWidth / 2,
                        y: value >= 0 ? valueY - 10 : zeroY + barHeight + 10
                    )
            }
        }
    }

    /// Format a value for display
    private func formatValue(_ value: Double) -> String {
        if abs(value - round(value)) < 0.001 {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.1f", value)
        }
    }

    /// Draw a line series
    @ViewBuilder
    private func lineSeries(series: XYDataSeries, width: CGFloat, height: CGFloat, barGroupWidth: CGFloat, valueRange: Double, color: Color) -> some View {
        Path { path in
            for (index, value) in series.values.enumerated() {
                let x = barGroupWidth * CGFloat(index) + barGroupWidth / 2
                let y = height * CGFloat((maxValue - value) / valueRange)

                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
        .stroke(color, lineWidth: 2)

        // Draw points
        ForEach(Array(series.values.enumerated()), id: \.offset) { index, value in
            let x = barGroupWidth * CGFloat(index) + barGroupWidth / 2
            let y = height * CGFloat((maxValue - value) / valueRange)

            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .position(x: x, y: y)
        }
    }

    /// Legend view
    @ViewBuilder
    private var legendView: some View {
        HStack(spacing: 16) {
            ForEach(Array(chart.dataSeries.enumerated()), id: \.offset) { index, series in
                HStack(spacing: 4) {
                    if series.type == .bar {
                        Rectangle()
                            .fill(seriesColors[index % seriesColors.count])
                            .frame(width: 12, height: 12)
                    } else {
                        Circle()
                            .fill(seriesColors[index % seriesColors.count])
                            .frame(width: 8, height: 8)
                    }

                    Text(series.label ?? "Series \(index + 1)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        Text("Bar Chart Example")
            .font(.headline)

        XYChartRenderer(chart: XYChart(
            title: "Monthly Sales",
            xAxisLabel: "Month",
            yAxisLabel: "Revenue ($K)",
            xAxisCategories: ["Jan", "Feb", "Mar", "Apr", "May"],
            dataSeries: [
                XYDataSeries(type: .bar, values: [30, 45, 25, 60, 40], label: "2024")
            ],
            orientation: .horizontal
        ))

        Text("Mixed Bar + Line")
            .font(.headline)

        XYChartRenderer(chart: XYChart(
            title: "Sales vs Target",
            xAxisLabel: nil,
            yAxisLabel: nil,
            xAxisCategories: ["Q1", "Q2", "Q3", "Q4"],
            dataSeries: [
                XYDataSeries(type: .bar, values: [120, 150, 180, 200], label: "Actual"),
                XYDataSeries(type: .line, values: [100, 130, 160, 190], label: "Target")
            ],
            orientation: .horizontal
        ))
    }
    .padding()
    .frame(width: 500, height: 700)
}
