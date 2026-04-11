# SAM Security and Privacy

How SAM protects data, credentials, and local workflows.

---

## Overview

SAM is designed to be local-first and privacy-conscious. Conversations and application state stay on your Mac unless you explicitly choose a cloud provider or remote integration.

This document describes the current security model as reflected in the codebase.

---

## Privacy Model

### Local by default

SAM stores its own data locally:

| Data | Location |
|------|----------|
| Conversations and app data | `~/Library/Application Support/SAM/` |
| Working files | `~/SAM/` |
| Local models | `~/Library/Caches/sam-rewritten/models/` |
| ALICE-generated images | `~/Library/Caches/sam/images/` |
| Provider credentials | macOS Keychain |

SAM does not maintain a mandatory cloud account, vendor sync service, or telemetry pipeline.

### No telemetry

SAM does not include analytics or phone-home usage tracking.

Expected outbound network activity comes from things you enable or request, such as:
- cloud AI provider calls
- update checks
- web research and page retrieval
- API server usage from your own clients
- ALICE server access for image generation

---

## Credential Handling

Provider credentials are stored in the macOS Keychain.

That means:
- keys are not meant to live in plain-text config files
- sensitive secrets are kept in the system credential store
- provider setup can be managed from the UI without inventing a custom secret store

SAM also includes secret-redaction logic to help avoid sending sensitive data to cloud providers unintentionally.

---

## Cloud Provider Privacy

When you use a hosted provider, SAM sends the data needed for that request.

That typically includes:
- your current prompt
- relevant conversation context
- system prompt content
- tool results needed for the current response

It does **not** imply unrestricted upload of everything on your Mac.

Local providers avoid that network path entirely.

---

## File Authorization Model

SAM's file and document workflows use a path-based authorization model.

### Working-directory behavior

- Inside the current working directory: operations are generally auto-approved
- Outside the working directory: authorization is required

This keeps autonomous file workflows practical while still protecting the rest of the system from silent overreach.

### Common workspace locations

- `~/SAM/conversation-*`
- `~/SAM/{topic-name}` for shared workspaces

---

## API Server Security

When the local API server is enabled for SAM-Web or other clients:

- requests require a token
- remote access is configurable
- the server is intended for trusted local-network use
- conversation-handling behavior can be configured for API sessions

### Recommendations

- leave the API server off when you do not need it
- do not expose it directly to the public internet
- treat the API token like any other credential

---

## Application Security Characteristics

SAM is a native macOS app with the runtime and integration requirements needed for:

- local model support
- file access
- local API server support
- voice and system integration features

Some features require capabilities that would not fit a tightly sandboxed App Store-style app. That is part of the tradeoff for a local, tool-capable assistant.

---

## Secrets and Sensitive Content

SAM includes protections for:
- API keys
- tokens
- credentials
- private content headed to cloud providers

This is especially important in tool-assisted workflows where file content may be summarized, searched, or passed into model requests.

---

## Conversation and Memory Storage

Conversation, memory, and related per-conversation data live under the Application Support tree.

Examples include:
- conversation files and metadata
- per-conversation memory databases
- todo/task state
- configuration backups and support data

Deleting a conversation removes its associated local state from SAM-managed storage.

---

## Updates

SAM uses Sparkle for updates.

That means update delivery includes:
- signed releases
- appcast-driven update metadata
- stable and development update channels

If you prefer manual updates, you can disable automatic update checks.

---

## Practical Security Posture

SAM's current approach is built around:

- local ownership of data
- explicit use of cloud providers instead of hidden cloud dependency
- Keychain-backed credentials
- path authorization for tool-driven file access
- visibility into tool activity through the UI

The goal is simple: useful autonomy without silent loss of control.

---

## See Also

- [Installation](INSTALLATION.md)
- [Architecture](ARCHITECTURE.md)
- [Tools](TOOLS.md)
- [project-docs/SECURITY_SPECIFICATION.md](../project-docs/SECURITY_SPECIFICATION.md)
