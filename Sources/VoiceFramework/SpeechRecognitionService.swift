// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Speech
import AVFoundation
import Combine
import Logging
import CoreAudio

/// Speech-to-text service using SFSpeechRecognizer
/// Thread-safe: Can be accessed from any thread, @Published updates dispatched to main
/// @unchecked Sendable: Class uses DispatchQueue.main.async for all state updates
public class SpeechRecognitionService: ObservableObject, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.voice.recognition")

    @Published public private(set) var isListening: Bool = false
    @Published public private(set) var transcribedText: String = ""
    @Published public private(set) var isAuthorized: Bool = false
    @Published public private(set) var partialTranscription: String = ""

    /// SFSpeechRecognizer instance (created lazily after permissions are granted)
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// Audio device manager for device selection
    private var audioDeviceManager: AudioDeviceManager?

    /// Callback for real-time transcription updates
    public var onTranscriptionUpdate: ((String, Bool) -> Void)?

    /// Callback for audio level updates (for pause detection)
    public var onAudioLevelUpdate: ((Float) -> Void)?

    public init() {
        /// Defer ALL speech recognition API calls until permissions are explicitly requested
        /// This prevents TCC crash on macOS 15.1+ where ANY access to SFSpeechRecognizer
        /// APIs (even status checks) require Info.plist keys AND explicit user permission
        logger.debug("SpeechRecognitionService initialized - deferring all SF API calls")
    }

    /// Set the audio device manager for device selection
    public func setAudioDeviceManager(_ manager: AudioDeviceManager) {
        self.audioDeviceManager = manager
        logger.debug("AudioDeviceManager configured for speech recognition")
    }

    /// Initialize recognizer after permissions are granted
    private func initializeRecognizer() {
        guard recognizer == nil else { return }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        recognizer?.supportsOnDeviceRecognition = true
        logger.debug("SFSpeechRecognizer initialized after permission grant")
    }

    /// Request microphone and speech recognition permissions
    public func requestPermissions() async -> Bool {
        /// On macOS, microphone permission is handled automatically by the system
        /// when we start using AVAudioEngine. Just request speech recognition.
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                /// Callback runs on background thread - resume immediately
                continuation.resume(returning: status == .authorized)
            }
        }

        /// Update @Published property on main thread
        DispatchQueue.main.async { [weak self] in
            self?.isAuthorized = speechGranted
            
            /// Initialize recognizer after permission is granted
            if speechGranted {
                self?.initializeRecognizer()
            }
        }

        return speechGranted
    }

    /// Check current authorization status
    private func checkAuthorizationStatus() {
        let status = SFSpeechRecognizer.authorizationStatus()
        DispatchQueue.main.async { [weak self] in
            self?.isAuthorized = (status == .authorized)
        }
    }

    /// Start listening and transcribing
    public func startListening() throws {
        logger.debug("startListening called, isListening=\(isListening), isAuthorized=\(isAuthorized)")

        /// Check if already listening
        guard !isListening else {
            logger.debug("Already listening, skipping")
            return
        }

        /// Check authorization
        guard isAuthorized else {
            logger.error("Not authorized")
            throw VoiceError.notAuthorized
        }

        /// Check recognizer availability
        guard let recognizer = recognizer, recognizer.isAvailable else {
            logger.error("Recognizer unavailable")
            throw VoiceError.recognizerUnavailable
        }

        logger.debug("Recognizer available, canceling existing tasks")

        /// Cancel any ongoing recognition and ensure clean state
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        /// Ensure audio engine is stopped and tap removed before restart
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        /// On macOS, we don't need to configure AVAudioSession
        /// The system handles audio routing automatically, but we may need to select a specific device

        /// Configure input device if specified
        if let deviceManager = audioDeviceManager,
           let deviceID = deviceManager.getSelectedInputDeviceID() {
            logger.debug("Configuring input device: \(deviceID)")
            deviceManager.configureAudioEngineInput(audioEngine, deviceID: deviceID)
        } else {
            logger.debug("Using system default input device")
        }

        /// Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()

        guard let recognitionRequest = recognitionRequest else {
            logger.error("Failed to create recognition request")
            throw VoiceError.recognitionRequestFailed
        }

        logger.debug("Recognition request created")

        recognitionRequest.shouldReportPartialResults = true

        /// Use on-device recognition if available
        if recognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
            logger.debug("Using on-device recognition")
        } else {
            logger.debug("On-device recognition not available, using server")
        }

        /// Get format from input node (use existing inputNode variable)
        logger.debug("Got input node, format: \(inputNode.outputFormat(forBus: 0))")

        /// Start recognition task
        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                Task { @MainActor in
                    self.logger.error("Recognition error: \(error)")
                }
            }

            var isFinal = false

            if let result = result {
                let transcription = result.bestTranscription.formattedString

                /// Calculate average confidence from segments
                let segments = result.bestTranscription.segments

                /// Log empty segments for debugging
                if segments.isEmpty {
                    Task { @MainActor in
                        self.logger.debug("Got result with NO segments (empty transcription)")
                    }
                    return
                }

                let avgConfidence = segments.map { $0.confidence }.reduce(0, +) / Float(segments.count)

                /// Accept transcriptions with confidence >= 0.2 (lowered from 0.3 for faster wake word detection)
                /// Wake word detection benefits from faster interim results, even if slightly less confident
                if avgConfidence >= 0.2 {
                    let isFinal = result.isFinal
                    DispatchQueue.main.async { [weak self] in
                        self?.logger.debug("Got transcription: '\(transcription)' (final: \(isFinal), confidence: \(avgConfidence))")
                        self?.partialTranscription = transcription
                        self?.onTranscriptionUpdate?(transcription, isFinal)
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.logger.debug("Ignoring low-confidence transcription: \(avgConfidence) < 0.2")
                    }
                }

                isFinal = result.isFinal
            }

            if error != nil {
                Task { @MainActor in
                    /// Check if error is just a task cancellation (happens during intentional stop)
                    let nsError = error! as NSError
                    let isCancellation = (nsError.domain == "kLSRErrorDomain" && nsError.code == 301) ||
                                       nsError.localizedDescription.contains("canceled")

                    if isCancellation {
                        self.logger.debug("Recognition task canceled (intentional stop)")
                        /// Task was canceled intentionally (stopListening called)
                    } else {
                        /// Real error - log and stop
                        self.logger.error("Recognition error, stopping: \(error!)")
                        self.stopListening()
                    }
                }
            }
            /// Note: We do NOT handle isFinal events
            /// Recognition task continues indefinitely
            /// State machine in VoiceManager controls wake word vs command logic
        }

        logger.debug("Recognition task started")

        /// Configure audio format and install tap with small buffer for minimal latency
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        /// Capture recognitionRequest directly to avoid accessing @MainActor property from audio thread
        /// SFSpeechAudioBufferRecognitionRequest.append() is thread-safe
        inputNode.installTap(onBus: 0, bufferSize: 512, format: recordingFormat) { [weak recognitionRequest, weak self] buffer, _ in
            recognitionRequest?.append(buffer)

            /// Calculate audio level for pause detection
            let channelData = buffer.floatChannelData?[0]
            let channelDataCount = Int(buffer.frameLength)

            if let data = channelData {
                var sum: Float = 0
                for i in 0..<channelDataCount {
                    sum += abs(data[i])
                }
                let averageLevel = sum / Float(channelDataCount)

                /// Use DispatchQueue instead of Task to avoid @MainActor isolation checks
                /// from audio thread callback
                DispatchQueue.main.async { [weak self] in
                    self?.onAudioLevelUpdate?(averageLevel)
                }
            }
        }

        logger.debug("Tap installed, starting audio engine")

        /// Start audio engine
        audioEngine.prepare()
        try audioEngine.start()

        logger.debug("Audio engine started successfully, isRunning: \(audioEngine.isRunning)")

        DispatchQueue.main.async { [weak self] in
            self?.isListening = true
            self?.transcribedText = ""
            self?.partialTranscription = ""
        }

        logger.debug("startListening complete, isListening=\(isListening)")
    }

    /// Stop listening
    public func stopListening() {
        logger.debug("stopListening called, isListening=\(isListening)")

        /// Stop recognition first (before audio engine) to prevent callbacks during shutdown
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        /// Stop audio engine and remove tap
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        /// Remove tap if installed
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        /// Finalize transcription
        let finalText = partialTranscription
        DispatchQueue.main.async { [weak self] in
            if !finalText.isEmpty {
                self?.transcribedText = finalText
            }
            self?.isListening = false
        }
        logger.debug("stopListening complete")
    }

    /// Pause listening temporarily (during TTS playback)
    public func pause() {
        guard isListening else { return }

        /// Pause audio engine to prevent capturing TTS output
        audioEngine.pause()
        logger.debug("Audio engine paused")
    }

    /// Resume listening after pause
    public func resume() {
        guard isListening else { return }

        /// Resume audio engine
        do {
            try audioEngine.start()
            logger.debug("Audio engine resumed")
        } catch {
            logger.error("Failed to resume audio engine: \(error)")
        }
    }

    /// Reset transcription state
    public func reset() {
        DispatchQueue.main.async { [weak self] in
            self?.transcribedText = ""
            self?.partialTranscription = ""
        }
    }
}

/// Voice-related errors
public enum VoiceError: Error {
    case notAuthorized
    case recognizerUnavailable
    case recognitionRequestFailed

    public var localizedDescription: String {
        switch self {
        case .notAuthorized:
            return "Microphone and speech recognition permissions not granted"
        case .recognizerUnavailable:
            return "Speech recognizer is not available"
        case .recognitionRequestFailed:
            return "Failed to create speech recognition request"
        }
    }
}
