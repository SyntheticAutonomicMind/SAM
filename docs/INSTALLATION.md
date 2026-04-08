# Installing SAM

**Everything you need to get SAM running on your Mac**

---

## System Requirements

| Requirement | Minimum | Recommended |
|------------|---------|-------------|
| **macOS** | 14.0 (Sonoma) | 15.0+ (Sequoia) |
| **Processor** | Intel or Apple Silicon | Apple Silicon (M1+) |
| **RAM** | 8GB | 16GB+ (for local models) |
| **Storage** | 500MB (app only) | 10GB+ (with local models) |

**Apple Silicon vs Intel:**
- Apple Silicon (M1/M2/M3/M4): Full feature support including MLX local models
- Intel: Cloud providers and llama.cpp local models work fine, MLX is not available

---

## Installation Methods

### Homebrew (Recommended)

The simplest way to install and update SAM.

```bash
# Add the SAM tap
brew tap SyntheticAutonomicMind/homebrew-SAM

# Install SAM
brew install --cask sam
```

**Updating:**
```bash
brew upgrade --cask sam
```

**Uninstalling:**
```bash
brew uninstall --cask sam
```

### Direct Download

1. Go to [GitHub Releases](https://github.com/SyntheticAutonomicMind/SAM/releases)
2. Download the latest `.dmg` file
3. Open the DMG
4. Drag SAM.app to your Applications folder
5. Eject the DMG

### First Launch (Important)

The first time you launch SAM, macOS Gatekeeper may block it:

1. **Right-click** SAM.app in Applications
2. Select **Open** from the context menu
3. Click **Open** in the dialog that appears

This is only needed once. After the first launch, SAM opens normally.

**Why this happens:** macOS requires explicit user consent to run applications downloaded from the internet, even when they're code-signed and notarized. This is a standard macOS security feature.

---

## Initial Setup

### 1. Choose an AI Provider

SAM needs at least one AI provider to function. On first launch:

1. Open Settings (,)
2. Go to **AI Providers**
3. Click **Add Provider**
4. Choose your provider:

**Quickest setup:** GitHub Copilot (if you have a subscription) - just sign in with your GitHub account, no API key needed.

**Most flexible:** OpenAI or Anthropic - create an API key at their website and paste it in.

**Most private:** Local MLX model - download a model and run it entirely on your Mac.

See [Providers Guide](PROVIDERS.md) for detailed setup instructions for each provider.

### 2. Start Chatting

Press N to create a new conversation and start typing. That's it.

### 3. Optional: Enable Voice

If you want hands-free control:

1. Go to Settings > Voice
2. Enable the wake word ("Hey SAM")
3. Grant microphone access when prompted
4. Enable text-to-speech if you want SAM to speak responses

### 4. Optional: Enable SAM-Web

To access SAM from other devices on your network:

1. Go to Settings > API Server
2. Enable the API server
3. Note the API token
4. Set up [SAM-Web](https://github.com/SyntheticAutonomicMind/SAM-web) on your network

---

## Auto-Updates

SAM checks for updates automatically using the Sparkle framework. When a new version is available, you'll see a notification with the option to update.

### Update Channels

- **Stable** (default) - Production releases, tested and documented
- **Development** - Pre-release builds with new features (opt-in in Settings > General)

### Disabling Auto-Updates

If you prefer manual updates, you can disable auto-update checks in Settings > General.

---

## Building from Source

For developers who want to build SAM from source code, see [BUILDING.md](../BUILDING.md).

**Quick start:**
```bash
git clone --recursive https://github.com/SyntheticAutonomicMind/SAM.git
cd SAM
make build-debug
```

---

## Data Locations

After installation, SAM stores data in these locations:

| Data | Location |
|------|----------|
| **Application** | `/Applications/SAM.app` |
| **Configuration** | `~/Library/Application Support/SAM/` |
| **Conversations** | `~/Library/Application Support/SAM/conversations/` |
| **Working files** | `~/SAM/` |
| **API keys** | macOS Keychain |

---

## Uninstalling SAM

### Application Only

- **Homebrew:** `brew uninstall --cask sam`
- **Manual:** Drag SAM.app from Applications to the Trash

### Complete Removal (Including Data)

1. Remove the application (above)
2. Delete configuration: `rm -rf ~/Library/Application\ Support/SAM/`
3. Delete working files: `rm -rf ~/SAM/`
4. Remove Keychain entries: Open Keychain Access, search for "syntheticautonomicmind", delete found items

---

## Troubleshooting Installation

### "SAM can't be opened because it is from an unidentified developer"

Right-click the app and select Open. This overrides Gatekeeper for the first launch.

### "SAM is damaged and can't be opened"

This sometimes happens with downloads. Try:
```bash
xattr -cr /Applications/SAM.app
```
Then open normally.

### Homebrew install fails

```bash
# Update Homebrew first
brew update

# Remove and re-add the tap
brew untap SyntheticAutonomicMind/homebrew-SAM
brew tap SyntheticAutonomicMind/homebrew-SAM

# Try again
brew install --cask sam
```

### SAM launches but shows a blank window

- Check that you're running macOS 14.0 or later
- Try resetting preferences: `rm -rf ~/Library/Application\ Support/SAM/preferences/`
- Relaunch SAM

---

## See Also

- [User Guide](USER_GUIDE.md) - Getting started after installation
- [Providers Guide](PROVIDERS.md) - Setting up AI providers
- [Building from Source](../BUILDING.md) - Developer build instructions
