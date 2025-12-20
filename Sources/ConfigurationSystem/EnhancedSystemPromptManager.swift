// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import SwiftUI

/// Enhanced System Prompt Manager with SAM 1.0 integration Combines SAM 1.0 PromptManager functionality with SAM's SystemPromptConfiguration.
@MainActor
public class EnhancedSystemPromptManager: ObservableObject {

    // MARK: - Logging
    private let logger = Logger(label: "com.sam.systemprompmanager")

    // MARK: - Data Models (from SAM 1.0)

    public struct SystemPrompt: Codable, Identifiable {
        public let id: String
        public let name: String
        public let category: String
        public let description: String
        public let prompt: String
        public let temperature: Double
        public let skills: [String]
        public let use_cases: [String]

        enum CodingKeys: String, CodingKey {
            case id, name, category, description, prompt, temperature, skills
            case use_cases = "use_cases"
        }
    }

    public struct SystemPromptsCollection: Codable {
        public let metadata: PromptMetadata
        public let prompts: [SystemPrompt]
    }

    public struct PromptMetadata: Codable {
        public let version: String
        public let description: String
        public let last_updated: String
        public let category: String

        enum CodingKeys: String, CodingKey {
            case version, description, category
            case last_updated = "last_updated"
        }
    }

    // MARK: - Published Properties

    @Published public var configurations: [SystemPromptConfiguration] = []
    @Published public var selectedConfigurationId: UUID?
    @AppStorage("defaultSystemPromptId") public var defaultSystemPromptId: String = "00000000-0000-0000-0000-000000000001"  // SAM Default UUID
    @Published public var availableSystemPrompts: [SystemPrompt] = []

    // MARK: - Storage Properties

    private var systemPrompts: [String: SystemPrompt] = [:]
    private var promptsByCategory: [String: [SystemPrompt]] = [:]

    // MARK: - UserDefaults Keys

    private let userDefaults = UserDefaults.standard
    private let configurationsKey = "SystemPromptConfigurations"
    private let selectedConfigurationKey = "SelectedSystemPromptConfiguration"

    // MARK: - Lifecycle

    public init() {
        loadSystemPromptsFromJSON()
        loadConfigurations()
        /// DISABLED: Only use JSON-based system prompts for simplicity if configurations.isEmpty { loadDefaultConfigurations() }.
    }

    // MARK: - SAM 1.0 JSON Loading Integration

    private func loadSystemPromptsFromJSON() {
        let systemPromptFiles = [
            "core_system_prompts"
        ]

        for fileName in systemPromptFiles {
            if let collection = loadSystemPromptCollection(fileName: fileName) {
                for prompt in collection.prompts {
                    systemPrompts[prompt.id] = prompt
                }
                logger.debug("Loaded \(collection.prompts.count) system prompts from \(fileName)")
            }
        }

        /// Update available prompts for UI.
        availableSystemPrompts = Array(systemPrompts.values)
        organizeByCategory()
    }

    private func loadSystemPromptCollection(fileName: String) -> SystemPromptsCollection? {
        let fullPath = "Prompts/SystemPrompts/\(fileName)"
        return loadJSONFile(path: fullPath, type: SystemPromptsCollection.self)
    }

    private func loadJSONFile<T: Codable>(path: String, type: T.Type) -> T? {
        /// Try to load from bundle Resources.
        if let bundleURL = Bundle.main.url(forResource: path, withExtension: "json") {
            return loadFromURL(bundleURL, type: type)
        }

        /// Try to load from source directory (development).
        let currentDirectory = FileManager.default.currentDirectoryPath
        let sourceBasePath = "\(currentDirectory)/Sources/ConfigurationSystem/Resources"
        let sourceURL = URL(fileURLWithPath: "\(sourceBasePath)/\(path).json")

        if FileManager.default.fileExists(atPath: sourceURL.path) {
            return loadFromURL(sourceURL, type: type)
        }

        logger.warning("Could not find JSON file at path: \(path)")
        return nil
    }

    private func loadFromURL<T: Codable>(_ url: URL, type: T.Type) -> T? {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let result = try decoder.decode(type, from: data)
            return result
        } catch {
            logger.error("Error loading JSON from \(url.path): \(error)")
            return nil
        }
    }

    private func organizeByCategory() {
        promptsByCategory.removeAll()
        for prompt in systemPrompts.values {
            if promptsByCategory[prompt.category] == nil {
                promptsByCategory[prompt.category] = []
            }
            promptsByCategory[prompt.category]?.append(prompt)
        }
    }

    // MARK: - Enhanced Configuration Management

    public var selectedConfiguration: SystemPromptConfiguration? {
        guard let selectedId = selectedConfigurationId else { return nil }
        return configurations.first { $0.id == selectedId }
    }

    public func addConfiguration(_ configuration: SystemPromptConfiguration) {
        configurations.append(configuration)
        saveConfigurations()
    }

    public func updateConfiguration(_ configuration: SystemPromptConfiguration) {
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
            var updatedConfig = configuration
            updatedConfig.updatedAt = Date()
            configurations[index] = updatedConfig
            saveConfigurations()
        }
    }

    public func removeConfiguration(_ configuration: SystemPromptConfiguration) {
        configurations.removeAll { $0.id == configuration.id }
        if selectedConfigurationId == configuration.id {
            selectedConfigurationId = configurations.first?.id
        }
        saveConfigurations()
    }

    public func selectConfiguration(_ configuration: SystemPromptConfiguration) {
        selectedConfigurationId = configuration.id
        userDefaults.set(configuration.id.uuidString, forKey: selectedConfigurationKey)
    }

    // MARK: - SAM 1.0 Integration Methods

    /// Get a system prompt by ID (SAM 1.0 style).
    public func getSystemPrompt(id: String) -> SystemPrompt? {
        return systemPrompts[id]
    }

    /// Get all system prompts in a category.
    public func getSystemPrompts(category: String) -> [SystemPrompt] {
        return promptsByCategory[category] ?? []
    }

    /// Get all available categories.
    public func getSystemPromptCategories() -> [String] {
        let allCategories = Array(promptsByCategory.keys)
        return allCategories.sorted { category1, category2 in
            if category1 == "core" && category2 != "core" {
                return true
            } else if category1 != "core" && category2 == "core" {
                return false
            } else {
                return category1 < category2
            }
        }
    }

    /// Create configuration from SAM 1.0 system prompt.
    public func createConfigurationFromSystemPrompt(_ systemPrompt: SystemPrompt) -> SystemPromptConfiguration {
        let component = SystemPromptComponent(
            title: systemPrompt.name,
            content: systemPrompt.prompt,
            isEnabled: true,
            order: 0
        )

        return SystemPromptConfiguration(
            name: systemPrompt.name,
            description: systemPrompt.description,
            components: [component]
        )
    }

    // MARK: - Enhanced System Prompt Generation

    public func generateSystemPrompt(for configurationId: UUID? = nil, toolsEnabled: Bool = true) -> String {
        let configuration = if let configurationId = configurationId {
            configurations.first { $0.id == configurationId }
        } else {
            selectedConfiguration
        }

        return configuration?.generateSystemPrompt(toolsEnabled: toolsEnabled) ?? ""
    }

    public func mergeWithChatPrompt(chatPrompt: String, configurationId: UUID? = nil) -> String {
        let systemPrompt = generateSystemPrompt(for: configurationId)

        if systemPrompt.isEmpty {
            return chatPrompt
        } else if chatPrompt.isEmpty {
            return systemPrompt
        } else {
            return "\(systemPrompt)\n\n## ADDITIONAL CONTEXT:\n\n\(chatPrompt)"
        }
    }

    // MARK: - Persistence

    private func loadConfigurations() {
        guard let data = userDefaults.data(forKey: configurationsKey),
              let decodedConfigurations = try? JSONDecoder().decode([SystemPromptConfiguration].self, from: data)
        else {
            return
        }

        configurations = decodedConfigurations

        /// Load selected configuration.
        if let selectedIdString = userDefaults.string(forKey: selectedConfigurationKey),
           let selectedId = UUID(uuidString: selectedIdString) {
            selectedConfigurationId = selectedId
        }
    }

    private func saveConfigurations() {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        userDefaults.set(data, forKey: configurationsKey)
    }

    private func loadDefaultConfigurations() {
        /// Create configurations from SAM 1.0 system prompts.
        var defaultConfigs: [SystemPromptConfiguration] = []

        /// Add SAM 1.0 prompts as configurations.
        for prompt in systemPrompts.values {
            let config = createConfigurationFromSystemPrompt(prompt)
            defaultConfigs.append(config)
        }

        /// Add any existing default configurations Only using JSON-based system prompts for simplicity.

        /// Remove duplicates based on name.
        let uniqueConfigs = defaultConfigs.reduce(into: [String: SystemPromptConfiguration]()) { result, config in
            result[config.name] = config
        }

        configurations = Array(uniqueConfigs.values)
        selectedConfigurationId = configurations.first?.id
        saveConfigurations()

        logger.debug("Loaded \(configurations.count) default configurations")
    }

    // MARK: - Logging Summary

    public func getLoadingSummary() -> String {
        return """
        Enhanced SystemPromptManager Summary:
        - System Prompts (SAM 1.0): \(systemPrompts.count)
        - System Categories: \(getSystemPromptCategories().joined(separator: ", "))
        - Configurations: \(configurations.count)
        - Selected: \(selectedConfiguration?.name ?? "None")
        """
    }
}
