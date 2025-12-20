// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import UniformTypeIdentifiers
import ConversationEngine
import Logging

/// Document Import View with Drag-and-Drop Interface Provides intuitive document import with drag-drop, file browser, and import progress.
struct DocumentImportView: View {
    @StateObject private var importSystem: DocumentImportSystem

    public init(conversationManager: ConversationManager) {
        self._importSystem = StateObject(wrappedValue: DocumentImportSystem(conversationManager: conversationManager))
    }
    @State private var isTargeted = false
    @State private var showingFilePicker = false
    @State private var importProgress: Double = 0.0
    @State private var isImporting = false
    @State private var recentImports: [ImportedDocument] = []
    @State private var showingImportHistory = false

    private let logger = Logger(label: "com.sam.ui.DocumentImport")

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                /// Header.
                headerSection

                /// Main drop zone.
                dropZoneSection

                /// Action buttons.
                actionButtonsSection

                /// Recent imports (if any).
                if !recentImports.isEmpty {
                    recentImportsSection
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Document Import")
            .onDrop(of: [UTType.item], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: supportedFileTypes,
                allowsMultipleSelection: true
            ) { result in
                handleFileSelection(result)
            }
            .sheet(isPresented: $showingImportHistory) {
                ImportHistoryView(imports: recentImports)
            }
        }
        .onAppear {
            loadRecentImports()
        }
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            Text("Import Documents")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Drag documents here or browse to add them to SAM's knowledge")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var dropZoneSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isTargeted ? Color.blue : Color.gray.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: isTargeted ? [] : [10])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted ? Color.blue.opacity(0.1) : Color.clear)
                )
                .frame(height: 200)
                .animation(.easeInOut(duration: 0.2), value: isTargeted)

            if isImporting {
                importProgressView
            } else {
                dropZoneContent
            }
        }
    }

    private var dropZoneContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 32))
                .foregroundColor(isTargeted ? .blue : .gray)

            Text(isTargeted ? "Drop documents to import" : "Drop documents here")
                .font(.headline)
                .foregroundColor(isTargeted ? .blue : .primary)

            Text("Supports PDF, Word, Excel, text files, and images")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var importProgressView: some View {
        VStack(spacing: 16) {
            ProgressView(value: importProgress, total: 1.0)
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(1.5)

            Text("Processing documents...")
                .font(.headline)

            Text("\(Int(importProgress * 100))% complete")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var actionButtonsSection: some View {
        HStack(spacing: 16) {
            Button(action: { showingFilePicker = true }) {
                Label("Browse Files", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(action: { showingImportHistory = true }) {
                Label("Import History", systemImage: "clock")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(recentImports.isEmpty)
        }
    }

    private var recentImportsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Imports")
                .font(.headline)

            LazyVStack(spacing: 8) {
                ForEach(Array(recentImports.prefix(3).enumerated()), id: \.element.id) { _, document in
                    RecentImportRow(document: document)
                }
            }

            if recentImports.count > 3 {
                Button("View All (\(recentImports.count))") {
                    showingImportHistory = true
                }
                .font(.caption)
                .foregroundColor(.blue)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - File Handling

    private var supportedFileTypes: [UTType] {
        [
            .pdf,
            .plainText,
            .rtf,
            .png,
            .jpeg,
            .tiff,
            UTType("com.microsoft.word.doc")!,
            UTType("org.openxmlformats.wordprocessingml.document")!,
            UTType("com.microsoft.excel.xls")!,
            UTType("org.openxmlformats.spreadsheetml.sheet")!,
            UTType("public.source-code")!
        ]
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        logger.debug("Handling drop with \(providers.count) items")

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        Task {
                            await importDocument(from: url)
                        }
                    }
                }
            }
        }

        return true
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                await importDocuments(from: urls)
            }

        case .failure(let error):
            logger.error("File selection failed: \(error.localizedDescription)")
        }
    }

    private func importDocuments(from urls: [URL]) async {
        await MainActor.run {
            isImporting = true
            importProgress = 0.0
        }

        for (index, url) in urls.enumerated() {
            await importDocument(from: url)

            await MainActor.run {
                importProgress = Double(index + 1) / Double(urls.count)
            }
        }

        await MainActor.run {
            isImporting = false
            loadRecentImports()
        }
    }

    private func importDocument(from url: URL) async {
        do {
            let document = try await importSystem.importDocument(from: url)

            await MainActor.run {
                logger.debug("Successfully imported: \(document.filename)")
                /// Could show success notification here.
            }
        } catch {
            await MainActor.run {
                logger.error("Import failed for \(url.lastPathComponent): \(error.localizedDescription)")
                /// Could show error alert here.
            }
        }
    }

    private func loadRecentImports() {
        /// In a real implementation, this would load from persistent storage For now, we'll simulate some recent imports.
        recentImports = []
    }
}

/// Row view for recent import display.
struct RecentImportRow: View {
    let document: ImportedDocument

    var body: some View {
        HStack {
            Image(systemName: symbolNameForUTType(document.contentType))
                .foregroundColor(colorForUTType(document.contentType))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(document.filename)
                    .font(.subheadline)
                    .lineLimit(1)

                Text(document.importDate, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(document.content.count.formatted() + " chars")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.5))
        .cornerRadius(8)
    }
}

/// Import history detail view.
struct ImportHistoryView: View {
    let imports: [ImportedDocument]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List(imports) { document in
                ImportHistoryRow(document: document)
            }
            .navigationTitle("Import History")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ImportHistoryRow: View {
    let document: ImportedDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbolNameForUTType(document.contentType))
                    .foregroundColor(colorForUTType(document.contentType))

                Text(document.filename)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text(document.importDate, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !document.metadata.isEmpty {
                HStack {
                    ForEach(Array(document.metadata.prefix(2)), id: \.key) { keyValue in
                        let (key, value) = keyValue
                        Text("\(key): \(value)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(4)
                    }
                    Spacer()
                }
            }

            Text("\(document.content.count) characters extracted")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Helper Methods

/// Helper functions for UTType-based display.
private func symbolNameForUTType(_ utType: UTType) -> String {
    if utType.conforms(to: .pdf) {
        return "doc.richtext"
    } else if utType.conforms(to: .plainText) {
        return "doc.plaintext"
    } else if utType.identifier.contains("word") {
        return "doc.text"
    } else if utType.identifier.contains("excel") || utType.identifier.contains("sheet") {
        return "tablecells"
    } else if utType.identifier.contains("powerpoint") || utType.identifier.contains("presentation") {
        return "rectangle.on.rectangle"
    } else if utType.identifier.contains("markdown") {
        return "text.alignleft"
    } else if utType.conforms(to: .image) {
        return "photo"
    } else {
        return "doc"
    }
}

private func colorForUTType(_ utType: UTType) -> Color {
    if utType.conforms(to: .pdf) {
        return .red
    } else if utType.conforms(to: .plainText) {
        return .secondary
    } else if utType.identifier.contains("word") {
        return .blue
    } else if utType.identifier.contains("excel") || utType.identifier.contains("sheet") {
        return .green
    } else if utType.identifier.contains("powerpoint") || utType.identifier.contains("presentation") {
        return .orange
    } else if utType.identifier.contains("markdown") {
        return .purple
    } else if utType.conforms(to: .image) {
        return .pink
    } else {
        return .gray
    }
}

#Preview {
    /// Preview needs a mock ConversationManager - simplified for compilation.
    struct PreviewWrapper: View {
        var body: some View {
            Text("DocumentImportView Preview")
        }
    }
    return PreviewWrapper()
}
