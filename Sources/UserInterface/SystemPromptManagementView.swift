// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem

// MARK: - System Prompt Configuration Row

struct SystemPromptConfigurationRow: View {
    let configuration: SystemPromptConfiguration
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(configuration.name)
                        .font(.headline)
                        .fontWeight(isSelected ? .semibold : .medium)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                    }

                    Spacer()
                }

                if !configuration.description.isEmpty {
                    Text(configuration.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                HStack {
                    Text("\(configuration.components.count) components")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("\(configuration.components.filter(\.isEnabled).count) active")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text("Updated \(configuration.updatedAt, style: .relative) ago")
                        .font(.caption)
                        .foregroundColor(.secondary)
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

            Divider()

            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }
}

// MARK: - Configuration Editor

struct SystemPromptConfigurationEditor: View {
    let configuration: SystemPromptConfiguration?
    let promptManager: SystemPromptManager
    @Binding var isPresented: Bool

    @State private var name: String
    @State private var description: String
    @State private var components: [SystemPromptComponent]
    @State private var showingNewComponent = false
    @State private var showingComponentLibrary = false
    @State private var editingComponent: SystemPromptComponent?

    /// Initialize with data immediately - no .onAppear race condition
    init(configuration: SystemPromptConfiguration?, promptManager: SystemPromptManager, isPresented: Binding<Bool>) {
        self.configuration = configuration
        self.promptManager = promptManager
        self._isPresented = isPresented
        
        // Initialize State values directly from configuration (if editing) or defaults (if new)
        if let configuration = configuration {
            self._name = State(initialValue: configuration.name)
            self._description = State(initialValue: configuration.description)
            self._components = State(initialValue: configuration.components)
        } else {
            self._name = State(initialValue: "")
            self._description = State(initialValue: "")
            self._components = State(initialValue: [])
        }
    }

    private var isEditing: Bool { configuration != nil }
    private var title: String { isEditing ? "Edit Template" : "New Template" }

    var body: some View {
        VStack(spacing: 0) {
            /// Header.
            HStack {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()
            }
            .padding()
            .background(Color(.controlBackgroundColor))

            Divider()

            /// Content.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    /// Basic Information.
                    GroupBox("Basic Information") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Template Name", text: $name)
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
                        .padding()
                    }

                    /// Components.
                    GroupBox("Components") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Prompt Components")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Spacer()

                                Button("Add from Library") {
                                    showingComponentLibrary = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("Add Component") {
                                    showingNewComponent = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            if components.isEmpty {
                                Text("No components added yet")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                            } else {
                                ForEach(components.sorted(by: { $0.order < $1.order })) { component in
                                    SystemPromptComponentRow(
                                        component: component,
                                        onToggle: { enabled in
                                            if let index = components.firstIndex(where: { $0.id == component.id }) {
                                                components[index].isEnabled = enabled
                                            }
                                        },
                                        onEdit: {
                                            editingComponent = component
                                        },
                                        onDelete: {
                                            components.removeAll { $0.id == component.id }
                                        }
                                    )
                                }
                            }
                        }
                        .padding()
                    }

                    /// Preview.
                    if !components.isEmpty {
                        GroupBox("Generated Prompt Preview") {
                            let previewText = generatePreviewPrompt()
                            ScrollView {
                                Text(previewText.isEmpty ? "No active components" : previewText)
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

            /// Footer.
            HStack {
                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Button(isEditing ? "Save Changes" : "Create Template") {
                    saveConfiguration()
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
        .sheet(isPresented: $showingNewComponent) {
            SystemPromptComponentEditor(
                component: nil,
                isPresented: $showingNewComponent,
                onSave: { component in
                    components.append(component)
                }
            )
        }
        .sheet(isPresented: $showingComponentLibrary) {
            PromptComponentBrowserView(
                isPresented: $showingComponentLibrary,
                onSelectComponent: { libraryComponent in
                    let newComponent = libraryComponent.toSystemPromptComponent(
                        order: components.count
                    )
                    components.append(newComponent)
                }
            )
        }
        .sheet(item: $editingComponent) { component in
            SystemPromptComponentEditor(
                component: component,
                isPresented: Binding(
                    get: { editingComponent != nil },
                    set: { if !$0 { editingComponent = nil } }
                ),
                onSave: { updatedComponent in
                    if let index = components.firstIndex(where: { $0.id == component.id }) {
                        components[index] = updatedComponent
                    }
                    editingComponent = nil
                }
            )
        }
    }

    private func generatePreviewPrompt() -> String {
        return components
            .filter { $0.isEnabled }
            .sorted { $0.order < $1.order }
            .map { $0.content }
            .joined(separator: "\n\n")
    }

    private func saveConfiguration() {
        let newConfiguration = SystemPromptConfiguration(
            id: configuration?.id ?? UUID(),
            name: name,
            description: description,
            components: components
        )

        if isEditing {
            promptManager.updateConfiguration(newConfiguration)
        } else {
            promptManager.addConfiguration(newConfiguration)
        }

        isPresented = false
    }
}

// MARK: - Component Row and Editor

struct SystemPromptComponentRow: View {
    let component: SystemPromptComponent
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: .init(
                get: { component.isEnabled },
                set: { newValue in
                    onToggle(newValue)
                }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
                Text(component.title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(String(component.content.prefix(100)) + (component.content.count > 100 ? "..." : ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Menu {
                Button("Edit") {
                    onEdit()
                }

                Button("Delete", role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct SystemPromptComponentEditor: View {
    let component: SystemPromptComponent?
    @Binding var isPresented: Bool
    let onSave: (SystemPromptComponent) -> Void

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var isEnabled: Bool = true
    @State private var order: Int = 0

    private var isEditing: Bool { component != nil }

    var body: some View {
        VStack(spacing: 0) {
            /// Header.
            HStack {
                Text(isEditing ? "Edit Component" : "New Component")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()
            }
            .padding()
            .background(Color(.controlBackgroundColor))

            Divider()

            /// Content.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Component Title", text: $title)
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Content")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        TextEditor(text: $content)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 200)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(.separatorColor), lineWidth: 1)
                            )
                    }

                    HStack {
                        Toggle("Enabled by default", isOn: $isEnabled)

                        Spacer()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Order")
                                .font(.caption)
                            TextField("Order", value: $order, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                    }
                }
                .padding()
            }

            Divider()

            /// Footer.
            HStack {
                Spacer()

                Button("Cancel") {
                    isPresented = false
                }

                Button(isEditing ? "Save Changes" : "Add Component") {
                    let newComponent = SystemPromptComponent(
                        id: component?.id ?? UUID(),
                        title: title,
                        content: content,
                        isEnabled: isEnabled,
                        order: order
                    )
                    onSave(newComponent)
                    isPresented = false
                }
                .disabled(title.isEmpty || content.isEmpty)
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(.controlBackgroundColor))
        }
        .frame(minWidth: 500, idealWidth: 600, maxWidth: 700,
               minHeight: 400, idealHeight: 500, maxHeight: 600)
        .onAppear {
            if let component = component {
                title = component.title
                content = component.content
                isEnabled = component.isEnabled
                order = component.order
            }
        }
    }
}

#Preview {
    SystemPromptConfigurationEditor(
        configuration: nil,
        promptManager: SystemPromptManager.shared,
        isPresented: .constant(true)
    )
}
