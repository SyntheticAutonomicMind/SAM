// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem

/// Editor for creating/editing custom instructions.
public struct CustomInstructionEditor: View {
    @ObservedObject var manager: CustomInstructionManager
    var instruction: CustomInstruction?

    @State private var name: String
    @State private var content: String

    @Environment(\.dismiss) private var dismiss

    public init(manager: CustomInstructionManager, instruction: CustomInstruction? = nil) {
        self.manager = manager
        self.instruction = instruction
        _name = State(initialValue: instruction?.name ?? "")
        _content = State(initialValue: instruction?.content ?? "")
    }

    public var body: some View {
        VStack(spacing: 16) {
            /// Header.
            HStack {
                Text(instruction == nil ? "New Custom Instruction" : "Edit Custom Instruction")
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
                if instruction != nil {
                    Button("Delete", role: .destructive) {
                        manager.deleteInstruction(id: instruction!.id)
                        dismiss()
                    }
                    Spacer()
                }

                Button("Cancel") {
                    dismiss()
                }

                Button("Save") {
                    saveInstruction()
                    dismiss()
                }
                .disabled(name.isEmpty || content.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
        .frame(width: 500, height: 450)
    }

    private func saveInstruction() {
        if let existing = instruction {
            var updated = existing
            updated.update(name: name, content: content)
            manager.updateInstruction(updated)
        } else {
            let newInstruction = CustomInstruction(name: name, content: content)
            manager.addInstruction(newInstruction)
        }
    }
}
