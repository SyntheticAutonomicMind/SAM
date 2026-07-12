// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem
import ConversationEngine

/// Panel for managing custom instructions (per-conversation).
public struct CustomInstructionPanel: View {
    @ObservedObject var manager: CustomInstructionManager
    @ObservedObject var conversation: ConversationModel
    @ObservedObject var conversationManager: ConversationManager
    @State private var editingInstruction: CustomInstruction?
    @State private var showNewInstructionEditor = false
    @State private var showDeleteConfirmation = false
    @State private var instructionToDelete: UUID?
    @State private var filterText: String = ""

    public init(manager: CustomInstructionManager = .shared, conversation: ConversationModel, conversationManager: ConversationManager) {
        self.manager = manager
        self.conversation = conversation
        self.conversationManager = conversationManager
    }

    /// Get filtered instructions based on filterText.
    private var filteredInstructions: [CustomInstruction] {
        let sorted = manager.customInstructions.sorted { $0.displayOrder < $1.displayOrder }

        if filterText.isEmpty {
            return sorted
        } else {
            return sorted.filter { instruction in
                instruction.name.localizedCaseInsensitiveContains(filterText) ||
                instruction.content.localizedCaseInsensitiveContains(filterText)
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            /// Header.
            HStack(alignment: .center) {
                Text("Custom Instructions")
                    .font(.headline)
                Spacer()
                Button(action: {
                    showNewInstructionEditor = true
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Add new custom instruction")
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)

            /// Filter text field.
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Filter instructions...", text: $filterText)
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
            if filteredInstructions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(manager.customInstructions.isEmpty ? "No custom instructions" : "No matches")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(manager.customInstructions.isEmpty ? "Create instructions to add context or behavioral guidance to your conversations." : "Try a different filter term.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                /// List with drag-and-drop reordering.
                List {
                    ForEach(filteredInstructions) { instruction in
                        HStack(spacing: 12) {
                            /// Drag handle.
                            Image(systemName: "line.3.horizontal")
                                .foregroundColor(.secondary)
                                .help("Drag to reorder")

                            /// Enable toggle.
                            Toggle("", isOn: Binding(
                                get: { manager.isEnabled(id: instruction.id, for: conversation.id, enabledIds: conversation.enabledCustomInstructionIds) },
                                set: { _ in
                                    manager.toggleEnabled(id: instruction.id, for: conversation.id, currentIds: &conversation.enabledCustomInstructionIds)
                                    /// Trigger save immediately after toggle.
                                    conversationManager.saveConversations()
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()

                            /// Name and preview.
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(instruction.name)
                                        .font(.subheadline)
                                        .fontWeight(.medium)

                                    /// Badge for conversation-specific instructions.
                                    if instruction.conversationIds != nil && !(instruction.conversationIds?.isEmpty ?? true) {
                                        Text("SCOPED")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.2))
                                            .foregroundColor(.blue)
                                            .cornerRadius(4)
                                    }
                                }

                                Text(instruction.content)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            /// Edit button.
                            Button(action: {
                                editingInstruction = instruction
                            }) {
                                Image(systemName: "pencil")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.plain)
                            .help("Edit instruction")

                            /// Delete button.
                            Button(action: {
                                instructionToDelete = instruction.id
                                showDeleteConfirmation = true
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Delete instruction")
                        }
                        .padding(.vertical, 4)
                    }
                    .onMove { source, destination in
                        moveInstruction(from: source, to: destination)
                    }
                }
                .listStyle(.sidebar)
                .frame(maxHeight: .infinity)
            }

            /// Footer.
            let enabledCount = conversation.enabledCustomInstructionIds.count
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
        .frame(maxWidth: .infinity)
        .sheet(item: $editingInstruction) { instruction in
            CustomInstructionEditor(manager: manager, instruction: instruction)
        }
        .sheet(isPresented: $showNewInstructionEditor) {
            CustomInstructionEditor(manager: manager, instruction: nil)
        }
        .alert("Delete Custom Instruction?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                instructionToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let id = instructionToDelete {
                    manager.deleteInstruction(id: id)
                }
                instructionToDelete = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    /// Handle drag-and-drop reordering.
    private func moveInstruction(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first else { return }

        /// When filtering is active, we need to map back to the full list.
        if !filterText.isEmpty {
            return
        }

        /// Get the instruction being moved.
        let sourceInstruction = filteredInstructions[sourceIndex]
        let instructionId = sourceInstruction.id

        /// Reorder in the manager.
        manager.reorder(instruction: instructionId, to: destination)
    }
}
