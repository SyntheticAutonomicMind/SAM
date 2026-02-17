// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Combine
import Logging
import AppKit

/// Central voice interaction coordinator with state machine
@MainActor
public class VoiceManager: ObservableObject {
    public static let shared = VoiceManager()

    @Published public var listeningMode: Bool = false {
        didSet {
            UserDefaults.standard.set(listeningMode, forKey: "voiceListeningMode")
        }
    }
    @Published public var speakingMode: Bool = false {
        didSet {
            UserDefaults.standard.set(speakingMode, forKey: "voiceSpeakingMode")
        }
    }
    @Published public private(set) var currentState: VoiceState = .idle
    @Published public private(set) var statusMessage: String = ""

    private let speechRecognition = SpeechRecognitionService()
    private let speechSynthesis = SpeechSynthesisService()
    private let wakeWordDetector = WakeWordDetector()
    private let commandRecognizer = CommandRecognizer()
    private let pauseDetector = PauseDetector()

    /// Audio device manager for input/output device and voice selection
    public let audioDeviceManager = AudioDeviceManager()

    private let logger = Logger(label: "com.sam.voice")
    private var cancellables = Set<AnyCancellable>()

    /// Callbacks for UI integration
    public var onTranscriptionUpdate: ((String) -> Void)?
    public var onMessageReadyToSend: (() -> Void)?
    public var onMessageNeedsEditing: (() -> Void)?
    public var onMessageCancelled: (() -> Void)?
    public var onWakeWordDetected: (() -> Void)?
    public var getCurrentMessageText: (() -> String)?
    public var onAuthorizationError: ((String) -> Void)?

    /// Track if we've received any transcription in activeListening state
    /// Prevents premature pause detection when user pauses between wake word and command
    private var hasReceivedTranscriptionInActiveState: Bool = false

    /// Timer to detect transcription pause (no new transcription for 2s)
    private var transcriptionPauseTimer: Timer?
    private let transcriptionPauseDelay: TimeInterval = 2.0

    /// Cancellation phrases that return to wake word detection without sending message
    /// Only triggers if the transcription is EXACTLY one of these phrases (no other content)
    private let cancellationPhrases = [
        "cancel", "stop", "nevermind", "never mind", "forget it", "scratch that"
    ]

    public enum VoiceState: Equatable {
        case idle
        case waitingForWakeWord
        case activeListening
        case speaking
    }

    /// Track if heavy initialization has been performed
    private var isInitialized = false

    private init() {
        /// Lightweight init - only restore persisted voice settings
        /// Heavy initialization (audio setup, handlers) is deferred until first use
        listeningMode = UserDefaults.standard.bool(forKey: "voiceListeningMode")
        speakingMode = UserDefaults.standard.bool(forKey: "voiceSpeakingMode")
        
        logger.debug("VoiceManager created (lightweight init, deferred heavy initialization)")
    }

    /// Perform heavy initialization (audio setup, handlers, permissions)
    /// Called lazily when voice features are first accessed
    private func ensureInitialized() {
        guard !isInitialized else { return }
        isInitialized = true
        
        logger.info("VoiceManager: Performing heavy initialization (audio setup, handlers)")
        
        /// Configure services with audio device manager for device/voice selection
        speechRecognition.setAudioDeviceManager(audioDeviceManager)
        speechSynthesis.setAudioDeviceManager(audioDeviceManager)

        setupRecognitionHandlers()
        setupPauseDetection()
        setupTTSCallbacks()
        setupDeviceChangeListener()

        /// Auto-enable listening if it was previously enabled
        if listeningMode {
            startListening()
        }
        
        logger.debug("VoiceManager: Heavy initialization complete")
    }

    /// Listen for audio device changes and restart listening when input device changes
    private func setupDeviceChangeListener() {
        audioDeviceManager.$selectedInputDeviceUID
            .dropFirst() /// Skip initial value
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    if self.listeningMode {
                        self.logger.info("Input device changed while listening - restarting recognition")
                        self.restartListening()
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Restart listening with current settings (used after device change)
    private func restartListening() {
        /// Stop current listening session
        speechRecognition.stopListening()
        pauseDetector.stopMonitoring()
        currentState = .idle

        /// Small delay to ensure clean teardown
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000) /// 100ms
            await MainActor.run {
                /// Restart listening with new device
                self.startListening()
            }
        }
    }

    /// Setup TTS callbacks for intelligent mic pause/resume
    private func setupTTSCallbacks() {
        /// Pause mic input when TTS starts (prevents SAM's voice from triggering wake words)
        speechSynthesis.onSpeakingStarted = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                if self.listeningMode {
                    self.speechRecognition.pause()
                    self.logger.debug("Paused speech recognition during TTS playback")
                }
            }
        }

        /// Resume mic input when TTS finishes
        speechSynthesis.onSpeakingFinished = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                if self.listeningMode {
                    self.speechRecognition.resume()
                    self.logger.debug("Resumed speech recognition after TTS playback")
                }
            }
        }
    }

    /// Setup speech recognition handlers
    private func setupRecognitionHandlers() {
        logger.debug("Setting up recognition handlers")
        /// Handle real-time transcription updates
        speechRecognition.onTranscriptionUpdate = { [weak self] text, isFinal in
            guard let self = self else { return }

            Task { @MainActor in
                self.handleTranscriptionUpdate(text: text, isFinal: isFinal)
            }
        }

        /// Handle audio level updates for pause detection
        speechRecognition.onAudioLevelUpdate = { [weak self] level in
            guard let self = self else { return }

            Task { @MainActor in
                self.pauseDetector.updateAudioLevel(level)
            }
        }
    }

    /// Setup pause detection
    private func setupPauseDetection() {
        pauseDetector.onPauseDetected = { [weak self] in
            guard let self = self else { return }

            Task { @MainActor in
                self.handlePauseDetected()
            }
        }
    }

    /// Toggle listening mode
    public func toggleListening() {
        ensureInitialized()
        if listeningMode {
            stopListening()
        } else {
            startListening()
        }
    }

    /// Toggle speaking mode
    public func toggleSpeaking() {
        ensureInitialized()
        if speakingMode {
            stopSpeaking()
        } else {
            startSpeaking()
        }
    }

    /// Start listening mode
    private func startListening() {
        /// Request permissions if needed
        Task {
            if !speechRecognition.isAuthorized {
                let granted = await speechRecognition.requestPermissions()
                guard granted else {
                    await MainActor.run {
                        statusMessage = "Microphone permission denied"
                        logger.error("Voice permissions denied")
                        /// Notify UI to show user-friendly error
                        onAuthorizationError?("Speech recognition is not enabled.\n\nPlease enable Siri & Dictation in System Settings:\n1. Open System Settings\n2. Go to Privacy & Security > Siri & Dictation\n3. Turn on \"Ask Siri\"\n\nThen restart SAM and try again.")
                        /// Disable listening mode since permission denied
                        listeningMode = false
                    }
                    return
                }
            }

            /// Start listening for wake words
            do {
                try await MainActor.run {
                    try speechRecognition.startListening()
                    listeningMode = true
                    currentState = .waitingForWakeWord
                    statusMessage = "Listening for wake word..."
                    pauseDetector.startMonitoring()
                    logger.info("Started listening for wake words")
                }
            } catch {
                await MainActor.run {
                    let errorMessage = "Failed to start listening: \(error.localizedDescription)"
                    statusMessage = errorMessage
                    logger.error("Failed to start listening: \(error)")
                    /// Check if it's an authorization error
                    if case VoiceError.notAuthorized = error {
                        onAuthorizationError?("Speech recognition is not enabled.\n\nPlease enable Siri & Dictation in System Settings:\n1. Open System Settings\n2. Go to Privacy & Security > Siri & Dictation\n3. Turn on \"Ask Siri\"\n\nThen restart SAM and try again.")
                    } else {
                        onAuthorizationError?(errorMessage)
                    }
                    /// Disable listening mode on error
                    listeningMode = false
                }
            }
        }
    }

    /// Stop listening mode
    private func stopListening() {
        speechRecognition.stopListening()
        pauseDetector.stopMonitoring()
        listeningMode = false
        currentState = .idle
        statusMessage = ""
        logger.info("Stopped listening")
    }

    /// Start speaking mode
    private func startSpeaking() {
        speakingMode = true
        statusMessage = "Speaking mode enabled"
        logger.info("Speaking mode enabled")
    }

    /// Stop speaking mode
    private func stopSpeaking() {
        speechSynthesis.stop()
        speakingMode = false
        statusMessage = ""
        logger.info("Speaking mode disabled")

        /// If we were in speaking state, return to wake word detection
        /// (TTS completion handler won't fire since we stopped it)
        if currentState == .speaking && listeningMode {
            currentState = .waitingForWakeWord
            statusMessage = "Listening for wake word..."
            logger.info("Returned to wake word detection after stopping TTS")
        }
    }

    /// Speak text aloud
    public func speak(_ text: String, completion: (() -> Void)? = nil) {
        ensureInitialized()
        guard speakingMode else { return }

        currentState = .speaking
        statusMessage = "Speaking..."

        speechSynthesis.speak(text) { [weak self] in
            guard let self = self else { return }

            Task { @MainActor in
                if self.currentState == .speaking {
                    self.currentState = .idle
                    self.statusMessage = ""
                }
                completion?()
            }
        }
    }

    /// Handle transcription updates
    private func handleTranscriptionUpdate(text: String, isFinal: Bool) {
        logger.debug("Transcription update: '\(text)' (final: \(isFinal)), state: \(currentState)")

        switch currentState {
        case .waitingForWakeWord:
            /// Check for wake word (process on INTERIM results for immediate response)
            let (detected, cleanedText) = wakeWordDetector.detect(in: text)

            if detected {
                logger.info("Wake word detected (isFinal=\(isFinal)), cleanedText='\(cleanedText)'")

                /// Play acknowledgment sound FIRST (immediate feedback)
                playWakeWordAcknowledgment()

                /// Switch to active listening
                /// Speech recognition continues running - wake word detector stripped wake phrase
                currentState = .activeListening
                statusMessage = "Listening..."
                pauseDetector.reset()
                hasReceivedTranscriptionInActiveState = false /// Reset flag for new command

                onWakeWordDetected?()

                logger.debug("Ready for command after wake word")
                if !cleanedText.isEmpty {
                    logger.info("WAKE_WORD_WITH_COMMAND: Passing '\(cleanedText)' to UI immediately")
                    onTranscriptionUpdate?(cleanedText)
                    hasReceivedTranscriptionInActiveState = true
                }
            }

        case .activeListening:
            /// Actively transcribing user input
            /// Strip wake word if it's still in the transcription
            let (detected, cleanedText) = wakeWordDetector.detect(in: text)

            logger.info("ACTIVE_LISTENING: text='\(text)', wakeDetected=\(detected), cleaned='\(cleanedText)', isFinal=\(isFinal)")

            /// Check for cancellation phrase BEFORE passing to UI
            /// Only cancel if it's EXACTLY a cancellation phrase (no other content)
            if checkForCancellation(cleanedText) {
                logger.info("CANCELLATION_DETECTED: '\(cleanedText)' - returning to wake word detection")

                /// Cancel active listening - return to wake word detection
                currentState = .waitingForWakeWord
                statusMessage = "Listening for wake word..."

                /// Clear transcription from UI
                onTranscriptionUpdate?("")

                /// Reset state flags
                hasReceivedTranscriptionInActiveState = false
                transcriptionPauseTimer?.invalidate()
                transcriptionPauseTimer = nil

                /// Notify UI that message was cancelled
                onMessageCancelled?()

                logger.info("Cancelled voice input - ready for next wake word")
                return
            }

            /// Always pass the cleaned text to UI (wake word stripped if present)
            if !cleanedText.isEmpty {
                logger.info("ACTIVE_LISTENING: Calling onTranscriptionUpdate with '\(cleanedText)'")
                onTranscriptionUpdate?(cleanedText)
                hasReceivedTranscriptionInActiveState = true /// Mark that we've received transcription

                /// Reset transcription pause timer - restart 2s countdown
                transcriptionPauseTimer?.invalidate()
                transcriptionPauseTimer = Timer.scheduledTimer(withTimeInterval: transcriptionPauseDelay, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.handleTranscriptionPause()
                    }
                }
            } else {
                logger.warning("ACTIVE_LISTENING: Cleaned text is empty, not updating UI")
            }

            statusMessage = "Listening..."

        default:
            break
        }
    }

    /// Check if transcription is EXACTLY a cancellation phrase (no other content)
    /// Returns true only if the entire cleaned text matches a cancellation phrase
    private func checkForCancellation(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let isCancellation = cancellationPhrases.contains(normalized)

        if isCancellation {
            logger.debug("Cancellation phrase matched: '\(normalized)'")
        }

        return isCancellation
    }

    /// Handle pause detected
    private func handlePauseDetected() {
        guard currentState == .activeListening else { return }

        /// Only trigger auto-send if we've actually received some transcription
        /// This prevents premature firing when user pauses between wake word and command
        guard hasReceivedTranscriptionInActiveState else {
            logger.debug("Pause detected but no transcription yet - ignoring")
            return
        }

        logger.info("Pause detected in active listening - auto-sending")

        /// Always auto-send after pause
        statusMessage = "Sending..."
        onMessageReadyToSend?()
        currentState = .waitingForWakeWord
        statusMessage = "Processing..."

        /// DON'T reset - speech recognition should continue for next wake word
        logger.info("Returning to wake word detection state")
    }

    /// Handle transcription pause (no new transcription for 2s)
    /// This is triggered by timer, not audio levels (works with background noise)
    private func handleTranscriptionPause() {
        guard currentState == .activeListening else { return }
        guard hasReceivedTranscriptionInActiveState else {
            logger.debug("Transcription pause but no text received - ignoring")
            return
        }

        logger.info("Transcription pause detected (2s since last update) - auto-sending")

        statusMessage = "Sending..."
        onMessageReadyToSend?()
        currentState = .waitingForWakeWord
        statusMessage = "Processing..."
        transcriptionPauseTimer?.invalidate()
        transcriptionPauseTimer = nil

        logger.info("Returning to wake word detection state after transcription pause")
    }

    /// Remove emojis from text for TTS
    private func stripEmojis(from text: String) -> String {
        return text.unicodeScalars.filter { scalar in
            /// Keep only characters that are NOT emoji
            /// Emoji ranges: https://unicode.org/emoji/charts/full-emoji-list.html
            let value = scalar.value
            return !(
                (value >= 0x1F600 && value <= 0x1F64F) || /// Emoticons
                (value >= 0x1F300 && value <= 0x1F5FF) || /// Misc Symbols and Pictographs
                (value >= 0x1F680 && value <= 0x1F6FF) || /// Transport and Map
                (value >= 0x1F1E0 && value <= 0x1F1FF) || /// Regional country flags
                (value >= 0x2600 && value <= 0x26FF) ||   /// Misc symbols
                (value >= 0x2700 && value <= 0x27BF) ||   /// Dingbats
                (value >= 0xFE00 && value <= 0xFE0F) ||   /// Variation selectors
                (value >= 0x1F900 && value <= 0x1F9FF) || /// Supplemental Symbols and Pictographs
                (value >= 0x1FA70 && value <= 0x1FAFF)    /// Symbols and Pictographs Extended-A
            )
        }.map { String($0) }.joined()
    }

    /// Speak assistant response (or just acknowledge if speaking mode disabled)
    public func speakResponse(_ text: String) {
        logger.info("speakResponse called: speakingMode=\(speakingMode), listeningMode=\(listeningMode), textLength=\(text.count)")

        guard speakingMode else {
            logger.info("Speaking mode disabled, returning to wake word detection")
            /// Speech recognition is already running continuously - just update state
            if listeningMode {
                currentState = .waitingForWakeWord
                statusMessage = "Listening for wake word..."
                logger.info("State updated: currentState=\(currentState), statusMessage=\(statusMessage)")
            } else {
                logger.warning("listeningMode is disabled, not changing state")
            }
            return
        }

        /// Strip emojis if preference is disabled (default)
        let speakEmojis = UserDefaults.standard.bool(forKey: "speakEmojis")
        let textToSpeak = speakEmojis ? text : stripEmojis(from: text).trimmingCharacters(in: .whitespaces)

        logger.info("Speaking assistant response (\(textToSpeak.count) chars, emojisRemoved=\(!speakEmojis))")

        /// Set state to speaking and speak the response
        currentState = .speaking
        speechSynthesis.speak(textToSpeak) { [weak self] in
            guard let self = self else { return }

            Task { @MainActor in
                /// Return to wake word detection if listening mode enabled
                /// Speech recognition continues running - just update state
                if self.listeningMode {
                    self.logger.info("Response spoken, returning to wake word detection")
                    self.currentState = .waitingForWakeWord
                    self.statusMessage = "Listening for wake word..."
                } else {
                    self.currentState = .idle
                    self.statusMessage = ""
                }
            }
        }
    }

    // MARK: - Streaming TTS Methods

    /// Queue a sentence for streaming TTS (speak as response is generated)
    /// Call this for each complete sentence during streaming
    public func queueSentenceForSpeaking(_ sentence: String) {
        guard speakingMode else { return }

        /// Strip emojis if preference is disabled (default)
        let speakEmojis = UserDefaults.standard.bool(forKey: "speakEmojis")
        let textToSpeak = speakEmojis ? sentence : stripEmojis(from: sentence).trimmingCharacters(in: .whitespaces)

        guard !textToSpeak.isEmpty else { return }

        /// Update state to speaking on first sentence
        if currentState != .speaking {
            currentState = .speaking
        }

        speechSynthesis.queueSentence(textToSpeak)
    }

    /// Mark streaming response as complete
    /// TTS will continue playing queued sentences and call completion when done
    public func finishStreamingSpeech() {
        guard speakingMode else {
            /// If speaking mode disabled, just return to listening
            if listeningMode {
                currentState = .waitingForWakeWord
                statusMessage = "Listening for wake word..."
            }
            return
        }

        speechSynthesis.finishStreaming { [weak self] in
            guard let self = self else { return }

            Task { @MainActor in
                /// Return to wake word detection if listening mode enabled
                if self.listeningMode {
                    self.logger.info("Streaming speech complete, returning to wake word detection")
                    self.currentState = .waitingForWakeWord
                    self.statusMessage = "Listening for wake word..."
                } else {
                    self.currentState = .idle
                    self.statusMessage = ""
                }
            }
        }
    }

    /// Cancel streaming TTS and clear queue
    public func cancelStreamingSpeech() {
        speechSynthesis.stop()
        speechSynthesis.clearQueue()

        if listeningMode {
            currentState = .waitingForWakeWord
            statusMessage = "Listening for wake word..."
        } else {
            currentState = .idle
            statusMessage = ""
        }
    }

    /// Reset to idle state
    public func reset() {
        stopListening()
        stopSpeaking()
        speechRecognition.reset()
        pauseDetector.reset()
        currentState = .idle
        statusMessage = ""
    }

    /// Reload wake words from preferences (call when settings change)
    public func reloadWakeWords() {
        wakeWordDetector.reloadWakeWords()
        logger.info("Wake words reloaded from preferences")
    }

    /// Play wake word acknowledgment sound (like Siri chime)
    private func playWakeWordAcknowledgment() {
        /// Use configured notification sound for wake word acknowledgment
        let notificationSound = UserDefaults.standard.string(forKey: "notificationSound") ?? "Submarine"

        if let sound = NSSound(named: notificationSound) {
            /// Play asynchronously - don't block main thread
            sound.play()
            logger.debug("Played wake word acknowledgment sound (\(notificationSound))")
        } else {
            /// Fallback to system beep
            NSSound.beep()
            logger.debug("Played wake word acknowledgment sound (beep)")
        }
    }
}
