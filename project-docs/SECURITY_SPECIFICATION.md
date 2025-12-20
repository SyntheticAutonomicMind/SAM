<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# SAM: Security Specification

## Overview

This document defines the comprehensive security architecture for SAM, designed to provide robust protection while maintaining the user-friendly interface and transparent operation principles established in the SAM specifications. Security is implemented as an invisible layer that protects users without requiring technical knowledge.

## Core Security Principles

### 1. Invisible Protection
- **Zero User Configuration**: Security works automatically without user setup
- **Transparent Operation**: Users aren't burdened with security decisions
- **Smart Defaults**: Maximum protection enabled by default
- **Progressive Security**: Advanced options available when needed

### 2. Privacy by Design
- **Local-First Processing**: Sensitive operations performed locally when possible
- **Minimal Data Collection**: Only collect data necessary for functionality
- **User Control**: Clear controls for data sharing and storage
- **Encryption Everywhere**: All data encrypted at rest and in transit

### 3. Defense in Depth
- **Multiple Security Layers**: No single point of failure
- **Proactive Protection**: Prevent attacks before they occur
- **Adaptive Response**: Security measures adjust to threat levels
- **Continuous Monitoring**: Real-time threat detection and response

## Security Architecture

### Security Manager System
```swift
class SecurityManager: ObservableObject {
    @Published var securityStatus: SecurityStatus = .protected
    @Published var threatLevel: ThreatLevel = .low
    @Published var activeProtections: [SecurityProtection] = []
    
    private let encryptionManager: EncryptionManager
    private let accessControlManager: AccessControlManager
    private let threatDetectionEngine: ThreatDetectionEngine
    private let privacyManager: PrivacyManager
    
    func initialize() async throws {
        // Initialize security systems silently
        try await setupEncryption()
        try await configureAccessControls()
        try await startThreatMonitoring()
        try await enablePrivacyProtections()
        
        // Update security status
        await updateSecurityStatus()
    }
    
    private func setupEncryption() async throws {
        // Set up encryption for all data automatically
        try await encryptionManager.initializeEncryption()
        
        // Enable database encryption
        try await encryptionManager.enableDatabaseEncryption()
        
        // Configure API communication encryption
        try await encryptionManager.configureAPIEncryption()
    }
    
    private func configureAccessControls() async throws {
        // Set up automatic permission management
        try await accessControlManager.initializePermissionSystem()
        
        // Configure tool access controls
        try await accessControlManager.setupToolPermissions()
        
        // Enable sandbox security
        try await accessControlManager.enableSandboxSecurity()
    }
    
    private func startThreatMonitoring() async throws {
        // Begin monitoring for threats
        try await threatDetectionEngine.startMonitoring()
        
        // Set up behavioral analysis
        try await threatDetectionEngine.enableBehavioralAnalysis()
        
        // Configure anomaly detection
        try await threatDetectionEngine.setupAnomalyDetection()
    }
    
    private func enablePrivacyProtections() async throws {
        // Configure data minimization
        try await privacyManager.enableDataMinimization()
        
        // Set up local processing preferences
        try await privacyManager.configureLocalProcessing()
        
        // Enable data retention policies
        try await privacyManager.setupRetentionPolicies()
    }
}

enum SecurityStatus {
    case protected      // All systems secure
    case monitoring     // Actively monitoring threats
    case responding     // Responding to security event
    case compromised    // Security breach detected
}

enum ThreatLevel {
    case low           // Normal operation
    case elevated      // Potential threats detected
    case high          // Active threats present
    case critical      // Immediate action required
}
```

## Data Protection

### Encryption System
```swift
class EncryptionManager {
    private let keyManager: KeyManager
    private let databaseEncryption: DatabaseEncryption
    private let communicationEncryption: CommunicationEncryption
    
    func initializeEncryption() async throws {
        // Generate or retrieve master encryption key
        let masterKey = try await keyManager.getMasterKey()
        
        // Initialize encryption systems
        try await databaseEncryption.initialize(with: masterKey)
        try await communicationEncryption.initialize(with: masterKey)
        
        // Test encryption functionality
        try await validateEncryptionSystems()
    }
    
    func encryptSensitiveData(_ data: Data, classification: DataClassification) async throws -> EncryptedData {
        let encryptionLevel = getEncryptionLevel(for: classification)
        
        switch encryptionLevel {
        case .standard:
            return try await standardEncrypt(data)
        case .enhanced:
            return try await enhancedEncrypt(data)
        case .maximum:
            return try await maximumEncrypt(data)
        }
    }
    
    private func standardEncrypt(_ data: Data) async throws -> EncryptedData {
        // AES-256-GCM encryption for standard data
        let key = try await keyManager.getDataEncryptionKey()
        let encryptedData = try AES.GCM.seal(data, using: key)
        
        return EncryptedData(
            data: encryptedData.combined!,
            algorithm: .aes256gcm,
            keyReference: key.keyID
        )
    }
    
    private func enhancedEncrypt(_ data: Data) async throws -> EncryptedData {
        // Double encryption for enhanced security
        let standardEncrypted = try await standardEncrypt(data)
        return try await standardEncrypt(standardEncrypted.data)
    }
    
    private func maximumEncrypt(_ data: Data) async throws -> EncryptedData {
        // Multi-layer encryption with key splitting
        let encryptionKey1 = try await keyManager.generateEphemeralKey()
        let encryptionKey2 = try await keyManager.generateEphemeralKey()
        
        // First layer encryption
        let firstLayer = try AES.GCM.seal(data, using: encryptionKey1)
        
        // Second layer encryption with different key
        let secondLayer = try AES.GCM.seal(firstLayer.combined!, using: encryptionKey2)
        
        // Store keys separately
        try await keyManager.storeKeySecurely(encryptionKey1, reference: "max_enc_key1")
        try await keyManager.storeKeySecurely(encryptionKey2, reference: "max_enc_key2")
        
        return EncryptedData(
            data: secondLayer.combined!,
            algorithm: .multiLayerAES,
            keyReference: "max_enc_keys"
        )
    }
}

enum DataClassification {
    case public         // No encryption needed
    case internal       // Standard encryption
    case confidential   // Enhanced encryption
    case restricted     // Maximum encryption
}

struct EncryptedData {
    let data: Data
    let algorithm: EncryptionAlgorithm
    let keyReference: String
    let timestamp: Date = Date()
}

enum EncryptionAlgorithm: String {
    case aes256gcm = "AES-256-GCM"
    case multiLayerAES = "Multi-Layer-AES"
    case postQuantum = "Post-Quantum"
}
```

### Secure Storage
```swift
class SecureStorageManager {
    private let keychain: KeychainManager
    private let encryptedFileSystem: EncryptedFileSystem
    private let secureDatabase: SecureDatabase
    
    func storeSecurely<T: Codable>(_ item: T, identifier: String, classification: DataClassification) async throws {
        let data = try JSONEncoder().encode(item)
        let classifiedData = ClassifiedData(data: data, classification: classification)
        
        switch classification {
        case .public:
            try await storeInUserDefaults(classifiedData, identifier: identifier)
        case .internal:
            try await storeInEncryptedDatabase(classifiedData, identifier: identifier)
        case .confidential:
            try await storeInEncryptedFileSystem(classifiedData, identifier: identifier)
        case .restricted:
            try await storeInKeychain(classifiedData, identifier: identifier)
        }
    }
    
    func retrieveSecurely<T: Codable>(_ type: T.Type, identifier: String) async throws -> T? {
        // Try different storage locations based on security level
        if let data = try await retrieveFromKeychain(identifier: identifier) {
            return try JSONDecoder().decode(type, from: data)
        }
        
        if let data = try await retrieveFromEncryptedFileSystem(identifier: identifier) {
            return try JSONDecoder().decode(type, from: data)
        }
        
        if let data = try await retrieveFromEncryptedDatabase(identifier: identifier) {
            return try JSONDecoder().decode(type, from: data)
        }
        
        if let data = try await retrieveFromUserDefaults(identifier: identifier) {
            return try JSONDecoder().decode(type, from: data)
        }
        
        return nil
    }
    
    private func storeInKeychain(_ data: ClassifiedData, identifier: String) async throws {
        // Use Keychain for most sensitive data
        try await keychain.store(data.data, identifier: identifier)
    }
    
    private func storeInEncryptedFileSystem(_ data: ClassifiedData, identifier: String) async throws {
        // Use encrypted file system for confidential data
        try await encryptedFileSystem.write(data.data, to: identifier)
    }
    
    private func storeInEncryptedDatabase(_ data: ClassifiedData, identifier: String) async throws {
        // Use encrypted database for internal data
        try await secureDatabase.save(data.data, identifier: identifier)
    }
    
    private func storeInUserDefaults(_ data: ClassifiedData, identifier: String) async throws {
        // Use standard UserDefaults for public data
        UserDefaults.standard.set(data.data, forKey: identifier)
    }
}

struct ClassifiedData {
    let data: Data
    let classification: DataClassification
    let timestamp: Date = Date()
}
```

## Access Control System

### Permission Management
```swift
class AccessControlManager {
    private let permissionEngine: PermissionEngine
    private let toolSecurityManager: ToolSecurityManager
    private let sandboxManager: SandboxManager
    
    func initializePermissionSystem() async throws {
        // Set up permission defaults
        try await configureDefaultPermissions()
        
        // Initialize tool security
        try await toolSecurityManager.initialize()
        
        // Set up sandbox environment
        try await sandboxManager.createSecureSandbox()
    }
    
    func checkPermission(for operation: SecurityOperation, context: OperationContext) async throws -> PermissionResult {
        // Analyze operation security requirements
        let securityAnalysis = await analyzeOperationSecurity(operation, context: context)
        
        // Check if operation is automatically allowed
        if securityAnalysis.riskLevel == .minimal {
            return PermissionResult.granted(reason: .automaticallyApproved)
        }
        
        // Check user preferences for this type of operation
        let userPreference = await getUserPermissionPreference(for: operation.category)
        
        switch userPreference {
        case .alwaysAllow:
            return PermissionResult.granted(reason: .userPreference)
        case .alwaysDeny:
            return PermissionResult.denied(reason: .userPreference)
        case .askEachTime:
            return await requestUserPermission(for: operation, analysis: securityAnalysis)
        case .automatic:
            return await makeAutomaticDecision(for: operation, analysis: securityAnalysis)
        }
    }
    
    private func makeAutomaticDecision(for operation: SecurityOperation, analysis: SecurityAnalysis) async -> PermissionResult {
        // Use intelligent decision making for user-friendly security
        let trustScore = calculateTrustScore(operation: operation, analysis: analysis)
        
        if trustScore >= 0.8 {
            return PermissionResult.granted(reason: .highTrust)
        } else if trustScore >= 0.5 {
            return PermissionResult.grantedWithMonitoring(reason: .moderateTrust)
        } else {
            return await requestUserPermissionWithExplanation(for: operation, analysis: analysis)
        }
    }
    
    private func requestUserPermissionWithExplanation(for operation: SecurityOperation, analysis: SecurityAnalysis) async -> PermissionResult {
        // Present user-friendly permission request
        let request = UserPermissionRequest(
            title: operation.userFriendlyTitle,
            description: operation.userFriendlyDescription,
            riskExplanation: analysis.userFriendlyRiskExplanation,
            suggestedAction: analysis.suggestedUserAction,
            allowedActions: ["Allow Once", "Allow Always", "Deny", "Learn More"]
        )
        
        let userResponse = await presentPermissionRequest(request)
        
        switch userResponse {
        case "Allow Once":
            return PermissionResult.granted(reason: .userApproval)
        case "Allow Always":
            await updateUserPreference(for: operation.category, preference: .alwaysAllow)
            return PermissionResult.granted(reason: .userApproval)
        case "Deny":
            return PermissionResult.denied(reason: .userDenial)
        case "Learn More":
            await showSecurityEducation(for: operation)
            return await requestUserPermissionWithExplanation(for: operation, analysis: analysis)
        default:
            return PermissionResult.denied(reason: .unknownResponse)
        }
    }
}

enum PermissionResult {
    case granted(reason: PermissionReason)
    case denied(reason: PermissionReason)
    case grantedWithMonitoring(reason: PermissionReason)
    case conditional(conditions: [SecurityCondition])
}

enum PermissionReason {
    case automaticallyApproved
    case userPreference
    case userApproval
    case userDenial
    case highTrust
    case moderateTrust
    case unknownResponse
}

struct SecurityOperation {
    let id: String
    let category: OperationCategory
    let userFriendlyTitle: String
    let userFriendlyDescription: String
    let requiredPermissions: [Permission]
    let riskLevel: RiskLevel
}

enum OperationCategory {
    case fileAccess
    case networkAccess
    case systemIntegration
    case dataProcessing
    case externalCommunication
}
```

### Tool Security Framework
```swift
class ToolSecurityManager {
    private let toolRegistry: [String: ToolSecurityProfile] = [:]
    private let executionMonitor: ToolExecutionMonitor
    private let sandboxManager: SandboxManager
    
    func validateToolExecution(_ tool: MCPTool, parameters: [String: Any]) async throws -> ValidationResult {
        // Get security profile for tool
        guard let profile = toolRegistry[tool.identifier] else {
            throw SecurityError.unknownTool(tool.identifier)
        }
        
        // Validate parameters for security risks
        let parameterValidation = try await validateParameters(parameters, profile: profile)
        guard parameterValidation.isValid else {
            throw SecurityError.invalidParameters(parameterValidation.issues)
        }
        
        // Check execution context
        let contextValidation = try await validateExecutionContext(profile: profile)
        guard contextValidation.isValid else {
            throw SecurityError.invalidContext(contextValidation.issues)
        }
        
        return ValidationResult.valid
    }
    
    func executeToolSecurely(_ tool: MCPTool, parameters: [String: Any]) async throws -> ToolResult {
        // Validate execution first
        try await validateToolExecution(tool, parameters: parameters)
        
        // Get security profile
        let profile = toolRegistry[tool.identifier]!
        
        // Create secure execution environment
        let sandbox = try await sandboxManager.createToolSandbox(profile: profile)
        
        // Execute with monitoring
        let result = try await executionMonitor.executeWithMonitoring(tool, parameters: parameters, sandbox: sandbox)
        
        // Validate result before returning
        try await validateToolResult(result, profile: profile)
        
        return result
    }
    
    private func validateParameters(_ parameters: [String: Any], profile: ToolSecurityProfile) async throws -> ParameterValidation {
        var issues: [SecurityIssue] = []
        
        for (key, value) in parameters {
            // Check for potentially dangerous values
            if let stringValue = value as? String {
                if containsDangerousContent(stringValue) {
                    issues.append(SecurityIssue.dangerousContent(parameter: key, content: stringValue))
                }
                
                if exceedsLengthLimit(stringValue, profile: profile) {
                    issues.append(SecurityIssue.parameterTooLong(parameter: key, length: stringValue.count))
                }
            }
            
            // Check parameter against allowed types
            if !profile.allowedParameterTypes[key]?.contains(type(of: value)) ?? false {
                issues.append(SecurityIssue.invalidParameterType(parameter: key, expectedType: profile.allowedParameterTypes[key]?.description ?? "unknown"))
            }
        }
        
        return ParameterValidation(isValid: issues.isEmpty, issues: issues)
    }
    
    private func containsDangerousContent(_ content: String) -> Bool {
        let dangerousPatterns = [
            #"<script.*?>.*?</script>"#,
            #"javascript:"#,
            #"data:text/html"#,
            #"eval\s*\("#,
            #"Function\s*\("#,
            #"\.\./.*\.\."#,  // Path traversal
            #"rm\s+-rf"#,      // Dangerous commands
            #"sudo\s+"#,
            #"chmod\s+777"#
        ]
        
        for pattern in dangerousPatterns {
            if content.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        
        return false
    }
}

struct ToolSecurityProfile {
    let toolIdentifier: String
    let riskLevel: RiskLevel
    let allowedParameterTypes: [String: [Any.Type]]
    let maxParameterLength: [String: Int]
    let requiredPermissions: [Permission]
    let sandboxRequirements: SandboxRequirements
    let executionTimeLimit: TimeInterval
    let memoryLimit: Int
    let networkAccessAllowed: Bool
    let fileSystemAccessLevel: FileSystemAccessLevel
}

enum RiskLevel {
    case minimal    // Safe operations, no confirmation needed
    case low        // Minor risks, automatic approval
    case moderate   // Some risks, smart approval or user confirmation
    case high       // Significant risks, user confirmation required
    case critical   // Dangerous operations, multiple confirmations required
}

enum FileSystemAccessLevel {
    case none           // No file system access
    case readOnly       // Read-only access to specific directories
    case restricted     // Limited write access to safe directories
    case full           // Full file system access (requires explicit permission)
}
```

## Threat Detection and Response

### Behavioral Analysis Engine
```swift
class BehavioralAnalysisEngine {
    private let normalBehaviorProfile: BehaviorProfile
    private let anomalyDetector: AnomalyDetector
    private let responseEngine: ThreatResponseEngine
    
    func analyzeBehavior(_ activity: UserActivity) async -> BehaviorAnalysis {
        // Build behavioral profile
        let currentProfile = buildBehaviorProfile(from: activity)
        
        // Compare with normal behavior
        let deviations = compareWithNormalBehavior(currentProfile, normal: normalBehaviorProfile)
        
        // Assess threat level
        let threatAssessment = assessThreatLevel(deviations: deviations)
        
        // Generate analysis result
        return BehaviorAnalysis(
            activity: activity,
            profile: currentProfile,
            deviations: deviations,
            threatLevel: threatAssessment.level,
            confidence: threatAssessment.confidence,
            recommendedActions: threatAssessment.recommendedActions
        )
    }
    
    func detectAnomalies(_ activity: UserActivity) async -> [SecurityAnomaly] {
        var anomalies: [SecurityAnomaly] = []
        
        // Check for unusual access patterns
        if let accessAnomaly = detectUnusualAccess(activity) {
            anomalies.append(accessAnomaly)
        }
        
        // Check for suspicious tool usage
        if let toolAnomaly = detectSuspiciousToolUsage(activity) {
            anomalies.append(toolAnomaly)
        }
        
        // Check for data exfiltration patterns
        if let dataAnomaly = detectDataExfiltrationPatterns(activity) {
            anomalies.append(dataAnomaly)
        }
        
        // Check for unusual network activity
        if let networkAnomaly = detectUnusualNetworkActivity(activity) {
            anomalies.append(networkAnomaly)
        }
        
        return anomalies
    }
    
    private func detectUnusualAccess(_ activity: UserActivity) -> SecurityAnomaly? {
        // Check for access outside normal hours
        let currentHour = Calendar.current.component(.hour, from: Date())
        let normalHours = normalBehaviorProfile.activeHours
        
        if !normalHours.contains(currentHour) {
            return SecurityAnomaly(
                type: .unusualAccessTime,
                severity: .medium,
                description: "Access outside normal hours (\(currentHour):00)",
                affectedResource: "System Access",
                timestamp: Date()
            )
        }
        
        // Check for unusual location (if available)
        if let location = activity.location,
           !isLocationWithinNormalRange(location) {
            return SecurityAnomaly(
                type: .unusualLocation,
                severity: .high,
                description: "Access from unusual location",
                affectedResource: "System Access",
                timestamp: Date()
            )
        }
        
        return nil
    }
    
    private func detectSuspiciousToolUsage(_ activity: UserActivity) -> SecurityAnomaly? {
        // Check for rapid tool execution
        let recentToolUses = activity.toolUsages.filter { usage in
            Date().timeIntervalSince(usage.timestamp) < 60 // Last minute
        }
        
        if recentToolUses.count > 10 {
            return SecurityAnomaly(
                type: .rapidToolExecution,
                severity: .high,
                description: "Unusually rapid tool execution (\(recentToolUses.count) in 1 minute)",
                affectedResource: "Tool System",
                timestamp: Date()
            )
        }
        
        // Check for use of dangerous tools
        let dangerousTools = recentToolUses.filter { usage in
            usage.tool.riskLevel == .high || usage.tool.riskLevel == .critical
        }
        
        if dangerousTools.count > 3 {
            return SecurityAnomaly(
                type: .dangerousToolUsage,
                severity: .critical,
                description: "Multiple dangerous tool executions",
                affectedResource: "Tool System",
                timestamp: Date()
            )
        }
        
        return nil
    }
}

struct SecurityAnomaly {
    let type: AnomalyType
    let severity: SeverityLevel
    let description: String
    let affectedResource: String
    let timestamp: Date
    let confidence: Double = 0.85
}

enum AnomalyType {
    case unusualAccessTime
    case unusualLocation
    case rapidToolExecution
    case dangerousToolUsage
    case dataExfiltration
    case networkAnomaly
    case authenticationAnomaly
}

enum SeverityLevel {
    case low
    case medium
    case high
    case critical
}
```

### Automated Response System
```swift
class AutomatedResponseSystem {
    private let responseStrategies: [AnomalyType: ResponseStrategy] = [:]
    private let quarantineManager: QuarantineManager
    private let notificationManager: SecurityNotificationManager
    
    func respondToThreat(_ threat: SecurityThreat) async throws {
        // Determine response strategy
        let strategy = selectResponseStrategy(for: threat)
        
        // Execute immediate response
        try await executeImmediateResponse(strategy, threat: threat)
        
        // Monitor for continued threats
        await monitorForContinuedThreats(threat)
        
        // Learn from the incident
        await updateThreatResponse(based: threat, strategy: strategy)
    }
    
    private func executeImmediateResponse(_ strategy: ResponseStrategy, threat: SecurityThreat) async throws {
        switch strategy.action {
        case .monitor:
            await enableEnhancedMonitoring(for: threat)
            
        case .restrict:
            try await restrictAccess(for: threat)
            
        case .quarantine:
            try await quarantineThreat(threat)
            
        case .block:
            try await blockThreat(threat)
            
        case .notify:
            await notifyUser(of: threat, strategy: strategy)
            
        case .escalate:
            await escalateToHumanReview(threat)
        }
    }
    
    private func quarantineThreat(_ threat: SecurityThreat) async throws {
        switch threat.type {
        case .suspiciousFile(let filePath):
            try await quarantineManager.quarantineFile(filePath)
            
        case .maliciousProcess(let processID):
            try await quarantineManager.terminateProcess(processID)
            
        case .suspiciousNetwork(let connection):
            try await quarantineManager.blockNetworkConnection(connection)
            
        case .compromisedTool(let toolID):
            try await quarantineManager.disableTool(toolID)
        }
    }
    
    private func notifyUser(of threat: SecurityThreat, strategy: ResponseStrategy) async {
        let notification = SecurityNotification(
            title: threat.userFriendlyTitle,
            message: threat.userFriendlyDescription,
            severity: threat.severity,
            actionsTaken: strategy.actionDescriptions,
            recommendedUserActions: strategy.userRecommendations
        )
        
        await notificationManager.presentNotification(notification)
    }
}

struct SecurityThreat {
    let id: UUID = UUID()
    let type: ThreatType
    let severity: SeverityLevel
    let source: ThreatSource
    let userFriendlyTitle: String
    let userFriendlyDescription: String
    let technicalDetails: String
    let timestamp: Date = Date()
}

enum ThreatType {
    case suspiciousFile(String)
    case maliciousProcess(Int)
    case suspiciousNetwork(NetworkConnection)
    case compromisedTool(String)
    case dataExfiltration(DataExfiltrationDetails)
    case authenticationBreach(AuthenticationDetails)
}

struct ResponseStrategy {
    let action: ResponseAction
    let actionDescriptions: [String]
    let userRecommendations: [String]
    let escalationThreshold: TimeInterval
}

enum ResponseAction {
    case monitor
    case restrict
    case quarantine
    case block
    case notify
    case escalate
}
```

## Privacy Protection

### Data Minimization Engine
```swift
class DataMinimizationEngine {
    private let dataClassifier: DataClassifier
    private let retentionPolicyManager: RetentionPolicyManager
    private let anonymizationEngine: AnonymizationEngine
    
    func minimizeDataCollection(_ data: CollectedData) async throws -> MinimizedData {
        // Classify data sensitivity
        let classification = await dataClassifier.classifyData(data)
        
        // Apply data minimization rules
        let minimized = try await applyMinimizationRules(data, classification: classification)
        
        // Apply retention policies
        let withRetention = try await retentionPolicyManager.applyRetentionPolicy(minimized)
        
        return withRetention
    }
    
    func anonymizeData(_ data: PersonalData) async throws -> AnonymizedData {
        // Identify personal identifiers
        let identifiers = await identifyPersonalIdentifiers(data)
        
        // Apply anonymization techniques
        let anonymized = try await anonymizationEngine.anonymize(data, identifiers: identifiers)
        
        // Validate anonymization effectiveness
        try await validateAnonymization(original: data, anonymized: anonymized)
        
        return anonymized
    }
    
    private func applyMinimizationRules(_ data: CollectedData, classification: DataClassification) async throws -> MinimizedData {
        var minimized = data
        
        switch classification.sensitivityLevel {
        case .public:
            // No minimization needed
            break
            
        case .internal:
            // Remove detailed metadata
            minimized = removeDetailedMetadata(minimized)
            
        case .confidential:
            // Remove personal identifiers
            minimized = removePersonalIdentifiers(minimized)
            
        case .restricted:
            // Encrypt and minimize
            minimized = try await encryptAndMinimize(minimized)
        }
        
        return MinimizedData(
            data: minimized,
            originalSize: data.size,
            minimizedSize: minimized.size,
            reductionRatio: Double(minimized.size) / Double(data.size)
        )
    }
    
    private func identifyPersonalIdentifiers(_ data: PersonalData) async -> [PersonalIdentifier] {
        var identifiers: [PersonalIdentifier] = []
        
        // Email addresses
        let emailRegex = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        identifiers.append(contentsOf: findMatches(in: data.content, pattern: emailRegex, type: .email))
        
        // Phone numbers
        let phoneRegex = #"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b"#
        identifiers.append(contentsOf: findMatches(in: data.content, pattern: phoneRegex, type: .phone))
        
        // Credit card numbers
        let cardRegex = #"\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b"#
        identifiers.append(contentsOf: findMatches(in: data.content, pattern: cardRegex, type: .creditCard))
        
        // Social security numbers
        let ssnRegex = #"\b\d{3}-\d{2}-\d{4}\b"#
        identifiers.append(contentsOf: findMatches(in: data.content, pattern: ssnRegex, type: .ssn))
        
        return identifiers
    }
}

struct PersonalIdentifier {
    let type: IdentifierType
    let value: String
    let location: Range<String.Index>
    let confidence: Double
}

enum IdentifierType {
    case email
    case phone
    case creditCard
    case ssn
    case ipAddress
    case macAddress
    case name
    case address
}
```

### Local Processing Preference Engine
```swift
class LocalProcessingEngine {
    private let mlxManager: MLXModelManager
    private let capabilityAssessment: LocalCapabilityAssessment
    private let privacyPolicyManager: PrivacyPolicyManager
    
    func determineProcessingLocation(for request: ProcessingRequest) async -> ProcessingDecision {
        // Assess local capabilities
        let localCapabilities = await capabilityAssessment.assessLocalCapabilities(for: request)
        
        // Check privacy requirements
        let privacyRequirements = await privacyPolicyManager.getPrivacyRequirements(for: request)
        
        // Check user preferences
        let userPreferences = await getUserProcessingPreferences(for: request.type)
        
        // Make decision based on multiple factors
        return await makeProcessingDecision(
            capabilities: localCapabilities,
            requirements: privacyRequirements,
            preferences: userPreferences,
            request: request
        )
    }
    
    private func makeProcessingDecision(
        capabilities: LocalCapabilities,
        requirements: PrivacyRequirements,
        preferences: UserProcessingPreferences,
        request: ProcessingRequest
    ) async -> ProcessingDecision {
        
        // Privacy-first decision making
        if requirements.requiresLocalProcessing {
            if capabilities.canProcessLocally {
                return ProcessingDecision.processLocally(reason: .privacyRequired)
            } else {
                return ProcessingDecision.cannotProcess(reason: .privacyConflict)
            }
        }
        
        // User preference consideration
        switch preferences.defaultPreference {
        case .alwaysLocal:
            if capabilities.canProcessLocally {
                return ProcessingDecision.processLocally(reason: .userPreference)
            } else {
                return await askUserForAlternative(request: request, limitation: capabilities.limitations)
            }
            
        case .alwaysRemote:
            if requirements.allowsRemoteProcessing {
                return ProcessingDecision.processRemotely(reason: .userPreference)
            } else {
                return ProcessingDecision.processLocally(reason: .privacyOverride)
            }
            
        case .automatic:
            return await makeAutomaticDecision(capabilities: capabilities, requirements: requirements, request: request)
        }
    }
    
    private func makeAutomaticDecision(
        capabilities: LocalCapabilities,
        requirements: PrivacyRequirements,
        request: ProcessingRequest
    ) async -> ProcessingDecision {
        
        // Calculate processing quality scores
        let localQuality = capabilities.qualityScore
        let remoteQuality = 0.95 // Assume high remote quality
        
        // Calculate privacy scores
        let localPrivacy = 1.0 // Maximum privacy
        let remotePrivacy = requirements.remotePrivacyScore
        
        // Calculate performance scores
        let localPerformance = capabilities.performanceScore
        let remotePerformance = await estimateRemotePerformance(for: request)
        
        // Weighted decision
        let localScore = (localQuality * 0.3) + (localPrivacy * 0.4) + (localPerformance * 0.3)
        let remoteScore = (remoteQuality * 0.3) + (remotePrivacy * 0.4) + (remotePerformance * 0.3)
        
        if localScore >= remoteScore {
            return ProcessingDecision.processLocally(reason: .optimal)
        } else {
            return ProcessingDecision.processRemotely(reason: .optimal)
        }
    }
}

struct ProcessingDecision {
    enum Location {
        case local
        case remote
        case cannot
    }
    
    enum Reason {
        case privacyRequired
        case privacyConflict
        case userPreference
        case privacyOverride
        case optimal
    }
    
    let location: Location
    let reason: Reason
    let explanation: String
    let alternativeOptions: [ProcessingAlternative]
    
    static func processLocally(reason: Reason) -> ProcessingDecision {
        return ProcessingDecision(
            location: .local,
            reason: reason,
            explanation: getExplanation(for: .local, reason: reason),
            alternativeOptions: []
        )
    }
    
    static func processRemotely(reason: Reason) -> ProcessingDecision {
        return ProcessingDecision(
            location: .remote,
            reason: reason,
            explanation: getExplanation(for: .remote, reason: reason),
            alternativeOptions: []
        )
    }
    
    static func cannotProcess(reason: Reason) -> ProcessingDecision {
        return ProcessingDecision(
            location: .cannot,
            reason: reason,
            explanation: getExplanation(for: .cannot, reason: reason),
            alternativeOptions: generateAlternatives(for: reason)
        )
    }
}
```

## User Security Education

### Security Awareness System
```swift
class SecurityEducationManager {
    private let educationContent: SecurityEducationContent
    private let userKnowledgeProfile: UserKnowledgeProfile
    private let adaptiveEducation: AdaptiveEducationEngine
    
    func provideContextualSecurityEducation(for event: SecurityEvent) async {
        // Assess user's current knowledge level
        let knowledgeLevel = await userKnowledgeProfile.getKnowledgeLevel(for: event.category)
        
        // Generate appropriate education content
        let educationContent = await adaptiveEducation.generateEducationContent(
            event: event,
            userLevel: knowledgeLevel
        )
        
        // Present education in user-friendly way
        await presentSecurityEducation(educationContent)
        
        // Track learning progress
        await userKnowledgeProfile.updateKnowledge(event.category, newLevel: educationContent.targetLevel)
    }
    
    private func presentSecurityEducation(_ content: SecurityEducationContent) async {
        let educationView = SecurityEducationView(content: content)
        await MainActor.run {
            // Present education view to user
            presentEducationView(educationView)
        }
    }
    
    func generateSecurityTip(for context: SecurityContext) async -> SecurityTip {
        let relevantTopics = identifyRelevantSecurityTopics(context)
        let userExpertise = await userKnowledgeProfile.getOverallExpertise()
        
        let tip = await adaptiveEducation.generateTip(
            topics: relevantTopics,
            expertise: userExpertise
        )
        
        return tip
    }
}

struct SecurityEducationContent {
    let title: String
    let level: EducationLevel
    let targetLevel: EducationLevel
    let explanation: String
    let visualAids: [EducationVisual]
    let interactiveElements: [InteractiveElement]
    let assessmentQuestions: [AssessmentQuestion]
    let practicalExercises: [PracticalExercise]
}

enum EducationLevel {
    case beginner
    case intermediate
    case advanced
    case expert
}

struct SecurityTip {
    let title: String
    let description: String
    let category: SecurityCategory
    let actionable: Bool
    let implementationSteps: [String]
    let relatedConcepts: [SecurityConcept]
}
```

## Compliance and Audit

### Compliance Manager
```swift
class ComplianceManager {
    private let gdprCompliance: GDPRComplianceEngine
    private let ccpaCompliance: CCPAComplianceEngine
    private let auditLogger: SecurityAuditLogger
    
    func ensureCompliance(for operation: DataOperation) async throws -> ComplianceResult {
        var complianceChecks: [ComplianceCheck] = []
        
        // GDPR compliance check
        let gdprCheck = await gdprCompliance.checkCompliance(operation)
        complianceChecks.append(gdprCheck)
        
        // CCPA compliance check (if applicable)
        if operation.affectsCaliforniaResidents {
            let ccpaCheck = await ccpaCompliance.checkCompliance(operation)
            complianceChecks.append(ccpaCheck)
        }
        
        // Other regional compliance checks
        let otherChecks = await performOtherComplianceChecks(operation)
        complianceChecks.append(contentsOf: otherChecks)
        
        // Aggregate results
        let overallCompliance = aggregateComplianceResults(complianceChecks)
        
        // Log compliance check
        await auditLogger.logComplianceCheck(operation, result: overallCompliance)
        
        return overallCompliance
    }
    
    func handleDataSubjectRequest(_ request: DataSubjectRequest) async throws -> DataSubjectResponse {
        switch request.type {
        case .accessRequest:
            return try await handleAccessRequest(request)
        case .deletionRequest:
            return try await handleDeletionRequest(request)
        case .rectificationRequest:
            return try await handleRectificationRequest(request)
        case .portabilityRequest:
            return try await handlePortabilityRequest(request)
        }
    }
    
    private func handleDeletionRequest(_ request: DataSubjectRequest) async throws -> DataSubjectResponse {
        // Verify identity
        try await verifyRequestorIdentity(request)
        
        // Find all data associated with the subject
        let userData = try await findUserData(subjectId: request.subjectId)
        
        // Check for legal basis to retain data
        let retentionCheck = await checkRetentionRequirements(userData)
        
        // Delete data that can be deleted
        let deletableData = userData.filter { !retentionCheck.mustRetain.contains($0.id) }
        try await deleteUserData(deletableData)
        
        // Anonymize data that must be retained
        let retainableData = userData.filter { retentionCheck.mustRetain.contains($0.id) }
        try await anonymizeUserData(retainableData)
        
        return DataSubjectResponse(
            requestId: request.id,
            status: .completed,
            actions: [
                "Deleted \(deletableData.count) data records",
                "Anonymized \(retainableData.count) data records that must be retained for legal compliance"
            ],
            completionDate: Date()
        )
    }
}

struct ComplianceResult {
    let isCompliant: Bool
    let regulations: [Regulation]
    let violations: [ComplianceViolation]
    let recommendations: [ComplianceRecommendation]
    let certificationsRequired: [ComplianceCertification]
}

enum DataSubjectRequestType {
    case accessRequest      // Right to access
    case deletionRequest    // Right to erasure
    case rectificationRequest // Right to rectification
    case portabilityRequest  // Right to data portability
}
```

## Success Metrics

### Security Effectiveness Metrics
- **Threat Detection Rate**: >95% of actual threats detected
- **False Positive Rate**: <5% of threat alerts are false positives
- **Response Time**: <30 seconds for automatic threat response
- **User Security Burden**: <1 security decision per user per week
- **Compliance Rate**: 100% compliance with applicable regulations

### User Experience Metrics
- **Security Transparency**: Users understand 90% of security decisions
- **Security Friction**: <2% of user operations require security intervention
- **Education Effectiveness**: 80% improvement in user security knowledge over 6 months
- **Trust Score**: >4.5/5 user trust in security measures

### Technical Security Metrics
- **Encryption Coverage**: 100% of sensitive data encrypted
- **Access Control Effectiveness**: 0 unauthorized access incidents
- **Data Minimization**: 50% reduction in collected data volume
- **Privacy Compliance**: 100% compliance with privacy regulations

This specification ensures SAM provides comprehensive security protection while maintaining the user-friendly experience and operational transparency that are core to the SAM vision.