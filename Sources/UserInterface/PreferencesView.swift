// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import APIFramework
import ConfigurationSystem
import ConversationEngine
import SharedData
import Logging

private let logger = Logger(label: "com.sam.preferences")

public struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var endpointManager: EndpointManager
    @State private var selectedSection: PreferencesSection

    public init(selectedSection: PreferencesSection = .general) {
        _selectedSection = State(initialValue: selectedSection)
    }

    public var body: some View {
        VStack(spacing: 0) {
            /// Header with title and close button.
            preferencesHeader

            Divider()

            /// Main content with sidebar.
            NavigationSplitView(
                sidebar: {
                    preferencesSidebar
                },
                detail: {
                    preferencesDetail
                }
            )
            .frame(minWidth: 800, idealWidth: 1000, maxWidth: 1200,
                   minHeight: 600, idealHeight: 800, maxHeight: .infinity)
        }
    }

    private var preferencesHeader: some View {
        HStack {
            Text("Preferences")
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .help("Close Preferences")
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var preferencesSidebar: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(PreferencesSection.allCases, id: \.self) { section in
                    PreferencesSectionRow(
                        section: section,
                        isSelected: selectedSection == section,
                        onSelect: {
                            selectedSection = section
                        }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    }

    @ViewBuilder
    private var preferencesDetail: some View {
        switch selectedSection {
        case .general:
            GeneralPreferencesView()

        case .appearance:
            AppearancePreferencesView()

        case .sound:
            SoundPreferencesPane()

        case .conversations:
            ConversationPreferencesView()

        case .sharedTopics:
            SharedDataPreferencesView()

        case .systemPrompts:
            SystemPromptPreferencesView()

        case .personalities:
            PersonalityPreferencesPane()

        case .apiEndpoints:
            EndpointManagementView()
                .environmentObject(endpointManager)

        case .localModels:
            LocalModelsPreferencePane(endpointManager: endpointManager)

        case .modelTraining:
            TrainingPreferencesPane()

        case .imageGeneration:
            StableDiffusionPreferencesPane()

        case .serpAPI:
            SerpAPIPreferencesPane()

        case .apiServer:
            APIServerPreferencesView()

        case .advanced:
            AdvancedPreferencesView()
        }
    }
}

// MARK: - Shared Data Preferences

struct SharedDataPreferencesView: View {
    @State private var topics: [SharedTopic] = []
    @State private var loading: Bool = false
    @State private var newTopicName: String = ""
    @State private var newTopicDescription: String = ""
    @State private var editingTopic: SharedTopic?
    @State private var showEditSheet: Bool = false
    @State private var editName: String = ""
    @State private var editDescription: String = ""
    private let manager = SharedTopicManager()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Shared Topics") {
                    VStack(alignment: .leading, spacing: 12) {
                        if loading {
                            ProgressView()
                        }

                        ForEach(topics, id: \.id) { topic in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(topic.name)
                                        .font(.body)
                                    if let description = topic.description, !description.isEmpty {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()

                                /// Edit button
                                Button(action: {
                                    editingTopic = topic
                                    editName = topic.name
                                    editDescription = topic.description ?? ""
                                    showEditSheet = true
                                }) {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.plain)
                                .help("Edit topic")

                                /// Delete button
                                Button(action: {
                                    deleteTopic(topic)
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Delete topic")
                            }
                            .padding(.vertical, 4)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Create New Topic")
                                .font(.headline)

                            TextField("Topic name", text: $newTopicName)
                                .textFieldStyle(.roundedBorder)

                            TextField("Description (optional)", text: $newTopicDescription)
                                .textFieldStyle(.roundedBorder)

                            Button("Create") {
                                createTopic()
                            }
                            .disabled(newTopicName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        Text("Create and manage named shared topics that agents can be assigned to. Topics are disabled by default and require explicit assignment per conversation.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
            .padding()
        }
        .onAppear {
            Task { await loadTopics() }
        }
        .sheet(isPresented: $showEditSheet) {
            editTopicSheet
        }
    }

    private var editTopicSheet: some View {
        VStack(spacing: 16) {
            Text("Edit Topic")
                .font(.headline)

            TextField("Topic name", text: $editName)
                .textFieldStyle(.roundedBorder)

            TextField("Description (optional)", text: $editDescription)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    showEditSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    updateTopic()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func loadTopics() async {
        loading = true
        do {
            let list = try manager.listTopics()
            await MainActor.run {
                topics = list
                loading = false
            }
        } catch {
            loading = false
        }
    }

    private func createTopic() {
        let name = newTopicName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let description = newTopicDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDescription = description.isEmpty ? nil : description

        do {
            _ = try manager.createTopic(name: name, description: finalDescription)
            newTopicName = ""
            newTopicDescription = ""
            Task { await loadTopics() }
        } catch {
            logger.error("Failed to create topic: \(error.localizedDescription)")
        }
    }

    private func updateTopic() {
        guard let topic = editingTopic else { return }
        let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let description = editDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDescription = description.isEmpty ? nil : description

        do {
            try manager.updateTopic(id: UUID(uuidString: topic.id)!, name: name, description: finalDescription)
            showEditSheet = false
            Task { await loadTopics() }
        } catch {
            logger.error("Failed to update topic: \(error.localizedDescription)")
        }
    }

    private func deleteTopic(_ topic: SharedTopic) {
        do {
            try manager.deleteTopic(id: UUID(uuidString: topic.id)!)
            Task { await loadTopics() }
        } catch {
            logger.error("Failed to delete topic: \(error.localizedDescription)")
        }
    }
}

// MARK: - Preferences Sections

public enum PreferencesSection: String, CaseIterable {
    case general = "General"
    case appearance = "Appearance"
    case sound = "Sound"
    case conversations = "Conversations"
    case sharedTopics = "Shared Topics"
    case systemPrompts = "System Prompts"
    case personalities = "Personalities"
    case apiEndpoints = "Remote Providers"
    case localModels = "Local Models"
    case modelTraining = "Model Training"
    case imageGeneration = "Image Generation"
    case serpAPI = "SerpAPI"
    case apiServer = "API Server"
    case advanced = "Advanced"

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .sound: return "speaker.wave.2.fill"
        case .conversations: return "bubble.left.and.bubble.right"
        case .sharedTopics: return "tray.full"
        case .systemPrompts: return "doc.text"
        case .personalities: return "theatermasks"
        case .apiEndpoints: return "network"
        case .localModels: return "externaldrive.fill"
        case .modelTraining: return "graduationcap.fill"
        case .imageGeneration: return "photo.stack.fill"
        case .serpAPI: return "magnifyingglass.circle"
        case .apiServer: return "server.rack"
        case .advanced: return "slider.horizontal.3"
        }
    }

    var color: Color {
        switch self {
        case .general: return .gray
        case .appearance: return .purple
        case .sound: return .blue
        case .conversations: return .blue
        case .sharedTopics: return .mint
        case .systemPrompts: return .cyan
        case .personalities: return .pink
        case .apiEndpoints: return .green
        case .localModels: return .indigo
        case .modelTraining: return .orange
        case .imageGeneration: return .blue
        case .serpAPI: return .teal
        case .apiServer: return .orange
        case .advanced: return .pink
        }
    }
}

// MARK: - Preferences Section Row

struct PreferencesSectionRow: View {
    let section: PreferencesSection
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: section.icon)
                    .foregroundColor(section.color)
                    .frame(width: 16, height: 16)

                Text(section.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General Preferences

struct GeneralPreferencesView: View {
    @EnvironmentObject private var endpointManager: EndpointManager
    @AppStorage("defaultModel") private var defaultModel: String = ""
    
    /// Model list management - using shared ModelListManager
    @ObservedObject private var modelListManager = ModelListManager.shared
    
    @AppStorage("userName") private var userName: String = ""
    @AppStorage("userLanguage") private var userLanguage: String = ""
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("enableNotifications") private var enableNotifications: Bool = true
    @AppStorage("enableSoundEffects") private var enableSoundEffects: Bool = true
    @AppStorage("notificationSound") private var notificationSound: String = "Submarine"
    @AppStorage("speakEmojis") private var speakEmojis: Bool = false /// Default OFF - don't speak emojis in TTS
    @AppStorage("git.userName") private var gitUserName: String = "Assistant SAM"
    @AppStorage("git.userEmail") private var gitUserEmail: String = "sam@syntheticautonomicmind.com"

    @State private var workingDirectoryBase: String = WorkingDirectoryConfiguration.shared.basePath
    @State private var showingDirectoryPicker: Bool = false

    /// Workflow settings (Phase 1 implementation).
    @AppStorage("workflow.maxIterations") private var maxIterations: Int = WorkflowConfiguration.defaultMaxIterations
    @State private var maxIterationsText: String = "\(WorkflowConfiguration.defaultMaxIterations)"

    /// Location settings
    @ObservedObject private var locationManager = LocationManager.shared
    @AppStorage("user.generalLocation") private var generalLocation: String = ""
    @AppStorage("user.usePreciseLocation") private var usePreciseLocation: Bool = false
    
    /// Development updates settings
    @AppStorage("developmentUpdatesEnabled") private var developmentUpdatesEnabled: Bool = false
    @State private var showDevelopmentConfirmation = false

    /// Language options.
    private let languageOptions = [
        "English", "Spanish", "French", "German", "Italian", "Portuguese", "Russian",
        "Chinese", "Japanese", "Korean", "Arabic", "Hindi", "Dutch", "Swedish",
        "Danish", "Norwegian", "Finnish", "Polish", "Turkish", "Thai", "Vietnamese"
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Default Model") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Select default model for new conversations")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        HStack {
                            Text("Model:")
                                .frame(width: 120, alignment: .leading)

                            if modelListManager.isLoading {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Loading models...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                ModelPickerView(
                                    selectedModel: $defaultModel,
                                    modelListManager: modelListManager,
                                    endpointManager: endpointManager
                                )
                                .frame(maxWidth: 400)
                            }

                            Spacer()
                        }

                        Text("This model will be used by default when creating new conversations")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                GroupBox("Personal Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Your Name:")
                                .frame(width: 120, alignment: .leading)
                            TextField("Enter your name", text: $userName)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Text("Language:")
                                .frame(width: 120, alignment: .leading)
                            Menu {
                                Button(action: { userLanguage = "" }) {
                                    Text("System Default (\(systemLanguage))")
                                        .font(.system(.caption, design: .monospaced))
                                }
                                ForEach(languageOptions, id: \.self) { language in
                                    Button(action: { userLanguage = language }) {
                                        Text(language)
                                            .font(.system(.caption, design: .monospaced))
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(userLanguage.isEmpty ? "System Default" : userLanguage)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .frame(width: 180)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(5)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                                )
                            }
                        }

                        Text("SAM will use this name to address you personally and communicate in your preferred language.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                GroupBox("Location") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("General Location:")
                                .frame(width: 120, alignment: .leading)
                            TextField("e.g., Austin, TX", text: $generalLocation)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Toggle("Use Precise Location", isOn: $usePreciseLocation)

                            if usePreciseLocation {
                                if locationManager.isFetchingLocation {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 16, height: 16)
                                } else if let preciseLocation = locationManager.preciseLocationString {
                                    Text("(\(preciseLocation))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    Button("Refresh") {
                                        locationManager.refreshLocation()
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                } else if locationManager.authorizationStatus == .denied {
                                    Text("(Access denied in System Settings)")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                } else if let error = locationManager.lastError {
                                    Text("(\(error))")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }

                        Text("General location is used for weather, local recommendations, and contextual responses. Enable precise location for more accurate results. Your location is never stored externally.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                GroupBox("Startup") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Launch at Login", isOn: $launchAtLogin)

                        Text("Automatically start SAM when you log in to your Mac.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                GroupBox("Notifications") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable Notifications", isOn: $enableNotifications)
                        Toggle("Enable Sound Effects", isOn: $enableSoundEffects)

                        HStack {
                            Text("Notification Sound:")
                                .frame(width: 120, alignment: .leading)

                            Picker("", selection: $notificationSound) {
                                Text("Basso").tag("Basso")
                                Text("Blow").tag("Blow")
                                Text("Bottle").tag("Bottle")
                                Text("Frog").tag("Frog")
                                Text("Funk").tag("Funk")
                                Text("Glass").tag("Glass")
                                Text("Hero").tag("Hero")
                                Text("Morse").tag("Morse")
                                Text("Ping").tag("Ping")
                                Text("Pop").tag("Pop")
                                Text("Purr").tag("Purr")
                                Text("Sosumi").tag("Sosumi")
                                Text("Submarine").tag("Submarine")
                                Text("Tink").tag("Tink")
                            }
                            .pickerStyle(.menu)
                            .frame(width: 150)

                            Button("Preview") {
                                if let sound = NSSound(named: notificationSound) {
                                    sound.play()
                                }
                            }
                            .buttonStyle(SAMButtonStyle(variant: .secondary))
                        }

                        Toggle("Speak Emojis", isOn: $speakEmojis)

                        Text("Configure how SAM notifies you about events and responses. When 'Speak Emojis' is off, emojis are removed from text-to-speech but remain visible in the UI.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }

                GroupBox("Git Configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Git User Name:")
                                .frame(width: 120, alignment: .leading)
                            TextField("Enter your git username", text: $gitUserName)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Text("Git User Email:")
                                .frame(width: 120, alignment: .leading)
                            TextField("Enter your git email", text: $gitUserEmail)
                                .textFieldStyle(.roundedBorder)
                        }

                        Text("Used when SAM saves code changes to version control (Git) on your behalf.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                GroupBox("Working Directory") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Base Path:")
                                .frame(width: 120, alignment: .leading)
                            TextField("Working directory base", text: $workingDirectoryBase)
                                .textFieldStyle(.roundedBorder)
                                .disabled(true)

                            Button("Choose...") {
                                showingDirectoryPicker = true
                            }
                            .help("Select a custom base directory for conversations")

                            Button("Reset") {
                                Task { @MainActor in
                                    WorkingDirectoryConfiguration.shared.resetToDefault()
                                    workingDirectoryBase = WorkingDirectoryConfiguration.shared.basePath
                                }
                            }
                            .help("Reset to default: ~/SAM")
                        }

                        Text("All conversation working directories will be created under this base path (e.g., \(workingDirectoryBase)/conversation-name/). Changing this affects new conversations only.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .fileImporter(
                    isPresented: $showingDirectoryPicker,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        let path = url.path.replacingOccurrences(of: "/Users/\(NSUserName())", with: "~")
                        Task { @MainActor in
                            WorkingDirectoryConfiguration.shared.updateBasePath(path)
                            workingDirectoryBase = WorkingDirectoryConfiguration.shared.basePath
                        }
                    case .failure(let error):
                        logger.warning("Directory picker error: \(error.localizedDescription)")
                    }
                }

                GroupBox("Workflow Settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Max Iterations:")
                                .frame(width: 120, alignment: .leading)
                            TextField("100", text: $maxIterationsText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .onChange(of: maxIterationsText) { newValue in
                                    if let value = Int(newValue), value > 0 && value <= 1000 {
                                        maxIterations = value
                                    }
                                }
                            Text("(Default: \(WorkflowConfiguration.defaultMaxIterations))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Text("Maximum number of steps SAM can take to complete a task. Higher values allow more complex tasks but may increase costs. Valid range: 1-1000.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if maxIterations != WorkflowConfiguration.defaultMaxIterations {
                            HStack {
                                Button("Reset to Default") {
                                    maxIterations = WorkflowConfiguration.defaultMaxIterations
                                    maxIterationsText = "\(WorkflowConfiguration.defaultMaxIterations)"
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Spacer()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                
                GroupBox("Development Updates") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Receive development updates", isOn: $developmentUpdatesEnabled)
                            .onChange(of: developmentUpdatesEnabled) { oldValue, newValue in
                                if newValue && !oldValue {
                                    // Enabling - show confirmation
                                    showDevelopmentConfirmation = true
                                } else if !newValue && oldValue {
                                    // Disabling - save immediately
                                    saveDevelopmentPreference(false)
                                }
                            }
                        
                        Text("Development builds are released frequently and may contain bugs, incomplete features, and breaking changes. They are intended for testing and feedback only.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .alert("Enable Development Updates?", isPresented: $showDevelopmentConfirmation) {
                    Button("Cancel", role: .cancel) {
                        developmentUpdatesEnabled = false
                    }
                    Button("Enable Development Updates") {
                        saveDevelopmentPreference(true)
                    }
                } message: {
                    Text("""
                    Development builds are released frequently and may contain:
                    • Bugs and instability
                    • Incomplete features
                    • Breaking changes
                    
                    Development updates are intended for testing and feedback.
                    Do not use development builds for critical production work.
                    """)
                }
            }
            .padding()
        }
        .onAppear {
            /// Initialize with system defaults if not set.
            if userName.isEmpty {
                userName = defaultUserName
            }
            maxIterationsText = "\(maxIterations)"
            /// Sync location settings from LocationManager
            generalLocation = locationManager.generalLocation
            usePreciseLocation = locationManager.usePreciseLocation
            /// Initialize ModelListManager with dependencies
            modelListManager.initialize(endpointManager: endpointManager)
        }
        .onChange(of: generalLocation) { _, newValue in
            locationManager.generalLocation = newValue
        }
        .onChange(of: usePreciseLocation) { _, newValue in
            locationManager.usePreciseLocation = newValue
        }
    }

    private var systemLanguage: String {
        let locale = Locale.current
        let languageCode = locale.language.languageCode?.identifier ?? "en"
        return getLanguageName(for: languageCode)
    }

    private var defaultUserName: String {
        let fullName = ProcessInfo.processInfo.fullUserName
        if !fullName.isEmpty {
            /// Extract first name from full name.
            let components = fullName.components(separatedBy: " ")
            return components.first ?? fullName
        }
        return ""
    }

    private func getLanguageName(for code: String) -> String {
        switch code {
        case "en": return "English"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        case "ru": return "Russian"
        case "zh": return "Chinese"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "ar": return "Arabic"
        case "hi": return "Hindi"
        case "nl": return "Dutch"
        case "sv": return "Swedish"
        case "da": return "Danish"
        case "no": return "Norwegian"
        case "fi": return "Finnish"
        case "pl": return "Polish"
        case "tr": return "Turkish"
        case "th": return "Thai"
        case "vi": return "Vietnamese"
        default: return "English"
        }
    }
    
    private func saveDevelopmentPreference(_ enabled: Bool) {
        developmentUpdatesEnabled = enabled
        // Post notification to AppDelegate to switch feed URL
        NotificationCenter.default.post(
            name: NSNotification.Name("developmentUpdatesPreferenceChanged"),
            object: nil
        )
    }

    /// Load available models similar to ChatWidget so General preferences show the full model list
}

// MARK: - Appearance Preferences

struct AppearancePreferencesView: View {
    @AppStorage("enableAnimations") private var enableAnimations: Bool = true
    /// DEPRECATED: showThinkingSteps - now per-conversation via Reasoning toggle.

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Interface") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable Animations", isOn: $enableAnimations)
                        /// DEPRECATED: "Show Detailed Thinking Steps" - now controlled per-conversation via Reasoning toggle in chat.

                        Text("Control visual effects. Thinking steps are now controlled per-conversation via the Reasoning toggle in chat.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
            }
            .padding()
        }
    }
}

// MARK: - Conversation Preferences

struct ConversationPreferencesView: View {
    @EnvironmentObject private var conversationManager: ConversationManager
    @EnvironmentObject private var folderManager: FolderManager
    @AppStorage("maxConversationHistory") private var maxConversationHistory: Int = 100
    @AppStorage("autoSaveInterval") private var autoSaveInterval: Double = 5.0

    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportError: String?
    @State private var importError: String?
    @State private var showingImportResult = false
    @State private var importResult: BulkImportResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Chat Behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Max Conversation History:")
                            TextField("Count", value: $maxConversationHistory, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Text("messages")
                        }

                        HStack {
                            Text("Auto-save Interval:")
                            Slider(value: $autoSaveInterval, in: 1...30, step: 1) {
                                Text("Auto-save")
                            } minimumValueLabel: {
                                Text("1m")
                            } maximumValueLabel: {
                                Text("30m")
                            }
                            Text("\(Int(autoSaveInterval))m")
                                .frame(width: 30)
                        }

                        Text("Configure conversation behavior and data retention.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                GroupBox("Import & Export") {
                    VStack(alignment: .leading, spacing: 16) {
                        /// Export section
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Export Conversations")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Text("Export all conversations to a single file for backup or transfer. Memory data is included automatically.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                Button(action: exportAllConversations) {
                                    HStack {
                                        if isExporting {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                        }
                                        Text("Export All (\(conversationManager.conversations.count))")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isExporting || conversationManager.conversations.isEmpty)

                                if let error = exportError {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }
                        }

                        Divider()

                        /// Import section
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Import Conversations")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Text("Import conversations from a SAM export file. Supports single and bulk exports.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                Button(action: importConversations) {
                                    HStack {
                                        if isImporting {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                        }
                                        Text("Import from File...")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(isImporting)

                                if let error = importError {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }

                            if let result = importResult {
                                HStack {
                                    Image(systemName: result.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundColor(result.failedCount == 0 ? .green : .orange)
                                    Text("\(result.successCount) imported, \(result.failedCount) failed, \(result.skippedCount) skipped")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Divider()

                        /// Info section
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Export Format")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("SAM exports use JSON format and include all conversation metadata, messages, settings, and memory data. Files can be imported back into SAM or processed by other tools.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
            .padding()
        }
    }

    private func exportAllConversations() {
        isExporting = true
        exportError = nil

        Task {
            do {
                let importExportService = ConversationImportExportService(
                    conversationManager: conversationManager,
                    memoryManager: conversationManager.memoryManager,
                    folderManager: folderManager
                )

                let filename = importExportService.generateBulkExportFilename(count: conversationManager.conversations.count)

                let panel = await MainActor.run {
                    let savePanel = NSSavePanel()
                    savePanel.allowedContentTypes = [.json]
                    savePanel.nameFieldStringValue = filename
                    savePanel.message = "Export all conversations"
                    savePanel.title = "Export SAM Conversations"
                    return savePanel
                }

                let result = await panel.begin()

                if result == .OK, let url = panel.url {
                    try await importExportService.exportConversations(
                        conversationManager.conversations,
                        to: url,
                        includeMemory: true
                    )

                    await MainActor.run {
                        isExporting = false
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    }
                } else {
                    await MainActor.run {
                        isExporting = false
                    }
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportError = error.localizedDescription
                }
            }
        }
    }

    private func importConversations() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a SAM conversation export file"
        panel.title = "Import Conversations"

        panel.begin { result in
            if result == .OK, let url = panel.url {
                performImport(from: url)
            }
        }
    }

    private func performImport(from url: URL) {
        isImporting = true
        importError = nil
        importResult = nil

        Task {
            do {
                let importExportService = ConversationImportExportService(
                    conversationManager: conversationManager,
                    memoryManager: conversationManager.memoryManager,
                    folderManager: folderManager
                )

                let result = try await importExportService.importFromFile(
                    url,
                    conflictResolution: .createNew,
                    importMemory: true
                )

                await MainActor.run {
                    isImporting = false
                    importResult = result
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    importError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - API Server Preferences

struct APIServerPreferencesView: View {
    @EnvironmentObject private var apiServer: SAMAPIServer

    @AppStorage("enableAPIServer") private var enableAPIServer: Bool = true
    @AppStorage("apiServerPort") private var apiServerPort: Int = 8080
    @AppStorage("apiServerAllowRemoteAccess") private var allowRemoteAccess: Bool = false
    @AppStorage("serverProxyMode") private var serverProxyMode: Bool = false
    @AppStorage("apiServerRequireAuth") private var apiServerRequireAuth: Bool = false
    @AppStorage("samAPIServerKey") private var apiServerKey: String = ""
    @AppStorage("apiCreateSeparateConversations") private var apiCreateSeparateConversations: Bool = true
    @AppStorage("apiHideConversationsFromUI") private var apiHideConversationsFromUI: Bool = true

    @State private var showingKeyGenerator = false

    /// Computed server status based on actual apiServer.isRunning state.
    private var serverStatus: ServerStatus {
        return apiServer.isRunning ? .running : .stopped
    }

    enum ServerStatus {
        case unknown, running, stopped, error

        var text: String {
            switch self {
            case .unknown: return "Unknown"
            case .running: return "Running"
            case .stopped: return "Stopped"
            case .error: return "Error"
            }
        }

        var color: Color {
            switch self {
            case .unknown: return .gray
            case .running: return .green
            case .stopped: return .orange
            case .error: return .red
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Server Configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Enable API Server", isOn: $enableAPIServer)
                            .onChange(of: enableAPIServer) { oldValue, newValue in
                                Task { @MainActor in
                                    if newValue {
                                        do {
                                            try await apiServer.startServer()
                                        } catch {
                                            // Revert toggle on error
                                            enableAPIServer = false
                                            let alert = NSAlert()
                                            alert.messageText = "Failed to Start API Server"
                                            alert.informativeText = error.localizedDescription
                                            alert.alertStyle = .warning
                                            alert.runModal()
                                        }
                                    } else {
                                        await apiServer.stopServer()
                                    }
                                }
                            }

                        HStack {
                            Text("Port:")
                            TextField("Port", value: $apiServerPort, formatter: {
                                let formatter = NumberFormatter()
                                formatter.usesGroupingSeparator = false
                                return formatter
                            }())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .disabled(!enableAPIServer)
                                .onChange(of: apiServerPort) { oldValue, newValue in
                                    /// Restart server with new port if it's currently running.
                                    if enableAPIServer && apiServer.isRunning {
                                        Task { @MainActor in
                                            await apiServer.stopServer()
                                            try? await apiServer.startServer(port: newValue)
                                        }
                                    }
                                }

                            Spacer()

                            /// Server Status Indicator (now updates in real-time).
                            HStack {
                                Circle()
                                    .fill(serverStatus.color)
                                    .frame(width: 8, height: 8)
                                Text(serverStatus.text)
                                    .font(.caption)
                                    .foregroundColor(serverStatus.color)
                            }
                        }

                        Toggle("Allow Remote Access", isOn: $allowRemoteAccess)
                            .disabled(!enableAPIServer)
                            .onChange(of: allowRemoteAccess) { oldValue, newValue in
                                /// Restart server with new binding if it's currently running.
                                if enableAPIServer && apiServer.isRunning {
                                    Task { @MainActor in
                                        await apiServer.stopServer()
                                        try? await apiServer.startServer()
                                    }
                                }
                            }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Network Access:")
                                .font(.caption)
                                .fontWeight(.medium)
                            if allowRemoteAccess {
                                Text("WARNING: Server accessible from ANY network interface (0.0.0.0:\(String(apiServerPort)))")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                Text("• Use with caution - exposes API to local network")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Server only accessible from this machine (127.0.0.1:\(String(apiServerPort)))")
                                    .font(.caption)
                                    .foregroundColor(.green)
                                Text("• Recommended for security - localhost only")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)

                        Toggle("Proxy Mode", isOn: $serverProxyMode)
                            .disabled(!enableAPIServer)

                        if serverProxyMode {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Proxy Mode Enabled:")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.orange)
                                Text("• Requests forwarded directly to LLM endpoint (1:1 passthrough)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("• NO SAM system prompts, NO MCP tools, NO additional processing")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("• External tool parameters preserved unchanged")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("• Use for tools like Aider that expect pure LLM API")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Normal Mode (Proxy Mode Disabled):")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("• Full SAM functionality (system prompts, MCP tools, memory)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("• Intelligent processing and tool execution")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                GroupBox("API Conversation Behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Create Separate Conversations for API Requests", isOn: $apiCreateSeparateConversations)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Session Management:")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("• When enabled: Each API request creates a new conversation")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("• When disabled: API requests reuse existing conversation")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("• Session ID support: Same session_id/context_id always reuses conversation")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        Toggle("Hide API Conversations from UI", isOn: $apiHideConversationsFromUI)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("UI Visibility:")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("• When enabled: API conversations won't appear in sidebar (Recommended)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("• When disabled: API conversations visible in conversation list")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("• Keeps your UI clean when using SAM with external tools")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Text("Control how API requests create and manage conversations. Session IDs always override this setting for tool integration.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }

                GroupBox("API Authentication") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("API Token")
                            .font(.headline)
                        
                        Text("All external API requests must include this token for authentication.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            if let token = UserDefaults.standard.string(forKey: "samAPIToken"), !token.isEmpty {
                                SecureField("Token", text: .constant(token))
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(true)
                                    .textSelection(.enabled)
                                
                                Button(action: {
                                    if let token = UserDefaults.standard.string(forKey: "samAPIToken"), !token.isEmpty {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(token, forType: .string)
                                    }
                                }) {
                                    Image(systemName: "doc.on.doc")
                                }
                                .help("Copy token to clipboard")
                                .buttonStyle(.borderless)
                                
                                Button(action: {
                                    regenerateAPIToken()
                                }) {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .help("Generate new token")
                                .buttonStyle(.borderless)
                                .alert("Regenerate API Token?", isPresented: $showRegenerateConfirmation) {
                                    Button("Cancel", role: .cancel) { }
                                    Button("Regenerate", role: .destructive) {
                                        performTokenRegeneration()
                                    }
                                } message: {
                                    Text("This will invalidate the current token. All external API clients will need to update to the new token.")
                                }
                            } else {
                                Text("Error: Token not found")
                                    .foregroundColor(.red)
                            }
                        }
                        
                        Text("Include in API requests: Authorization: Bearer YOUR-TOKEN")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                        
                        if allowRemoteAccess {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("WARNING: Remote access is enabled. Anyone on your network with this token can access the API.")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            .padding(.top, 8)
                            .padding(8)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                GroupBox("Testing & Examples") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Test Endpoints:")
                            .font(.caption)
                            .fontWeight(.medium)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Health Check:")
                                .font(.caption2)
                                .fontWeight(.medium)
                            Text("curl http://localhost:\(apiServerPort)/health")
                                .font(.system(.caption2, design: .monospaced))
                                .padding(4)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(4)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("List Models:")
                                .font(.caption2)
                                .fontWeight(.medium)
                            Text("curl http://localhost:\(apiServerPort)/v1/models")
                                .font(.system(.caption2, design: .monospaced))
                                .padding(4)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(4)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Chat Completion:")
                                .font(.caption2)
                                .fontWeight(.medium)
                            Text("""
curl -X POST http:
  -H "Content-Type: application/json" \\
  -d '{"model": "sam-assistant", "messages": [{"role": "user", "content": "Hello"}]}'
""")
                                .font(.system(.caption2, design: .monospaced))
                                .padding(4)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(4)
                        }

                        Text("Copy these commands to test the API in Terminal.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
            }
            .padding()
        }
    }

    @State private var showRegenerateConfirmation = false
    
    private func regenerateAPIToken() {
        showRegenerateConfirmation = true
    }
    
    private func performTokenRegeneration() {
        // Generate new secure token
        let newToken = "\(UUID().uuidString)-\(UUID().uuidString)"
        
        // Store in UserDefaults
        UserDefaults.standard.set(newToken, forKey: "samAPIToken")
        UserDefaults.standard.synchronize()
        
        // Show success notification
        let notification = NSUserNotification()
        notification.title = "API Token Regenerated"
        notification.informativeText = "Your API token has been updated. External API clients will need the new token."
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func generateAPIKey() {
        let characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        let length = 32
        apiServerKey = String((0..<length).compactMap { _ in
            characters.randomElement()
        })
    }
}

// MARK: - Advanced Preferences

struct AdvancedPreferencesView: View {
    @AppStorage("logLevel") private var logLevel: String = "Info"
    @AppStorage("authorizationExpiryDuration") private var authorizationExpiryDuration: String = "5m"
    @AppStorage("imageGenerationDisableSafety") private var imageGenerationDisableSafety: Bool = false

    @State private var validationError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Debugging") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Log Level:")
                                .frame(width: 120, alignment: .leading)
                            Menu {
                                Button(action: {
                                    logLevel = "Error"
                                    configureLogLevel("Error")
                                }) {
                                    Text("Error")
                                        .font(.system(.caption, design: .monospaced))
                                }
                                Button(action: {
                                    logLevel = "Warning"
                                    configureLogLevel("Warning")
                                }) {
                                    Text("Warning")
                                        .font(.system(.caption, design: .monospaced))
                                }
                                Button(action: {
                                    logLevel = "Info"
                                    configureLogLevel("Info")
                                }) {
                                    Text("Info")
                                        .font(.system(.caption, design: .monospaced))
                                }
                                Button(action: {
                                    logLevel = "Debug"
                                    configureLogLevel("Debug")
                                }) {
                                    Text("Debug")
                                        .font(.system(.caption, design: .monospaced))
                                }
                            } label: {
                                HStack {
                                    Text(logLevel)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .frame(width: 100)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(5)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                                )
                            }
                        }

                        Text("Configure logging level. Changes take effect immediately.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                GroupBox("Authorization") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Authorization Expiry:")
                                .frame(width: 120, alignment: .leading)

                            TextField("Duration", text: $authorizationExpiryDuration)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .onChange(of: authorizationExpiryDuration) { _, newValue in
                                    validateDuration(newValue)
                                }

                            Text("(e.g., 5m, 300s, 1h)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let error = validationError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }

                        Text("""
                            How long user-granted authorizations remain valid.
                            Formats: s (seconds), m (minutes), h (hours).
                            Examples: 30s, 5m, 1h, 90m
                            """)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                // NSFW settings moved to Image Generation → Settings for consolidated control

                GroupBox("Reset") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("Reset to Defaults") {
                            resetToDefaults()
                        }
                        .foregroundColor(.red)

                        Text("Reset all preferences to their default values.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
            .padding()
        }
    }

    private func validateDuration(_ duration: String) {
        /// Parse duration format (e.g., "5m", "300s", "1h").
        guard !duration.isEmpty else {
            validationError = nil
            return
        }

        let pattern = "^([0-9]+)([smh])$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: duration, options: [], range: NSRange(duration.startIndex..., in: duration)),
              match.numberOfRanges == 3 else {
            validationError = "Invalid format. Use: 30s, 5m, or 1h"
            return
        }

        let numberRange = Range(match.range(at: 1), in: duration)!
        let number = Int(duration[numberRange])!

        let unitRange = Range(match.range(at: 2), in: duration)!
        let unit = String(duration[unitRange])

        /// Calculate seconds.
        let seconds: Int
        switch unit {
        case "s":
            seconds = number

        case "m":
            seconds = number * 60

        case "h":
            seconds = number * 3600

        default:
            validationError = "Unknown unit. Use s, m, or h"
            return
        }

        /// Validate range (30 seconds to 24 hours).
        if seconds < 30 {
            validationError = "Minimum: 30s"
        } else if seconds > 86400 {
            validationError = "Maximum: 24h"
        } else {
            validationError = nil
        }
    }

    private func configureLogLevel(_ levelString: String) {
        /// Convert string to Logger.Level.
        let logLevel: Logger.Level
        switch levelString {
        case "Error":
            logLevel = .error

        case "Warning":
            logLevel = .warning

        case "Info":
            logLevel = .info

        case "Debug":
            logLevel = .debug

        default:
            logLevel = .info
        }

        /// Update DynamicLogHandler's shared log level This immediately affects all existing loggers.
        DynamicLogHandler.currentLogLevel = logLevel

        logger.info("Log level changed to: \(levelString) (takes effect immediately)")
    }

    private func resetToDefaults() {
        /// Reset UserDefaults to default values.
        UserDefaults.standard.removeObject(forKey: "launchAtLogin")
        UserDefaults.standard.removeObject(forKey: "enableNotifications")
        UserDefaults.standard.removeObject(forKey: "enableSoundEffects")
        UserDefaults.standard.removeObject(forKey: "messageSpacing")
        UserDefaults.standard.removeObject(forKey: "enableAnimations")
        UserDefaults.standard.removeObject(forKey: "maxConversationHistory")
        UserDefaults.standard.removeObject(forKey: "autoSaveInterval")
        UserDefaults.standard.removeObject(forKey: "logLevel")
        UserDefaults.standard.removeObject(forKey: "authorizationExpiryDuration")
        UserDefaults.standard.removeObject(forKey: "imageGenerationDisableSafety")
    }
}

// MARK: - System Prompt Preferences

struct SystemPromptPreferencesView: View {
    @ObservedObject private var promptManager = SystemPromptManager.shared
    @State private var showingEditor = false
    @State private var editingConfiguration: SystemPromptConfiguration?
    @State private var showingDeleteConfirmation = false

    private var selectedConfiguration: SystemPromptConfiguration? {
        guard let selectedId = promptManager.selectedConfigurationId else { return nil }
        return promptManager.allConfigurations.first { $0.id == selectedId }
    }

    private var isDefaultConfigurationSelected: Bool {
        guard let selectedId = promptManager.selectedConfigurationId else { return false }
        /// Check if selected ID matches any default configuration.
        return SystemPromptConfiguration.defaultConfigurations().contains(where: { $0.id == selectedId })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            /// Header.
            HStack {
                VStack(alignment: .leading) {
                    Text("System Prompts")
                        .font(.headline)
                    Text("Click to select, right-click for options. Selected prompt is used for new conversations.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("New Template") {
                    editingConfiguration = nil
                    showingEditor = true
                }
                .buttonStyle(.borderedProminent)
            }

            /// Default Prompt Selector
            HStack {
                Text("Default for New Conversations:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                PromptPickerView(
                    selectedPromptIdString: $promptManager.defaultSystemPromptId,
                    prompts: promptManager.allConfigurations
                )

                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.blue.opacity(0.05))
            .cornerRadius(6)

            /// Toolbar.
            if let selected = selectedConfiguration {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selected: \(selected.name)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("\(selected.components.count) components, \(selected.components.filter(\.isEnabled).count) active")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Edit") {
                        editingConfiguration = selected
                        showingEditor = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Delete") {
                        /// Prevent deletion of default configurations (like SAM Default).
                        if !isDefaultConfigurationSelected {
                            showingDeleteConfirmation = true
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(.red)
                    .disabled(isDefaultConfigurationSelected)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(6)
            }

            /// Configuration Management.
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(promptManager.allConfigurations, id: \.id) { configuration in
                        let isDefault = SystemPromptConfiguration.defaultConfigurations().contains(where: { $0.id == configuration.id })

                        SystemPromptConfigurationRow(
                            configuration: configuration,
                            isSelected: configuration.id == promptManager.selectedConfigurationId,
                            onSelect: {
                                promptManager.selectConfiguration(configuration)
                            },
                            onEdit: {
                                if !isDefault {
                                    editingConfiguration = configuration
                                    showingEditor = true
                                }
                            },
                            onDelete: {
                                /// Only allow deleting user configurations (not defaults).
                                if !isDefault {
                                    promptManager.removeConfiguration(configuration)
                                }
                            }
                        )
                    }
                }
                .padding(.vertical, 8)
            }

            /// Info section.
            GroupBox("System Prompt Management") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("• Create custom system prompts with editable components")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("• Enable/disable components to customize behavior")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("• Selected prompt is used as default for new conversations")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("• Each conversation can override the system prompt individually")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .padding()
        .sheet(isPresented: $showingEditor) {
            SystemPromptConfigurationEditor(
                configuration: editingConfiguration,
                promptManager: promptManager,
                isPresented: $showingEditor
            )
        }
        .alert("Delete System Prompt", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let selected = selectedConfiguration {
                    promptManager.removeConfiguration(selected)
                }
            }
        } message: {
            if let selected = selectedConfiguration {
                Text("Are you sure you want to delete '\(selected.name)'? This action cannot be undone.")
            }
        }
    }
}

#Preview {
    PreferencesView()
}

// MARK: - Personality Preferences

struct PersonalityPreferencesPane: View {
    @ObservedObject private var personalityManager = PersonalityManager.shared
    @State private var showingEditor = false
    @State private var editingPersonality: Personality?
    @State private var showingDeleteConfirmation = false

    private var selectedPersonality: Personality? {
        guard let selectedId = personalityManager.selectedPersonalityId else { return nil }
        return personalityManager.allPersonalities.first { $0.id == selectedId }
    }

    private var isDefaultPersonalitySelected: Bool {
        guard let selectedId = personalityManager.selectedPersonalityId else { return false }
        return Personality.defaultPersonalities().contains(where: { $0.id == selectedId })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            /// Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Personalities")
                        .font(.headline)
                    Text("Click to select, right-click for options. Personalities modify SAM's tone and behavior.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("New Personality") {
                    editingPersonality = nil
                    showingEditor = true
                }
                .buttonStyle(.borderedProminent)
            }

            /// Default Personality Selector
            HStack {
                Text("Default for New Conversations:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                PersonalityPickerView(
                    selectedPersonalityId: Binding(
                        get: {
                            UUID(uuidString: personalityManager.defaultPersonalityId)
                        },
                        set: { newValue in
                            if let newValue = newValue {
                                personalityManager.defaultPersonalityId = newValue.uuidString
                            }
                        }
                    )
                )

                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.pink.opacity(0.05))
            .cornerRadius(6)

            /// Toolbar
            if let selected = selectedPersonality {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Selected: \(selected.name)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("\(selected.selectedTraits.count) traits\(selected.customInstructions.isEmpty ? "" : ", custom instructions")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Edit") {
                        editingPersonality = selected
                        showingEditor = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Delete") {
                        if !isDefaultPersonalitySelected {
                            showingDeleteConfirmation = true
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(.red)
                    .disabled(isDefaultPersonalitySelected)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(6)
            }

            /// Personality List
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(personalityManager.allPersonalities, id: \.id) { personality in
                        let isDefault = Personality.defaultPersonalities().contains(where: { $0.id == personality.id })

                        PersonalityRow(
                            personality: personality,
                            isSelected: personality.id == personalityManager.selectedPersonalityId,
                            onSelect: {
                                personalityManager.selectPersonality(personality)
                            },
                            onEdit: {
                                editingPersonality = personality
                                showingEditor = true
                            },
                            onDelete: {
                                if !isDefault {
                                    personalityManager.deletePersonality(personality)
                                }
                            }
                        )
                    }
                }
                .padding(.vertical, 8)
            }

            /// Info section
            GroupBox("Personality Management") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("• Built-in personalities can be edited (creates an editable copy)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("• Select traits from 5 categories to define personality")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("• Add custom instructions for additional fine-tuning")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("• Personalities merge into system prompt at runtime (don't modify stored prompts)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .padding()
        .sheet(isPresented: $showingEditor) {
            PersonalityEditor(
                personality: editingPersonality,
                personalityManager: personalityManager,
                isPresented: $showingEditor
            )
        }
        .alert("Delete Personality", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let selected = selectedPersonality {
                    personalityManager.deletePersonality(selected)
                }
            }
        } message: {
            if let selected = selectedPersonality {
                Text("Are you sure you want to delete '\(selected.name)'? This action cannot be undone.")
            }
        }
    }
}
