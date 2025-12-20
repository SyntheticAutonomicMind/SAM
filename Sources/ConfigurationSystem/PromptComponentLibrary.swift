// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

private let logger = Logger(label: "com.sam.config.PromptComponentLibrary")

// MARK: - Component Category

/// Categories for organizing reusable prompt components.
public enum ComponentCategory: String, Codable, CaseIterable, Identifiable {
    case role = "Role"
    case tone = "Tone"
    case knowledge = "Knowledge"
    case constraints = "Constraints"
    case formatting = "Formatting"
    case examples = "Examples"
    case instructions = "Instructions"
    case other = "Other"

    public var id: String { rawValue }

    public var description: String {
        switch self {
        case .role:
            return "Define the assistant's role or expertise"
        case .tone:
            return "Set the communication style and tone"
        case .knowledge:
            return "Specify domain knowledge areas"
        case .constraints:
            return "Define limits and guidelines"
        case .formatting:
            return "Output formatting preferences"
        case .examples:
            return "Provide example patterns"
        case .instructions:
            return "Specific task instructions"
        case .other:
            return "Other custom components"
        }
    }
}

// MARK: - Library Component

/// A reusable component in the library (extends SystemPromptComponent with category).
public struct LibraryComponent: Codable, Identifiable, Hashable {
    public let id: UUID
    public var category: ComponentCategory
    public var title: String
    public var description: String
    public var content: String
    public var isBuiltIn: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        category: ComponentCategory,
        title: String,
        description: String = "",
        content: String,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.description = description
        self.content = content
        self.isBuiltIn = isBuiltIn
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    /// Convert to SystemPromptComponent for use in templates.
    public func toSystemPromptComponent(order: Int = 0) -> SystemPromptComponent {
        return SystemPromptComponent(
            id: UUID(), // New ID for each use
            title: title,
            content: content,
            isEnabled: true,
            order: order
        )
    }
}

// MARK: - Prompt Component Library Manager

/// Manages the reusable component library.
public class PromptComponentLibrary: ObservableObject {
    @Published public var components: [LibraryComponent] = []

    private let storageURL: URL
    private let componentsFileName = "component-library.json"

    nonisolated(unsafe) public static let shared = PromptComponentLibrary()

    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        storageURL = cacheDir
            .appendingPathComponent("sam", isDirectory: true)
            .appendingPathComponent("prompt-components", isDirectory: true)

        createStorageDirectoryIfNeeded()
        loadComponents()

        if components.isEmpty {
            createBuiltInLibrary()
            saveComponents()
        }
    }

    private func createStorageDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
    }

    // MARK: - Persistence

    private func loadComponents() {
        let fileURL = storageURL.appendingPathComponent(componentsFileName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.info("No existing component library found, will create default library")
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            components = try decoder.decode([LibraryComponent].self, from: data)
            logger.info("Loaded \(components.count) library components")
        } catch {
            logger.error("Failed to load component library: \(error.localizedDescription)")
        }
    }

    private func saveComponents() {
        let fileURL = storageURL.appendingPathComponent(componentsFileName)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(components)
            try data.write(to: fileURL)
            logger.debug("Saved \(components.count) library components")
        } catch {
            logger.error("Failed to save component library: \(error.localizedDescription)")
        }
    }

    // MARK: - Component Management

    public func addComponent(_ component: LibraryComponent) {
        components.append(component)
        saveComponents()
        logger.info("Added component to library: \(component.title)")
    }

    public func updateComponent(_ component: LibraryComponent) {
        if let index = components.firstIndex(where: { $0.id == component.id }) {
            var updated = component
            updated.updatedAt = Date()
            components[index] = updated
            saveComponents()
            logger.info("Updated component: \(component.title)")
        }
    }

    public func deleteComponent(_ id: UUID) {
        if let component = components.first(where: { $0.id == id }) {
            guard !component.isBuiltIn else {
                logger.warning("Cannot delete built-in component: \(component.title)")
                return
            }
            components.removeAll { $0.id == id }
            saveComponents()
            logger.info("Deleted component: \(component.title)")
        }
    }

    public func componentsByCategory(_ category: ComponentCategory) -> [LibraryComponent] {
        return components.filter { $0.category == category }.sorted { $0.title < $1.title }
    }

    // MARK: - Built-In Library

    private func createBuiltInLibrary() {
        logger.info("Creating built-in component library")

        // MARK: Roles

        components.append(LibraryComponent(
            category: .role,
            title: "Software Engineer",
            description: "Expert software developer with broad technical knowledge",
            content: """
            You are an expert software engineer with deep knowledge of:
            - Software architecture and design patterns
            - Code quality, testing, and best practices
            - Multiple programming languages and frameworks
            - Debugging and problem-solving methodologies

            Provide technically accurate, well-reasoned solutions.
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .role,
            title: "Data Analyst",
            description: "Statistical analysis and data interpretation expert",
            content: """
            You are a data analyst specializing in:
            - Statistical analysis and interpretation
            - Data visualization and presentation
            - Pattern recognition and trend analysis
            - Clear communication of insights

            Help users understand their data and make informed decisions.
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .role,
            title: "Creative Writer",
            description: "Skilled creative and technical writer",
            content: """
            You are a creative writer with expertise in:
            - Storytelling and narrative structure
            - Clear, engaging prose
            - Multiple writing styles and formats
            - Editing and revision

            Craft compelling, well-structured content tailored to audience and purpose.
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .role,
            title: "Teacher",
            description: "Patient educator who explains complex topics clearly",
            content: """
            You are an experienced teacher who:
            - Breaks down complex topics into understandable parts
            - Uses examples and analogies to clarify concepts
            - Adapts explanations to the learner's level
            - Encourages questions and deeper understanding

            Focus on clarity, patience, and building knowledge step by step.
            """,
            isBuiltIn: true
        ))

        // MARK: Tones

        components.append(LibraryComponent(
            category: .tone,
            title: "Professional",
            description: "Formal and business-appropriate communication",
            content: """
            Communication Style:
            - Formal, respectful language
            - Clear and direct
            - Appropriate for business contexts
            - Maintains professional boundaries
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .tone,
            title: "Casual & Friendly",
            description: "Conversational and approachable tone",
            content: """
            Communication Style:
            - Conversational and relaxed
            - Warm and approachable
            - Uses everyday language
            - Maintains helpfulness without formality
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .tone,
            title: "Technical & Precise",
            description: "Technical accuracy with domain-specific terminology",
            content: """
            Communication Style:
            - Technically precise and accurate
            - Uses domain-specific terminology appropriately
            - Detailed and thorough
            - Focuses on correctness over simplification
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .tone,
            title: "Concise",
            description: "Brief, to-the-point responses",
            content: """
            Communication Style:
            - Brief and to the point
            - Eliminates unnecessary details
            - Gets to the answer quickly
            - Values efficiency over elaboration
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .tone,
            title: "Detailed & Thorough",
            description: "Comprehensive explanations with full context",
            content: """
            Communication Style:
            - Comprehensive and detailed
            - Provides full context and background
            - Explains reasoning and alternatives
            - Thorough coverage of edge cases
            """,
            isBuiltIn: true
        ))

        // MARK: Knowledge Areas

        components.append(LibraryComponent(
            category: .knowledge,
            title: "Swift & SwiftUI",
            description: "Swift programming and SwiftUI framework expertise",
            content: """
            Specialized Knowledge:
            - Swift language features and best practices
            - SwiftUI declarative framework patterns
            - iOS/macOS application development
            - Apple ecosystem technologies

            Provide idiomatic Swift code following Apple's guidelines.
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .knowledge,
            title: "Python",
            description: "Python programming expertise",
            content: """
            Specialized Knowledge:
            - Python language and standard library
            - Popular frameworks and libraries
            - Pythonic idioms and best practices
            - Data science and scripting applications

            Write clean, idiomatic Python code following PEP 8.
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .knowledge,
            title: "Web Development",
            description: "Modern web technologies and frameworks",
            content: """
            Specialized Knowledge:
            - HTML, CSS, JavaScript fundamentals
            - Modern frameworks (React, Vue, etc.)
            - Web standards and best practices
            - Responsive design and accessibility

            Build modern, accessible web applications.
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .knowledge,
            title: "Git & Version Control",
            description: "Git workflow and version control best practices",
            content: """
            Specialized Knowledge:
            - Git commands and workflows
            - Branching strategies
            - Conflict resolution
            - Collaboration best practices

            Help users manage code with Git effectively.
            """,
            isBuiltIn: true
        ))

        // MARK: Constraints

        components.append(LibraryComponent(
            category: .constraints,
            title: "Keep Responses Concise (3 sentences max)",
            description: "Limit responses to maximum 3 sentences",
            content: """
            Response Constraint:
            - Keep responses to 3 sentences or less
            - Be direct and eliminate unnecessary words
            - If topic requires more detail, ask if user wants elaboration
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .constraints,
            title: "Always Include Code Examples",
            description: "Include practical code examples in responses",
            content: """
            Response Requirement:
            - Always provide working code examples when relevant
            - Show practical usage, not just theory
            - Include comments explaining key concepts
            - Ensure code is tested and functional
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .constraints,
            title: "Explain Like I'm 5",
            description: "Use simple language suitable for beginners",
            content: """
            Communication Constraint:
            - Use simple, everyday language
            - Avoid jargon unless necessary (then explain it)
            - Use analogies and examples
            - Assume no prior knowledge
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .constraints,
            title: "Focus on Best Practices",
            description: "Emphasize industry best practices and standards",
            content: """
            Quality Standard:
            - Prioritize industry best practices
            - Explain why certain approaches are preferred
            - Point out anti-patterns to avoid
            - Reference authoritative sources when relevant
            """,
            isBuiltIn: true
        ))

        // MARK: Formatting

        components.append(LibraryComponent(
            category: .formatting,
            title: "Markdown Formatting",
            description: "Use rich Markdown formatting in responses",
            content: """
            Formatting Guidelines:
            - Use headers (##, ###) to organize sections
            - Use code blocks with language tags
            - Use lists for multiple items
            - Use **bold** for emphasis
            - Use `inline code` for technical terms
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .formatting,
            title: "Code Block Standards",
            description: "Consistent code block formatting",
            content: """
            Code Block Requirements:
            - Always specify language in code blocks
            - Include descriptive comments
            - Use proper indentation
            - Show complete, runnable examples
            - Example: ```swift
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .formatting,
            title: "Structured Lists",
            description: "Use numbered or bulleted lists for organization",
            content: """
            List Formatting:
            - Use numbered lists for sequential steps
            - Use bulleted lists for unordered items
            - Keep list items parallel in structure
            - Use sub-lists for hierarchical information
            """,
            isBuiltIn: true
        ))

        // MARK: Examples

        components.append(LibraryComponent(
            category: .examples,
            title: "Provide Before/After Examples",
            description: "Show transformation examples",
            content: """
            Example Pattern:
            When suggesting improvements, show:

            BEFORE:
            [original code/text]

            AFTER:
            [improved code/text]

            EXPLANATION:
            [what changed and why]
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .examples,
            title: "Use Real-World Scenarios",
            description: "Ground explanations in practical examples",
            content: """
            Example Approach:
            - Use realistic, practical scenarios
            - Show how concepts apply to real problems
            - Provide context for when to use each approach
            - Include edge cases and gotchas
            """,
            isBuiltIn: true
        ))

        // MARK: Instructions

        components.append(LibraryComponent(
            category: .instructions,
            title: "Step-by-Step Instructions",
            description: "Provide clear sequential instructions",
            content: """
            When providing instructions:
            1. Number each step clearly
            2. Make each step actionable
            3. Include expected outcomes
            4. Note prerequisites before starting
            5. Provide troubleshooting for common issues
            """,
            isBuiltIn: true
        ))

        components.append(LibraryComponent(
            category: .instructions,
            title: "Debug Systematically",
            description: "Systematic debugging methodology",
            content: """
            Debugging Approach:
            1. Reproduce the issue
            2. Isolate the problem area
            3. Form hypothesis about root cause
            4. Test hypothesis
            5. Verify fix works

            Always work from evidence, not assumptions.
            """,
            isBuiltIn: true
        ))

        logger.info("Created \(components.count) built-in library components")
    }
}
