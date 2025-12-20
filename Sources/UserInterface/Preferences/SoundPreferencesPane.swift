// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import AVFoundation
import AppKit
import VoiceFramework
import Logging

private let logger = Logger(label: "com.sam.preferences.sound")

/// Native macOS speech synthesizer wrapper for testing voices
class NativeSpeechTester: NSObject, NSSpeechSynthesizerDelegate {
    private var synthesizer: NSSpeechSynthesizer?
    var onComplete: (() -> Void)?

    func speak(_ text: String, voiceName: String?) {
        /// Stop any existing speech
        synthesizer?.stopSpeaking()

        /// Create new synthesizer
        if let voiceName = voiceName {
            synthesizer = NSSpeechSynthesizer(voice: NSSpeechSynthesizer.VoiceName(rawValue: voiceName))
        } else {
            synthesizer = NSSpeechSynthesizer()
        }
        synthesizer?.delegate = self
        synthesizer?.startSpeaking(text)
    }

    func stop() {
        synthesizer?.stopSpeaking()
    }

    /// NSSpeechSynthesizerDelegate
    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        onComplete?()
    }
}

/// Preferences pane for audio input, output, and voice settings
struct SoundPreferencesPane: View {
    /// Use VoiceManager.shared.audioDeviceManager to ensure settings affect the actual speech synthesis
    @ObservedObject private var audioManager = VoiceManager.shared.audioDeviceManager
    @State private var testingSpeech = false
    @State private var nativeTester = NativeSpeechTester()
    @State private var showingVoiceHelp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                /// Header
                Text("Sound Settings")
                    .font(.title)
                    .fontWeight(.semibold)
                    .padding(.bottom, 4)

                /// Input Device Section
                inputDeviceSection

                Divider()

                /// Output Device Section
                outputDeviceSection

                Divider()

                /// Voice Section
                voiceSection
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            nativeTester.onComplete = {
                Task { @MainActor in
                    testingSpeech = false
                }
            }
        }
        .sheet(isPresented: $showingVoiceHelp) {
            VoiceDownloadHelpView()
        }
    }

    // MARK: - Input Device Section

    private var inputDeviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "mic.fill")
                    .foregroundColor(.blue)
                Text("Input Device")
                    .font(.headline)
            }

            Text("Select the microphone to use for voice input and wake word detection.")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Input Device", selection: Binding(
                get: { audioManager.selectedInputDeviceUID ?? "" },
                set: { audioManager.selectedInputDeviceUID = $0.isEmpty ? nil : $0 }
            )) {
                Text("Auto (System Default)")
                    .tag("")

                ForEach(audioManager.inputDevices) { device in
                    Text(device.name)
                        .tag(device.uid)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 400)

            if audioManager.inputDevices.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("No input devices found. Connect a microphone to enable voice input.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Button(action: { audioManager.refreshDevices() }) {
                Label("Refresh Devices", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.link)
        }
    }

    // MARK: - Output Device Section

    private var outputDeviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(.green)
                Text("Output Device")
                    .font(.headline)
            }

            Text("Select the speaker or headphones for SAM's voice responses.")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Output Device", selection: Binding(
                get: { audioManager.selectedOutputDeviceUID ?? "" },
                set: { audioManager.selectedOutputDeviceUID = $0.isEmpty ? nil : $0 }
            )) {
                Text("Auto (System Default)")
                    .tag("")

                ForEach(audioManager.outputDevices) { device in
                    Text(device.name)
                        .tag(device.uid)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 400)
        }
    }

    // MARK: - Voice Section

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundColor(.purple)
                Text("Voice")
                    .font(.headline)
            }

            Text("Select the voice for SAM's spoken responses.")
                .font(.caption)
                .foregroundColor(.secondary)

            /// Voice picker using native macOS voices
            Picker("Voice", selection: Binding(
                get: { audioManager.selectedVoiceIdentifier ?? "" },
                set: { audioManager.selectedVoiceIdentifier = $0.isEmpty ? nil : $0 }
            )) {
                Text("Auto (System Default)")
                    .tag("")

                ForEach(audioManager.availableVoices) { voice in
                    Text(voice.displayName)
                        .tag(voice.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 400)

            /// Speech rate slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Speech Rate")
                        .font(.subheadline)
                    Spacer()
                    Text(speechRateLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Slider(
                    value: $audioManager.speechRate,
                    in: 0.5...1.5,
                    step: 0.05
                ) {
                    Text("Speech Rate")
                } minimumValueLabel: {
                    Text("Slow")
                        .font(.caption2)
                } maximumValueLabel: {
                    Text("Fast")
                        .font(.caption2)
                }
                .frame(maxWidth: 400)
            }

            HStack(spacing: 16) {
                Button(action: testVoice) {
                    HStack {
                        if testingSpeech {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("Test Voice")
                    }
                }
                .disabled(testingSpeech)

                Button(action: stopTestVoice) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!testingSpeech)

                Button(action: { audioManager.refreshVoices() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.link)
            }

            /// Help for downloading more voices
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Want More Natural Voices?", systemImage: "info.circle")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Button("Show Instructions") {
                            showingVoiceHelp = true
                        }
                        .buttonStyle(.link)
                    }

                    Text("macOS includes many high-quality voices that can be downloaded for free. Premium voices like Samantha (Enhanced) or Zoe sound much more natural.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(8)
            }
        }
    }

    /// Human-readable label for current speech rate
    private var speechRateLabel: String {
        let rate = audioManager.speechRate
        if rate < 0.75 {
            return "Very Slow"
        } else if rate < 0.9 {
            return "Slow"
        } else if rate < 1.05 {
            return "Normal"
        } else if rate < 1.25 {
            return "Fast"
        } else {
            return "Very Fast"
        }
    }

    func testVoice() {
        testingSpeech = true
        let voiceId = audioManager.selectedVoiceIdentifier
        nativeTester.speak(
            "Hello! I'm SAM, your AI assistant. How can I help you today?",
            voiceName: voiceId
        )
    }

    private func stopTestVoice() {
        nativeTester.stop()
        testingSpeech = false
    }
}

/// Help view for downloading premium voices
struct VoiceDownloadHelpView: View {
    @Environment(\.dismiss) private var dismiss

    /// Get the appropriate Apple support URL based on macOS version
    private var appleVoiceDocsURL: URL {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let majorVersion = version.majorVersion

        /// macOS 15 (Sequoia) and later use different URL format
        if majorVersion >= 15 {
            return URL(string: "https://support.apple.com/guide/mac-help/mchlp2290/\(majorVersion).0/mac/\(majorVersion).0")!
        } else if majorVersion >= 13 {
            /// macOS 13 (Ventura) and 14 (Sonoma)
            return URL(string: "https://support.apple.com/guide/mac-help/mchlp2290/mac")!
        } else {
            /// Older versions - fallback to generic page
            return URL(string: "https://support.apple.com/guide/mac-help/mchlp2290/mac")!
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Download Premium Voices")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("macOS includes many high-quality voices that sound much more natural than the default voices.")
                    .font(.body)

                Text("You can download additional voices in System Settings. Apple's documentation explains how to manage and download voices for your version of macOS.")
                    .font(.body)
                    .foregroundColor(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Recommended Voices", systemImage: "star.fill")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Text("Look for voices marked 'Premium' or 'Enhanced' for the most natural sound. Popular choices include Samantha (Enhanced), Zoe, and Ava.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                }
            }

            Divider()

            Text("After downloading new voices, click 'Refresh' in the Sound preferences to see them in SAM's voice dropdown.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button("View Apple Docs") {
                    NSWorkspace.shared.open(appleVoiceDocsURL)
                }
                .buttonStyle(.link)

                Spacer()

                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Done") {
                    dismiss()
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

#Preview {
    SoundPreferencesPane()
        .frame(width: 600, height: 800)
}
