import Foundation
import Logging

/// Actor that scans installed models and extracts their chat templates
public actor ModelTemplateScanner {
    private let logger = Logger(label: "com.sam.training.scanner")
    private var cachedModels: [ModelTemplate]?
    private var lastScanTime: Date?
    
    /// Represents a scanned model with its chat template
    public struct ModelTemplate: Identifiable, Sendable, Hashable {
        public let id: String  // Unique identifier (path-based)
        public let displayName: String  // Human-readable name
        public let chatTemplate: String  // Jinja2 template string
        public let modelFamily: String  // e.g., "Qwen", "Llama", "Mistral"
        public let modelType: String  // From config.json
        public let path: String  // Full path to model directory
        
        public init(
            id: String,
            displayName: String,
            chatTemplate: String,
            modelFamily: String,
            modelType: String,
            path: String
        ) {
            self.id = id
            self.displayName = displayName
            self.chatTemplate = chatTemplate
            self.modelFamily = modelFamily
            self.modelType = modelType
            self.path = path
        }
    }
    
    /// Decodable structures for parsing JSON config files
    private struct TokenizerConfig: Codable {
        let chatTemplate: String?
        let eosToken: String?
        let modelMaxLength: Int?
        
        enum CodingKeys: String, CodingKey {
            case chatTemplate = "chat_template"
            case eosToken = "eos_token"
            case modelMaxLength = "model_max_length"
        }
    }
    
    private struct ModelConfig: Codable {
        let modelType: String?
        let architectures: [String]?
        
        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case architectures
        }
    }
    
    public init() {}
    
    /// Scans all installed models and returns their templates
    /// - Parameter forceRescan: If true, ignores cache and rescans directory
    /// - Returns: Array of ModelTemplate structs
    public func scanInstalledModels(forceRescan: Bool = false) async -> [ModelTemplate] {
        // Return cached results if available and not forcing rescan
        if !forceRescan, let cached = cachedModels, let lastScan = lastScanTime {
            let timeSinceLastScan = Date().timeIntervalSince(lastScan)
            if timeSinceLastScan < 300 { // 5 minutes cache
                logger.debug("Returning cached models", metadata: ["count": "\(cached.count)"])
                return cached
            }
        }
        
        let modelsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sam/models")
        
        logger.info("Scanning models directory", metadata: ["path": "\(modelsPath.path)"])
        
        guard FileManager.default.fileExists(atPath: modelsPath.path) else {
            logger.warning("Models directory does not exist", metadata: ["path": "\(modelsPath.path)"])
            return []
        }
        
        var models: [ModelTemplate] = []
        
        do {
            let familyDirs = try FileManager.default.contentsOfDirectory(
                at: modelsPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            
            // First, scan for GGUF files in the models directory root
            for item in familyDirs {
                // Check if it's a .gguf file (not a directory)
                if item.pathExtension == "gguf" {
                    if let template = await parseGGUFFile(item) {
                        models.append(template)
                    }
                }
            }
            
            // Then scan subdirectories for MLX/SafeTensors models
            for familyDir in familyDirs {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: familyDir.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    continue
                }
                
                let familyName = familyDir.lastPathComponent
                
                // Skip managed directory
                if familyName == ".managed" {
                    continue
                }
                
                // Scan model directories within family
                let modelDirs = try FileManager.default.contentsOfDirectory(
                    at: familyDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                
                for modelDir in modelDirs {
                    // Check if this is a directory containing a GGUF file
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: modelDir.path, isDirectory: &isDirectory),
                       isDirectory.boolValue {
                        // Look for .gguf files in this directory
                        if let ggufFiles = try? FileManager.default.contentsOfDirectory(
                            at: modelDir,
                            includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]
                        ).filter({ $0.pathExtension == "gguf" }) {
                            for ggufFile in ggufFiles {
                                if let template = await parseGGUFFile(ggufFile, familyName: familyName) {
                                    models.append(template)
                                }
                            }
                        }
                        
                        // Also check for MLX model structure (tokenizer_config.json)
                        if let template = await parseModelDirectory(modelDir, familyName: familyName) {
                            models.append(template)
                        }
                    }
                }
            }
            
            logger.info("Scan complete", metadata: [
                "modelsFound": "\(models.count)",
                "families": "\(Set(models.map { $0.modelFamily }).count)"
            ])
            
            // Cache results
            cachedModels = models
            lastScanTime = Date()
            
            return models.sorted { $0.displayName < $1.displayName }
            
        } catch {
            logger.error("Failed to scan models directory", metadata: [
                "error": "\(error.localizedDescription)",
                "path": "\(modelsPath.path)"
            ])
            return []
        }
    }
    
    /// Get template for a specific model ID
    /// - Parameter modelId: The model ID to look up
    /// - Returns: The chat template string if found
    public func getTemplate(for modelId: String) async -> String? {
        let models = await scanInstalledModels()
        return models.first { $0.id == modelId }?.chatTemplate
    }
    
    /// Parse a single model directory and extract template
    private func parseModelDirectory(_ modelDir: URL, familyName: String) async -> ModelTemplate? {
        let tokenizerConfigPath = modelDir.appendingPathComponent("tokenizer_config.json")
        let configPath = modelDir.appendingPathComponent("config.json")
        
        // Must have tokenizer_config.json
        guard FileManager.default.fileExists(atPath: tokenizerConfigPath.path) else {
            logger.debug("No tokenizer_config.json found", metadata: ["path": "\(modelDir.path)"])
            return nil
        }
        
        do {
            // Parse tokenizer config
            let tokenizerData = try Data(contentsOf: tokenizerConfigPath)
            let tokenizerConfig = try JSONDecoder().decode(TokenizerConfig.self, from: tokenizerData)
            
            guard let chatTemplate = tokenizerConfig.chatTemplate else {
                logger.debug("No chat_template in tokenizer_config.json", metadata: ["path": "\(modelDir.path)"])
                return nil
            }
            
            // Parse model config for metadata
            var modelType = "unknown"
            if FileManager.default.fileExists(atPath: configPath.path) {
                let configData = try Data(contentsOf: configPath)
                let modelConfig = try JSONDecoder().decode(ModelConfig.self, from: configData)
                modelType = modelConfig.modelType ?? "unknown"
            }
            
            let modelName = modelDir.lastPathComponent
            let modelId = "\(familyName)/\(modelName)"
            
            logger.debug("Found model with template", metadata: [
                "id": "\(modelId)",
                "type": "\(modelType)",
                "templateLength": "\(chatTemplate.count)"
            ])
            
            return ModelTemplate(
                id: modelId,
                displayName: modelName,
                chatTemplate: chatTemplate,
                modelFamily: familyName,
                modelType: modelType,
                path: modelDir.path
            )
            
        } catch {
            logger.error("Failed to parse model config", metadata: [
                "error": "\(error.localizedDescription)",
                "path": "\(modelDir.path)"
            ])
            return nil
        }
    }
    
    /// Parse a GGUF file and create a template entry
    private func parseGGUFFile(_ ggufPath: URL, familyName: String = "GGUF") async -> ModelTemplate? {
        let modelName = ggufPath.deletingPathExtension().lastPathComponent
        let modelId = "\(familyName)/\(modelName)"
        
        // GGUF models use a generic chat template since they don't have tokenizer configs
        // The actual template will be determined at runtime by the LlamaProvider
        let genericTemplate = """
        {{ bos_token }}{% for message in messages %}{% if message['role'] == 'user' %}{{ 'User: ' + message['content'] + '\\n' }}{% elif message['role'] == 'assistant' %}{{ 'Assistant: ' + message['content'] + '\\n' }}{% endif %}{% endfor %}{% if add_generation_prompt %}{{ 'Assistant: ' }}{% endif %}
        """
        
        logger.debug("Found GGUF model", metadata: [
            "id": "\(modelId)",
            "path": "\(ggufPath.path)",
            "family": "\(familyName)"
        ])
        
        return ModelTemplate(
            id: modelId,
            displayName: modelName,
            chatTemplate: genericTemplate,
            modelFamily: familyName,
            modelType: "gguf",
            path: ggufPath.path
        )
    }
    
    /// Clear cached model data (useful for testing)
    public func clearCache() {
        cachedModels = nil
        lastScanTime = nil
        logger.debug("Cache cleared")
    }
}
