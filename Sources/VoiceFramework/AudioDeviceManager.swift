// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import AVFoundation
import AppKit
import CoreAudio
import Logging
import Combine

/// Represents an audio device (input or output)
public struct AudioDevice: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let isInput: Bool
    public let isOutput: Bool

    public init(id: AudioDeviceID, name: String, uid: String, isInput: Bool, isOutput: Bool) {
        self.id = id
        self.name = name
        self.uid = uid
        self.isInput = isInput
        self.isOutput = isOutput
    }
}

/// Represents a macOS native voice
public struct NativeVoice: Identifiable, Hashable {
    public let id: String  /// Voice identifier (e.g., "com.apple.speech.synthesis.voice.samantha")
    public let name: String  /// Display name (e.g., "Samantha")
    public let language: String  /// Locale identifier (e.g., "en_US")

    public var displayName: String {
        let langName = Locale.current.localizedString(forIdentifier: language) ?? language
        return "\(name) (\(langName))"
    }
}

/// Manages audio device enumeration and selection
/// Thread-safe: Can be accessed from any thread, @Published updates dispatched to main
/// @unchecked Sendable: Class uses DispatchQueue.main.async for all state updates
public class AudioDeviceManager: ObservableObject, @unchecked Sendable {
    private let logger = Logger(label: "com.sam.audio.devices")

    /// Available input devices
    @Published public private(set) var inputDevices: [AudioDevice] = []

    /// Available output devices
    @Published public private(set) var outputDevices: [AudioDevice] = []

    /// Selected input device UID (nil = system default)
    @Published public var selectedInputDeviceUID: String? {
        didSet {
            UserDefaults.standard.set(selectedInputDeviceUID, forKey: "sam.audio.inputDeviceUID")
            logger.info("Input device changed to: \(selectedInputDeviceUID ?? "Auto")")
        }
    }

    /// Selected output device UID (nil = system default)
    @Published public var selectedOutputDeviceUID: String? {
        didSet {
            UserDefaults.standard.set(selectedOutputDeviceUID, forKey: "sam.audio.outputDeviceUID")
            logger.info("Output device changed to: \(selectedOutputDeviceUID ?? "Auto")")
        }
    }

    /// Selected voice identifier (nil = system default)
    @Published public var selectedVoiceIdentifier: String? {
        didSet {
            UserDefaults.standard.set(selectedVoiceIdentifier, forKey: "sam.audio.voiceIdentifier")
            logger.info("Voice changed to: \(selectedVoiceIdentifier ?? "Auto")")
        }
    }

    /// Speech rate multiplier (0.5 = slow, 1.0 = normal, 1.5 = fast)
    @Published public var speechRate: Float = 0.95 {
        didSet {
            UserDefaults.standard.set(speechRate, forKey: "sam.audio.speechRate")
            logger.info("Speech rate changed to: \(speechRate)")
        }
    }

    /// Available system voices (native macOS voices via NSSpeechSynthesizer)
    @Published public private(set) var availableVoices: [NativeVoice] = []

    public init() {
        /// Load saved preferences
        selectedInputDeviceUID = UserDefaults.standard.string(forKey: "sam.audio.inputDeviceUID")
        selectedOutputDeviceUID = UserDefaults.standard.string(forKey: "sam.audio.outputDeviceUID")
        selectedVoiceIdentifier = UserDefaults.standard.string(forKey: "sam.audio.voiceIdentifier")

        /// Load speech rate with default of 0.95 (slightly slower than default for natural sound)
        if UserDefaults.standard.object(forKey: "sam.audio.speechRate") != nil {
            speechRate = UserDefaults.standard.float(forKey: "sam.audio.speechRate")
        }

        /// Enumerate devices
        refreshDevices()
        refreshVoices()

        /// Listen for device changes
        setupDeviceChangeListener()
    }

    /// Refresh the list of available audio devices
    public func refreshDevices() {
        let inputs = getAudioDevices(isInput: true)
        let outputs = getAudioDevices(isInput: false)
        DispatchQueue.main.async { [weak self] in
            self?.inputDevices = inputs
            self?.outputDevices = outputs
            self?.logger.info("Found \(inputs.count) input devices, \(outputs.count) output devices")
        }
    }

    /// Refresh the list of available voices using native macOS API
    /// Note: NSSpeechSynthesizer is deprecated in macOS 14 but provides more reliable voice enumeration
    public func refreshVoices() {
        let voices = NSSpeechSynthesizer.availableVoices

        let voiceList: [NativeVoice] = voices.compactMap { voiceName in
            let attrs = NSSpeechSynthesizer.attributes(forVoice: voiceName)
            guard let name = attrs[.name] as? String,
                  let language = attrs[.localeIdentifier] as? String else {
                return nil
            }
            return NativeVoice(id: voiceName.rawValue, name: name, language: language)
        }
        .filter { $0.language.hasPrefix("en") }
        .sorted { $0.name < $1.name }

        DispatchQueue.main.async { [weak self] in
            self?.availableVoices = voiceList
            self?.logger.info("Found \(voiceList.count) English voices via NSSpeechSynthesizer")
        }
    }

    /// Get the selected input device ID (or 0 for system default)
    public func getSelectedInputDeviceID() -> AudioDeviceID? {
        guard let uid = selectedInputDeviceUID else { return nil }
        return inputDevices.first { $0.uid == uid }?.id
    }

    /// Get the selected output device ID (or 0 for system default)
    public func getSelectedOutputDeviceID() -> AudioDeviceID? {
        guard let uid = selectedOutputDeviceUID else { return nil }
        return outputDevices.first { $0.uid == uid }?.id
    }

    // MARK: - Private Methods

    private func getAudioDevices(isInput: Bool) -> [AudioDevice] {
        var devices: [AudioDevice] = []

        /// Get the list of all audio devices
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else {
            logger.error("Failed to get audio devices size: \(status)")
            return devices
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else {
            logger.error("Failed to get audio devices: \(status)")
            return devices
        }

        /// Filter and get device info
        for deviceID in deviceIDs {
            /// Check if device has input/output streams
            let hasInput = deviceHasStreams(deviceID: deviceID, isInput: true)
            let hasOutput = deviceHasStreams(deviceID: deviceID, isInput: false)

            /// Skip if device doesn't match requested type
            if isInput && !hasInput { continue }
            if !isInput && !hasOutput { continue }

            /// Get device name
            guard let name = getDeviceName(deviceID: deviceID) else { continue }

            /// Get device UID
            guard let uid = getDeviceUID(deviceID: deviceID) else { continue }

            let device = AudioDevice(
                id: deviceID,
                name: name,
                uid: uid,
                isInput: hasInput,
                isOutput: hasOutput
            )
            devices.append(device)
        }

        return devices.sorted { $0.name < $1.name }
    }

    private func deviceHasStreams(deviceID: AudioDeviceID, isInput: Bool) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        return status == noErr && dataSize > 0
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &name
        )

        guard status == noErr, let deviceName = name?.takeUnretainedValue() else {
            return nil
        }

        return deviceName as String
    }

    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &uid
        )

        guard status == noErr, let deviceUID = uid?.takeUnretainedValue() else {
            return nil
        }

        return deviceUID as String
    }

    private func setupDeviceChangeListener() {
        /// Listen for audio device configuration changes
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        /// C-style callback to avoid Swift concurrency checks
        /// Must not capture any Swift variables - only use raw clientData pointer
        let callback: AudioObjectPropertyListenerProc = { (_, _, _, clientData) -> OSStatus in
            /// Immediately dispatch to main without capturing - pass pointer as bits
            if let ptr = clientData {
                let ptrBits = unsafeBitCast(ptr, to: UInt.self)
                DispatchQueue.main.async {
                    let reconstructed = unsafeBitCast(ptrBits, to: UnsafeRawPointer.self)
                    let manager = Unmanaged<AudioDeviceManager>.fromOpaque(reconstructed).takeUnretainedValue()
                    manager.refreshDevices()
                }
            }
            return noErr
        }

        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            callback,
            selfPtr
        )
    }

    /// Set the input device for an AVAudioEngine
    public func configureAudioEngineInput(_ audioEngine: AVAudioEngine, deviceID: AudioDeviceID?) {
        #if os(macOS)
        guard let deviceID = deviceID else {
            logger.debug("Using system default input device")
            return
        }

        /// Get the audio unit from the input node
        let inputNode = audioEngine.inputNode
        let audioUnit = inputNode.audioUnit

        guard let audioUnit = audioUnit else {
            logger.error("Failed to get audio unit from input node")
            return
        }

        /// Set the input device
        var deviceIDVar = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceIDVar,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status == noErr {
            logger.info("Set input device to ID: \(deviceID)")
        } else {
            logger.error("Failed to set input device: \(status)")
        }
        #endif
    }
}
