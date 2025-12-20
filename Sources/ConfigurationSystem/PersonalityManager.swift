// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import SwiftUI

/// Manager for personality configurations
/// ARCHITECTURE: Similar to SystemPromptManager
/// - `personalities` stores ONLY user-created personalities (persisted)
/// - Default personalities are ALWAYS generated fresh from code (never persisted)
/// - `allPersonalities` combines defaults + user personalities for UI display
@MainActor
public class PersonalityManager: ObservableObject {
    private let logger = Logger(label: "com.sam.personalitymanager")

    /// User-created personalities (persisted to UserDefaults)
    @Published public var personalities: [Personality] = []

    /// Selected personality ID for current session
    @Published public var selectedPersonalityId: UUID?

    /// Default personality ID for new conversations
    @AppStorage("defaultPersonalityId") public var defaultPersonalityId: String = "00000000-0000-0000-0000-000000000001"  // Assistant UUID

    // MARK: - UserDefaults Keys

    private let userDefaults = UserDefaults.standard
    private let personalitiesKey = "UserPersonalities"
    private let selectedPersonalityKey = "SelectedPersonalityId"

    /// Default personalities generated fresh from code (never persisted)
    private var defaultPersonalities: [Personality] {
        Personality.defaultPersonalities()
    }

    /// All personalities (defaults + user-created) for UI display
    public var allPersonalities: [Personality] {
        defaultPersonalities + personalities
    }

    /// Singleton instance
    public static let shared = PersonalityManager()

    // MARK: - Lifecycle

    public init() {
        loadPersonalities()

        /// Ensure selectedPersonalityId is set to Assistant default if none selected
        if selectedPersonalityId == nil {
            let assistantId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            selectedPersonalityId = assistantId
            logger.info("AUTO-SELECT: Set selectedPersonalityId to Assistant (\(assistantId))")
        }
    }

    public var selectedPersonality: Personality? {
        guard let selectedId = selectedPersonalityId else { return nil }
        return allPersonalities.first { $0.id == selectedId }
    }

    // MARK: - Personality Management

    /// Get all personalities (default + custom)
    public func getAllPersonalities() -> [Personality] {
        return allPersonalities
    }

    /// Get personality by ID
    public func getPersonality(id: UUID) -> Personality? {
        return allPersonalities.first { $0.id == id }
    }

    /// Get personality by ID string (for UserDefaults compatibility)
    public func getPersonality(idString: String) -> Personality? {
        guard let uuid = UUID(uuidString: idString) else { return nil }
        return getPersonality(id: uuid)
    }

    /// Get default personality (Assistant)
    public var defaultPersonality: Personality {
        if let personality = getPersonality(idString: defaultPersonalityId) {
            return personality
        }
        return Personality.assistant
    }

    /// Add new personality
    public func addPersonality(_ personality: Personality) {
        /// Only add to user personalities (never save defaults)
        personalities.append(personality)
        savePersonalities()
        logger.info("Added personality: \(personality.name)")
    }

    /// Update existing personality
    /// If updating a default personality, creates a user copy
    public func updatePersonality(_ personality: Personality) {
        /// Check if this is a default personality
        let isDefault = defaultPersonalities.contains(where: { $0.id == personality.id })

        if isDefault {
            /// Create new user copy with new UUID (using init to create mutable copy)
            let userCopy = Personality(
                id: UUID(),
                name: personality.name,
                description: personality.description,
                selectedTraits: personality.selectedTraits,
                customInstructions: personality.customInstructions,
                isDefault: false
            )
            personalities.append(userCopy)
            logger.info("Created user copy of default personality: \(personality.name)")
        } else {
            /// Update existing user personality
            if let index = personalities.firstIndex(where: { $0.id == personality.id }) {
                /// Create new instance to ensure isDefault = false
                let updated = Personality(
                    id: personality.id,
                    name: personality.name,
                    description: personality.description,
                    selectedTraits: personality.selectedTraits,
                    customInstructions: personality.customInstructions,
                    isDefault: false
                )
                personalities[index] = updated
                logger.info("Updated personality: \(personality.name)")
            }
        }

        savePersonalities()
    }

    /// Delete personality (only user-created ones)
    public func deletePersonality(_ personality: Personality) {
        /// Prevent deleting default personalities
        if personality.isDefault {
            logger.warning("Cannot delete default personality: \(personality.name)")
            return
        }

        personalities.removeAll { $0.id == personality.id }

        /// If deleted personality was the default, reset to Assistant
        if defaultPersonalityId == personality.id.uuidString {
            defaultPersonalityId = Personality.assistant.id.uuidString
        }

        savePersonalities()
        logger.info("Deleted personality: \(personality.name)")
    }

    /// Select personality for current session
    public func selectPersonality(_ personality: Personality) {
        selectedPersonalityId = personality.id
        userDefaults.set(personality.id.uuidString, forKey: selectedPersonalityKey)
        logger.info("Selected personality: \(personality.name)")
    }

    /// Set default personality for new conversations
    public func setDefaultPersonality(_ personality: Personality) {
        defaultPersonalityId = personality.id.uuidString
        logger.info("Set default personality: \(personality.name)")
    }

    // MARK: - Prompt Generation

    /// Generate personality prompt additions for a given personality ID
    public func generatePromptAdditions(for personalityId: UUID?) -> String {
        guard let personalityId = personalityId,
              let personality = getPersonality(id: personalityId) else {
            return ""
        }

        /// Empty personality returns empty string
        if personality.isEmpty {
            return ""
        }

        let additions = personality.generatePromptAdditions()
        logger.debug("Generated personality additions for '\(personality.name)': \(additions.count) characters")
        return additions
    }

    /// Merge personality additions into system prompt
    public func mergePersonalityIntoPrompt(basePrompt: String, personalityId: UUID?) -> String {
        let additions = generatePromptAdditions(for: personalityId)

        if additions.isEmpty {
            return basePrompt
        }

        /// Add personality additions at the end of system prompt
        let mergedPrompt = """
        \(basePrompt)

        ---

        \(additions)
        """

        logger.debug("Merged personality into system prompt")
        return mergedPrompt
    }

    // MARK: - Persistence

    /// Load personalities from UserDefaults
    private func loadPersonalities() {
        /// Load ONLY user-created personalities (defaults generated fresh from code)
        if let data = userDefaults.data(forKey: personalitiesKey),
           let userPersonalities = try? JSONDecoder().decode([Personality].self, from: data) {
            personalities = userPersonalities
            logger.info("Loaded \(personalities.count) user-created personalities")
        } else {
            logger.info("No user personalities found, using defaults only")
        }

        /// Load selected personality ID
        if let selectedIdString = userDefaults.string(forKey: selectedPersonalityKey),
           let selectedId = UUID(uuidString: selectedIdString) {
            selectedPersonalityId = selectedId
            logger.debug("Loaded selected personality: \(selectedId)")
        }
    }

    /// Save user-created personalities to UserDefaults
    private func savePersonalities() {
        /// Save ONLY user-created personalities (never save defaults)
        guard let data = try? JSONEncoder().encode(personalities) else {
            logger.error("Failed to encode user personalities")
            return
        }

        userDefaults.set(data, forKey: personalitiesKey)
        logger.debug("Saved \(personalities.count) user personalities")
    }

    // MARK: - Validation

    /// Validate personality name is unique
    public func isNameUnique(_ name: String, excludingId: UUID? = nil) -> Bool {
        return !allPersonalities.contains { personality in
            personality.name.lowercased() == name.lowercased() &&
            personality.id != excludingId
        }
    }
}
