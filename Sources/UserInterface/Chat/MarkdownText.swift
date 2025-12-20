// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Enhanced SwiftUI component for beautiful markdown rendering using custom SAM parser Provides production-grade markdown rendering with enhanced visual styling and smooth animations Zero third-party dependencies - fully native Swift implementation.
struct MarkdownText: View {
    private let content: String
    @State private var isAnimating = false

    init(_ content: String) {
        self.content = content
    }

    var body: some View {
        /// Use custom MarkdownContentView instead of swift-markdown-ui.
        MarkdownContentView(content: content)
            .textSelection(.enabled)
            /// REMOVED: .animation() was causing layout recalculations during streaming
            /// Enhanced styling for better presentation.
            .padding(.vertical, 4)
            /// Better spacing and readability.
            .lineSpacing(2)
            /// Smooth content transitions - only for insert/remove, not updates.
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .leading)),
                removal: .opacity.combined(with: .scale(scale: 0.95))
            ))
    }
}

/// Preview helper for MarkdownText development and testing.
struct MarkdownText_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                /// User message example.
                VStack(alignment: .trailing) {
                    HStack {
                        Spacer()
                        MarkdownText("Can you help me with **Swift development**? I need to understand `async/await` patterns.")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(Color.accentColor)
                            )
                            .foregroundColor(.white)
                    }
                }

                /// Assistant response example.
                VStack(alignment: .leading) {
                    HStack {
                        MarkdownText("""
                        # Swift Async/Await Guide

                        I'd be happy to help you understand **async/await** in Swift! Here's a comprehensive overview:

                        ## Basic Syntax

                        ```swift
                        async func fetchData() async throws -> Data {
                            let url = URL(string: "https://api.example.com/data")!
                            let (data, _) = try await URLSession.shared.data(from: url)
                            return data
                        }
                        ```

                        ## Key Concepts

                        1. **Async Functions**: Marked with `async` keyword
                        2. **Await Keyword**: Used to call async functions
                        3. **Task Creation**: Using `Task { }` for concurrent execution

                        ### Task Lists for Learning
                        - [x] Understand async function syntax
                        - [x] Learn about await keyword
                        - [ ] Practice with URLSession
                        - [ ] Implement error handling

                        ## Comparison Table

                        | Pattern | Before | After |
                        |---------|---------|--------|
                        | Completion | `completion: @escaping (Result) -> Void` | `async throws -> Result` |
                        | Calling | `fetch { result in ... }` | `let result = try await fetch()` |

                        > **Tip**: Async/await makes asynchronous code look and behave more like synchronous code, improving readability and reducing callback hell.

                        Would you like me to show you more specific examples?
                        """)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Color.primary.opacity(0.05))
                                .shadow(
                                    color: .primary.opacity(0.1),
                                    radius: 2,
                                    x: 0,
                                    y: 1
                                )
                        )
                        .foregroundColor(.primary)
                        Spacer()
                    }
                }

                /// Processing example.
                VStack(alignment: .leading) {
                    HStack {
                        MarkdownText("")
                        Spacer()
                    }
                }
            }
            .padding()
        }
        .previewDisplayName("Enhanced Markdown Chat")
    }
}
