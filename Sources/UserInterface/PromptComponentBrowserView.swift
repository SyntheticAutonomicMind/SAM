// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConfigurationSystem

// MARK: - Component Library Browser

/// Browse and manage the reusable component library.
public struct PromptComponentBrowserView: View {
    @ObservedObject var library = PromptComponentLibrary.shared
    @Binding var isPresented: Bool
    let onSelectComponent: (LibraryComponent) -> Void

    @State private var selectedCategory: ComponentCategory?
    @State private var searchText: String = ""
    @State private var selectedComponent: LibraryComponent?
    @State private var showingComponentEditor = false
    @State private var editingComponent: LibraryComponent?

    private var filteredComponents: [LibraryComponent] {
        var components = library.components

        if let category = selectedCategory {
            components = components.filter { $0.category == category }
        }

        if !searchText.isEmpty {
            components = components.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText) ||
                $0.content.localizedCaseInsensitiveContains(searchText)
            }
        }

        return components.sorted { $0.title < $1.title }
    }

    public init(
        isPresented: Binding<Bool>,
        onSelectComponent: @escaping (LibraryComponent) -> Void
    ) {
        self._isPresented = isPresented
        self.onSelectComponent = onSelectComponent
    }

    public var body: some View {
        VStack(spacing: 0) {
            /// Header.
            HStack {
                Text("Component Library")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button("New Component") {
                    editingComponent = nil
                    showingComponentEditor = true
                }
                .buttonStyle(.bordered)

                Button("Done") {
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(.controlBackgroundColor))

            Divider()

            /// Search Bar.
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search components...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal)
            .padding(.top, 8)

            /// Content.
            HSplitView {
                /// Category Sidebar.
                VStack(alignment: .leading, spacing: 0) {
                    Text("Categories")
                        .font(.headline)
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                    List(selection: $selectedCategory) {
                        Section {
                            Button(action: { selectedCategory = nil }) {
                                HStack {
                                    Image(systemName: "square.grid.2x2")
                                    Text("All Components")
                                    Spacer()
                                    Text("\(library.components.count)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .tag(nil as ComponentCategory?)
                        }

                        Section("By Category") {
                            ForEach(ComponentCategory.allCases) { category in
                                Button(action: { selectedCategory = category }) {
                                    HStack {
                                        Image(systemName: categoryIcon(category))
                                        Text(category.rawValue)
                                        Spacer()
                                        Text("\(library.componentsByCategory(category).count)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .tag(category as ComponentCategory?)
                            }
                        }
                    }
                }
                .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

                /// Component List and Preview.
                VStack(spacing: 0) {
                    if filteredComponents.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "tray")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text(searchText.isEmpty ? "No components in this category" : "No components match your search")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(filteredComponents, selection: $selectedComponent) { component in
                            ComponentLibraryRow(
                                component: component,
                                onSelect: {
                                    onSelectComponent(component)
                                },
                                onEdit: {
                                    if !component.isBuiltIn {
                                        editingComponent = component
                                        showingComponentEditor = true
                                    }
                                },
                                onDelete: {
                                    if !component.isBuiltIn {
                                        library.deleteComponent(component.id)
                                    }
                                }
                            )
                        }
                    }

                    /// Preview pane.
                    if let component = selectedComponent {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Preview")
                                    .font(.headline)
                                Spacer()
                                if component.isBuiltIn {
                                    Text("Built-in")
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.2))
                                        .cornerRadius(4)
                                }
                            }

                            Text(component.description)
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            Divider()

                            ScrollView {
                                Text(component.content)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 150)

                            HStack {
                                Button("Add to Template") {
                                    onSelectComponent(component)
                                }
                                .buttonStyle(.borderedProminent)

                                Spacer()
                            }
                        }
                        .padding()
                        .background(Color(.controlBackgroundColor))
                    }
                }
            }
        }
        .frame(minWidth: 700, idealWidth: 900, maxWidth: .infinity,
               minHeight: 500, idealHeight: 600, maxHeight: .infinity)
        .sheet(isPresented: $showingComponentEditor) {
            LibraryComponentEditor(
                component: editingComponent,
                isPresented: $showingComponentEditor,
                onSave: { component in
                    if editingComponent != nil {
                        library.updateComponent(component)
                    } else {
                        library.addComponent(component)
                    }
                    editingComponent = nil
                }
            )
        }
    }

    private func categoryIcon(_ category: ComponentCategory) -> String {
        switch category {
        case .role: return "person.circle"
        case .tone: return "waveform"
        case .knowledge: return "book"
        case .constraints: return "slider.horizontal.3"
        case .formatting: return "textformat"
        case .examples: return "lightbulb"
        case .instructions: return "list.number"
        case .other: return "folder"
        }
    }
}

// MARK: - Component Library Row

struct ComponentLibraryRow: View {
    let component: LibraryComponent
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(component.title)
                        .font(.headline)

                    if component.isBuiltIn {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                    }
                }

                Text(component.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                HStack {
                    Text(component.category.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)

                    Spacer()

                    Text(component.updatedAt, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: onSelect) {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Add to template")
        }
        .padding(8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Add to Template") {
                onSelect()
            }

            if !component.isBuiltIn {
                Divider()

                Button("Edit") {
                    onEdit()
                }

                Button("Delete", role: .destructive) {
                    onDelete()
                }
            }
        }
    }
}

// MARK: - Library Component Editor

struct LibraryComponentEditor: View {
    let component: LibraryComponent?
    @Binding var isPresented: Bool
    let onSave: (LibraryComponent) -> Void

    @State private var category: ComponentCategory = .other
    @State private var title: String = ""
    @State private var description: String = ""
    @State private var content: String = ""

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
                    /// Category.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Category")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Picker("Category", selection: $category) {
                            ForEach(ComponentCategory.allCases) { cat in
                                Text(cat.rawValue).tag(cat)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)

                        Text(category.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    /// Title.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Title")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        TextField("Component title", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    /// Description.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        TextField("Brief description", text: $description)
                            .textFieldStyle(.roundedBorder)
                    }

                    /// Content.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Content")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        TextEditor(text: $content)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 250)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(.separatorColor), lineWidth: 1)
                            )
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

                Button(isEditing ? "Save Changes" : "Add Component") {
                    let newComponent = LibraryComponent(
                        id: component?.id ?? UUID(),
                        category: category,
                        title: title,
                        description: description,
                        content: content,
                        isBuiltIn: component?.isBuiltIn ?? false
                    )
                    onSave(newComponent)
                    isPresented = false
                }
                .disabled(title.isEmpty || content.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(.controlBackgroundColor))
        }
        .frame(minWidth: 500, idealWidth: 600, maxWidth: 700,
               minHeight: 500, idealHeight: 650, maxHeight: 800)
        .onAppear {
            if let component = component {
                category = component.category
                title = component.title
                description = component.description
                content = component.content
            }
        }
    }
}

#Preview {
    PromptComponentBrowserView(
        isPresented: .constant(true),
        onSelectComponent: { _ in }
    )
}
