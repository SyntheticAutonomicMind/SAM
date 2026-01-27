// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging

private let logger = Logger(label: "com.sam.help.renderer")

// MARK: - Help Content Renderer

/// Renders help content elements from JSON data.
/// Each element type has its own dedicated render function to avoid SwiftUI type-checker timeouts.
struct HelpContentRenderer: View {
    let elements: [HelpElement]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(elements) { element in
                ElementRenderer(element: element)
            }
        }
    }
}

// MARK: - Element Router

/// Routes each element to its appropriate renderer.
/// Using a separate struct avoids complex type inference in parent view.
private struct ElementRenderer: View {
    let element: HelpElement

    var body: some View {
        switch element.type {
        case .heading:
            HeadingElement(content: element.content)
        case .subheading:
            SubheadingElement(content: element.content)
        case .text:
            TextElement(content: element.content)
        case .bulletPoint:
            BulletPointElement(content: element.content, icon: element.properties?["icon"])
        case .step:
            StepElement(content: element.content, number: element.properties?["number"] ?? "1")
        case .example:
            ExampleElement(content: element.content, title: element.properties?["title"])
        case .tip:
            TipElement(content: element.content)
        case .warning:
            WarningElement(content: element.content)
        case .note:
            NoteElement(content: element.content)
        case .keyboardShortcut:
            KeyboardShortcutElement(keys: element.properties?["keys"] ?? "", description: element.content)
        case .divider:
            DividerElement()
        case .group:
            GroupElement(title: element.content, children: element.children ?? [])
        case .code:
            CodeElement(content: element.content)
        case .link:
            LinkElement(content: element.content, url: element.properties?["url"])
        case .troubleshootingItem:
            TroubleshootingElement(question: element.properties?["question"] ?? "", solution: element.content)
        case .formatSupport:
            FormatSupportElement(
                format: element.properties?["format"] ?? "",
                icon: element.properties?["icon"] ?? "doc",
                color: element.properties?["color"] ?? "gray",
                description: element.content
            )
        case .systemPromptOption:
            SystemPromptElement(
                name: element.properties?["name"] ?? "",
                bestFor: element.properties?["bestFor"] ?? "",
                description: element.content
            )
        case .capabilityCategory:
            CapabilityCategoryElement(
                icon: element.properties?["icon"] ?? "star",
                title: element.properties?["title"] ?? "",
                description: element.properties?["description"] ?? "",
                children: element.children ?? []
            )
        case .toolCategory:
            ToolCategoryElement(
                icon: element.properties?["icon"] ?? "hammer",
                title: element.properties?["title"] ?? "",
                color: element.properties?["color"] ?? "gray",
                children: element.children ?? []
            )
        }
    }
}

// MARK: - Individual Element Views

private struct HeadingElement: View {
    let content: String
    var body: some View {
        Text(content)
            .font(.largeTitle)
            .fontWeight(.bold)
    }
}

private struct SubheadingElement: View {
    let content: String
    var body: some View {
        Text(content)
            .font(.title2)
            .fontWeight(.semibold)
            .padding(.top, 8)
    }
}

private struct TextElement: View {
    let content: String
    var body: some View {
        Text(.init(content))
            .font(.body)
    }
}

private struct BulletPointElement: View {
    let content: String
    let icon: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
                    .frame(width: 16)
            } else {
                Text("•")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .frame(width: 16)
            }
            Text(.init(content))
                .font(.body)
        }
    }
}

private struct StepElement: View {
    let content: String
    let number: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.accentColor))
            Text(.init(content))
                .font(.body)
        }
    }
}

private struct ExampleElement: View {
    let content: String
    let title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = title {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(content)
                .font(.body)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
        }
    }
}

private struct TipElement: View {
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundColor(.yellow)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Tip")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(.init(content))
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(8)
    }
}

private struct WarningElement: View {
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Warning")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(.init(content))
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
}

private struct NoteElement: View {
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Note")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(.init(content))
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
    }
}

private struct KeyboardShortcutElement: View {
    let keys: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor)
                .cornerRadius(6)
                .frame(minWidth: 80, alignment: .leading)
            Text(description)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct DividerElement: View {
    var body: some View {
        Divider()
            .padding(.vertical, 8)
    }
}

private struct GroupElement: View {
    let title: String
    let children: [HelpElement]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.primary)
                .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(children) { child in
                    ElementRenderer(element: child)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

private struct CodeElement: View {
    let content: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(content)
                .font(.system(.caption, design: .monospaced))
                .padding()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

private struct LinkElement: View {
    let content: String
    let url: String?

    var body: some View {
        if let urlString = url, let linkURL = URL(string: urlString) {
            Link(destination: linkURL) {
                HStack(spacing: 4) {
                    Text(content)
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                }
            }
            .foregroundColor(.accentColor)
        } else {
            Text(content)
                .foregroundColor(.accentColor)
        }
    }
}

private struct TroubleshootingElement: View {
    let question: String
    let solution: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.orange)
                    .frame(width: 24, height: 24)
                Text(question)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
            }
            Text(solution)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.2), lineWidth: 1)
        )
    }
}

private struct FormatSupportElement: View {
    let format: String
    let icon: String
    let color: String
    let description: String

    private var colorValue: Color {
        switch color {
        case "red": return .red
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "purple": return .purple
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(colorValue)
                .frame(width: 32, height: 32)
                .background(Circle().fill(colorValue.opacity(0.1)))

            VStack(alignment: .leading, spacing: 3) {
                Text(format)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct SystemPromptElement: View {
    let name: String
    let bestFor: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Text(bestFor)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .italic()
            }
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 1)
        )
    }
}

private struct CapabilityCategoryElement: View {
    let icon: String
    let title: String
    let description: String
    let children: [HelpElement]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.accentColor)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(children) { child in
                    ElementRenderer(element: child)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
        )
    }
}

private struct ToolCategoryElement: View {
    let icon: String
    let title: String
    let color: String
    let children: [HelpElement]

    private var colorValue: Color {
        switch color {
        case "purple": return .purple
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "gray": return .gray
        case "indigo": return .indigo
        case "cyan": return .cyan
        case "yellow": return .yellow
        case "pink": return .pink
        case "mint": return .mint
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(colorValue)
                    .frame(width: 24, height: 24)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(children) { child in
                    ElementRenderer(element: child)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorValue.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(colorValue.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Section Content View

/// Displays a complete help section with header and content.
struct HelpSectionContentView: View {
    let section: HelpSectionData

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: section.icon)
                    .font(.title)
                    .foregroundColor(.accentColor)
                Text(section.title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }

            Divider()

            HelpContentRenderer(elements: section.elements)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
