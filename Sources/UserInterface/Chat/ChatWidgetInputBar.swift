// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import AppKit
import ConversationEngine
import ConfigurationSystem
import APIFramework
import Logging

extension ChatWidget {
    // MARK: - Message Input Bar
    
    var messageInput: some View {
        VStack(spacing: 0) {
            standardMessageInputUI

            /// Status bar - always visible at the bottom of the window.
            Divider()
            statusBar
        }
        .background(Color.clear)
        .onAppear {
            loadGlobalMLXSettings()
            loadGlobalLlamaSettings()
        }
    }

    var statusBar: some View {
        HStack(spacing: 6) {
            if isSending {
                /// Animated braille spinner when processing.
                Text(brailleFrames[brailleSpinnerFrame % brailleFrames.count])
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .frame(width: 14)
                    .task {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s = 10fps
                            brailleSpinnerFrame = (brailleSpinnerFrame + 1) % brailleFrames.count
                        }
                    }

                Text(busyStatusText.isEmpty ? "Generating..." : busyStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                /// Idle state: ready indicator.
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundColor(.green)
                    .frame(width: 14)

                Text("Ready.")
                    .font(.caption)
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .frame(height: 20)
        .background(Color.clear)
    }

    var standardMessageInputUI: some View {
        VStack(spacing: 0) {
            /// Text input area.
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(
                    get: { messageText },
                    set: { newValue in
                        // Prevent typing if model not loaded
                        if endpointManager.isLocalModel(selectedModel) && !isLocalModelLoaded {
                            logger.warning("BLOCKED: Cannot type when model not loaded")
                            return
                        }
                        messageText = newValue
                    }
                ))
                    .font(.body)
                    .disabled(shouldDisableInput || (isSending && !isAwaitingUserInput))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isAwaitingUserInput
                                    ? Color.blue.opacity(0.6)
                                    : Color(NSColor.separatorColor),
                                lineWidth: isAwaitingUserInput ? 2 : 1
                            )
                    )
                    .frame(minHeight: 45, maxHeight: 200)
                    .frame(height: max(45, min(inputTextHeight, 200)))
                    .focused($isInputFocused)
                    .onChange(of: messageText) { oldValue, newValue in
                        /// Prevent typing if model not loaded
                        if shouldDisableInput && newValue != oldValue {
                            logger.warning("BLOCKED TYPING: shouldDisableInput=true, reverting '\(newValue)' to '\(oldValue)'")
                            messageText = oldValue
                            return
                        }
                        /// Keep bridge in sync for voice manager readback
                        voiceBridge.currentMessageText = newValue

                        /// Auto-resize input height based on content
                        recalculateInputHeight(for: newValue)

                        /// FEATURE: Auto-save draft message to conversation with debounced disk persistence
                        /// Save whenever text changes so it persists even if user quits app
                        if let conversation = activeConversation, newValue != conversation.settings.draftMessage {
                            conversation.settings.draftMessage = newValue

                            /// Cancel previous save task and schedule new one (debounce)
                            draftSaveTask?.cancel()
                            draftSaveTask = Task {
                                /// Wait 500ms before saving to disk (debounce rapid typing)
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    conversationManager.saveConversations()
                                    logger.debug("DRAFT_PERSIST: Saved draft to disk (\(newValue.count) chars)")
                                }
                            }
                        }
                    }
                    .onKeyPress { keyPress in
                        /// Handle Enter key behavior based on modifiers.
                        if keyPress.key == .return {
                            /// Shift+Enter: Insert newline (allow default behavior) Note: Cmd+Enter doesn't work reliably in SwiftUI TextEditor, use Shift+Enter instead.
                            if keyPress.modifiers.contains(.shift) {
                                return .ignored
                            } else {
                                /// Plain Enter: Send message.
                                if isAwaitingUserInput {
                                    submitUserResponse()
                                } else if !isSending && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    sendMessage()
                                }
                                return .handled
                            }
                        }
                        return .ignored
                    }

                /// Placeholder text or collaboration prompt.
                if messageText.isEmpty {
                    if isAwaitingUserInput {
                        /// Show simple waiting indicator instead of full prompt (agent's prompt now appears as a message in the chat above).
                        HStack {
                            Image(systemName: "hourglass")
                                .foregroundColor(.blue)
                            Text("Agent is waiting for your response...")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                    } else if endpointManager.isLocalModel(selectedModel) && !isLocalModelLoaded {
                        /// Show instruction to load local model.
                        HStack {
                            Image(systemName: "play.fill")
                                .foregroundColor(.orange)
                            Text("Click the Load Model button below to start chatting")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                    } else {
                        /// Show placeholder with voice or keyboard instructions
                        if voiceManager.listeningMode {
                            Text("Say \"Hey SAM\" and wait for chime, or type your message\n(Enter to send, Shift+Enter for newline)")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .allowsHitTesting(false)
                                .padding(8)
                        } else {
                            Text("Ask SAM anything...\n(Enter to send, Shift+Enter for newline)")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .allowsHitTesting(false)
                                .padding(8)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            /// Unified bottom bar: pickers on left, controls on right.
            HStack(spacing: 6) {
                /// Model picker - opens directly as a menu.
                ModelPickerView(
                    selectedModel: $selectedModel,
                    modelListManager: modelListManager,
                    endpointManager: endpointManager
                )

                /// Local model load/eject controls.
                if endpointManager.isLocalModel(selectedModel) {
                    let currentStatus = endpointManager.modelLoadingStatus[selectedModel] ?? .notLoaded
                    let isLoading: Bool = { if case .loading = currentStatus { return true }; return false }()
                    if currentStatus == .loaded {
                        Button(action: { ejectLocalModel() }) {
                            HStack(spacing: 3) {
                                Image(systemName: "eject.fill")
                                    .font(.system(size: 10))
                                Text("Eject")
                                    .font(.caption2)
                            }
                            .foregroundColor(.green)
                        }
                        .buttonStyle(.borderless)
                        .help("Eject model")
                    } else if isLoading {
                        HStack(spacing: 3) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                            Text("Loading...")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    } else {
                        Button(action: { loadLocalModel() }) {
                            HStack(spacing: 3) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10))
                                Text("Load")
                                    .font(.caption2)
                            }
                            .foregroundColor(.orange)
                        }
                        .buttonStyle(.borderless)
                        .help("Load model into memory")
                    }
                }

                /// System prompt picker - opens directly as a menu.
                if let activeConv = conversationManager.activeConversation {
                    let conversationConfigs = systemPromptManager.configurationsForConversation(
                        workspacePath: activeConv.workingDirectory
                    )
                    if !conversationConfigs.isEmpty {
                        let binding = Binding<UUID>(
                            get: {
                                activeConv.settings.selectedSystemPromptId
                                ?? conversationConfigs.first?.id
                                ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                            },
                            set: { newValue in
                                if var conv = conversationManager.activeConversation {
                                    conv.settings.selectedSystemPromptId = newValue

                                    conversationManager.activeConversation = conv
                                    conversationManager.saveConversations()
                                }

                                systemPromptManager.selectedConfigurationId = newValue
                                if let config = conversationConfigs.first(where: { $0.id == newValue }) {
                                    systemPromptManager.selectConfiguration(config)
                                }
                            }
                        )

                        PromptPickerView(
                            selectedPromptId: binding,
                            prompts: conversationConfigs
                        )
                    }

                    /// Personality picker - opens directly as a menu.
                    PersonalityPickerView(
                        selectedPersonalityId: Binding<UUID?>(
                            get: { activeConv.settings.selectedPersonalityId },
                            set: { newValue in
                                if var conv = conversationManager.activeConversation {
                                    conv.settings.selectedPersonalityId = newValue
                                    conversationManager.activeConversation = conv
                                    conversationManager.saveConversations()
                                }
                            }
                        )
                    )
                }

                Divider()
                    .frame(height: 14)

                /// Controls button - panels, parameters, features, settings, and actions.
                Button(action: { showingControlsPopover.toggle() }) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(showingControlsPopover ? .accentColor : .secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Controls & settings")
                .popover(isPresented: $showingControlsPopover, arrowEdge: .top) {
                    controlsPopoverContent
                        .frame(width: 300)
                }

                /// Todo list button.
                Button(action: { showingTodoListPopover.toggle() }) {
                    ZStack {
                        Image(systemName: "list.clipboard")
                            .foregroundColor(showingTodoListPopover ? .accentColor : .secondary)
                            .frame(width: 16, height: 16)

                        if !agentTodoList.isEmpty {
                            Text("\(agentTodoList.count)")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundColor(.white)
                                .padding(2)
                                .background(Circle().fill(Color.accentColor))
                                .offset(x: 8, y: -8)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .help("Agent todo list")
                .popover(isPresented: $showingTodoListPopover, arrowEdge: .top) {
                    todoListPopoverContent
                        .frame(width: 320)
                }

                Spacer()

                /// Attach files button.
                Button(action: { attachFiles() }) {
                    Image(systemName: attachedFiles.isEmpty ? "paperclip" : "paperclip.badge.ellipsis")
                        .foregroundColor(attachedFiles.isEmpty ? .secondary : .accentColor)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help(attachedFiles.isEmpty ? "Attach files" : "Attached: \(attachedFiles.count)")

                /// Speaker button.
                Button(action: { voiceManager.toggleSpeaking() }) {
                    Image(systemName: voiceManager.speakingMode ? "speaker.fill" : "speaker")
                        .foregroundColor(voiceManager.speakingMode ? .accentColor : .secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Speaking mode")

                /// Microphone button.
                Button(action: { voiceManager.toggleListening() }) {
                    Image(systemName: voiceManager.listeningMode ? "mic.fill" : "mic")
                        .foregroundColor(
                            voiceManager.currentState == .activeListening ? .red :
                            voiceManager.listeningMode ? .accentColor : .secondary
                        )
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("Listening mode")
                .disabled(shouldDisableInput)

                Divider()
                    .frame(height: 14)

                /// Send/Stop button.
                Button(action: {
                    if isAwaitingUserInput {
                        submitUserResponse()
                    } else if isSending {
                        streamingTask?.cancel()
                        streamingTask = nil
                        isSending = false
                        currentOrchestrator?.cancelWorkflow()
                        currentOrchestrator = nil
                        if let conversation = activeConversation {
                            conversation.isProcessing = false
                        }
                        Task {
                            await endpointManager.cancelLocalModelGeneration()
                        }
                    } else {
                        sendMessage()
                    }
                }) {
                    HStack(spacing: 4) {
                        if isAwaitingUserInput {
                            Image(systemName: "arrowshape.up.fill")
                                .font(.caption)
                            Text("Submit")
                                .font(.caption)
                        } else if isSending {
                            Image(systemName: "stop.fill")
                                .font(.caption)
                            Text("Stop")
                                .font(.caption)
                        } else {
                            Image(systemName: "arrowshape.up.fill")
                                .font(.caption)
                            Text("Send")
                                .font(.caption)
                        }
                    }
                    .foregroundColor(
                        isSending ? .red :
                        isAwaitingUserInput ? .white :
                        messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .white
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        isSending ? Color.red.opacity(0.15) :
                        isAwaitingUserInput ? Color.accentColor :
                        messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.clear : Color.accentColor
                    )
                    .cornerRadius(6)
                }
                .buttonStyle(.borderless)
                .disabled(
                    (!isAwaitingUserInput && !isSending && messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
                    (!isAwaitingUserInput && shouldDisableInput)
                )
                .help(
                    isAwaitingUserInput ? "Submit response" :
                    isSending ? "Stop generation" :
                    "Send message"
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

}
