# Installing SAM

Everything you need to get SAM running on your Mac.

---

## System Requirements

| Requirement | Minimum | Recommended |
|------------|---------|-------------|
| **macOS** | 14.0 (Sonoma) | 15.0+ (Sequoia) |
| **Processor** | Intel or Apple Silicon | Apple Silicon (M1+) |
| **RAM** | 8GB | 16GB+ for local models |
| **Storage** | 500MB for the app | 10GB+ if you plan to use local models |

### Apple Silicon vs Intel

- **Apple Silicon** - best experience overall, including MLX local models
- **Intel** - cloud providers and `llama.cpp` local models work, but MLX is not available

---

## Installation Methods

### Homebrew

SAM can be installed with Homebrew:

```bash
brew tap SyntheticAutonomicMind/homebrew-SAM
brew install --cask sam
```

To update later:

```bash
brew upgrade --cask sam
```

To uninstall:

```bash
brew uninstall --cask sam
```

### Direct Download

1. Open [GitHub Releases](https://github.com/SyntheticAutonomicMind/SAM/releases)
2. Download the latest `.dmg`
3. Open the DMG
4. Drag `SAM.app` to your Applications folder
5. Eject the DMG

---

## First Launch

The first time you open SAM, macOS may ask you to confirm that you want to run it.

1. Open `SAM.app` from Applications
2. If Gatekeeper prompts, use **Right-click -> Open**
3. Confirm the dialog

After the first launch, SAM should open normally.

---

## Initial Setup

### 1. Add an AI provider

SAM needs at least one provider before it can respond.

1. Open **Settings**
2. Go to **AI Providers**
3. Click **Add Provider**
4. Choose one of the supported providers:
   - **OpenAI**
   - **GitHub Copilot**
   - **DeepSeek**
   - **Google Gemini**
   - **MiniMax**
   - **OpenRouter**
   - **Local MLX**
   - **Local llama.cpp**
   - **Custom OpenAI-compatible endpoint**

For setup details, see [Providers Guide](PROVIDERS.md).

### 2. Start a conversation

Create a new conversation and start typing naturally. SAM saves conversations automatically.

### 3. Optional: enable voice features

If you want hands-free interaction:

1. Open **Settings > Voice**
2. Enable the wake word if desired
3. Grant microphone access when macOS asks
4. Enable text-to-speech if you want spoken responses

### 4. Optional: enable the API server

If you want browser-based or remote access through SAM-Web:

1. Open **Settings > API Server**
2. Enable the API server
3. Copy the generated API token
4. Configure [SAM-Web](https://github.com/SyntheticAutonomicMind/SAM-web)

---

## Auto-Updates

SAM uses Sparkle for updates.

### Update Channels

- **Stable** - default channel for production releases
- **Development** - opt-in prerelease builds for faster access to new work

You can change update preferences in **Settings > General**.

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
| **Local models** | `~/Library/Caches/sam-rewritten/models/` |
| **Generated ALICE images** | `~/Library/Caches/sam/images/` |

---

## Building from Source

If you want to build SAM yourself, see [BUILDING.md](../BUILDING.md).

Quick start:

```bash
git clone --recursive https://github.com/SyntheticAutonomicMind/SAM.git
cd SAM
make build-debug
```

---

## Uninstalling SAM

### Remove the app

- **Homebrew:** `brew uninstall --cask sam`
- **Manual install:** move `SAM.app` to the Trash

### Remove all local data

1. Delete `~/Library/Application Support/SAM/`
2. Delete `~/SAM/`
3. Remove SAM-related entries from Keychain Access if desired

---

## Troubleshooting

### Homebrew install fails

Try refreshing Homebrew and the tap:

```bash
brew update
brew untap SyntheticAutonomicMind/homebrew-SAM
brew tap SyntheticAutonomicMind/homebrew-SAM
brew install --cask sam
```

### Gatekeeper blocks launch

Use **Right-click -> Open** on first launch.

### App appears damaged

Try clearing quarantine attributes:

```bash
xattr -cr /Applications/SAM.app
```

### Blank window on launch

- Confirm you are on macOS 14.0 or newer
- Try resetting preferences under `~/Library/Application Support/SAM/`
- Relaunch the app

---

## See Also

- [User Guide](USER_GUIDE.md)
- [Providers Guide](PROVIDERS.md)
- [Building from Source](../BUILDING.md)
