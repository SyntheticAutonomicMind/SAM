<!-- SPDX-License-Identifier: CC-BY-NC-4.0 -->
<!-- SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius) -->


# SAM: Security Specification

**Version:** 2.0  
**Last Updated:** August 23, 2026  
**Module:** `Sources/SecurityFramework/`

---

## Overview

This document defines the security architecture for SAM (Synthetic Autonomic Mind), describing the actual implemented security model. SAM follows a privacy-first, local-first design with defense-in-depth principles.

## Core Security Principles

### 1. Privacy by Design
- **Local-First Processing**: Sensitive operations performed locally when possible
- **Zero Telemetry**: No analytics, crash reporters, or phone-home behaviors
- **User Control**: Clear controls for data sharing and storage
- **Encryption at Rest**: All data encrypted via macOS FileVault

### 2. Invisible Protection
- **Zero User Configuration**: Security works automatically
- **Smart Defaults**: Maximum protection enabled by default
- **Transparent Operation**: Users aren't burdened with security decisions

### 3. Defense in Depth
- **Multiple Security Layers**: No single point of failure
- **Path-Based Authorization**: File access controlled by working directory
- **API Token Authentication**: Required for all API server endpoints
- **macOS Permission Integration**: Uses system permissions for Calendar, Contacts, Notes

---

## Security Architecture

### SecurityFramework Module

**Location:** `Sources/SecurityFramework/`

**Components:**
- **SecurityOperations.swift** - Centralized security checks and path authorization
- **PathAuthorization** - Working directory enforcement

```swift
// Key security functions
public func authorizePath(_ path: String, for tool: String, operation: String) async throws -> AuthorizationResult
public func isPathInWorkingDirectory(_ path: String) -> Bool
public func resolveWorkingDirectory(for conversationId: UUID?) -> String
```

### Working Directory Security Model

SAM uses a **path-based authorization** system:

```
~/SAM/
├── conversation-1/    # Files for conversation 1 (auto-approved)
├── conversation-2/    # Files for conversation 2 (auto-approved)
├── my-project/        # Shared Topic workspace (auto-approved)
└── ...
```

**Authorization Rules:**
| Path Location | Authorization |
|--------------|---------------|
| Inside `~/SAM/` | Auto-approved |
| Outside `~/SAM/` | Requires `user_collaboration` confirmation |
| Relative paths | Auto-resolved to working directory |

**Implementation:**

```swift
public func authorizePath(_ path: String, for tool: String, operation: String) async throws -> AuthorizationResult {
    let workingDir = resolveWorkingDirectory(for: currentConversationId)
    let resolvedPath = (path as NSString).expandingTildeInPath
    let workingDirExpanded = (workingDir as NSString).expandingTildeInPath
    
    // Check if path is within working directory
    if resolvedPath.hasPrefix(workingDirExpanded) {
        return .approved
    }
    
    // Outside working directory - request user confirmation
    return .requiresConfirmation(
        tool: tool,
        operation: operation,
        path: resolvedPath,
        workingDirectory: workingDirExpanded
    )
}
```

---

## Data Protection

### Data Storage Locations

| Data | Location | Encryption |
|------|----------|------------|
| Conversations | `~/Library/Application Support/SAM/conversations/` | FileVault (macOS) |
| Configuration | `~/Library/Application Support/SAM/` | FileVault |
| API Keys | macOS Keychain | Keychain encryption (hardware-backed on Apple Silicon) |
| Working Files | `~/SAM/` | FileVault |
| Local Models | `~/Library/Caches/sam-rewritten/models/` | FileVault |
| LTM Database | `~/Library/Application Support/SAM/ltm.db` | FileVault |
| KV Store | `~/Library/Application Support/SAM/kv_store.db` | FileVault |

### API Key Storage

- **macOS Keychain** with app's access group (`com.fewtarius.syntheticautonomicmind`)
- Hardware-backed encryption on Apple Silicon
- Automatic locking when Mac sleeps or locks
- Never written to plain text files, logs, or config files

### Network Communication

**Outbound Connections Only:**
1. **AI Provider APIs** - Messages sent to configured cloud providers
2. **Update Checks** - Sparkle framework (can be disabled)
3. **Web Operations** - Only when explicitly requested via `web_operations` tool
4. **ALICE Image Generation** - Only when `image_generation` tool used

**No Inbound Connections** except:
- **Local API Server** (port 8080, disabled by default, requires token auth)

---

## API Server Security

### Authentication

```swift
// Token-based authentication for all endpoints
let authHeader = request.headers["Authorization"]
guard authHeader == "Bearer \(apiToken)" else {
    return Response(status: .unauthorized)
}
```

### Security Features:
- **Token-based auth** - All API requests require valid token
- **Local network only** - Binds to all interfaces but intended for LAN
- **No internet exposure** - SAM does not configure port forwarding/UPnP
- **CORS** - Configurable cross-origin headers
- **Rate limiting** - Built-in request throttling

### Recommendations:
- Keep API server disabled when not in use
- Use only on trusted networks
- Don't expose port 8080 to internet
- Treat API token like a password

---

## Tool Authorization

### File Operations

The `file_operations` tool enforces path-based authorization:
- **Auto-approved**: Operations within `~/SAM/`
- **Requires confirmation**: Operations outside `~/SAM/` via `user_collaboration`

### macOS Integration Tools

Tools requiring system permissions:
- **Calendar/Reminders** (`calendar_operations`) - EventKit permission prompt
- **Contacts** (`contacts_operations`) - Contacts framework permission prompt
- **Notes** (`notes_operations`) - Notes app permission prompt
- **Spotlight** (`spotlight_search`) - Uses system index, respects macOS privacy

### Web Operations

- **User-initiated only** - Only executed when AI decides to use them
- **No automatic web access** - AI must explicitly call tools
- **SerpAPI** - Optional, requires user-configured API key

---

## Application Hardening

### Runtime Environment

| Security Feature | Status |
|-----------------|--------|
| **Hardened Runtime** | Enabled |
| **Code Signing** | Developer ID signed |
| **Notarization** | Apple notarized |
| **App Sandbox** | Not sandboxed (requires server capabilities and unrestricted file access) |

### Entitlements

| Entitlement | Purpose |
|------------|---------|
| `com.apple.security.keychain` | Secure API key storage |
| `com.apple.security.cs.allow-jit` | MLX/CachyLLama JIT compilation |
| `com.apple.security.cs.allow-unsigned-executable-memory` | MLX Metal operations |
| `com.apple.security.cs.disable-library-validation` | MLX framework loading |

---

## Threat Model

### In Scope

| Threat | Mitigation |
|--------|------------|
| **Unauthorized file access** | Path-based authorization, working directory enforcement |
| **API key theft** | Keychain storage, hardware encryption |
| **API server abuse** | Token authentication, local network only |
| **Malicious tool execution** | Path authorization, user confirmation for sensitive operations |
| **Data exfiltration** | Local-first design, no telemetry, user controls cloud providers |

### Out of Scope

| Threat | Reason |
|--------|--------|
| **Physical access** | Requires macOS login compromise |
| **Social engineering** | User education, not technical control |
| **Third-party AI provider breaches** | Provider responsibility |
| **Malware on host system** | OS-level protection |
| **Supply chain attacks** | Dependency pinning, notarization |

---

## Privacy Features

### Zero Telemetry

SAM collects **no usage data**:
- No analytics
- No crash reporters
- No phone-home behaviors
- No feature usage tracking

### Data Minimization

**Cloud Provider Requests Include Only:**
- Current message
- Relevant conversation context (managed by context window)
- System prompt
- Tool call results (from current conversation)

**Cloud Provider Requests Exclude:**
- Other conversations
- Imported documents (only relevant RAG chunks)
- Local files (unless part of active context)
- Settings, preferences, API keys
- LTM entries (unless explicitly included)

### Local Models = Zero External Data

When using MLX, CachyLLama, or llama.cpp:
- All inference on-device
- No data leaves Mac
- No API keys required

---

## Update Security

### Sparkle Framework

- **Code signed** - All updates signed with developer identity
- **Notarized** - Updates notarized by Apple
- **Appcast verification** - Metadata verified before installation
- **Separate channels** - Stable and development feeds separate
- **Optional** - Auto-updates can be disabled in Settings

---

## Entitlements Reference

```xml
<!-- SAM.entitlements -->
<dict>
    <key>com.apple.security.keychain</key>
    <true/>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.device.microphone</key>
    <true/>
</dict>
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2.0 | 2026-08-23 | Updated to reflect actual implementation: SecurityFramework module, path-based auth, Keychain storage, API server security, macOS permissions integration |
| 1.0 | 2025-12-20 | Initial specification (aspirational) |

---

## See Also

- [API Authentication](API_AUTHENTICATION.md) - API server authentication implementation
- [Configuration System](CONFIGURATION_SYSTEM.md) - Keychain and preferences
- [Conversation Engine](CONVERSATION_ENGINE.md) - Session validation
- [SAM.entitlements](../SAM.entitlements) - Application entitlements
- [docs/SECURITY.md](../docs/SECURITY.md) - User-facing security documentation