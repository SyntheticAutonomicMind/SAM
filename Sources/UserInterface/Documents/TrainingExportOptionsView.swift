// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import SwiftUI
import Training

/// Configuration view for training data export options
/// Allows users to customize chat template, PII settings, and content inclusion
struct TrainingExportOptionsView: View {
    @Binding var isPresented: Bool
    let onExport: (TrainingDataModels.ExportOptions) -> Void
    
    @State private var selectedTemplate: ChatTemplate = .llama3
    @State private var selectedModelId: String = ""
    @State private var installedModels: [ModelTemplateScanner.ModelTemplate] = []
    @State private var isLoadingModels: Bool = false
    @State private var stripPII: Bool = true  // Enable by default for privacy
    @State private var includeSystemPrompts: Bool = false
    @State private var includeToolCalls: Bool = true
    @State private var includeThinkTags: Bool = true
    @State private var selectedPIIEntities: Set<PIIDetector.PIIEntity> = Set(PIIDetector.PIIEntity.allCases)  // All entities by default
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Training Data Export Options")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Configure how your conversation will be formatted for LLM training")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Target Model Section
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Target Model", systemImage: "brain")
                            .font(.headline)
                        
                        Text("Select the installed model to use its chat template")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if isLoadingModels {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Scanning installed models...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 8)
                        } else if installedModels.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("No models with chat templates found")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Text("Models should be installed at ~/Library/Caches/sam/models/")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 8)
                        } else {
                            Picker("Model", selection: $selectedModelId) {
                                ForEach(installedModels) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                            }
                            .pickerStyle(.menu)
                            
                            // Show model family and type
                            if let selectedModel = installedModels.first(where: { $0.id == selectedModelId }) {
                                HStack(spacing: 16) {
                                    Text("Family: \(selectedModel.modelFamily)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    
                                    if selectedModel.modelType != "unknown" {
                                        Text("Type: \(selectedModel.modelType)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.leading, 8)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                    
                    // Content Inclusion Section
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Content Inclusion", systemImage: "checkmark.circle")
                            .font(.headline)
                        
                        Toggle("Include Tool Calls", isOn: $includeToolCalls)
                            .help("Include tool execution details in the training data")
                        
                        Toggle("Include Sequential Thinking", isOn: $includeThinkTags)
                            .help("Include <think> tagged reasoning content")
                        
                        Toggle("Include System Prompts", isOn: $includeSystemPrompts)
                            .help("Include system-level instructions in each example")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                    
                    // PII Protection Section
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Privacy Protection", systemImage: "lock.shield")
                            .font(.headline)
                        
                        Toggle("Enable PII Detection & Redaction", isOn: $stripPII)
                            .help("Automatically detect and redact personally identifiable information")
                        
                        if stripPII {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Entities to Redact:")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                ForEach(PIIDetector.PIIEntity.allCases, id: \.self) { entity in
                                    Toggle(entity.rawValue, isOn: Binding(
                                        get: { selectedPIIEntities.contains(entity) },
                                        set: { isSelected in
                                            if isSelected {
                                                selectedPIIEntities.insert(entity)
                                            } else {
                                                selectedPIIEntities.remove(entity)
                                            }
                                        }
                                    ))
                                    .font(.caption)
                                }
                            }
                            .padding(.leading, 16)
                            .padding(.top, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                    
                    // Info Section
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Export Format", systemImage: "info.circle")
                            .font(.headline)
                        
                        Text("Your conversation will be exported as JSONL (JSON Lines) format, with one training example per line. This format is compatible with most LLM training frameworks including llama.cpp, Hugging Face Transformers, and MLX.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            .frame(maxHeight: 400)
            
            // Action Buttons
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Export") {
                    // Get the custom template if a model is selected
                    let customTemplate = installedModels.first(where: { $0.id == selectedModelId })?.chatTemplate
                    
                    let options = TrainingDataModels.ExportOptions(
                        stripPII: stripPII,
                        includeSystemPrompts: includeSystemPrompts,
                        includeToolCalls: includeToolCalls,
                        includeThinkTags: includeThinkTags,
                        selectedPIIEntities: selectedPIIEntities,
                        template: selectedTemplate,
                        modelId: selectedModelId.isEmpty ? nil : selectedModelId,
                        customTemplate: customTemplate,
                        outputFormat: .jsonl
                    )
                    onExport(options)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(installedModels.isEmpty)  // Disable if no models found
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear {
            loadInstalledModels()
        }
    }
    
    /// Load installed models on view appearance
    private func loadInstalledModels() {
        isLoadingModels = true
        Task {
            let scanner = ModelTemplateScanner()
            let models = await scanner.scanInstalledModels()
            await MainActor.run {
                installedModels = models
                if let first = models.first {
                    selectedModelId = first.id
                }
                isLoadingModels = false
            }
        }
    }
}
