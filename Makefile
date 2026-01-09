# SAM Makefile
# Build System with MLX Integration

# Project configuration
PROJECT_NAME = SAM
EXECUTABLE_NAME = SAM
BUILD_DIR = .build
BUNDLE_NAME = mlx-swift_Cmlx.bundle

# Code signing configuration
# Set APPLE_DEVELOPER_ID in your environment (.profile, .zshrc, etc.):
#   export APPLE_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
DEVELOPER_ID ?= $(APPLE_DEVELOPER_ID)
ENTITLEMENTS = SAM.entitlements
APP_BUNDLE_DEBUG = .build/Build/Products/Debug/SAM.app
APP_BUNDLE_RELEASE = .build/Build/Products/Release/SAM.app

# Build targets
.PHONY: all build clean test test-unit test-e2e test-all test-quick run help metallib llamacpp build-debug build-release bundle-python
.PHONY: sign sign-debug sign-release verify-signature notarize staple distribute production
.PHONY: dist
.PHONY: build-dev release-dev appcast-dev

# Default target
all: build

# Build the project (release by default)
build: build-release

# Build llama.cpp framework for local model support (macOS-only, no iOS/tvOS/visionOS)
llamacpp:
	@echo "Building llama.cpp framework (macOS-only)..."
	@if [ ! -d "external/llama.cpp" ]; then \
		echo "ERROR: ERROR: llama.cpp submodule not found"; \
		echo "Run: git submodule update --init --recursive"; \
		exit 1; \
	fi
	@export CMAKE_C_COMPILER_LAUNCHER=ccache && \
	export CMAKE_CXX_COMPILER_LAUNCHER=ccache && \
	cd external/llama.cpp && ../../scripts/build-llama-macos.sh
	@echo "SUCCESS: llama.cpp framework built successfully"
	@echo "Framework: external/llama.cpp/build-apple/llama.xcframework"

# Build debug version (no Python bundling)
build-debug-no-python: llamacpp
	@echo "Setting build version from git commit..."
	@./scripts/set-build-version.sh Debug
	@echo "Building SAM [Debug]..."
	@echo "Using xcodebuild for MLX Metal library compatibility..."
	xcodebuild -scheme SAM-Package -configuration Debug -derivedDataPath .build -destination 'platform=OS X'
	@echo "SUCCESS: Debug build complete"
	@echo "Copying frameworks to PackageFrameworks..."
	@mkdir -p .build/Build/Products/Debug/PackageFrameworks
	@cp -R external/llama.cpp/build-apple/llama.xcframework/macos-arm64/llama.framework .build/Build/Products/Debug/PackageFrameworks/
	@if [ -d ".build/Build/Products/Debug/Sparkle.framework" ]; then \
		cp -R .build/Build/Products/Debug/Sparkle.framework .build/Build/Products/Debug/PackageFrameworks/; \
		echo "SUCCESS: Sparkle.framework installed to PackageFrameworks"; \
	fi
	@echo "SUCCESS: llama.framework installed to PackageFrameworks"
	@echo "Creating .app bundle with Info.plist and app icon..."
	@mkdir -p .build/Build/Products/Debug/SAM.app/Contents/MacOS
	@mkdir -p .build/Build/Products/Debug/SAM.app/Contents/Resources
	@mkdir -p .build/Build/Products/Debug/SAM.app/Contents/Frameworks
	@cp .build/Build/Products/Debug/SAM .build/Build/Products/Debug/SAM.app/Contents/MacOS/
	@cp Info.plist .build/Build/Products/Debug/SAM.app/Contents/
	@cp Resources/sam-icon.icns .build/Build/Products/Debug/SAM.app/Contents/Resources/
	@cp Resources/sam-icon.png .build/Build/Products/Debug/SAM.app/Contents/Resources/
	@cp Resources/fewtarius.jpg .build/Build/Products/Debug/SAM.app/Contents/Resources/
	@cp Resources/fewtarius-avatar.jpg .build/Build/Products/Debug/SAM.app/Contents/Resources/
	@cp Resources/terminal.html .build/Build/Products/Debug/SAM.app/Contents/Resources/
	@cp Resources/vendor/xterm/xterm.css .build/Build/Products/Debug/SAM.app/Contents/Resources/
	@cp Resources/vendor/xterm/xterm.js .build/Build/Products/Debug/SAM.app/Contents/Resources/
	@cp Resources/vendor/xterm/xterm-addon-fit.js .build/Build/Products/Debug/SAM.app/Contents/Resources/
	@cp Sources/ConfigurationSystem/Resources/model_config.json .build/Build/Products/Debug/SAM.app/Contents/Resources/
	@cp Resources/whats-new.json .build/Build/Products/Debug/SAM.app/Contents/Resources/
	@cp -R .build/Build/Products/Debug/PackageFrameworks/llama.framework .build/Build/Products/Debug/SAM.app/Contents/Frameworks/
	@if [ -d ".build/Build/Products/Debug/Sparkle.framework" ]; then \
		echo "Copying Sparkle.framework to app bundle..."; \
		cp -R .build/Build/Products/Debug/Sparkle.framework .build/Build/Products/Debug/SAM.app/Contents/Frameworks/; \
	fi
	@echo "Copying MLX Metal library bundle to app Resources..."
	@cp -R .build/Build/Products/Debug/mlx-swift_Cmlx.bundle .build/Build/Products/Debug/SAM.app/Contents/Resources/
	@echo "�Fixing framework rpath in executable..."
	@install_name_tool -add_rpath @executable_path/../Frameworks .build/Build/Products/Debug/SAM.app/Contents/MacOS/SAM 2>/dev/null || true
	@echo "SUCCESS: App bundle created with embedded Info.plist, app icon, and frameworks"
	@echo "�Debug executable: .build/Build/Products/Debug/SAM"
	@echo "App bundle: .build/Build/Products/Debug/SAM.app"

# Bundle Python framework for model conversion (optional, adds ~250MB)
bundle-python:
	@echo "Bundling Python framework into SAM.app (Debug)..."
	@./scripts/bundle_python_standalone.sh Debug
	@echo "SUCCESS: Python framework bundled"
	@echo "Conversion scripts can now use bundled Python"

# Bundle Python for release builds
bundle-python-release:
	@echo "Bundling Python framework into SAM.app (Release)..."
	@./scripts/bundle_python_standalone.sh Release
	@echo "SUCCESS: Python framework bundled (Release)"
	@echo "Conversion scripts can now use bundled Python"

# Build debug version (WITH Python and ml-stable-diffusion - DEFAULT)
build-debug: build-debug-no-python bundle-python
	@echo "SUCCESS: Debug build with Python and ml-stable-diffusion complete"
	@echo ""
	@echo "Python environment: .build/Build/Products/Debug/SAM.app/Contents/Resources/python_env/"
	@echo "Conversion script: scripts/convert_sd_to_coreml.py"
	@echo "ml-stable-diffusion: external/ml-stable-diffusion/"

# Build debug with Python bundled (DEPRECATED - use build-debug instead)
build-debug-python: build-debug
	@echo "Note: build-debug-python is deprecated. Use 'make build-debug' (Python now included by default)"

# Build release version (no Python bundling)
build-release-no-python: llamacpp
	@echo "Setting build version from git commit..."
	@./scripts/set-build-version.sh Release
	@echo "Building SAM [Release]..."
	@echo "Using xcodebuild for MLX Metal library compatibility..."
	xcodebuild -scheme SAM-Package -configuration Release -derivedDataPath .build -destination 'platform=OS X'
	@echo "Copying llama.framework to PackageFrameworks..."
	@mkdir -p .build/Build/Products/Release/PackageFrameworks
	@cp -R external/llama.cpp/build-apple/llama.xcframework/macos-arm64/llama.framework .build/Build/Products/Release/PackageFrameworks/
	@echo "Fixing llama framework install name (before signing)..."
	@install_name_tool -id "@rpath/llama.framework/Versions/A/llama" .build/Build/Products/Release/PackageFrameworks/llama.framework/Versions/A/llama 2>/dev/null || true
	@echo "SUCCESS: llama.framework installed to PackageFrameworks"
	@echo "Creating .app bundle with Info.plist and app icon..."
	@mkdir -p .build/Build/Products/Release/SAM.app/Contents/MacOS
	@mkdir -p .build/Build/Products/Release/SAM.app/Contents/Resources
	@mkdir -p .build/Build/Products/Release/SAM.app/Contents/Frameworks
	@cp .build/Build/Products/Release/SAM .build/Build/Products/Release/SAM.app/Contents/MacOS/
	@cp Info.plist .build/Build/Products/Release/SAM.app/Contents/
	@cp Resources/sam-icon.icns .build/Build/Products/Release/SAM.app/Contents/Resources/
	@cp Resources/sam-icon.png .build/Build/Products/Release/SAM.app/Contents/Resources/
	@cp Resources/fewtarius.jpg .build/Build/Products/Release/SAM.app/Contents/Resources/
	@cp Resources/fewtarius-avatar.jpg .build/Build/Products/Release/SAM.app/Contents/Resources/
	@cp Resources/terminal.html .build/Build/Products/Release/SAM.app/Contents/Resources/
	@cp Resources/vendor/xterm/xterm.css .build/Build/Products/Release/SAM.app/Contents/Resources/
	@cp Resources/vendor/xterm/xterm.js .build/Build/Products/Release/SAM.app/Contents/Resources/
	@cp Resources/vendor/xterm/xterm-addon-fit.js .build/Build/Products/Release/SAM.app/Contents/Resources/
	@cp Sources/ConfigurationSystem/Resources/model_config.json .build/Build/Products/Release/SAM.app/Contents/Resources/
	@cp Resources/whats-new.json .build/Build/Products/Release/SAM.app/Contents/Resources/
	@cp -R .build/Build/Products/Release/PackageFrameworks/llama.framework .build/Build/Products/Release/SAM.app/Contents/Frameworks/
	@echo "Fixing llama framework install name..."
	@install_name_tool -id "@rpath/llama.framework/Versions/A/llama" .build/Build/Products/Release/SAM.app/Contents/Frameworks/llama.framework/Versions/A/llama 2>/dev/null || true
	@if [ -d ".build/Build/Products/Release/Sparkle.framework" ]; then \
		echo "Copying Sparkle.framework to app bundle..."; \
		cp -R .build/Build/Products/Release/Sparkle.framework .build/Build/Products/Release/SAM.app/Contents/Frameworks/; \
	fi
	@echo "�Copying MLX Metal library bundle to app Resources..."
	@cp -R .build/Build/Products/Release/mlx-swift_Cmlx.bundle .build/Build/Products/Release/SAM.app/Contents/Resources/
	@echo "Fixing framework rpath in executable..."
	@install_name_tool -add_rpath @executable_path/../Frameworks .build/Build/Products/Release/SAM.app/Contents/MacOS/SAM 2>/dev/null || true
	@echo "SUCCESS: App bundle created with embedded Info.plist, app icon, and frameworks"
	@echo "SUCCESS: Release build complete (no Python)"
	@echo "Release executable: .build/Build/Products/Release/SAM"
	@echo "App bundle: .build/Build/Products/Release/SAM.app"

# Build release version (WITH Python and ml-stable-diffusion - DEFAULT)
build-release: build-release-no-python bundle-python-release
	@echo "SUCCESS: Release build with Python and ml-stable-diffusion complete"
	@echo ""
	@echo "Python environment: .build/Build/Products/Release/SAM.app/Contents/Resources/python_env/"
	@echo "Conversion script: scripts/convert_sd_to_coreml.py"
	@echo "ml-stable-diffusion: external/ml-stable-diffusion/"

# Build release version with Python bundled (DEPRECATED - use build-release instead)
build-release-python: build-release
	@echo "Note: build-release-python is deprecated. Use 'make build-release' (Python now included by default)"

# Development Channel Build Targets

# Build development version (increments version with -dev tag)
build-dev:
	@echo "Building development version..."
	@./scripts/increment-dev-version.sh
	@$(MAKE) build-release
	@echo "SUCCESS: Development build complete"
	@echo "Version: $$(cat Info.plist | grep -A1 CFBundleShortVersionString | tail -1 | sed 's/.*<string>\(.*\)<\/string>/\1/')"

# Create signed development release (for distribution)
release-dev: build-dev
	@echo "Creating signed development release..."
	@if [ -z "$(DEVELOPER_ID)" ]; then \
		echo "ERROR: DEVELOPER_ID not set"; \
		echo "Set APPLE_DEVELOPER_ID in your environment"; \
		exit 1; \
	fi
	@echo "Development release requires manual steps:"
	@echo "1. Sign and notarize: ./scripts/sign-and-notarize.sh"
	@echo "2. Create GitHub pre-release with -dev tag"
	@echo "3. Update appcast-dev-items.xml manually"
	@echo "4. Run: make appcast-dev"
	@echo "5. Commit and push changes"

# Generate development appcast (merges dev items + stable releases)
appcast-dev:
	@echo "Generating development appcast..."
	@./scripts/generate-dev-appcast.sh
	@echo "SUCCESS: appcast-dev.xml generated"
	@echo "Remember to commit: git add appcast-dev.xml && git commit"

# Ensure Metal library bundle is available
# NOTE: The metallib is automatically built by mlx-swift package during xcodebuild.
# This target is kept for backwards compatibility but is no longer required as a build prerequisite.
# The built metallib appears at: .build/Build/Products/{Debug,Release}/mlx-swift_Cmlx.bundle/
metallib:
	@echo "MLX Metal library check (informational only)..."
	@echo "The metallib is built automatically by mlx-swift during xcodebuild."
	@if [ -f ".build/Build/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]; then \
		echo "SUCCESS: MLX Metal library found in build output"; \
		echo "Library: .build/Build/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"; \
	elif [ -f ".build/Build/Products/Release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]; then \
		echo "SUCCESS: MLX Metal library found in build output"; \
		echo "Library: .build/Build/Products/Release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"; \
	else \
		echo "INFO: MLX Metal library will be built during xcodebuild"; \
	fi

# Install the MLX bundle to Resources for runtime access (deprecated - bundle is built during xcodebuild)
install-metallib:
	@echo "NOTE: install-metallib is deprecated."
	@echo "The MLX Metal library is now automatically built by xcodebuild and copied to the app bundle."
	@echo "No manual installation required."

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	swift package clean
	rm -rf $(BUILD_DIR)
	@echo "Cleaning dependencies and caches..."
	rm -rf .dependencies/
	rm -rf .python_cache/
	rm -f .last_version 2>/dev/null || true
	rm -f Tests/*.txt Tests/*.log 2>/dev/null || true
	@echo "SUCCESS: Clean complete - all build artifacts, dependencies, and temporary files removed"

# Run all tests (Swift unit tests + Python E2E tests)
test: test-all

# Run Swift unit tests only
test-unit:
	@echo "Running Swift unit tests..."
	@echo ""
	xcodebuild test -scheme SAM-Package -destination 'platform=OS X' -derivedDataPath .build 2>&1 | tee .build/test-output.log
	@echo ""
	@echo "SUCCESS: Swift unit tests complete"
	@grep -E "Test Suite.*passed|Test Suite.*failed|Executed [0-9]+ tests" .build/test-output.log | tail -5

# Run Python E2E tests only (requires SAM to be running)
test-e2e:
	@echo "Running Python E2E tests..."
	@echo ""
	@if ! curl -s http://127.0.0.1:8080/api/models > /dev/null 2>&1; then \
		echo "ERROR: SAM server not running at http://127.0.0.1:8080"; \
		echo "Start SAM first: make run-background"; \
		exit 1; \
	fi
	@python3 Tests/e2e/mcp_e2e_tests.py
	@echo ""
	@echo "SUCCESS: E2E tests complete"

# Run all tests (comprehensive test runner)
test-all:
	@echo "Running comprehensive test suite..."
	@echo ""
	@./scripts/run_all_tests.sh

# Run quick tests (unit tests only, no E2E - faster for development)
test-quick:
	@echo "Running quick tests (Swift unit tests only)..."
	@echo ""
	@$(MAKE) test-unit

# Start SAM in background for E2E testing
run-background: build-debug
	@echo "Starting SAM in background for testing..."
	@pkill -9 SAM 2>/dev/null || true
	@sleep 1
	@nohup $(BUILD_DIR)/Build/Products/Debug/SAM.app/Contents/MacOS/SAM > sam_server.log 2>&1 &
	@sleep 3
	@if curl -s http://127.0.0.1:8080/api/models > /dev/null 2>&1; then \
		echo "SUCCESS: SAM server started at http://127.0.0.1:8080"; \
		echo "Server log: sam_server.log"; \
	else \
		echo "WARNING: SAM server may still be starting..."; \
		echo "Check: tail -f sam_server.log"; \
	fi

# Stop background SAM instance
stop-background:
	@echo "Stopping SAM server..."
	@pkill -9 SAM 2>/dev/null || true
	@echo "SUCCESS: SAM server stopped"

# Run tests with coverage (builds, starts server, runs all tests)
test-ci: build-debug run-background
	@echo "Running CI test suite..."
	@sleep 5
	@$(MAKE) test-all || ($(MAKE) stop-background && exit 1)
	@$(MAKE) stop-background
	@echo "SUCCESS: CI tests complete"

# Run the application (debug)
run: build-debug install-metallib
	@echo "Running $(EXECUTABLE_NAME)..."
	$(BUILD_DIR)/Build/Products/Debug/$(EXECUTABLE_NAME)

# Run the application (release)
run-release: build-release install-metallib
	@echo "Running $(EXECUTABLE_NAME) [Release]..."
	$(BUILD_DIR)/Build/Products/Release/$(EXECUTABLE_NAME)

# Show help
help:
	@echo "SAM Makefile Help"
	@echo ""
	@echo "Build Commands:"
	@echo "  build               - Build the project (release mode)"
	@echo "  build-debug         - Build in debug mode WITH Python (~250MB)"
	@echo "  build-release       - Build in release mode (no Python)"
	@echo "  build-release-python - Build in release mode WITH Python (~250MB)"
	@echo "  clean               - Clean build artifacts"
	@echo ""
	@echo "Testing Commands:"
	@echo "  test                - Run all tests (unit + E2E)"
	@echo "  test-unit           - Run Swift unit tests only"
	@echo "  test-e2e            - Run Python E2E tests (requires running SAM)"
	@echo "  test-quick          - Run quick tests (unit only, faster)"
	@echo "  test-ci             - CI mode: build, start SAM, run all tests"
	@echo "  run-background      - Start SAM in background for E2E testing"
	@echo "  stop-background     - Stop background SAM instance"
	@echo ""
	@echo "Python Bundling:"
	@echo "  bundle-python         - Bundle Python into Debug build"
	@echo "  bundle-python-release - Bundle Python into Release build"
	@echo ""
	@echo "MLX Commands:"
	@echo "  metallib       - Verify MLX Metal library bundle"
	@echo "  install-metallib - Install Metal library to Resources"
	@echo ""
	@echo "Run Commands:"
	@echo "  run            - Build and run (debug)"
	@echo "  run-release    - Build and run (release)"
	@echo ""
	@echo "Distribution Commands:"
	@echo "  dist           - Create clean distribution in ../SAM-dist"
	@echo ""
	@echo "Code Signing Commands:"
	@echo "  sign           - Sign release build with Developer ID"
	@echo "  sign-debug     - Sign debug build"
	@echo "  sign-release   - Sign release build"
	@echo "  verify-signature - Verify app signature and Gatekeeper"
	@echo "  notarize       - Submit signed app for Apple notarization"
	@echo "  staple         - Staple notarization ticket to app"
	@echo "  distribute     - Create distribution package (sign + notarize + staple)"
	@echo "  production     - Complete production build (build + sign + notarize)"
	@echo ""
	@echo "Usage Examples:"
	@echo "  make build && make run"
	@echo "  make test-unit               # Quick unit tests during development"
	@echo "  make run-background && make test-e2e  # E2E tests"
	@echo "  make test-ci                 # Full CI test pipeline"
	@echo "  make clean && make build-release"
	@echo "  make sign && make verify-signature"
	@echo "  make production  # Full production build end-to-end"
	@echo "  make dist        # Create distribution repository"
	@echo ""
	@echo "Required Structure:"
	@echo "  $(BUNDLE_NAME)/default.metallib - MLX Metal library"

# MARK: - Code Signing Targets

# Sign the release build (default)
sign: sign-release

# Sign debug build
sign-debug: build-debug
	@echo "Signing SAM.app (Debug) with Developer ID..."
	@if [ -z "$(DEVELOPER_ID)" ]; then \
		echo "ERROR: ERROR: APPLE_DEVELOPER_ID environment variable not set"; \
		echo ""; \
		echo "Set it in your shell profile (~/.profile, ~/.zshrc, etc.):"; \
		echo '  export APPLE_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"'; \
		echo ""; \
		echo "Or set it temporarily:"; \
		echo '  export APPLE_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"'; \
		echo '  make sign-debug'; \
		exit 1; \
	fi
	@if [ ! -f "$(ENTITLEMENTS)" ]; then \
		echo "ERROR: ERROR: $(ENTITLEMENTS) not found"; \
		exit 1; \
	fi
	codesign --force --sign $(DEVELOPER_ID) \
		--entitlements $(ENTITLEMENTS) \
		--options runtime \
		--timestamp \
		--deep \
		$(APP_BUNDLE_DEBUG)
	@echo "SUCCESS: Debug build signed successfully"

# Sign release build
sign-release: build-release
	@echo "Signing SAM.app (Release) with Developer ID..."
	@if [ -z "$(DEVELOPER_ID)" ]; then \
		echo "ERROR: ERROR: APPLE_DEVELOPER_ID environment variable not set"; \
		echo ""; \
		echo "Set it in your shell profile (~/.profile, ~/.zshrc, etc.):"; \
		echo '  export APPLE_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"'; \
		echo ""; \
		echo "Or set it temporarily:"; \
		echo '  export APPLE_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"'; \
		echo '  make sign-release'; \
		exit 1; \
	fi
	@if [ ! -f "$(ENTITLEMENTS)" ]; then \
		echo "ERROR: ERROR: $(ENTITLEMENTS) not found"; \
		exit 1; \
	fi
	codesign --force --sign $(DEVELOPER_ID) \
		--entitlements $(ENTITLEMENTS) \
		--options runtime \
		--timestamp \
		--deep \
		$(APP_BUNDLE_RELEASE)
	@echo "SUCCESS: Release build signed successfully"

# Verify app signature and Gatekeeper acceptance
verify-signature:
	@echo "Verifying SAM.app signature..."
	@if [ -d "$(APP_BUNDLE_RELEASE)" ]; then \
		echo "Verifying Release Build:"; \
		codesign --verify --verbose=4 $(APP_BUNDLE_RELEASE) 2>&1; \
		echo ""; \
		echo "Checking Gatekeeper Assessment:"; \
		spctl --assess --type execute --verbose=4 $(APP_BUNDLE_RELEASE) 2>&1 || true; \
		echo ""; \
		echo "Signature Details:"; \
		codesign -dv --verbose=4 $(APP_BUNDLE_RELEASE) 2>&1; \
	elif [ -d "$(APP_BUNDLE_DEBUG)" ]; then \
		echo "Verifying Debug Build:"; \
		codesign --verify --verbose=4 $(APP_BUNDLE_DEBUG) 2>&1; \
		echo ""; \
		echo "Checking Gatekeeper Assessment:"; \
		spctl --assess --type execute --verbose=4 $(APP_BUNDLE_DEBUG) 2>&1 || true; \
		echo ""; \
		echo "Signature Details:"; \
		codesign -dv --verbose=4 $(APP_BUNDLE_DEBUG) 2>&1; \
	else \
		echo "ERROR: No app bundle found. Run 'make build' first."; \
		exit 1; \
	fi

# Submit app for Apple notarization (uses automated scripts)
notarize:
	@echo "Submitting SAM.app for notarization (via automated scripts)..."
	@if [ ! -f "./scripts/sign_app.sh" ] || [ ! -f "./scripts/notarize_app.sh" ]; then \
		echo "ERROR: ERROR: Signing/notarization scripts not found"; \
		echo "Expected: scripts/sign_app.sh and scripts/notarize_app.sh"; \
		exit 1; \
	fi
	@echo "Step 1: Signing app..."
	@./scripts/sign_app.sh
	@echo ""
	@echo "Step 2: Submitting for notarization..."
	@./scripts/notarize_app.sh
	@echo "SUCCESS: App signed, notarized, and stapled successfully"

# Staple notarization ticket to app (if needed separately)
staple:
	@echo "Stapling notarization ticket to SAM.app..."
	@if [ ! -d "$(APP_BUNDLE_RELEASE)" ]; then \
		echo "ERROR: ERROR: Release app bundle not found"; \
		exit 1; \
	fi
	xcrun stapler staple $(APP_BUNDLE_RELEASE)
	@echo "SUCCESS: Notarization ticket stapled successfully"

# Create DMG for distribution
create-dmg:
	@echo "Creating DMG installer..."
	@if [ ! -d "$(APP_BUNDLE_RELEASE)" ]; then \
		echo "ERROR: ERROR: Release app bundle not found"; \
		exit 1; \
	fi
	@ABS_APP_PATH=$$(cd "$(APP_BUNDLE_RELEASE)" && pwd); \
	VERSION=$$(defaults read "$$ABS_APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "dev"); \
	DMG_PATH="dist/SAM-$$VERSION.dmg"; \
	echo "  → Version: $$VERSION"; \
	echo "  → Output: $$DMG_PATH"; \
	mkdir -p dist; \
	rm -f "$$DMG_PATH"; \
	hdiutil create -volname "SAM $$VERSION" \
		-srcfolder "$(APP_BUNDLE_RELEASE)" \
		-ov -format UDZO \
		"$$DMG_PATH"; \
	echo "SUCCESS: DMG created: $$DMG_PATH"; \
	echo "DMG size: $$(du -h $$DMG_PATH | cut -f1)"

# Create complete distribution package (build, sign, notarize, DMG)
distribute: build-release-python notarize create-dmg
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "SAM Distribution Ready!"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "SUCCESS: Built: Release configuration"
	@echo "SUCCESS: Signed: Developer ID"
	@echo "SUCCESS: Notarized: Apple-approved"
	@echo "SUCCESS: Stapled: Offline validation ready"
	@echo "SUCCESS: DMG: Created for distribution"
	@echo ""
	@ABS_APP_PATH=$$(cd "$(APP_BUNDLE_RELEASE)" && pwd); \
	VERSION=$$(defaults read "$$ABS_APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "dev"); \
	ARCHIVE="dist/SAM-$$VERSION.zip"; \
	DMG="dist/SAM-$$VERSION.dmg"; \
	if [ -f "$$ARCHIVE" ]; then \
		echo "Distribution ZIP: $$ARCHIVE ($$(du -h $$ARCHIVE | cut -f1))"; \
	fi; \
	if [ -f "$$DMG" ]; then \
		echo "Distribution DMG: $$DMG ($$(du -h $$DMG | cut -f1))"; \
	fi
	@echo ""
	@echo "Ready for distribution:"
	@echo "   • DMG for user downloads (recommended)"
	@echo "   • ZIP for automated deployments"
	@echo "   • Both notarized and stapled"
	@echo ""

# Sign, notarize, and create distribution (assumes build already complete)
# Use this in CI/CD workflows where build-release was already run
production-sign-only:
	@echo "Creating signed and notarized distribution (skipping build)..."
	@echo ""
	@if [ ! -d "$(APP_BUNDLE_RELEASE)" ]; then \
		echo "ERROR: Release app bundle not found at $(APP_BUNDLE_RELEASE)"; \
		echo "Run 'make build-release' first"; \
		exit 1; \
	fi
	@echo "Signing and notarizing..."
	@$(MAKE) notarize
	@echo ""
	@echo "Creating DMG..."
	@$(MAKE) create-dmg
	@echo ""
	@echo "Updating appcast.xml..."
	@ABS_APP_PATH=$$(cd "$(APP_BUNDLE_RELEASE)" && pwd); \
	VERSION=$$(defaults read "$$ABS_APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "dev"); \
	DMG_PATH="dist/SAM-$$VERSION.dmg"; \
	if [ -f "$$DMG_PATH" ]; then \
		./scripts/update_appcast.sh "$$VERSION" "$$DMG_PATH" || echo "WARNING: Failed to update appcast.xml (manual update required)"; \
	else \
		echo "WARNING: DMG not found at $$DMG_PATH - cannot update appcast.xml"; \
	fi
	@echo ""
	@echo "SUCCESS: Production distribution complete (sign-only mode)!"
	@echo ""
	@echo "Production Release Checklist:"
	@echo "   SUCCESS: Code signed with Developer ID"
	@echo "   SUCCESS: Submitted to Apple for notarization"
	@echo "   SUCCESS: Notarization ticket stapled"
	@echo "   SUCCESS: Distribution DMG created"
	@echo "   SUCCESS: appcast.xml updated"

# Alias for distribute - builds, signs, notarizes, creates DMG, updates appcast.xml, and prepares production release
production: 
	@echo "Checking if version bump is needed..."
	@./scripts/check-version.sh
	@echo ""
	@echo "Building release with Python bundling..."
	@$(MAKE) build-release-python
	@echo ""
	@echo "Creating distribution..."
	@$(MAKE) notarize
	@$(MAKE) create-dmg
	@echo ""
	@echo "Updating appcast.xml..."
	@ABS_APP_PATH=$$(cd "$(APP_BUNDLE_RELEASE)" && pwd); \
	VERSION=$$(defaults read "$$ABS_APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "dev"); \
	DMG_PATH="dist/SAM-$$VERSION.dmg"; \
	if [ -f "$$DMG_PATH" ]; then \
		./scripts/update_appcast.sh "$$VERSION" "$$DMG_PATH" || echo "WARNING: Failed to update appcast.xml (manual update required)"; \
	else \
		echo "WARNING: DMG not found at $$DMG_PATH - cannot update appcast.xml"; \
	fi
	@echo ""
	@echo "SUCCESS: Production build complete!"
	@echo ""
	@echo "Production Release Checklist:"
	@echo "   SUCCESS: Release build compiled"
	@echo "   SUCCESS: App bundle created with all frameworks"

# Sign and notarize existing release build (for CI/CD - assumes build already complete)
sign-only-release:
	@echo "Configuring keychain access..."
	@security list-keychains -s login.keychain-db
	@echo "Keychain should be unlocked by environment script"
	@echo ""
	@echo "Signing and notarizing release build..."
	@$(MAKE) notarize
	@echo ""
	@echo "Creating DMG..."
	@$(MAKE) create-dmg
	@echo ""
	@echo "Updating appcast.xml..."
	@ABS_APP_PATH=$$(cd "$(APP_BUNDLE_RELEASE)" && pwd); \
	VERSION=$$(defaults read "$$ABS_APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "dev"); \
	DMG_PATH="dist/SAM-$$VERSION.dmg"; \
	if [ -f "$$DMG_PATH" ]; then \
		./scripts/update_appcast.sh "$$VERSION" "$$DMG_PATH" || echo "WARNING: Failed to update appcast.xml"; \
	else \
		echo "WARNING: DMG not found at $$DMG_PATH"; \
	fi
	@echo ""
	@echo "Build complete"
	@echo "Next Steps:"
	@echo "   1. Review appcast.xml changes: git diff appcast.xml"
	@echo "   2. Test the DMG: open dist/SAM-*.dmg"
	@echo "   3. Drag SAM to /Applications from DMG"
	@echo "   4. Verify signature: make verify-signature"
	@echo "   5. Commit appcast.xml: git add appcast.xml && git commit -m 'chore: Update appcast.xml for vX.Y.Z'"
	@echo "   6. Upload DMG to distribution platform"
	@echo ""

# MARK: - Distribution Target

# Create clean distribution in ../SAM-dist
dist:
	@echo "Creating SAM distribution..."
	@if [ ! -f "scripts/create-dist.sh" ]; then \
		echo "ERROR: ERROR: scripts/create-dist.sh not found"; \
		exit 1; \
	fi
	@chmod +x scripts/create-dist.sh
	@./scripts/create-dist.sh
	@echo ""
	@echo "SUCCESS: Distribution created in ../SAM-dist"
	@echo "Next: cd ../SAM-dist && make build-debug"
