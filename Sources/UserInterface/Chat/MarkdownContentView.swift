// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import OSLog

/// SwiftUI view for rendering markdown using AST-based parser
/// Supports full nested markdown structures (blockquotes in lists, etc.)
struct MarkdownContentView: View {
    let content: String

    /// PERFORMANCE: Cache parsed AST
    @State private var cachedAST: MarkdownASTNode?
    @State private var lastContent: String = ""
    @State private var isLoading: Bool = false
    @State private var parseTask: Task<Void, Never>?

    @Environment(\.fontSizeScale) private var fontSizeScale

    private let logger = Logger(subsystem: "com.sam.ui.MarkdownContentView", category: "UserInterface")

    var body: some View {
        /// FIX: Use VStack instead of LazyVStack to ensure content renders immediately
        /// When nested inside another LazyVStack (ChatWidget), using LazyVStack here
        /// causes double-lazy loading which can result in empty message bubbles
        /// VStack ensures markdown content renders as soon as the outer view is visible
        VStack(alignment: .leading, spacing: 12) {
            if let ast = cachedAST {
                /// Render parsed AST (normal case - parsing complete)
                MarkdownViewRenderer(fontSizeScale: fontSizeScale).render(ast)
                    .textSelection(.enabled)
            } else {
                /// Immediate fallback — show raw text content without any
                /// loading indicator. This ensures content is ALWAYS visible
                /// immediately when the view renders, before the async AST
                /// parsing completes. For conversations with 100+ messages,
                /// showing ProgressView or nothing until parsing completes
                /// causes the "doesn't paint until I scroll" bug because the
                /// ScrollView layout is computed before views have content.
                Text(content)
                    .textSelection(.enabled)
                    .font(FontManager.shared.body(fontSizeScale))
            }
        }
        .task(id: content) {
            /// Use .task(id:) instead of .onAppear + .onChange for cleaner lifecycle
            /// This automatically cancels and restarts when content changes
            await parseContent()
        }
    }

    /// Parse markdown into AST
    @MainActor
    private func parseContent() async {
        /// Skip if content matches cached version
        guard content != lastContent || cachedAST == nil else { return }

        logger.info("AST_PARSING_TRIGGERED: content length=\(content.count), preview: \(content.prefix(100))")

        lastContent = content
        isLoading = true

        /// Parse on background thread
        let contentToparse = content
        let ast = await Task.detached(priority: .userInitiated) {
            let parser = MarkdownASTParser()
            return parser.parse(contentToparse)
        }.value

        /// Update state (automatically on MainActor since method is @MainActor)
        cachedAST = ast
        isLoading = false
        logger.debug("[AST_CACHED] AST ready for rendering")
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        MarkdownContentView(content: """
        # Sample Markdown

        This is a **bold** and *italic* text example with `inline code`.

        ## Nested Example: Blockquote in List

        - Item 1
        > Quote in item 1
        - Item 2
        - [Link in list](https://example.com)

        ## Table Example

        | Name | Age | City |
        |------|-----|------|
        | John | 25  | NYC  |
        | Jane | 30  | LA   |

        ## Code Block

        ```swift
        func greet() {
            print("Hello, World!")
        }
        ```

        ## Task List

        - [x] Completed task
        - [ ] Pending task

        > This is a blockquote
        > with multiple lines
        """)
        .padding()
    }
}
