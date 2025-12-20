// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import ConversationEngine

/// Panel for managing mini-prompts (per-conversation).
public struct MiniPromptPanel: View {
    @ObservedObject var manager: MiniPromptManager
    @ObservedObject var conversation: ConversationModel
    @ObservedObject var conversationManager: ConversationManager
    @State private var editingPrompt: MiniPrompt?
    @State private var showNewPromptEditor = false
    @State private var showDeleteConfirmation = false
    @State private var promptToDelete: UUID?
    @State private var filterText: String = ""

    public init(manager: MiniPromptManager = .shared, conversation: ConversationModel, conversationManager: ConversationManager) {
        self.manager = manager
        self.conversation = conversation
        self.conversationManager = conversationManager
    }

    /// Get filtered prompts based on filterText.
    private var filteredPrompts: [MiniPrompt] {
        let sorted = manager.miniPrompts.sorted { $0.displayOrder < $1.displayOrder }

        if filterText.isEmpty {
            return sorted
        } else {
            return sorted.filter { prompt in
                prompt.name.localizedCaseInsensitiveContains(filterText) ||
                prompt.content.localizedCaseInsensitiveContains(filterText)
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            /// Header.
            HStack(alignment: .center) {
                Text("Mini-Prompts")
                    .font(.headline)
                Spacer()
                Button(action: {
                    showNewPromptEditor = true
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Add new mini-prompt")
            }
            .padding()

            /// Filter text field.
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Filter prompts...", text: $filterText)
                    .textFieldStyle(.plain)
                if !filterText.isEmpty {
                    Button(action: { filterText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            /// Empty state.
            if filteredPrompts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(manager.miniPrompts.isEmpty ? "No mini-prompts" : "No matches")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(manager.miniPrompts.isEmpty ? "Create contextual prompts to add context to your conversations." : "Try a different filter term.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                /// List with drag-and-drop reordering (CRITICAL: Must use List for .onMove to work).
                List {
                    ForEach(filteredPrompts) { prompt in
                        HStack(spacing: 12) {
                            /// Drag handle.
                            Image(systemName: "line.3.horizontal")
                                .foregroundColor(.secondary)
                                .help("Drag to reorder")

                            /// Enable toggle.
                            Toggle("", isOn: Binding(
                                get: { manager.isEnabled(id: prompt.id, for: conversation.id, enabledIds: conversation.enabledMiniPromptIds) },
                                set: { _ in
                                    manager.toggleEnabled(id: prompt.id, for: conversation.id, currentIds: &conversation.enabledMiniPromptIds)
                                    /// Trigger save immediately after toggle.
                                    conversationManager.saveConversations()
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()

                            /// Name and preview.
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(prompt.name)
                                        .font(.subheadline)
                                        .fontWeight(.medium)

                                    /// Badge for conversation-specific prompts.
                                    if prompt.conversationIds != nil && !(prompt.conversationIds?.isEmpty ?? true) {
                                        Text("SCOPED")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.2))
                                            .foregroundColor(.blue)
                                            .cornerRadius(4)
                                    }
                                }

                                Text(prompt.content)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            /// Edit button.
                            Button(action: {
                                editingPrompt = prompt
                            }) {
                                Image(systemName: "pencil")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                            .help("Edit prompt")

                            /// Delete button.
                            Button(action: {
                                promptToDelete = prompt.id
                                showDeleteConfirmation = true
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Delete prompt")
                        }
                        .padding(.vertical, 4)
                    }
                    .onMove { source, destination in
                        movePrompt(from: source, to: destination)
                    }
                }
                .listStyle(.sidebar)
                .frame(maxHeight: .infinity)
            }

            /// Footer.
            let enabledCount = conversation.enabledMiniPromptIds.count
            if enabledCount > 0 {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("\(enabledCount) enabled for this conversation")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
        .frame(minWidth: 300, idealWidth: 350, maxWidth: 400)
        .sheet(item: $editingPrompt) { prompt in
            MiniPromptEditor(manager: manager, prompt: prompt)
        }
        .sheet(isPresented: $showNewPromptEditor) {
            MiniPromptEditor(manager: manager, prompt: nil)
        }
        .alert("Delete Mini-Prompt?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                promptToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let id = promptToDelete {
                    manager.deletePrompt(id: id)
                }
                promptToDelete = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    /// Handle drag-and-drop reordering.
    private func movePrompt(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first else { return }

        /// When filtering is active, we need to map back to the full list.
        if !filterText.isEmpty {
            /// Cannot reorder when filtering - would be confusing User must clear filter first.
            return
        }

        /// Get the prompt being moved.
        let sourcePrompt = filteredPrompts[sourceIndex]
        let promptId = sourcePrompt.id

        /// Reorder in the manager.
        manager.reorder(prompt: promptId, to: destination)
    }
}
