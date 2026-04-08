# SAM Security and Privacy

**How SAM protects your data and privacy**

---

## Overview

SAM is designed with privacy as a core principle, not an afterthought. Your data stays on your Mac, and SAM collects zero telemetry. This document explains the security model, what data goes where, and what controls you have.

---

## Privacy Model

### Your Data Stays Local

Everything SAM stores lives on your Mac:

| Data | Location | Encrypted |
|------|----------|-----------|
| Conversations | `~/Library/Application Support/SAM/conversations/` | At rest (macOS FileVault) |
| Configuration | `~/Library/Application Support/SAM/` | At rest (macOS FileVault) |
| API keys | macOS Keychain | Yes (Keychain encryption) |
| Working files | `~/SAM/` | At rest (macOS FileVault) |
| Local models | `~/Library/Application Support/SAM/` | At rest (macOS FileVault) |

SAM does not maintain any cloud storage, remote databases, or sync services.

### Zero Telemetry

SAM collects no usage data. There are no analytics, no crash reporters, no phone-home behaviors. The only network traffic SAM generates is:

1. **AI provider requests** - When you use a cloud AI provider, your messages are sent to that provider's API
2. **Update checks** - SAM checks for updates via Sparkle (can be disabled)
3. **Web operations** - When you explicitly ask SAM to search or fetch web pages

### What Cloud Providers See

When you use a cloud AI provider (OpenAI, Anthropic, GitHub Copilot, DeepSeek, Google Gemini, MiniMax, OpenRouter):

- **Sent:** Your message, relevant conversation context, system prompt, and tool call results
- **Not sent:** Other conversations, imported documents (only relevant chunks), local files (unless part of active context), your settings, or any other data

Each provider has their own data retention and privacy policies. SAM minimizes what's sent by using context management to include only relevant information.

### Local Models See Nothing External

When you use local models (MLX or llama.cpp), all processing happens on your Mac. Zero data leaves your machine.

---

## Application Security

### Runtime Environment

SAM runs as a standard macOS application with hardened runtime:

| Security Feature | Status |
|-----------------|--------|
| **Hardened Runtime** | Enabled |
| **Code Signing** | Developer ID signed |
| **Notarization** | Apple notarized |
| **App Sandbox** | Not sandboxed (requires server capabilities and unrestricted file access) |

SAM is not sandboxed because it runs a local HTTP server for SAM-Web and needs unrestricted file system access for its tool system. This is standard for developer tools and productivity applications distributed outside the App Store.

### Entitlements

SAM requests minimal entitlements:

| Entitlement | Why |
|------------|-----|
| **Keychain access** | Secure storage for API keys |
| **JIT compilation** | Required for MLX and llama.cpp model inference |
| **Unsigned executable memory** | Required for MLX Metal operations |
| **Disable library validation** | Required for MLX framework loading |

These entitlements are necessary for local model inference on Apple Silicon. They do not grant SAM access to other applications' data or keychain items.

### API Key Storage

API keys are stored in the macOS Keychain using the app's keychain access group (`com.fewtarius.syntheticautonomicmind`). The Keychain provides:

- Hardware-backed encryption on Apple Silicon
- Access control (only SAM can read SAM's keys)
- Automatic locking when the Mac sleeps or locks

API keys are never written to plain text files, logs, or configuration files on disk.

---

## Tool Authorization

### Path-Based Authorization

SAM's tool system uses path-based authorization to control file access:

- **Inside working directory** (`~/SAM/`): All file operations are auto-approved
- **Outside working directory**: The AI must request permission through `user_collaboration` before accessing files

This means the AI can freely read, write, and manage files within its workspace, but cannot touch your Desktop, Documents, or other personal folders without explicit approval.

### Working Directory Structure

```
~/SAM/
├── conversation-1/    # Files for conversation 1
├── conversation-2/    # Files for conversation 2
├── my-project/        # Shared Topic workspace
└── ...
```

Each conversation gets an isolated workspace. Shared Topics get named directories.

### What Tools Can and Cannot Do

**Can do (auto-approved):**
- Read/write files in `~/SAM/`
- Search the web
- Perform calculations
- Create documents in the working directory
- Access imported document content

**Requires permission:**
- Access files outside `~/SAM/`
- Any operation the AI determines needs user confirmation

**Cannot do:**
- Access other applications' data
- Modify system files
- Install software
- Access the Keychain (except through SAM's own key management)

---

## API Server Security

When the API server is enabled (for SAM-Web):

### Authentication

- **Token-based auth** - All API requests require a valid authentication token
- **Token generation** - Tokens are generated locally and displayed in Settings
- **No default access** - The API server rejects unauthenticated requests

### Network Exposure

- **Local network only** - The server binds to all interfaces but is intended for LAN use
- **Port 8080** - Default port (configurable)
- **No internet exposure** - SAM does not configure port forwarding or UPnP
- **CORS** - Configurable cross-origin resource sharing headers

### Recommendations

- Keep the API server disabled when not in use
- Use the API server only on trusted networks
- Don't expose port 8080 to the internet
- Treat the API token like a password

---

## Data Retention

### Conversations

Conversations are stored indefinitely until you delete them. There is no automatic expiration.

### Imported Documents

Imported document content (text chunks and vector embeddings) is stored in the conversation's vector database. Deleting the conversation deletes the imported document data.

### Configuration Backups

SAM creates automatic backups of configuration files using atomic write operations (temp file -> rename). Old backups are not automatically cleaned up.

### Clearing All Data

To remove all SAM data from your Mac:

1. Quit SAM
2. Delete `~/Library/Application Support/SAM/`
3. Delete `~/SAM/`
4. Remove SAM's Keychain entries (search for "syntheticautonomicmind" in Keychain Access)
5. Delete SAM.app from Applications

---

## Update Security

SAM uses the Sparkle framework for automatic updates:

- **Code signed** - All updates are signed with the developer's code signing identity
- **Notarized** - Updates are notarized by Apple
- **Appcast verification** - Update metadata is verified before installation
- **Separate channels** - Stable and development update feeds are separate
- **Optional** - Auto-updates can be disabled in Settings

---

## Reporting Security Issues

If you discover a security vulnerability in SAM, please report it responsibly:

1. **Do not** open a public GitHub issue
2. Contact the maintainer directly via the security contact listed on the [GitHub repository](https://github.com/SyntheticAutonomicMind/SAM)
3. Include details about the vulnerability and steps to reproduce
4. Allow reasonable time for a fix before public disclosure

---

## See Also

- [project-docs/SECURITY_SPECIFICATION.md](../project-docs/SECURITY_SPECIFICATION.md) - Detailed security architecture
- [project-docs/API_AUTHENTICATION.md](../project-docs/API_AUTHENTICATION.md) - Authentication implementation
- [SAM.entitlements](../SAM.entitlements) - Application entitlements
