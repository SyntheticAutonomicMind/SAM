// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem

// MARK: - Personality Row

struct PersonalityRow: View {
    let personality: Personality
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var isDefaultPersonality: Bool {
        Personality.defaultPersonalities().contains(where: { $0.id == personality.id })
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(personality.name)
                        .font(.headline)
                        .fontWeight(isSelected ? .semibold : .medium)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                    }

                    if isDefaultPersonality {
                        Text("BUILT-IN")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    }

                    Spacer()
                }

                if !personality.description.isEmpty {
                    Text(personality.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                /// Show selected traits
                if !personality.selectedTraits.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(PersonalityTraitCategory.allCases, id: \.self) { category in
                            if let trait = personality.selectedTraits[category] {
                                Text(trait.displayName)
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(colorForCategory(category))
                                    .cornerRadius(4)
                            }
                        }
                    }
                }

                /// Show custom instructions indicator
                if !personality.customInstructions.isEmpty {
                    Text("+ Custom Instructions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                }
            }

            Spacer()
        }
        .padding()
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color(.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button("Edit") {
                onEdit()
            }

            if !isDefaultPersonality {
                Divider()

                Button("Delete", role: .destructive) {
                    onDelete()
                }
            }
        }
    }

    private func colorForCategory(_ category: PersonalityTraitCategory) -> Color {
        switch category {
        case .tone: return .blue
        case .formality: return .purple
        case .verbosity: return .green
        case .humor: return .orange
        case .teachingStyle: return .pink
        }
    }
}

// MARK: - Personality Editor

struct PersonalityEditor: View {
    let personality: Personality?
    let personalityManager: PersonalityManager
    @Binding var isPresented: Bool

    @State private var name: String
    @State private var description: String
    @State private var selectedTraits: [PersonalityTraitCategory: PersonalityTrait]
    @State private var customInstructions: String

    /// Initialize with data immediately - no .onAppear race condition
    init(personality: Personality?, personalityManager: PersonalityManager, isPresented: Binding<Bool>) {
        self.personality = personality
        self.personalityManager = personalityManager
        self._isPresented = isPresented
        
        // Initialize State values directly from personality (if editing) or defaults (if new)
        if let personality = personality {
            self._name = State(initialValue: personality.name)
            self._description = State(initialValue: personality.description)
            self._selectedTraits = State(initialValue: personality.selectedTraits)
            self._customInstructions = State(initialValue: personality.customInstructions)
        } else {
            self._name = State(initialValue: "")
            self._description = State(initialValue: "")
            self._selectedTraits = State(initialValue: [:])
            self._customInstructions = State(initialValue: "")
        }
    }

    private var isEditing: Bool { personality != nil }
    private var title: String { isEditing ? "Edit Personality" : "New Personality" }

    /// Check if we're editing a default personality (will create copy)
    private var isEditingDefault: Bool {
        guard let personality = personality else { return false }
        return Personality.defaultPersonalities().contains(where: { $0.id == personality.id })
    }

    var body: some View {
        VStack(spacing: 0) {
            /// Header
            HStack {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)

                if isEditingDefault {
                    Text("(Creating editable copy)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .background(Color(.controlBackgroundColor))

            Divider()

            /// Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    /// Basic Information
                    GroupBox("Basic Information") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Personality Name", text: $name)
                                .textFieldStyle(.roundedBorder)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Description")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                TextEditor(text: $description)
                                    .frame(minHeight: 60, maxHeight: 120)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color(.separatorColor), lineWidth: 1)
                                    )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }

                    /// Trait Selection
                    GroupBox("Personality Traits") {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Select one trait from each category to define the personality")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            ForEach(PersonalityTraitCategory.allCases, id: \.self) { category in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(category.displayName)
                                            .font(.subheadline)
                                            .fontWeight(.medium)

                                        Text(category.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(width: 200, alignment: .leading)

                                    Spacer()

                                    let traits = PersonalityTrait.traits(for: category)
                                    Picker("", selection: Binding(
                                        get: { selectedTraits[category] },
                                        set: { newValue in
                                            if let newValue = newValue {
                                                selectedTraits[category] = newValue
                                            } else {
                                                selectedTraits.removeValue(forKey: category)
                                            }
                                        }
                                    )) {
                                        Text("None")
                                            .font(.system(.caption, design: .monospaced))
                                            .tag(nil as PersonalityTrait?)
                                        ForEach(traits, id: \.self) { trait in
                                            Text(trait.displayName)
                                                .font(.system(.caption, design: .monospaced))
                                                .tag(trait as PersonalityTrait?)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 200)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }

                    /// Custom Instructions
                    GroupBox("Custom Instructions") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Additional instructions to customize behavior (optional)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            TextEditor(text: $customInstructions)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 150)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(.separatorColor), lineWidth: 1)
                                )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }

                    /// Preview
                    if !selectedTraits.isEmpty || !customInstructions.isEmpty {
                        GroupBox("Personality Prompt Preview") {
                            let previewPersonality = Personality(
                                name: name.isEmpty ? "Preview" : name,
                                description: description,
                                selectedTraits: selectedTraits,
                                customInstructions: customInstructions
                            )
                            ScrollView {
                                Text(previewPersonality.generatePromptAdditions())
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 200)
                        }
                    }
                }
                .padding()
            }

            Divider()

            /// Footer
            HStack {
                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Button(isEditing ? (isEditingDefault ? "Save as Copy" : "Save Changes") : "Create Personality") {
                    savePersonality()
                }
                .disabled(name.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(.controlBackgroundColor))
        }
        .frame(minWidth: 600, idealWidth: 800, maxWidth: 1000,
               minHeight: 500, idealHeight: 700, maxHeight: .infinity)
    }

    private func savePersonality() {
        let newPersonality = Personality(
            id: (isEditing && !isEditingDefault) ? personality!.id : UUID(),
            name: name,
            description: description,
            selectedTraits: selectedTraits,
            customInstructions: customInstructions,
            isDefault: false  /// User-created personalities are never default
        )

        if isEditing {
            personalityManager.updatePersonality(newPersonality)
        } else {
            personalityManager.addPersonality(newPersonality)
        }

        isPresented = false
    }
}

#Preview {
    PersonalityEditor(
        personality: nil,
        personalityManager: PersonalityManager.shared,
        isPresented: .constant(true)
    )
}
