// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import ConversationEngine
import APIFramework
import MCPFramework
import ConfigurationSystem
import SharedData
import Logging
import UniformTypeIdentifiers

// MARK: - Conversation Row Content with Hover States

private struct ConversationRowContent: View {
    let conversation: ConversationModel
    let isActive: Bool
    @State private var isHovered = false
    @EnvironmentObject private var conversationManager: ConversationManager

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)

                if let lastMessage = conversation.messages.last {
                    Text(lastMessage.content)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            /// Pin icon (visible when hovered or pinned).
            if conversation.isPinned || isHovered {
                Button(action: {
                    conversation.isPinned.toggle()
                    conversationManager.saveConversations()

                    /// Trigger SwiftUI to re-sort conversations SwiftUI doesn't automatically detect changes to properties within array items Force recomputation of sortedConversations by notifying conversationManager.
                    conversationManager.objectWillChange.send()
                }) {
                    Image(systemName: conversation.isPinned ? "pin.fill" : "pin")
                        .foregroundColor(conversation.isPinned ? (isActive ? .white : .accentColor) : (isActive ? .white.opacity(0.7) : .secondary))
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help(conversation.isPinned ? "Unpin conversation" : "Pin conversation")
            }

            if isActive {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
            }
        }
        .padding()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }

    private var backgroundColor: Color {
        if isActive {
            return Color.accentColor.opacity(0.15)
        } else if isHovered {
            return Color.primary.opacity(0.05)
        } else {
            return Color.clear
        }
    }
}

public struct MainWindowView: View {
    @EnvironmentObject private var conversationManager: ConversationManager
    @EnvironmentObject private var endpointManager: EndpointManager
    @StateObject private var folderManager = FolderManager()
    @State private var showingPreferences = false
    @State private var showingHelp = false
    @State private var showingAPIReference = false
    @AppStorage("showingSidebar") private var showingSidebar: Bool = false
    @AppStorage("showingMiniPrompts") private var showingMiniPrompts: Bool = false
    @State private var showingRenameDialog = false
    @State private var conversationToRename: ConversationModel?
    @State private var newConversationName = ""
    @State private var showingDeleteConfirmation = false
    @State private var conversationToDelete: ConversationModel?
    @State private var showingDeleteAllConfirmation = false
    @State private var showingWorkingDirectoryDeleteConfirmation = false
    @State private var workingDirectoryToDelete: String?
    @State private var showingGlobalSearch = false
    @State private var selectedMessageId: UUID?
    @State private var conversationToExport: ConversationModel?
    @AppStorage("hasSeenWelcomeScreen") private var hasSeenWelcomeScreen: Bool = false
    @State private var showingWelcomeScreen: Bool = false
    @State private var showingWhatsNew: Bool = false
    @State private var showingOnboardingWizard: Bool = false
    @State private var selectedConversations: Set<UUID> = []
    @State private var showingDeleteSelectedConfirmation = false
    @State private var showingFolderCreation = false
    @State private var newFolderName = ""
    @State private var showingFolderDeletion = false
    @State private var folderToDelete: Folder?

    // Convert to Shared Topic state
    @State private var showingConvertToTopicDialog = false
    @State private var conversationToConvert: ConversationModel?
    @State private var newTopicName = ""
    @State private var newTopicDescription = ""

    // Import/Export state
    @State private var showingImportDialog = false
    @State private var showingBulkExportDialog = false
    @State private var importResult: BulkImportResult?
    @State private var showingImportResultDialog = false
    @State private var isImporting = false
    @State private var importError: String?

    // Conversation filter state
    @State private var conversationFilterText: String = ""

    // Uncategorized section collapsed state
    @AppStorage("uncategorizedCollapsed") private var uncategorizedCollapsed: Bool = false

    private let logger = Logger(label: "com.syntheticautonomicmind.sam.MainWindow")

    public init() {}

    // MARK: - Computed Properties

    /// Pinned conversations (newest first by creation date).
    private var pinnedConversations: [ConversationModel] {
        conversationManager.conversations
            .filter { $0.isPinned }
            .sorted { $0.created > $1.created }
    }

    /// Unpinned conversations (newest first by creation date).
    private var unpinnedConversations: [ConversationModel] {
        conversationManager.conversations
            .filter { !$0.isPinned }
            .sorted { $0.created > $1.created }
    }

    /// All conversations with pinned first, then unpinned (both newest first).
    private var sortedConversations: [ConversationModel] {
        return pinnedConversations + unpinnedConversations
    }

    /// Filtered conversations based on search text.
    private var filteredConversations: [ConversationModel] {
        if conversationFilterText.isEmpty {
            return sortedConversations
        }
        return sortedConversations.filter { conv in
            conv.title.localizedCaseInsensitiveContains(conversationFilterText) ||
            conv.messages.contains { msg in
                msg.content.localizedCaseInsensitiveContains(conversationFilterText)
            }
        }
    }

    // MARK: - Welcome Screen

    private var welcomeScreen: some View {
        SAMEmptyStateView(
            icon: "bubble.left.and.bubble.right",
            title: "Welcome to SAM",
            description: "Your intelligent AI assistant is ready to help. Start a conversation by asking a question, requesting assistance, or exploring what SAM can do for you.",
            actionTitle: "Start New Conversation",
            action: {
                conversationManager.createNewConversation()
            }
        )
        .padding(.horizontal, 40)
    }
    
    // MARK: - Onboarding Wizard Content
    
    private var onboardingWizardContent: some View {
        OnboardingWizardView(isPresented: $showingOnboardingWizard)
            .environmentObject(endpointManager)
            .environmentObject(conversationManager)
    }

    public var body: some View {
        HSplitView {
            /// Sidebar (collapsible).
            if showingSidebar {
                VStack {
                    /// Conversation list header.
                    HStack {
                        Text("Conversations")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Spacer()

                        Button(action: {
                            conversationManager.createNewConversation()
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(showingOnboardingWizard ? .secondary : .accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("New Conversation (N)")
                        .disabled(showingOnboardingWizard)
                    }
                    .padding()

                    /// Filter text field
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Filter conversations...", text: $conversationFilterText)
                            .textFieldStyle(.plain)
                        if !conversationFilterText.isEmpty {
                            Button(action: { conversationFilterText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                    /// Conversation list.
                    conversationListView

                    Spacer()
                }
                .frame(minWidth: 250, idealWidth: 280, maxWidth: 350)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            }

            /// Main content with sidebar toggle and conversation switching.
            VStack(spacing: 0) {
                /// Toolbar with sidebar toggle and mini-prompts toggle.
                HStack {
                    Button(action: {
                        withAnimation {
                            showingSidebar.toggle()
                        }
                    }) {
                        Image(systemName: "sidebar.left")
                            .foregroundColor(showingSidebar ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Sidebar")

                    /// New Conversation button - only visible when sidebar is hidden
                    if !showingSidebar {
                        Button(action: {
                            conversationManager.createNewConversation()
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(showingOnboardingWizard ? .secondary : .accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("New Conversation (N)")
                        .disabled(showingOnboardingWizard)
                    }

                    Spacer()

                    Button(action: {
                        withAnimation {
                            showingMiniPrompts.toggle()
                        }
                    }) {
                        Image(systemName: "text.badge.plus")
                            .foregroundColor(showingMiniPrompts ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Mini-Prompts: Show or hide prompt suggestions for this conversation")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                /// Main content: Onboarding wizard, Welcome screen, or ChatWidget.
                if showingOnboardingWizard {
                    /// Onboarding wizard when no models or providers configured (not skippable)
                    onboardingWizardContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if conversationManager.conversations.isEmpty {
                    /// Welcome screen when no conversations exist.
                    welcomeScreen
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let activeConv = conversationManager.activeConversation,
                          let messageBus = activeConv.messageBus {
                    /// ChatWidget with conversation switching support.
                    /// Pass MessageBus as @ObservedObject for direct observation of message changes
                    ChatWidget(activeConversation: activeConv, messageBus: messageBus, showingMiniPrompts: $showingMiniPrompts)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id("chatWidget-\(activeConv.id.uuidString)")
                        .environmentObject(conversationManager)
                }
            }

            /// Mini-prompts panel (collapsible).
            if showingMiniPrompts, let activeConversation = conversationManager.activeConversation {
                MiniPromptPanel(conversation: activeConversation, conversationManager: conversationManager)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            /// Global search overlay (Cmd+F).
            if showingGlobalSearch {
                GlobalSearchView(isPresented: $showingGlobalSearch) { conversationId, messageId in
                    self.handleSearchResultSelection(conversationId: conversationId, messageId: messageId)
                }
                .environmentObject(conversationManager)
            }
        }
        .sheet(isPresented: $showingPreferences) {
            PreferencesView()
                .environmentObject(endpointManager)
                .environmentObject(folderManager)
        }
        .sheet(isPresented: $showingHelp) {
            HelpView()
        }
        .sheet(isPresented: $showingAPIReference) {
            APIReferenceView()
        }
        .sheet(isPresented: $showingWelcomeScreen) {
            WelcomeView(isPresented: $showingWelcomeScreen)
                .environmentObject(endpointManager)
                .environmentObject(conversationManager)
        }
        .sheet(isPresented: $showingWhatsNew) {
            WhatsNewView(isPresented: $showingWhatsNew)
        }
        .sheet(isPresented: $showingRenameDialog) {
            renameConversationDialog
        }
        .sheet(isPresented: $showingFolderCreation) {
            topicCreationDialog
        }
        .sheet(isPresented: $showingConvertToTopicDialog) {
            convertToTopicDialog
        }
        .sheet(isPresented: $showingImportDialog) {
            importConversationDialog
        }
        .sheet(isPresented: $showingImportResultDialog) {
            importResultDialog
        }
        .sheet(item: $conversationToExport) { conversation in
            ExportDialog(conversation: conversation, isPresented: Binding(
                get: { conversationToExport != nil },
                set: { if !$0 { conversationToExport = nil } }
            ))
        }
        .confirmationDialog("Delete Conversation", isPresented: $showingDeleteConfirmation, presenting: conversationToDelete) { conversation in
            Button("Delete", role: .destructive) {
                if conversationManager.activeConversation?.id == conversation.id {
                    /// Clear the active conversation if it's the one being deleted.
                    conversationManager.activeConversation = conversationManager.conversations.first { $0.id != conversation.id }
                }

                /// Delete conversation and check working directory status.
                let result = conversationManager.deleteConversation(conversation)

                /// If working directory is not empty, prompt user.
                if !result.isEmpty && !result.deleted {
                    workingDirectoryToDelete = result.workingDirectoryPath
                    showingWorkingDirectoryDeleteConfirmation = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { conversation in
            Text("Are you sure you want to delete '\(conversation.title)'? This action cannot be undone.")
        }
        .confirmationDialog("Delete Working Directory", isPresented: $showingWorkingDirectoryDeleteConfirmation, presenting: workingDirectoryToDelete) { path in
            Button("Delete Files", role: .destructive) {
                _ = conversationManager.forceDeleteWorkingDirectory(path: path)
                workingDirectoryToDelete = nil
            }
            Button("Keep Files", role: .cancel) {
                workingDirectoryToDelete = nil
            }
        } message: { path in
            Text("The conversation's working directory at '\(path)' contains files. Do you want to delete these files?")
        }
        .confirmationDialog("Delete All Conversations", isPresented: $showingDeleteAllConfirmation) {
            Button("Delete", role: .destructive) {
                /// Delete conversations but keep directories.
                conversationManager.deleteAllConversations(deleteDirectories: false)

                /// After deletion, activate first remaining conversation or create new one
                if let firstConversation = conversationManager.conversations.first {
                    conversationManager.activeConversation = firstConversation
                } else {
                    conversationManager.createNewConversation()
                }
            }

            let info = conversationManager.getDeleteAllConversationsInfo()
            if info.withDirectories > 0 {
                Button("Delete + Files (\(info.withDirectories))", role: .destructive) {
                    /// Delete conversations and their directories.
                    conversationManager.deleteAllConversations(deleteDirectories: true)

                    /// After deletion, activate first remaining conversation or create new one
                    if let firstConversation = conversationManager.conversations.first {
                        conversationManager.activeConversation = firstConversation
                    } else {
                        conversationManager.createNewConversation()
                    }
                }
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            let info = conversationManager.getDeleteAllConversationsInfo()
            return Text(deleteAllMessage(info: info))
        }
        .confirmationDialog("Delete Selected Conversations", isPresented: $showingDeleteSelectedConfirmation) {
            Button("Delete", role: .destructive) {
                deleteSelectedConversations(deleteDirectories: false)
            }

            let info = getSelectedConversationsInfo()
            if info.withDirectories > 0 {
                Button("Delete + Files (\(info.withDirectories))", role: .destructive) {
                    deleteSelectedConversations(deleteDirectories: true)
                }
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            let info = getSelectedConversationsInfo()
            return Text(deleteSelectedMessage(info: info))
        }
        .onAppear {
            logger.debug("Main window view initialized")
            logger.debug("Main window structure loaded successfully")

            /// Check if onboarding is needed (no models AND no providers configured)
            let modelManager = LocalModelManager()
            let hasLocalModels = !modelManager.getModels().isEmpty
            
            /// Check for ANY provider configuration in UserDefaults (not just saved_provider_ids)
            let hasProviders = UserDefaults.standard.dictionaryRepresentation().keys.contains { key in
                key.starts(with: "provider_config_")
            }
            
            let needsOnboarding = !hasLocalModels && !hasProviders
            
            logger.info("ONBOARDING_CHECK: hasModels=\(hasLocalModels), hasProviders=\(hasProviders), needsOnboarding=\(needsOnboarding)")
            
            if needsOnboarding {
                /// Show onboarding wizard for first-time setup
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showingOnboardingWizard = true
                }
            } else if !hasSeenWelcomeScreen {
                /// Show welcome screen on first launch if already configured
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showingWelcomeScreen = true
                }
            } else if WhatsNewView.shouldShow() {
                /// Show What's New for returning users on version update.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showingWhatsNew = true
                }
            }
        }
        .confirmationDialog("Delete Folder", isPresented: $showingFolderDeletion, presenting: folderToDelete) { folder in
            Button("Delete Folder", role: .destructive) {
                /// Move all conversations in this topic to uncategorized
                conversationManager.deleteFolder(folder.id)
                /// Delete the topic itself
                folderManager.deleteFolder(folder.id)
                folderToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                folderToDelete = nil
            }
        } message: { folder in
            let convCount = conversationManager.conversationsForFolder(folder.id).count
            if convCount > 0 {
                Text("Are you sure you want to delete '\(folder.name)'? All \(convCount) conversation(s) will be moved to Uncategorized.")
            } else {
                Text("Are you sure you want to delete '\(folder.name)'?")
            }
        }
        .setupNotificationHandlers(
            conversationManager: conversationManager,
            showingPreferences: $showingPreferences,
            showingHelp: $showingHelp,
            showingAPIReference: $showingAPIReference,
            showingWelcomeScreen: $showingWelcomeScreen,
            showingRenameDialog: $showingRenameDialog,
            showingDeleteConfirmation: $showingDeleteConfirmation,
            showingDeleteAllConfirmation: $showingDeleteAllConfirmation,
            showingFolderCreation: $showingFolderCreation,
            showingConvertToTopicDialog: $showingConvertToTopicDialog,
            conversationToRename: $conversationToRename,
            conversationToDelete: $conversationToDelete,
            conversationToConvert: $conversationToConvert,
            newConversationName: $newConversationName,
            newTopicName: $newTopicName,
            newTopicDescription: $newTopicDescription,
            showingGlobalSearch: $showingGlobalSearch,
            exportConversation: exportConversation,
            printConversation: printConversation,
            copyConversationToClipboard: copyConversationToClipboard
        )
        .onReceive(NotificationCenter.default.publisher(for: .showWhatsNew)) { _ in
            showingWhatsNew = true
        }
    }

    /// Folder section header with collapse toggle and context menu for deletion
    private func folderHeader(folder: Folder, conversationCount: Int) -> some View {
        Button(action: {
            folderManager.toggleCollapsed(folder.id)
        }) {
            HStack(spacing: 6) {
                Image(systemName: folder.isCollapsed ? "chevron.right" : "chevron.down")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .frame(width: 12)

                if let icon = folder.icon {
                    Image(systemName: icon)
                }
                Text(folder.name)

                Text("(\(conversationCount))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Delete Folder", role: .destructive) {
                folderToDelete = folder
                showingFolderDeletion = true
            }
        }
    }

    /// Folder label for DisclosureGroup (no chevron - DisclosureGroup provides it)
    private func folderLabel(folder: Folder, conversationCount: Int) -> some View {
        HStack(spacing: 6) {
            if let icon = folder.icon {
                Image(systemName: icon)
            }
            Text(folder.name)

            Text("(\(conversationCount))")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Delete Folder", role: .destructive) {
                folderToDelete = folder
                showingFolderDeletion = true
            }
        }
    }

    /// Uncategorized section header with collapse toggle (consistent with folder style)
    private func uncategorizedHeader(conversationCount: Int) -> some View {
        Button(action: {
            uncategorizedCollapsed.toggle()
        }) {
            HStack(spacing: 6) {
                Image(systemName: uncategorizedCollapsed ? "chevron.right" : "chevron.down")
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .frame(width: 12)

                Text("Uncategorized")

                Text("(\(conversationCount))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    /// Uncategorized label for DisclosureGroup (no chevron - DisclosureGroup provides it)
    private func uncategorizedLabel(conversationCount: Int) -> some View {
        HStack(spacing: 6) {
            Text("Uncategorized")

            Text("(\(conversationCount))")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func conversationRow(_ conversation: ConversationModel) -> some View {
        ConversationRowContent(
            conversation: conversation,
            isActive: conversationManager.activeConversation?.id == conversation.id
        )
        .contentShape(Rectangle())
        .contextMenu {
            /// Show multi-select actions if multiple conversations selected.
            if selectedConversations.count > 1 {
                let selectedConvs = conversationManager.conversations.filter { selectedConversations.contains($0.id) }
                let allPinned = selectedConvs.allSatisfy { $0.isPinned }
                let allUnpinned = selectedConvs.allSatisfy { !$0.isPinned }

                if allPinned {
                    Button("Unpin \(selectedConversations.count) Conversations") {
                        bulkTogglePin(pin: false)
                    }
                } else if allUnpinned {
                    Button("Pin \(selectedConversations.count) Conversations") {
                        bulkTogglePin(pin: true)
                    }
                } else {
                    /// Mixed state - offer both options
                    Button("Pin All Selected") {
                        bulkTogglePin(pin: true)
                    }
                    Button("Unpin All Selected") {
                        bulkTogglePin(pin: false)
                    }
                }

                Divider()

                Button("Export \(selectedConversations.count) Conversations...") {
                    bulkExport()
                }

                Divider()

                /// Folder organization menu (multi-select)
                Menu("Move to Folder") {
                    Button("Create New Folder...") {
                        showingFolderCreation = true
                    }

                    if !folderManager.folders.isEmpty {
                        Divider()
                        ForEach(folderManager.folders, id: \.id) { folder in
                            Button(folder.name) {
                                conversationManager.assignFolder(folder.id, to: Array(selectedConversations))
                            }
                        }
                    }
                }

                Button("Remove from Folders") {
                    conversationManager.assignFolder(nil, to: Array(selectedConversations))
                }

                Divider()

                Button("Delete \(selectedConversations.count) Conversations", role: .destructive) {
                    showingDeleteSelectedConfirmation = true
                }
            } else {
                /// Single conversation actions - use reusable context menu.
                conversationContextMenu(conversation)
            }
        }
    }

    // MARK: - Helper Methods

    /// Reusable context menu for conversations (used in sidebar and header).
    @ViewBuilder
    private func conversationContextMenu(_ conversation: ConversationModel) -> some View {
        Button(conversation.isPinned ? "Unpin Conversation" : "Pin Conversation") {
            conversation.isPinned.toggle()
            conversationManager.saveConversations()
            conversationManager.objectWillChange.send()
        }

        Divider()

        Button("Rename...") {
            conversationToRename = conversation
            newConversationName = conversation.title
            showingRenameDialog = true
        }

        Button("Duplicate") {
            let duplicatedConversation = conversationManager.duplicateConversation(conversation)
            conversationManager.selectConversation(duplicatedConversation)
        }

        Button("Export...") {
            exportConversation(conversation)
        }

        Button("Copy Conversation") {
            copyConversationToClipboard(conversation)
        }

        Divider()

        /// Folder organization menu
        Menu("Move to Folder") {
            Button("Create New Folder...") {
                showingFolderCreation = true
            }

            if !folderManager.folders.isEmpty {
                Divider()
                ForEach(folderManager.folders, id: \.id) { folder in
                    Button(action: {
                        conversationManager.assignFolder(folder.id, to: [conversation.id])
                    }) {
                        HStack {
                            if let icon = folder.icon {
                                Image(systemName: icon)
                            }
                            Text(folder.name)
                            if conversation.folderId == folder.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }

        if conversation.folderId != nil {
            Button("Remove from Folder") {
                conversationManager.assignFolder(nil, to: [conversation.id])
            }
        }

        Divider()

        Button("Convert to Shared Topic…") {
            conversationToConvert = conversation
            newTopicName = conversation.title
            newTopicDescription = ""
            showingConvertToTopicDialog = true
        }

        Divider()

        Button("Delete", role: .destructive) {
            conversationToDelete = conversation
            showingDeleteConfirmation = true
        }
    }

    private var renameConversationDialog: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rename Conversation")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Enter a new name for this conversation")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            TextField("Conversation name", text: $newConversationName)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if !newConversationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        renameConversation()
                    }
                }

            HStack {
                Button("Cancel") {
                    showingRenameDialog = false
                    conversationToRename = nil
                    newConversationName = ""
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Rename") {
                    renameConversation()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newConversationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 350)
    }

    private var topicCreationDialog: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Create Folder")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Enter a name for the new folder")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            TextField("Folder name", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        createFolder()
                    }
                }

            HStack {
                Button("Cancel") {
                    showingFolderCreation = false
                    newFolderName = ""
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Create") {
                    createFolder()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 350)
    }

    private func createFolder() {
        let trimmedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            let folder = folderManager.createFolder(name: trimmedName)
            /// Assign selected conversations to the new topic
            if !selectedConversations.isEmpty {
                conversationManager.assignFolder(folder.id, to: Array(selectedConversations))
            }
        }
        showingFolderCreation = false
        newFolderName = ""
    }

    // MARK: - Import Conversations

    private var importConversationDialog: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Import Conversations")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Import conversations from a SAM export file (.json)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "doc.badge.plus")
                        .foregroundColor(.blue)
                        .font(.title2)

                    VStack(alignment: .leading) {
                        Text("Select a SAM export file")
                            .font(.headline)
                        Text("Supports single and bulk exports")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Browse...") {
                        selectImportFile()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if isImporting {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Importing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let error = importError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Import Options")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("• Duplicate IDs will create new conversations")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("• Memory data will be imported if present")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("• Working directories will use default locations")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)

            HStack {
                Button("Cancel") {
                    showingImportDialog = false
                    importError = nil
                }
                .buttonStyle(.bordered)
                .disabled(isImporting)

                Spacer()
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func selectImportFile() {
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

        Task {
            do {
                let importExportService = ConversationImportExportService(
                    conversationManager: conversationManager,
                    memoryManager: conversationManager.memoryManager
                )

                let result = try await importExportService.importFromFile(
                    url,
                    conflictResolution: .createNew,
                    importMemory: true
                )

                await MainActor.run {
                    isImporting = false
                    importResult = result
                    showingImportDialog = false
                    showingImportResultDialog = true

                    /// Select first imported conversation
                    if let firstSuccess = result.results.first(where: { $0.success && $0.conflictResolution != .skip }),
                       let conversation = conversationManager.conversations.first(where: { $0.id == firstSuccess.newId }) {
                        conversationManager.selectConversation(conversation)
                    }

                    logger.info("Import complete: \(result.successCount) succeeded, \(result.failedCount) failed")
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    importError = "Import failed: \(error.localizedDescription)"
                    logger.error("Import failed: \(error)")
                }
            }
        }
    }

    private var importResultDialog: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: importResult?.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(importResult?.failedCount == 0 ? .green : .orange)
                        .font(.title2)

                    Text("Import Complete")
                        .font(.title2)
                        .fontWeight(.semibold)
                }

                Text(importResultSummary)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let result = importResult {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(result.results, id: \.newId) { item in
                            HStack {
                                Image(systemName: item.success ? "checkmark.circle" : "xmark.circle")
                                    .foregroundColor(item.success ? .green : .red)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.subheadline)
                                        .lineLimit(1)

                                    if item.success {
                                        Text("\(item.messageCount) messages, \(item.memoryCount) memories")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    } else if let error = item.error {
                                        Text(error)
                                            .font(.caption)
                                            .foregroundColor(.red)
                                    }
                                }

                                Spacer()

                                if item.conflictResolution == .skip {
                                    Text("Skipped")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            HStack {
                Spacer()

                Button("Done") {
                    showingImportResultDialog = false
                    importResult = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 450)
    }

    private var importResultSummary: String {
        guard let result = importResult else { return "" }

        var parts: [String] = []
        if result.successCount > 0 {
            parts.append("\(result.successCount) imported")
        }
        if result.failedCount > 0 {
            parts.append("\(result.failedCount) failed")
        }
        if result.skippedCount > 0 {
            parts.append("\(result.skippedCount) skipped")
        }

        return parts.joined(separator: ", ")
    }

    // MARK: - Convert to Shared Topic

    private var convertToTopicDialog: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Convert to Shared Topic")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Create a shared topic from this conversation. Other agents can then access this topic's history.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("Topic Name", text: $newTopicName)
                    .textFieldStyle(.roundedBorder)

                TextField("Description (optional)", text: $newTopicDescription)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Messages from this conversation will be copied to the shared topic. The original conversation will remain unchanged.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button("Cancel") {
                    showingConvertToTopicDialog = false
                    conversationToConvert = nil
                    newTopicName = ""
                    newTopicDescription = ""
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Convert") {
                    convertToSharedTopic()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newTopicName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func convertToSharedTopic() {
        guard let conversation = conversationToConvert else { return }

        let trimmedName = newTopicName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let trimmedDescription = newTopicDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                let topicManager = SharedTopicManager()

                // Create the topic
                let topic = try topicManager.createTopic(
                    name: trimmedName,
                    description: trimmedDescription.isEmpty ? nil : trimmedDescription
                )

                // Copy conversation messages to topic entries
                for message in conversation.messages {
                    let entryContent = """
                    [\(message.isFromUser ? "User" : "Assistant")] \(message.timestamp.ISO8601Format())
                    \(message.content)
                    """

                    try topicManager.createEntry(
                        topicId: topic.id,
                        key: message.id.uuidString,
                        content: entryContent,
                        contentType: message.isFromUser ? "user_message" : "assistant_message",
                        createdBy: conversation.id.uuidString
                    )
                }

                logger.info("Converted conversation '\(conversation.title)' to shared topic '\(trimmedName)'")

                await MainActor.run {
                    showingConvertToTopicDialog = false
                    conversationToConvert = nil
                    newTopicName = ""
                    newTopicDescription = ""
                }
            } catch {
                logger.error("Failed to convert conversation to shared topic: \(error)")
            }
        }
    }

    private func renameConversation() {
        guard let conversation = conversationToRename else { return }

        let trimmedName = newConversationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            conversationManager.renameConversation(conversation, to: trimmedName)
        }

        showingRenameDialog = false
        conversationToRename = nil
        newConversationName = ""
    }

    private func exportConversation(_ conversation: ConversationModel) {
        conversationToExport = conversation
    }

    /// Copy entire conversation to clipboard in readable format
    private func copyConversationToClipboard(_ conversation: ConversationModel) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short

        var text = "Conversation: \(conversation.title)\n"
        text += "ID: \(conversation.id.uuidString)\n"
        text += "Created: \(dateFormatter.string(from: conversation.created))\n"
        text += String(repeating: "=", count: 60) + "\n\n"

        /// Filter out empty messages and tool call JSON
        let validMessages = conversation.messages.filter { message in
            let hasContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasContentParts = message.contentParts != nil && !message.contentParts!.isEmpty
            return hasContent || hasContentParts
        }

        for message in validMessages {
            let timestamp = dateFormatter.string(from: message.timestamp)
            let role = message.isFromUser ? "User" : "Assistant"

            text += "[\(timestamp)] \(role):\n"

            if !message.content.isEmpty {
                text += message.content + "\n"
            }

            /// Include image information from contentParts
            if let contentParts = message.contentParts {
                for part in contentParts {
                    if case .imageUrl(let imageURL) = part {
                        text += "[Image: \(imageURL.url)]\n"
                    }
                }
            }

            text += "\n" + String(repeating: "-", count: 40) + "\n\n"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        logger.info("Copied conversation to clipboard: \(conversation.title)")
    }

    /// Generate delete all conversations confirmation message
    private func deleteAllMessage(info: (totalToDelete: Int, withDirectories: Int, pinned: Int)) -> String {
        if info.totalToDelete == 0 {
            return "No conversations to delete. All \(info.pinned) conversations are pinned."
        }

        var message = "This will delete \(info.totalToDelete) conversation\(info.totalToDelete == 1 ? "" : "s")."

        if info.pinned > 0 {
            message += "\n\n\(info.pinned) pinned conversation\(info.pinned == 1 ? "" : "s") will be preserved."
        }

        if info.withDirectories > 0 {
            message += "\n\n\(info.withDirectories) working director\(info.withDirectories == 1 ? "y" : "ies") can also be deleted."
        }

        let sharedCount = info.totalToDelete - info.withDirectories
        if sharedCount > 0 {
            message += "\n\nShared topic directories will not be deleted."
        }

        return message
    }

    @MainActor
    private func printConversation(_ conversation: ConversationModel) {
        PrintService.printConversation(conversation: conversation, messages: conversation.messages)
    }

    // MARK: - Search Result Handling

    /// Handle search result selection: switch conversation and scroll to message.
    private func handleSearchResultSelection(conversationId: UUID, messageId: UUID) {
        /// Find and switch to the conversation containing the message.
        if let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
            conversationManager.selectConversation(conversation)

            /// Post notification to scroll to the message after conversation loads.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(
                    name: .scrollToMessage,
                    object: nil,
                    userInfo: ["messageId": messageId]
                )
            }

            logger.debug("Search result selected - switching to conversation: \(conversation.title), message: \(messageId)")
        }
    }

    // MARK: - Multi-Select Delete

    /// Get info about selected conversations to delete
    private func getSelectedConversationsInfo() -> (totalToDelete: Int, withDirectories: Int, pinned: Int) {
        let selectedConvs = conversationManager.conversations.filter { selectedConversations.contains($0.id) }
        let pinnedCount = selectedConvs.filter { $0.isPinned }.count
        let unpinnedConvs = selectedConvs.filter { !$0.isPinned }
        let isolated = unpinnedConvs.filter { !$0.settings.useSharedData }

        return (totalToDelete: unpinnedConvs.count, withDirectories: isolated.count, pinned: pinnedCount)
    }

    /// Generate delete selected message
    private func deleteSelectedMessage(info: (totalToDelete: Int, withDirectories: Int, pinned: Int)) -> String {
        var message = ""

        if info.pinned > 0 {
            message += "\(info.pinned) pinned conversation(s) will be protected.\n\n"
        }

        message += "Delete \(info.totalToDelete) conversation(s)?\n\n"

        if info.withDirectories > 0 {
            message += "\(info.withDirectories) conversation(s) with isolated working directories.\n\n"
            message += "Choose whether to delete metadata only or also delete working directories."
        } else {
            message += "All selected conversations use shared data directories.\nOnly metadata will be deleted."
        }

        return message
    }

    /// Delete selected conversations with proper cleanup
    private func deleteSelectedConversations(deleteDirectories: Bool = false) {
        let selectedIds = Array(selectedConversations)
        let selectedConvs = conversationManager.conversations.filter { selectedIds.contains($0.id) }

        /// Separate pinned/unpinned
        let pinnedConvs = selectedConvs.filter { $0.isPinned }
        let unpinnedConvs = selectedConvs.filter { !$0.isPinned }

        /// Further separate isolated/shared
        let isolatedConvs = unpinnedConvs.filter { !$0.settings.useSharedData }

        /// Clear runtime state for all unpinned conversations
        for conversation in unpinnedConvs {
            conversationManager.stateManager.clearState(conversationId: conversation.id)
        }

        /// Delete memory databases for all unpinned conversations
        for conversation in unpinnedConvs {
            do {
                try conversationManager.memoryManager.deleteConversationDatabase(conversationId: conversation.id)
                logger.debug("Deleted memory database for conversation \(conversation.id)")
            } catch {
                logger.error("Failed to delete memory database for conversation \(conversation.id): \(error)")
            }
        }

        /// Remove unpinned conversations
        conversationManager.conversations.removeAll { selectedIds.contains($0.id) && !$0.isPinned }

        /// If active conversation was deleted, switch to first pinned or first remaining
        if let active = conversationManager.activeConversation, selectedIds.contains(active.id) && !active.isPinned {
            conversationManager.activeConversation = pinnedConvs.first ?? conversationManager.conversations.first
        }

        /// Delete directories for isolated conversations if requested
        var deletedDirectoryCount = 0
        if deleteDirectories {
            for conversation in isolatedConvs {
                let directory = conversation.workingDirectory

                /// Safety check: Path must contain conversation UUID
                guard directory.contains(conversation.id.uuidString) else {
                    logger.warning("Skipping directory deletion: \(directory) (safety check failed)")
                    continue
                }

                /// Never delete shared folder directories
                guard !conversation.settings.useSharedData else {
                    logger.warning("Skipping shared folder directory: \(directory)")
                    continue
                }

                do {
                    let fileManager = FileManager.default
                    if fileManager.fileExists(atPath: directory) {
                        try fileManager.removeItem(atPath: directory)
                        deletedDirectoryCount += 1
                        logger.info("Deleted directory: \(directory)")
                    }
                } catch {
                    logger.error("Failed to delete directory \(directory): \(error)")
                }
            }
        }

        /// Save updated conversations list
        conversationManager.saveConversations()

        /// Clear selection
        selectedConversations.removeAll()

        logger.info("""
            Deleted \(unpinnedConvs.count) selected conversations (\(pinnedConvs.count) pinned protected)
            - Isolated: \(isolatedConvs.count)
            - Directories deleted: \(deletedDirectoryCount)
            """)
    }

    /// Bulk pin/unpin selected conversations
    private func bulkTogglePin(pin: Bool) {
        let selectedIds = Array(selectedConversations)
        let selectedConvs = conversationManager.conversations.filter { selectedIds.contains($0.id) }

        for conversation in selectedConvs {
            conversation.isPinned = pin
        }

        conversationManager.saveConversations()
        conversationManager.objectWillChange.send()

        logger.info("\(pin ? "Pinned" : "Unpinned") \(selectedConvs.count) conversations")

        /// Clear selection
        selectedConversations.removeAll()
    }

    /// Bulk export selected conversations
    private func bulkExport() {
        let selectedIds = Array(selectedConversations)
        let selectedConvs = conversationManager.conversations.filter { selectedIds.contains($0.id) }

        /// Export each conversation
        for conversation in selectedConvs {
            exportConversation(conversation)
        }

        logger.info("Exported \(selectedConvs.count) conversations")

        /// Clear selection
        selectedConversations.removeAll()
    }
}

// MARK: - Conversation List View Helper

extension MainWindowView {
    /// Filter conversations by filter text
    private func filterConversations(_ conversations: [ConversationModel]) -> [ConversationModel] {
        guard !conversationFilterText.isEmpty else { return conversations }
        return conversations.filter { conv in
            conv.title.localizedCaseInsensitiveContains(conversationFilterText) ||
            conv.messages.contains { msg in
                msg.content.localizedCaseInsensitiveContains(conversationFilterText)
            }
        }
    }

    /// Separate computed property to avoid type-checking complexity
    private var conversationListView: some View {
        List(selection: $selectedConversations) {
            /// CRITICAL: Sort folders ALPHABETICALLY by name (NOT by conversation dates)
            /// Folders sorted by name ensures stable, predictable organization
            let sortedFolders = folderManager.folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            /// Folder-organized conversations (pinned first within each folder)
            ForEach(sortedFolders, id: \.id) { folder in
                let allFolderConversations = conversationManager.conversationsForFolder(folder.id)
                /// CRITICAL: Sort by CREATED date (NOT updated) - newest at top, oldest at bottom
                /// Using 'created' prevents re-sorting when conversations are accessed/modified
                let pinnedInFolder = allFolderConversations.filter { $0.isPinned }.sorted { $0.created > $1.created }
                let unpinnedInFolder = allFolderConversations.filter { !$0.isPinned }.sorted { $0.created > $1.created }
                let allFolderSorted = pinnedInFolder + unpinnedInFolder
                let folderConversations = filterConversations(allFolderSorted)

                if !folderConversations.isEmpty || conversationFilterText.isEmpty {
                    /// Use DisclosureGroup for consistent collapsible styling
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { !folder.isCollapsed },
                            set: { _ in folderManager.toggleCollapsed(folder.id) }
                        )
                    ) {
                        if !folderConversations.isEmpty {
                            ForEach(folderConversations, id: \.id) { conversation in
                                conversationRow(conversation)
                                    .tag(conversation.id)
                            }
                        } else if conversationFilterText.isEmpty {
                            Text("No conversations")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        }
                    } label: {
                        folderLabel(folder: folder, conversationCount: folderConversations.count)
                    }
                }
            }

            /// Uncategorized conversations (pinned first, no folder assigned)
            let allUncategorized = conversationManager.conversationsForFolder(nil)
            /// CRITICAL: Sort by CREATED date (NOT updated) - newest at top, oldest at bottom
            /// Using 'created' prevents re-sorting when conversations are accessed/modified
            let pinnedUncategorized = allUncategorized.filter { $0.isPinned }.sorted { $0.created > $1.created }
            let unpinnedUncategorized = allUncategorized.filter { !$0.isPinned }.sorted { $0.created > $1.created }
            let allUncategorizedSorted = pinnedUncategorized + unpinnedUncategorized
            let uncategorizedConversations = filterConversations(allUncategorizedSorted)

            if !uncategorizedConversations.isEmpty {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { !uncategorizedCollapsed },
                        set: { _ in uncategorizedCollapsed.toggle() }
                    )
                ) {
                    ForEach(uncategorizedConversations, id: \.id) { conversation in
                        conversationRow(conversation)
                            .tag(conversation.id)
                    }
                } label: {
                    uncategorizedLabel(conversationCount: uncategorizedConversations.count)
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            /// Initialize selection with active conversation
            if let activeId = conversationManager.activeConversation?.id {
                selectedConversations = [activeId]
            }
        }
        .onChange(of: conversationManager.activeConversation?.id) { newActiveId in
            /// Keep selection in sync with active conversation (unless multi-selecting)
            /// ONLY sync if selection doesn't already match (prevents circular updates)
            if selectedConversations.count <= 1,
               let activeId = newActiveId,
               selectedConversations != [activeId] {
                selectedConversations = [activeId]
            }
        }
        .onChange(of: selectedConversations) { newSelection in
            /// Auto-switch conversation when selecting single item
            if newSelection.count == 1, let conversationId = newSelection.first {
                /// Use Task to avoid immediate state change that clears selection
                Task { @MainActor in
                    if let conversation = conversationManager.conversations.first(where: { $0.id == conversationId }) {
                        conversationManager.selectConversation(conversation)
                    }
                }
            }
        }
    }
}

// MARK: - UI Setup

extension View {
    func setupNotificationHandlers(
        conversationManager: ConversationManager,
        showingPreferences: Binding<Bool>,
        showingHelp: Binding<Bool>,
        showingAPIReference: Binding<Bool>,
        showingWelcomeScreen: Binding<Bool>,
        showingRenameDialog: Binding<Bool>,
        showingDeleteConfirmation: Binding<Bool>,
        showingDeleteAllConfirmation: Binding<Bool>,
        showingFolderCreation: Binding<Bool>,
        showingConvertToTopicDialog: Binding<Bool>,
        conversationToRename: Binding<ConversationModel?>,
        conversationToDelete: Binding<ConversationModel?>,
        conversationToConvert: Binding<ConversationModel?>,
        newConversationName: Binding<String>,
        newTopicName: Binding<String>,
        newTopicDescription: Binding<String>,
        showingGlobalSearch: Binding<Bool>,
        exportConversation: @escaping (ConversationModel) -> Void,
        printConversation: @escaping (ConversationModel) -> Void,
        copyConversationToClipboard: @escaping (ConversationModel) -> Void
    ) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: .showPreferences)) { _ in
                showingPreferences.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showWelcome)) { _ in
                showingWelcomeScreen.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showHelp)) { _ in
                showingHelp.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAPIReference)) { _ in
                showingAPIReference.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showGlobalSearch)) { _ in
                showingGlobalSearch.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .newConversation)) { _ in
                conversationManager.createNewConversation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .clearConversation)) { _ in
                if let activeConversation = conversationManager.activeConversation {
                    activeConversation.messageBus?.clearMessages()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .renameConversation)) { notification in
                let conversation = notification.object as? ConversationModel ?? conversationManager.activeConversation
                if let conversation = conversation {
                    conversationToRename.wrappedValue = conversation
                    newConversationName.wrappedValue = conversation.title
                    showingRenameDialog.wrappedValue = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .duplicateConversation)) { _ in
                if let activeConversation = conversationManager.activeConversation {
                    let duplicated = conversationManager.duplicateConversation(activeConversation)
                    conversationManager.selectConversation(duplicated)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportConversation)) { notification in
                let conversation = notification.object as? ConversationModel ?? conversationManager.activeConversation
                if let conversation = conversation {
                    exportConversation(conversation)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyConversation)) { notification in
                let conversation = notification.object as? ConversationModel ?? conversationManager.activeConversation
                if let conversation = conversation {
                    copyConversationToClipboard(conversation)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .printConversation)) { _ in
                if let activeConversation = conversationManager.activeConversation {
                    printConversation(activeConversation)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteConversation)) { notification in
                let conversation = notification.object as? ConversationModel ?? conversationManager.activeConversation
                if let conversation = conversation {
                    conversationToDelete.wrappedValue = conversation
                    showingDeleteConfirmation.wrappedValue = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteAllConversations)) { _ in
                showingDeleteAllConfirmation.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .createFolder)) { _ in
                showingFolderCreation.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .convertToSharedTopic)) { notification in
                let conversation = notification.object as? ConversationModel ?? conversationManager.activeConversation
                if let conversation = conversation {
                    conversationToConvert.wrappedValue = conversation
                    newTopicName.wrappedValue = conversation.title
                    newTopicDescription.wrappedValue = ""
                    showingConvertToTopicDialog.wrappedValue = true
                }
            }
    }
}

#Preview {
    MainWindowView()
}
