# Building SAM (Synthetic Autonomic Mind)

This document explains how to build SAM on macOS. SAM requires modern development tools and is optimized for Apple Silicon.

## System Requirements

**Minimum:**
- macOS 15.0 (Sequoia) or later
- Xcode 16.0 or later
- Swift 6.0 (included with Xcode 16)
- Apple Silicon (M1/M2/M3/M4) recommended
- 16GB RAM for development
- 20GB free disk space

**Development Tools:**
- Xcode 16.0+ with Command Line Tools
- Homebrew package manager
- Git with submodule support

## Quick Build (TL;DR)

```bash
cd /path/to/SAM
git submodule update --init --recursive
make build-debug
```

**Note:** First build will take 10-15 minutes as it compiles llama.cpp and downloads dependencies.

## Platform and Expectations

- **macOS**: 15.0+ required for development (users can run on macOS 14.0+)
- **Xcode**: Full Xcode 16.0+ installation required (not just Command Line Tools)
- **Architecture**: Apple Silicon (arm64) strongly recommended for MLX and best performance
- **Swift**: 6.0 language features are used throughout the codebase

## Prerequisites (tools)

Install these tools if you haven't already. You mentioned you already installed `cmake`, `ccache`, and Xcode — good. The rest below are commonly required.

Using Homebrew (recommended):

```bash
# install Homebrew if missing (visit https://brew.sh for details)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# install common build tools
brew install git cmake ccache pkg-config wget
```

Notes:
- `libtool`, `dsymutil`, `clang`, `clang++`, and other Apple toolchain binaries are provided by Xcode / Command Line Tools. They are not installed via Homebrew.
- `ccache` is optional but recommended for faster incremental builds.

## Xcode / Command Line Tools

If CMake complains about missing C/C++ compilers (the error you encountered), it's usually because the Xcode Command Line Tools aren't fully installed or `xcode-select` is not pointing to the right developer directory.

Run these commands to install/verify and accept the license:

```bash
# Install Xcode command line tools (will prompt a GUI dialog)
xcode-select --install

# If you have the full Xcode app, make sure xcode-select points to it (adjust path if you installed Xcode somewhere else)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# Accept the license (required for some CI/headless scenarios)
sudo xcodebuild -license accept

# Verify the developer directory
xcode-select -p

# Check compiler is available
clang --version
clang++ --version
```

If `clang` is missing after installing Xcode CLT, restart your terminal session and re-run `clang --version`.

## Git submodules

The project depends on `external/llama.cpp` (and possibly other externals). Initialize submodules before building:

```bash
git submodule update --init --recursive
```

If the submodule update fails behind a proxy, ensure your Git credentials and proxy settings are correct.

## Swift toolchain and SPM

SAM uses Swift Package Manager (SPM). Ensure your Xcode installation includes a Swift toolchain compatible with `swift-tools-version: 5.9`.

Check Swift version:

```bash
swift --version
```

Resolve Swift packages before building if you want to pre-fetch dependencies:

```bash
swift package resolve
```

You can also run `swift build` or `swift test` to exercise Swift targets directly.

## Building llama.cpp (required binary target)

The `Makefile` runs `scripts/build-llama-macos.sh` which requires:

- cmake
- xcodebuild
- libtool
- dsymutil
- clang (from Xcode)

When you run `make build-debug`, the first step is the `llamacpp` target which runs that script. If that script fails with the CMake compiler error, follow the Xcode / Command Line Tools steps above.

If you prefer to run the builder manually for debugging:

```bash
cd external/llama.cpp
./scripts/build-llama-macos.sh
# or: bash scripts/build-llama-macos.sh
```

Watch the output for missing tool names. The script explicitly checks for `cmake`, `xcodebuild`, `libtool`, and `dsymutil`.

## Typical build flow (recommended)

1. Open a terminal and navigate to the repo root:

```bash
cd /Users/andrew/repositories/SyntheticAutonomicMind/SAM
```

2. Initialize submodules and fetch SPM packages:

```bash
git submodule update --init --recursive
swift package resolve
```

3. Run the debug build (this will build llama.cpp first):

```bash
make build-debug
```

4. If `make build-debug` succeeds, the debug executable will be at:

```
.build/Build/Products/Debug/SAM
```

and the app bundle at:

```
.build/Build/Products/Debug/SAM.app
```

## Troubleshooting — common errors and fixes

1) CMake says "No CMAKE_C_COMPILER could be found" or "No CMAKE_CXX_COMPILER could be found"

Cause: Xcode Command Line Tools not installed or `xcode-select` is pointing to a non-standard location.

Fix:

```bash
# Install CLI tools
xcode-select --install
# Or explicitly point to Xcode
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
# Accept license
sudo xcodebuild -license accept
# Verify
clang --version
cmake --version
```

If the problem persists, try setting environment variables (temporary):

```bash
export CC=clang
export CXX=clang++
make build-debug
```

2) Submodule missing (llama.cpp not found)

Fix:

```bash
git submodule update --init --recursive
```

3) Swift package resolution / SPM network errors

Fix:

```bash
swift package resolve --verbose
# or inspect Package.resolved
cat Package.resolved
```

4) `xcodebuild` scheme not found or fails

The Makefile uses scheme `SAM-Package`. If `xcodebuild` complains about a missing scheme, open the Xcode project generated by SPM or regenerate the Xcode project with SPM:

```bash
swift package generate-xcodeproj # (if needed)
# Or open Package.swift directly in Xcode and build there
open Package.swift
```

## Signing / Notarization

The Makefile contains targets to sign and notarize (`sign`, `notarize`, `distribute`). For signing you need a valid Developer ID and the `APPLE_DEVELOPER_ID` environment variable set. Example:

```bash
export APPLE_DEVELOPER_ID='Developer ID Application: Your Name (TEAMID)'
make sign-release
```

## Developer checklist / quick commands

```bash
# 1. Verify developer tools
xcode-select -p
clang --version
cmake --version

# 2. Initialize repo
git submodule update --init --recursive
swift package resolve

# 3. Build debug
make build-debug

# 4. Run
.build/Build/Products/Debug/SAM
```

## Notes and caveats

- The llama.cpp build in `scripts/build-llama-macos.sh` intentionally builds arm64-only frameworks for Apple Silicon. If you need x86_64 support, you'll need to adapt the script and pass `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"` and build both architectures.
- MLX integration requires the `mlx-swift` SPM package; make sure your network allows fetching GitHub packages.
- If you require reproducible CI builds, pin package versions in `Package.resolved` and install Homebrew packages as part of the CI image.

---

If you'd like, I can:

- Try some follow-up commands in your environment (e.g. `xcode-select -p`, `clang --version`) to help pinpoint the problem output you saw.
- Add a short troubleshooting script that checks for the required tools and prints a friendly checklist.
- Create a `scripts/check-build-env.sh` script that runs basic checks (cmake, clang, xcode-select, git submodules) and prints actionable errors.

Tell me which of the above you'd like me to add next and I will implement it in the repo. (If you want me to proceed with edits, I'll create the check script and commit it.)
