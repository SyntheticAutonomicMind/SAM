// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConversationEngine
import ConfigurationSystem
import Training
import Logging

/// Unified export dialog for conversations and messages Used by: ChatWidget toolbar, MainWindowView menu, MessageView context menu.
struct ExportDialog: View {
    let conversation: ConversationModel
    let singleMessage: EnhancedMessage?
    @Binding var isPresented: Bool
    @EnvironmentObject private var conversationManager: ConversationManager

    @State private var isExporting: Bool = false
    @State private var exportError: String?
    @State private var showingTrainingOptions: Bool = false

    private let logger = Logger(label: "com.sam.ui.export")

    init(conversation: ConversationModel, isPresented: Binding<Bool>) {
        self.conversation = conversation
        self.singleMessage = nil
        self._isPresented = isPresented
    }

    init(conversation: ConversationModel, message: EnhancedMessage, isPresented: Binding<Bool>) {
        self.conversation = conversation
        self.singleMessage = message
        self._isPresented = isPresented
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(singleMessage != nil ? "Export Message" : "Export Conversation")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Choose a format to export your \(singleMessage != nil ? "message" : "conversation")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 12) {
                /// PDF Export Option.
                Button(action: {
                    exportAsPDF()
                    isPresented = false
                }) {
                    exportOption(
                        icon: "doc.richtext",
                        color: .orange,
                        title: "PDF Document",
                        description: "Professional format with formatting"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isExporting)

                /// JSON Export Option.
                Button(action: {
                    exportAsJSON()
                    isPresented = false
                }) {
                    exportOption(
                        icon: "doc.text",
                        color: .blue,
                        title: "JSON Format",
                        description: "Simple JSON (not re-importable)"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isExporting)

                /// Markdown Export Option.
                Button(action: {
                    exportAsMarkdown()
                    isPresented = false
                }) {
                    exportOption(
                        icon: "text.alignleft",
                        color: .green,
                        title: "Markdown",
                        description: "Simple readable text format"
                    )
                }
                .buttonStyle(.plain)
                .disabled(isExporting)

                /// Training Data Export (conversations only)
                if singleMessage == nil {
                    Button(action: {
                        exportAsTrainingData()
                    }) {
                        exportOption(
                            icon: "brain",
                            color: .pink,
                            title: "Training Data (JSONL)",
                            description: "LLM training format with PII protection"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isExporting)
                }

                /// SAM Export Package (conversations only) - includes memory data
                if singleMessage == nil {
                    Divider()
                        .padding(.vertical, 4)

                    Button(action: {
                        exportAsSAMPackage()
                    }) {
                        exportOption(
                            icon: "arrow.down.doc.fill",
                            color: .purple,
                            title: "SAM Export Package",
                            description: "Full export with memory - re-importable"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isExporting)
                }
            }

            if let error = exportError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 4)
            }

            HStack {
                Spacer()

                if isExporting {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.trailing, 8)
                }

                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .disabled(isExporting)
            }
        }
        .padding(24)
        .frame(width: 400)
        .sheet(isPresented: $showingTrainingOptions) {
            TrainingExportOptionsView(
                isPresented: $showingTrainingOptions,
                onExport: performTrainingDataExport
            )
        }
    }

    // MARK: - UI Setup

    private func exportOption(icon: String, color: Color, title: String, description: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding()
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Export Functions

    private func exportAsSAMPackage() {
        isExporting = true
        exportError = nil

        Task {
            do {
                let importExportService = ConversationImportExportService(
                    conversationManager: conversationManager,
                    memoryManager: conversationManager.memoryManager
                )

                let filename = importExportService.generateExportFilename(for: conversation)

                let panel = await MainActor.run {
                    let savePanel = NSSavePanel()
                    savePanel.allowedContentTypes = [.json]
                    savePanel.nameFieldStringValue = filename
                    savePanel.message = "Export conversation with full metadata and memory"
                    savePanel.title = "Export SAM Package"
                    return savePanel
                }

                let result = await panel.begin()

                if result == .OK, let url = panel.url {
                    try await importExportService.exportConversationToFile(
                        conversation,
                        to: url,
                        includeMemory: true
                    )

                    await MainActor.run {
                        logger.info("Exported SAM package to: \(url.path)")
                        isExporting = false
                        isPresented = false

                        /// Show in Finder
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    }
                } else {
                    await MainActor.run {
                        isExporting = false
                    }
                }
            } catch {
                await MainActor.run {
                    logger.error("SAM package export failed: \(error)")
                    exportError = "Export failed: \(error.localizedDescription)"
                    isExporting = false
                }
            }
        }
    }

    private func exportAsPDF() {
        if let message = singleMessage {
            exportMessageAsPDF(message)
        } else {
            exportConversationAsPDF()
        }
    }

    private func exportAsJSON() {
        if let message = singleMessage {
            exportMessageAsJSON(message)
        } else {
            exportConversationAsJSON()
        }
    }

    private func exportAsMarkdown() {
        if let message = singleMessage {
            exportMessageAsMarkdown(message)
        } else {
            exportConversationAsMarkdown()
        }
    }

    private func exportAsTrainingData() {
        // Only for conversations, not single messages
        exportConversationAsTrainingData()
    }

    // MARK: - Message Export

    private func exportMessageAsPDF(_ message: EnhancedMessage) {
        /// Capture conversation title on the calling actor (likely main) before offloading work.
        let convTitle = conversation.title
        let sanitizedTitle = convTitle.components(separatedBy: CharacterSet(charactersIn: ":/\\?%*|\"<>")).joined(separator: "_")

        Task.detached(priority: .userInitiated) {
            do {
                let tempURL = try await MessageExportService.exportMessageToPDFAsync(
                    message: message,
                    conversationTitle: convTitle,
                    modelName: nil
                )
                await MainActor.run {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.pdf]
                    panel.nameFieldStringValue = "SAM_Message_\(sanitizedTitle).pdf"
                    panel.message = "Export message as PDF"

                    panel.begin { result in
                        if result == .OK, let url = panel.url {
                            do {
                                if FileManager.default.fileExists(atPath: url.path) {
                                    try FileManager.default.removeItem(at: url)
                                }
                                try FileManager.default.copyItem(at: tempURL, to: url)
                                try? FileManager.default.removeItem(at: tempURL)
                                NSWorkspace.shared.open(url)
                            } catch {
                                logger.error("PDF save failed: \(error)")
                            }
                        }
                    }
                }
            } catch {
                logger.error("PDF export failed: \(error)")
            }
        }
    }

    private func exportMessageAsJSON(_ message: EnhancedMessage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "message.json"
        panel.message = "Export message as JSON"

        panel.begin { result in
            if result == .OK, let url = panel.url {
                do {
                    let jsonData = formatMessageAsJSON(message)
                    try jsonData.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    logger.error("JSON export failed: \(error)")
                }
            }
        }
    }

    private func exportMessageAsMarkdown(_ message: EnhancedMessage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "message.md"
        panel.message = "Export message as Markdown"

        panel.begin { result in
            if result == .OK, let url = panel.url {
                do {
                    let markdownData = formatMessageAsMarkdown(message)
                    try markdownData.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    logger.error("Markdown export failed: \(error)")
                }
            }
        }
    }

    // MARK: - Conversation Export

    private func exportConversationAsPDF() {
        Task {
            do {
                let exporter = ConversationPDFExporter()
                let tempURL = try await exporter.generatePDF(conversation: conversation)

                await MainActor.run {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.pdf]
                    let sanitizedTitle = conversation.title.components(separatedBy: CharacterSet(charactersIn: ":/\\?%*|\"<>")).joined(separator: "_")
                    panel.nameFieldStringValue = "SAM_\(sanitizedTitle).pdf"
                    panel.message = "Export conversation as PDF"

                    panel.begin { result in
                        if result == .OK, let url = panel.url {
                            do {
                                if FileManager.default.fileExists(atPath: url.path) {
                                    try FileManager.default.removeItem(at: url)
                                }
                                try FileManager.default.copyItem(at: tempURL, to: url)
                                try? FileManager.default.removeItem(at: tempURL)

                                NSWorkspace.shared.open(url)
                            } catch {
                                logger.error("PDF save failed: \(error)")
                            }
                        }
                    }
                }
            } catch {
                logger.error("PDF generation failed: \(error)")
            }
        }
    }

    private func exportConversationAsJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let sanitizedTitle = conversation.title.components(separatedBy: CharacterSet(charactersIn: ":/\\?%*|\"<>")).joined(separator: "_")
        panel.nameFieldStringValue = "\(sanitizedTitle).json"
        panel.message = "Export conversation as JSON"

        panel.begin { result in
            if result == .OK, let url = panel.url {
                do {
                    let jsonData = formatConversationAsJSON()
                    try jsonData.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    logger.error("JSON export failed: \(error)")
                }
            }
        }
    }

    private func exportConversationAsMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let sanitizedTitle = conversation.title.components(separatedBy: CharacterSet(charactersIn: ":/\\?%*|\"<>")).joined(separator: "_")
        panel.nameFieldStringValue = "\(sanitizedTitle).md"
        panel.message = "Export conversation as Markdown"

        panel.begin { result in
            if result == .OK, let url = panel.url {
                do {
                    let markdownData = formatConversationAsMarkdown()
                    try markdownData.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    logger.error("Markdown export failed: \(error)")
                }
            }
        }
    }

    private func exportConversationAsTrainingData() {
        // Show options dialog first
        showingTrainingOptions = true
    }
    
    private func performTrainingDataExport(with options: TrainingDataModels.ExportOptions) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let importExportService = ConversationImportExportService.shared
        
        // Inject memory manager to enable memory export
        importExportService.setConversationManager(conversationManager)
        
        let suggestedFilename = importExportService.generateTrainingExportFilename(
            for: conversation,
            template: options.template,
            modelId: options.modelId
        )
        panel.nameFieldStringValue = suggestedFilename
        panel.message = "Export conversation as Training Data (JSONL)"

        panel.begin { result in
            if result == .OK, let url = panel.url {
                Task {
                    do {
                        isExporting = true
                        
                        let result = try await importExportService.exportAsTrainingData(
                            conversation: conversation,
                            outputURL: url,
                            options: options
                        )
                        
                        await MainActor.run {
                            isExporting = false
                            logger.info("Training data export complete", metadata: [
                                "examples": "\(result.statistics.totalExamples)",
                                "tokens": "\(result.statistics.totalTokensEstimate)",
                                "template": "\(options.template.rawValue)",
                                "file": "\(url.path)"
                            ])
                            
                            // Open file location
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                            
                            // Close the export dialog
                            isPresented = false
                        }
                    } catch {
                        await MainActor.run {
                            isExporting = false
                            logger.error("Training data export failed: \(error)")
                            exportError = "Training export failed: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func formatMessageAsJSON(_ message: EnhancedMessage) -> String {
        let jsonObject: [String: Any] = [
            "id": message.id.uuidString,
            "content": message.content,
            "isFromUser": message.isFromUser,
            "timestamp": message.timestamp.ISO8601Format(),
            "conversationTitle": conversation.title
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted)
            return String(data: jsonData, encoding: .utf8) ?? ""
        } catch {
            return "Error creating JSON: \(error)"
        }
    }

    private func formatMessageAsMarkdown(_ message: EnhancedMessage) -> String {
        let sender = message.isFromUser ? "User" : "Assistant"
        var text = "# Message from \(conversation.title)\n\n"
        text += "**\(sender)** - \(message.timestamp.formatted(date: .abbreviated, time: .shortened))\n\n"
        text += message.content + "\n"
        return text
    }

    private func formatConversationAsJSON() -> String {
        let jsonObject: [String: Any] = [
            "id": conversation.id.uuidString,
            "title": conversation.title,
            "created": conversation.created.ISO8601Format(),
            "updated": conversation.updated.ISO8601Format(),
            "messages": conversation.messages.map { message in
                [
                    "id": message.id.uuidString,
                    "content": message.content,
                    "isFromUser": message.isFromUser,
                    "timestamp": message.timestamp.ISO8601Format()
                ]
            }
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted)
            return String(data: jsonData, encoding: .utf8) ?? ""
        } catch {
            return "Error creating JSON: \(error)"
        }
    }

    private func formatConversationAsMarkdown() -> String {
        var text = "# \(conversation.title)\n\n"
        text += "Created: \(conversation.created.formatted())\n\n"
        text += "---\n\n"

        for message in conversation.messages {
            let sender = message.isFromUser ? "User" : "Assistant"
            text += "## \(sender) - \(message.timestamp.formatted(date: .abbreviated, time: .shortened))\n\n"
            text += "\(message.content)\n\n"
            text += "---\n\n"
        }

        return text
    }
}
