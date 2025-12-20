// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import AppKit
import Combine
import Logging

/// Text-to-speech service using NSSpeechSynthesizer (native macOS TTS)
/// This provides more natural sounding voices than AVSpeechSynthesizer
/// Supports streaming TTS by queuing sentences as they arrive
@MainActor
public class SpeechSynthesisService: NSObject, ObservableObject, NSSpeechSynthesizerDelegate {
    @Published public private(set) var isSpeaking: Bool = false

    private var synthesizer: NSSpeechSynthesizer?
    private var currentCompletionHandler: (() -> Void)?
    private let logger = Logger(label: "com.sam.voice.synthesis")

    /// Audio device manager for voice selection
    private var audioDeviceManager: AudioDeviceManager?

    /// Callbacks for TTS lifecycle events
    public var onSpeakingStarted: (() -> Void)?
    public var onSpeakingFinished: (() -> Void)?

    /// Sentence queue for streaming TTS
    private var sentenceQueue: [String] = []
    private var isProcessingQueue = false
    private var streamingCompletionHandler: (() -> Void)?

    public override init() {
        super.init()
        /// Create synthesizer with default voice
        self.synthesizer = NSSpeechSynthesizer()
        self.synthesizer?.delegate = self
    }

    /// Set the audio device manager for voice selection
    public func setAudioDeviceManager(_ manager: AudioDeviceManager) {
        self.audioDeviceManager = manager
        logger.debug("AudioDeviceManager configured for speech synthesis")
        /// Update synthesizer with configured voice
        updateSynthesizerVoice()
    }

    /// Update the synthesizer to use the selected voice
    private func updateSynthesizerVoice() {
        let voiceId = audioDeviceManager?.selectedVoiceIdentifier
        let rateMultiplier = audioDeviceManager?.speechRate ?? 1.0

        logger.info("updateSynthesizerVoice: voiceId=\(voiceId ?? "nil"), rate=\(rateMultiplier), hasManager=\(audioDeviceManager != nil)")

        if let voiceId = voiceId {
            /// Create synthesizer with selected voice
            let voiceName = NSSpeechSynthesizer.VoiceName(rawValue: voiceId)
            synthesizer = NSSpeechSynthesizer(voice: voiceName)

            if synthesizer == nil {
                logger.error("Failed to create synthesizer with voice: \(voiceId), falling back to default")
                synthesizer = NSSpeechSynthesizer()
            } else {
                logger.info("Created synthesizer with voice: \(voiceId)")
            }
        } else {
            /// Use system default
            logger.info("No voice selected, using system default")
            synthesizer = NSSpeechSynthesizer()
        }

        synthesizer?.delegate = self

        /// Set speech rate (NSSpeechSynthesizer uses different rate scale)
        /// NSSpeechSynthesizer rate: ~180-220 words per minute is normal
        /// The rate property is words per minute
        let baseRate: Float = 180
        synthesizer?.rate = baseRate * rateMultiplier

        logger.info("Synthesizer configured: voice=\(synthesizer?.voice()?.rawValue ?? "default"), rate=\(synthesizer?.rate ?? 0)")
    }

    /// Speak text aloud with optional completion handler
    public func speak(_ text: String, completion: (() -> Void)? = nil) {
        logger.info("speak() called: isSpeaking=\(isSpeaking), text.count=\(text.count)")

        /// Stop any existing speech
        synthesizer?.stopSpeaking()

        /// Update voice in case settings changed
        updateSynthesizerVoice()

        /// Strip markdown formatting for cleaner speech
        let cleanText = stripMarkdown(text)

        /// Store completion handler
        currentCompletionHandler = completion

        /// Start speaking
        isSpeaking = true
        onSpeakingStarted?()

        let success = synthesizer?.startSpeaking(cleanText) ?? false
        if !success {
            logger.error("Failed to start speaking")
            isSpeaking = false
            onSpeakingFinished?()
            completion?()
            currentCompletionHandler = nil
        } else {
            logger.info("Speech started successfully")
        }
    }

    /// Stop speaking immediately
    public func stop() {
        synthesizer?.stopSpeaking()
        currentCompletionHandler = nil
        sentenceQueue.removeAll()
        isProcessingQueue = false
        streamingCompletionHandler = nil
        isSpeaking = false
    }

    /// Pause speaking
    public func pause() {
        synthesizer?.pauseSpeaking(at: .wordBoundary)
    }

    /// Resume speaking
    public func resume() {
        synthesizer?.continueSpeaking()
    }

    // MARK: - Streaming TTS Methods

    /// Queue a sentence for streaming TTS
    /// Sentences are spoken in order as they are queued
    public func queueSentence(_ sentence: String) {
        let cleanText = stripMarkdown(sentence.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleanText.isEmpty else { return }

        logger.debug("Queueing sentence for TTS: \(cleanText.prefix(50))...")
        sentenceQueue.append(cleanText)

        /// Start processing queue if not already
        if !isProcessingQueue {
            processNextSentence()
        }
    }

    /// Mark streaming as complete - will call completion after queue finishes
    public func finishStreaming(completion: (() -> Void)? = nil) {
        streamingCompletionHandler = completion

        /// If queue is empty and not speaking, call completion immediately
        if sentenceQueue.isEmpty && !isSpeaking {
            logger.info("Streaming complete, no sentences pending")
            onSpeakingFinished?()
            streamingCompletionHandler?()
            streamingCompletionHandler = nil
        } else {
            logger.info("Streaming marked complete, \(sentenceQueue.count) sentences pending")
        }
    }

    /// Clear the sentence queue (for cancellation)
    public func clearQueue() {
        sentenceQueue.removeAll()
        streamingCompletionHandler = nil
        logger.debug("Sentence queue cleared")
    }

    /// Check if there are queued sentences
    public var hasQueuedSentences: Bool {
        !sentenceQueue.isEmpty || isSpeaking
    }

    /// Process the next sentence in the queue
    private func processNextSentence() {
        guard !sentenceQueue.isEmpty else {
            isProcessingQueue = false

            /// Check if streaming is complete
            if let completion = streamingCompletionHandler {
                logger.info("Queue empty, calling streaming completion")
                onSpeakingFinished?()
                completion()
                streamingCompletionHandler = nil
            }
            return
        }

        isProcessingQueue = true
        let sentence = sentenceQueue.removeFirst()

        logger.debug("Speaking queued sentence: \(sentence.prefix(50))...")

        /// Update voice settings in case they changed
        updateSynthesizerVoice()

        isSpeaking = true
        if sentenceQueue.isEmpty && streamingCompletionHandler == nil {
            /// First sentence in queue - notify started
            onSpeakingStarted?()
        }

        let success = synthesizer?.startSpeaking(sentence) ?? false
        if !success {
            logger.error("Failed to speak queued sentence")
            /// Try next sentence
            processNextSentence()
        }
    }

    /// Strip markdown formatting for cleaner TTS
    private func stripMarkdown(_ text: String) -> String {
        var cleaned = text

        /// Remove code blocks
        cleaned = cleaned.replacingOccurrences(of: "```[^`]*```", with: "code block", options: .regularExpression)

        /// Remove inline code
        cleaned = cleaned.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)

        /// Remove bold/italic
        cleaned = cleaned.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\*([^*]+)\\*", with: "$1", options: .regularExpression)

        /// Remove headers
        cleaned = cleaned.replacingOccurrences(of: "^#+\\s+", with: "", options: .regularExpression)

        /// Remove links
        cleaned = cleaned.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)

        return cleaned
    }

    // MARK: - NSSpeechSynthesizerDelegate

    nonisolated public func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        Task { @MainActor in
            logger.info("TTS finished: \(finishedSpeaking)")
            isSpeaking = false

            /// Check if there are more sentences in the queue (streaming TTS)
            if !sentenceQueue.isEmpty {
                logger.debug("Processing next queued sentence (\(sentenceQueue.count) remaining)")
                processNextSentence()
            } else if isProcessingQueue {
                /// Queue is empty - notify finished and check for streaming completion
                logger.info("Sentence queue empty")
                onSpeakingFinished?()
                isProcessingQueue = false

                if let completion = streamingCompletionHandler {
                    logger.info("Executing streaming completion handler")
                    completion()
                    streamingCompletionHandler = nil
                }
            } else {
                /// Non-streaming (single speak call) completion
                onSpeakingFinished?()

                /// Execute completion handler if exists
                if let completion = currentCompletionHandler {
                    logger.info("Executing completion handler")
                    completion()
                    currentCompletionHandler = nil
                }
            }
        }
    }

    nonisolated public func speechSynthesizer(_ sender: NSSpeechSynthesizer, willSpeakWord characterRange: NSRange, of string: String) {
        /// Can be used for word highlighting in future
    }
}
