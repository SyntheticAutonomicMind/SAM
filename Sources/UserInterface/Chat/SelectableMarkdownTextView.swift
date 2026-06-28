// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import AppKit
import SwiftUI
import OSLog

/// NSTextView wrapped for SwiftUI that provides native multi-line text selection.
/// Unlike SwiftUI's Text with .textSelection(.enabled) which only supports
/// single-line selection on macOS, NSTextView provides full macOS text selection:
/// drag selection, Shift+Click, triple-click, Cmd+A, etc.
struct SelectableMarkdownTextView: NSViewRepresentable {
    let markdown: String
    let isFromUser: Bool

    private let logger = Logger(subsystem: "com.sam.ui.SelectableMarkdownTextView", category: "UserInterface")

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = true
        tv.usesRuler = false
        tv.usesInspectorBar = false
        tv.usesFindPanel = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false

        context.coordinator.textView = tv
        return tv
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        guard context.coordinator.lastMarkdown != markdown else { return }
        context.coordinator.lastMarkdown = markdown

        /// Render synchronously - NSTextView needs content immediately for sizing.
        /// Async rendering causes zero-height frames because SwiftUI lays out
        /// before the async task completes.
        let attributed = renderMarkdownSync(markdown, isFromUser: isFromUser)
        textView.textStorage?.setAttributedString(attributed)
    }

    /// Synchronous markdown-to-attributed-string conversion.
    /// Acceptable because markdown is already parsed by the time it reaches
    /// the chat bubble, and conversion is fast for individual messages.
    private func renderMarkdownSync(_ content: String, isFromUser: Bool) -> NSAttributedString {
        if isFromUser && content.count < 500 && !content.contains("```") && !content.contains("`") {
            let attr = NSMutableAttributedString(string: content)
            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = 2
            attr.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: attr.length))
            attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: attr.length))
            attr.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: attr.length))
            return attr
        }

        /// Parse markdown and convert to attributed string. Runs on current
        /// thread (MainActor in updateNSView) but is fast for chat messages.
        let parser = MarkdownASTParser()
        let node = parser.parse(content)
        let converter = MarkdownASTToNSAttributedString()
        return converter.convertSync(node)
    }

    // MARK: - Coordinator

    class Coordinator {
        weak var textView: NSTextView?
        var lastMarkdown: String?
    }
}
