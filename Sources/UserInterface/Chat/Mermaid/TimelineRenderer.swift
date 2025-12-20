// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Native SwiftUI renderer for Mermaid timelines
struct TimelineRenderer: View {
    let timeline: Timeline

    private let periodWidth: CGFloat = 150
    private let lineHeight: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let title = timeline.title {
                Text(title)
                    .font(.headline)
                    .padding(.bottom, 8)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    ForEach(Array(timeline.events.enumerated()), id: \.element.id) { index, event in
                        VStack(spacing: 8) {
                            // Period label
                            Text(event.period)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.accentColor)

                            // Timeline point
                            ZStack {
                                // Line
                                if index < timeline.events.count - 1 {
                                    Rectangle()
                                        .fill(Color.accentColor.opacity(0.3))
                                        .frame(width: periodWidth, height: lineHeight)
                                        .offset(x: periodWidth / 2)
                                }

                                // Point
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 12, height: 12)
                            }
                            .frame(height: 20)

                            // Events
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(event.events, id: \.self) { eventText in
                                    Text(eventText)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(width: periodWidth - 20)
                        }
                        .frame(width: periodWidth)
                    }
                }
            }
        }
        .padding()
    }
}
