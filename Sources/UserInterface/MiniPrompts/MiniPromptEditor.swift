// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem

/// Editor for creating/editing mini-prompts.
public struct MiniPromptEditor: View {
    @ObservedObject var manager: MiniPromptManager
    var prompt: MiniPrompt?

    @State private var name: String
    @State private var content: String

    @Environment(\.dismiss) private var dismiss

    public init(manager: MiniPromptManager, prompt: MiniPrompt? = nil) {
        self.manager = manager
        self.prompt = prompt
        /// Initialize @State variables with prompt data if editing, empty if new.
        _name = State(initialValue: prompt?.name ?? "")
        _content = State(initialValue: prompt?.content ?? "")
    }

    public var body: some View {
        VStack(spacing: 16) {
            /// Header.
            HStack {
                Text(prompt == nil ? "New Mini-Prompt" : "Edit Mini-Prompt")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
            }

            /// Name field.
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextField("e.g., Project Context", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            /// Content editor.
            VStack(alignment: .leading, spacing: 4) {
                Text("Content")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                TextEditor(text: $content)
                    .font(.body)
                    .frame(minHeight: 200, maxHeight: .infinity)
                    .border(Color.secondary.opacity(0.2), width: 1)
                Text("\(content.count) characters")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            /// Actions.
            HStack {
                if prompt != nil {
                    Button("Delete", role: .destructive) {
                        manager.deletePrompt(id: prompt!.id)
                        dismiss()
                    }
                    Spacer()
                }

                Button("Cancel") {
                    dismiss()
                }

                Button("Save") {
                    savePrompt()
                    dismiss()
                }
                .disabled(name.isEmpty || content.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
        .frame(width: 500, height: 450)
    }

    private func savePrompt() {
        if let existing = prompt {
            var updated = existing
            updated.update(name: name, content: content)
            manager.updatePrompt(updated)
        } else {
            let newPrompt = MiniPrompt(name: name, content: content)
            manager.addPrompt(newPrompt)
        }
    }
}
