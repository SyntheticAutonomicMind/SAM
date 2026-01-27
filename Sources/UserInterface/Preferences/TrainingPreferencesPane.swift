// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging
import Training

private let logger = Logger(label: "com.sam.training.preferences")

/// Preference pane for managing model fine-tuning and LoRA adapters
struct TrainingPreferencesPane: View {
    @State private var selectedTab: TrainingTab = .train
    
    enum TrainingTab: String, CaseIterable {
        case train = "Train"
        case adapters = "Adapters"
        
        var icon: String {
            switch self {
            case .train: return "brain.head.profile"
            case .adapters: return "list.bullet.rectangle"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab Selector
            HStack(spacing: 1) {
                ForEach(TrainingTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 14))
                            Text(tab.rawValue)
                                .fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.1) : Color.clear)
                        .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Tab Content
            ScrollView {
                Group {
                    switch selectedTab {
                    case .train:
                        TrainingTabView()
                    case .adapters:
                        AdaptersTabView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding()
            }
        }
    }
}

// MARK: - Training Tab

struct TrainingTabView: View {
    @State private var selectedDatasetURL: URL?
    @State private var selectedModelId: String = ""
    @State private var installedModels: [ModelTemplateScanner.ModelTemplate] = []
    @State private var isLoadingModels: Bool = false
    @State private var isTraining: Bool = false
    @State private var trainingProgress: Double = 0.0
    @State private var currentLoss: Float = 0.0
    @State private var currentEpoch: Int = 0
    @State private var currentStep: Int = 0
    @State private var totalSteps: Int = 0
    @State private var errorMessage: String?
    @State private var adapterName: String = ""
    
    // Training configuration (persisted with @AppStorage)
    @AppStorage("lora_training_rank") private var loraRank: Int = 8
    @AppStorage("lora_training_learning_rate") private var learningRateDouble: Double = 1e-4
    @AppStorage("lora_training_epochs") private var epochs: Int = 3
    @AppStorage("lora_training_batch_size") private var batchSize: Int = 4
    
    // MARK: - Dynamic Parameter Guidance
    
    /// Get available system memory in GB
    private var availableMemoryGB: Double {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        return Double(physicalMemory) / (1024.0 * 1024.0 * 1024.0)
    }
    
    /// Calculate safe maximum rank based on system memory and selected model
    private var recommendedMaxRank: Int {
        // Memory-based limits (conservative to avoid OOM)
        // 8GB RAM: rank 8-16
        // 16GB RAM: rank 16-32
        // 24GB RAM: rank 32-64
        // 32GB+ RAM: rank 64-128
        let memGB = availableMemoryGB
        if memGB < 12 { return 16 }
        else if memGB < 20 { return 32 }
        else if memGB < 28 { return 64 }
        else { return 128 }
    }
    
    /// Get dynamic rank guidance text
    private var rankGuidance: String {
        let maxSafe = recommendedMaxRank
        return "Higher rank = more capacity but more memory. Your system (\(Int(availableMemoryGB))GB RAM) can safely handle rank up to \(maxSafe)."
    }
    
    /// Get dynamic epochs guidance text based on dataset size
    private var epochsGuidance: String {
        return "More epochs = better learning. Start with 10-20, increase if final loss >0.5. Watch for overfitting at 50+."
    }
    
    /// Get dynamic batch size guidance text
    private var batchSizeGuidance: String {
        let memGB = availableMemoryGB
        let suggestedBatch: Int
        if memGB < 12 { suggestedBatch = 2 }
        else if memGB < 20 { suggestedBatch = 4 }
        else if memGB < 28 { suggestedBatch = 8 }
        else { suggestedBatch = 16 }
        
        return "Larger batch = faster training but more memory. Your system can handle batch size up to \(suggestedBatch). Use 1 if OOM occurs."
    }
    
    // Computed property to convert Double to Float for training
    private var learningRate: Float {
        get { Float(learningRateDouble) }
        set { learningRateDouble = Double(newValue) }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            Text("Train LoRA Adapter")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Fine-tune a local model on your training data")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Divider()
            
            // Training Progress - Prominently displayed at top when active
            if isTraining {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "brain.head.profile.fill")
                            .foregroundColor(.blue)
                        Text("Training in progress...")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Spacer()
                        
                        Text("\(Int(trainingProgress * 100))%")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                    }
                    
                    ProgressView(value: trainingProgress)
                        .tint(.blue)
                    
                    // Training stats
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Epoch")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(currentEpoch + 1)/\(epochs)")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Step")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(currentStep)/\(totalSteps)")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Loss")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.4f", currentLoss))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(currentLoss < 1.0 ? .green : .primary)
                        }
                    }
                    
                    // Cancel button in progress area
                    HStack {
                        Spacer()
                        Button("Cancel Training") {
                            cancelTraining()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
                .padding()
                .background(Color.blue.opacity(0.15))
                .cornerRadius(8)
            }
            
            // Error Message - Also prominently displayed at top
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }
            
            // Dataset Selection
            VStack(alignment: .leading, spacing: 12) {
                Label("Training Dataset", systemImage: "doc.text")
                    .font(.headline)
                
                HStack {
                    if let url = selectedDatasetURL {
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("No dataset selected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button("Choose JSONL File...") {
                        selectDataset()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            // Model Selection
            VStack(alignment: .leading, spacing: 12) {
                Label("Base Model", systemImage: "brain")
                    .font(.headline)
                
                Text("Select the model to fine-tune")
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
                        Text("No models found")
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
                    .disabled(selectedDatasetURL == nil)
                    
                    // Show model family
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
            .onAppear {
                loadInstalledModels()
            }
            
            // Adapter Name
            VStack(alignment: .leading, spacing: 12) {
                Label("Adapter Name", systemImage: "tag")
                    .font(.headline)
                
                TextField("Enter a name for this adapter", text: $adapterName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isTraining)
                
                Text("This name will identify your trained adapter")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            // Training Configuration (Editable)
            VStack(alignment: .leading, spacing: 16) {
                Label("Training Configuration", systemImage: "slider.horizontal.3")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Rank:")
                                .frame(width: 120, alignment: .leading)
                            Slider(value: Binding(
                                get: { Double(loraRank) },
                                set: { loraRank = Int($0) }
                            ), in: 4...128, step: 4)
                            Text("\(loraRank)")
                                .frame(width: 40, alignment: .trailing)
                        }
                        // Guidance removed - was confusing and inaccurate for all-layer training
                    }
                    
                    HStack {
                        Text("Learning Rate:")
                            .frame(width: 120, alignment: .leading)
                        TextField("Learning Rate", value: $learningRateDouble, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Epochs:")
                                .frame(width: 120, alignment: .leading)
                            Slider(value: Binding(
                                get: { Double(epochs) },
                                set: { epochs = Int($0) }
                            ), in: 1...50, step: 1)
                            Text("\(epochs)")
                                .frame(width: 40, alignment: .trailing)
                        }
                        // Guidance removed - user can adjust based on loss curve
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Batch Size:")
                                .frame(width: 120, alignment: .leading)
                            Slider(value: Binding(
                                get: { Double(batchSize) },
                                set: { batchSize = Int($0) }
                            ), in: 1...32, step: 1)
                            Text("\(batchSize)")
                                .frame(width: 40, alignment: .trailing)
                        }
                        // Guidance removed - memory limits vary by configuration
                    }
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            // Training Controls - Only show Start button when not training
            if !isTraining {
                HStack {
                    Spacer()
                    
                    Button("Start Training") {
                        startTraining()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedDatasetURL == nil || selectedModelId.isEmpty || adapterName.isEmpty)
                }
            }
            
            Spacer()
        }
    }
    
    private func selectDataset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Select a JSONL training dataset"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                selectedDatasetURL = url
                logger.info("Selected dataset", metadata: ["path": "\(url.path)"])
            }
        }
    }
    
    private func startTraining() {
        guard let datasetURL = selectedDatasetURL else { return }
        guard !selectedModelId.isEmpty else { return }
        
        isTraining = true
        trainingProgress = 0.0
        errorMessage = nil
        logger.info("Starting training", metadata: [
            "model": "\(selectedModelId)",
            "dataset": "\(datasetURL.lastPathComponent)"
        ])
        
        Task {
            do {
                // Get actual model path from template
                guard let modelTemplate = installedModels.first(where: { $0.id == selectedModelId }) else {
                    throw TrainingError.modelNotFound(selectedModelId)
                }
                
                let config = TrainingConfig(
                    rank: loraRank,
                    alpha: Float(loraRank) * 2.0,
                    learningRate: learningRate,
                    batchSize: batchSize,
                    epochs: epochs
                )
                
                // Detect model type and use appropriate training service
                if modelTemplate.path.hasSuffix(".gguf") {
                    // GGUF model - use GGUF training service
                    logger.info("Using GGUF training service", metadata: ["modelPath": "\(modelTemplate.path)"])
                    try await trainGGUFModel(
                        datasetURL: datasetURL,
                        modelTemplate: modelTemplate,
                        config: config
                    )
                } else {
                    // MLX model (SafeTensors) - use MLX training service
                    logger.info("Using MLX training service", metadata: ["modelPath": "\(modelTemplate.path)"])
                    try await trainMLXModel(
                        datasetURL: datasetURL,
                        modelTemplate: modelTemplate,
                        config: config
                    )
                }
            } catch {
                await MainActor.run {
                    isTraining = false
                    errorMessage = error.localizedDescription
                    logger.error("Training failed", metadata: [
                        "error": "\(error.localizedDescription)"
                    ])
                }
            }
        }
    }
    
    /// Train an MLX model (SafeTensors format)
    private func trainMLXModel(
        datasetURL: URL,
        modelTemplate: ModelTemplateScanner.ModelTemplate,
        config: TrainingConfig
    ) async throws {
        let service = MLXTrainingService()
        
        let adapter = try await service.startTraining(
            datasetURL: datasetURL,
            modelId: selectedModelId,
            modelPath: modelTemplate.path,
            config: config,
            adapterName: adapterName.isEmpty ? "Untitled Adapter" : adapterName
        ) { progress in
            MainActor.assumeIsolated {
                trainingProgress = progress.progress
                currentLoss = progress.loss
                currentEpoch = progress.epoch
                currentStep = progress.step
                totalSteps = progress.totalSteps
            }
        }
        
        // Save adapter
        try await AdapterManager.shared.saveAdapter(adapter)
        
        await MainActor.run {
            isTraining = false
            logger.info("MLX training complete", metadata: [
                "adapterId": "\(adapter.id)",
                "finalLoss": "\(adapter.metadata.finalLoss)"
            ])
        }
    }
    
    /// Train a GGUF model using Hugging Face Transformers + PEFT
    private func trainGGUFModel(
        datasetURL: URL,
        modelTemplate: ModelTemplateScanner.ModelTemplate,
        config: TrainingConfig
    ) async throws {
        // Check if we have HuggingFace model ID metadata
        let huggingFaceId: String
        if let metadata = await GGUFMetadataManager.shared.loadMetadata(for: modelTemplate.path) {
            huggingFaceId = metadata.huggingFaceModelId
            logger.info("Found HF metadata for GGUF model", metadata: [
                "ggufPath": "\(modelTemplate.path)",
                "hfId": "\(huggingFaceId)",
                "source": "\(metadata.notes ?? "local")"
            ])
        } else {
            // No metadata - show error
            await MainActor.run {
                isTraining = false
                errorMessage = """
                Could not determine the Hugging Face model ID for this GGUF model.
                
                Attempted to fetch metadata from Hugging Face but no matching repository was found.
                Please create a .metadata.json file next to the GGUF file specifying the base model.
                """
            }
            throw GGUFTrainingError.noHuggingFaceModelId
        }
        
        let service = GGUFTrainingService()
        
        let ggufPath = try await service.startTraining(
            datasetURL: datasetURL,
            ggufModelPath: modelTemplate.path,
            huggingFaceModelId: huggingFaceId,
            config: config,
            modelName: adapterName.isEmpty ? "Trained Model" : adapterName
        ) { progress in
            MainActor.assumeIsolated {
                trainingProgress = progress.progress
                currentLoss = progress.loss
                currentEpoch = progress.epoch
                currentStep = progress.step
                totalSteps = progress.totalSteps
            }
        }
        
        await MainActor.run {
            isTraining = false
            logger.info("GGUF training complete", metadata: [
                "ggufPath": "\(ggufPath)"
            ])
            
            // Training complete - error message cleared
            // Note: Success notification would be shown here in future UI enhancement
            errorMessage = nil
        }
    }
    
    private func cancelTraining() {
        isTraining = false
        trainingProgress = 0.0
        logger.info("Training cancelled")
    }
    
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

// MARK: - Adapters Tab

struct AdaptersTabView: View {
    @State private var adapters: [AdapterInfo] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("LoRA Adapters")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Manage your trained model adapters")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Divider()
            
            // Adapter list
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Installed Adapters", systemImage: "list.bullet.rectangle")
                        .font(.headline)
                    
                    Spacer()
                    
                    Button(action: loadAdapters) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                }
                
                if isLoading {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading adapters...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else if adapters.isEmpty {
                    Text("No adapters yet. Train a model to create one.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(adapters) { adapter in
                        AdapterRow(adapter: adapter, onDelete: {
                            deleteAdapter(adapter.id)
                        })
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            // Error message
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
            }
            
            Spacer()
        }
        .onAppear {
            loadAdapters()
        }
    }
    
    private func loadAdapters() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let loaded = try await AdapterManager.shared.listAdapters()
                await MainActor.run {
                    adapters = loaded
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
    
    private func deleteAdapter(_ id: String) {
        Task {
            do {
                try await AdapterManager.shared.deleteAdapter(id: id)
                await MainActor.run {
                    adapters.removeAll { $0.id == id }
                    logger.info("Adapter deleted", metadata: ["id": "\\(id)"])
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Adapter Row

struct AdapterRow: View {
    let adapter: AdapterInfo
    let onDelete: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(adapter.id)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text("Dataset: \(adapter.metadata.trainingDataset)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(formatDate(adapter.metadata.createdAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Text("Loss: \(String(format: "%.4f", adapter.metadata.finalLoss))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            HStack(spacing: 12) {
                // Training info
                HStack(spacing: 8) {
                    Text("Epochs: \(adapter.metadata.epochs)")
                    Text("•")
                    Text("Steps: \(adapter.metadata.trainingSteps)")
                    Text("•")
                    Text("LR: \(String(format: "%.0e", adapter.metadata.learningRate))")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                
                Spacer()
                
                // Actions
                HStack(spacing: 8) {
                    Button("Load in Chat") {
                        loadInChat(adapter.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    /// Load adapter in chat conversation
    /// Future enhancement: Integrate with chat UI to automatically load adapter
    private func loadInChat(_ adapterId: String) {
        logger.info("Load adapter in chat", metadata: ["id": "\(adapterId)"])
        // Implementation pending: Wire up to ChatWidget to set active adapter
    }
}

// MARK: - Preview

#Preview {
    TrainingPreferencesPane()
        .frame(width: 800, height: 600)
}
