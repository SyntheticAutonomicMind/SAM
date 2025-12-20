#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

#
# SAM macOS-only llama.cpp framework builder
# Simplified version of build-xcframework.sh focusing only on macOS arm64+x86_64
# Original: external/llama.cpp/build-xcframework.sh

set -e

echo "🦙 Building llama.cpp framework for macOS..."

# Build configuration
MACOS_MIN_OS_VERSION=13.3
BUILD_SHARED_LIBS=OFF
LLAMA_BUILD_EXAMPLES=OFF
LLAMA_BUILD_TOOLS=OFF
LLAMA_BUILD_TESTS=OFF
LLAMA_BUILD_SERVER=OFF
GGML_METAL=ON
GGML_METAL_EMBED_LIBRARY=ON
GGML_BLAS_DEFAULT=ON
GGML_METAL_USE_BF16=ON
GGML_OPENMP=OFF

COMMON_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"
COMMON_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"

# Common CMake arguments
COMMON_CMAKE_ARGS=(
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT="dwarf-with-dsym"
    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES
    -DCMAKE_XCODE_ATTRIBUTE_COPY_PHASE_STRIP=NO
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO
    -DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM=ggml
    -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS}
    -DLLAMA_BUILD_EXAMPLES=${LLAMA_BUILD_EXAMPLES}
    -DLLAMA_BUILD_TOOLS=${LLAMA_BUILD_TOOLS}
    -DLLAMA_BUILD_TESTS=${LLAMA_BUILD_TESTS}
    -DLLAMA_BUILD_SERVER=${LLAMA_BUILD_SERVER}
    -DGGML_METAL_EMBED_LIBRARY=${GGML_METAL_EMBED_LIBRARY}
    -DGGML_BLAS_DEFAULT=${GGML_BLAS_DEFAULT}
    -DGGML_METAL=${GGML_METAL}
    -DGGML_METAL_USE_BF16=${GGML_METAL_USE_BF16}
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=${GGML_OPENMP}
)

# Check for required tools
echo "Checking for required tools..."
for tool in cmake xcodebuild libtool dsymutil; do
    if ! command -v $tool &> /dev/null; then
        echo "ERROR: $tool is required but not found"
        exit 1
    fi
done

# Ensure Metal toolchain is available (required to compile .metal files)
if ! xcrun --find metal >/dev/null 2>&1; then
    echo "ℹ️  Metal toolchain not found. Attempting to download MetalToolchain with xcodebuild..."
    # Try to download the Metal toolchain component (xcodebuild will handle permissions/prompts)
    xcodebuild -downloadComponent "MetalToolchain" || true
    # Run first-launch actions to finish installing any missing components
    xcodebuild -runFirstLaunch || true
    if ! xcrun --find metal >/dev/null 2>&1; then
        echo "ERROR: Metal toolchain still not available after attempting automatic install."
        echo "Run: xcodebuild -downloadComponent \"MetalToolchain\" or open Xcode and accept/install additional components."
        exit 1
    else
        echo "SUCCESS: Metal toolchain installed/available"
    fi
else
    echo "SUCCESS: Metal toolchain available: $(xcrun --find metal)"
fi

# Clean up previous builds
echo "🧹 Cleaning previous build..."
rm -rf build-apple
rm -rf build-macos

# Configure with CMake (arm64 only for Apple Silicon)
echo "⚙️  Configuring llama.cpp with CMake (arm64-only)..."
cmake -B build-macos -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION} \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -DLLAMA_CURL=OFF \
    -S .

# Build with Xcode
echo "🔨 Building llama.cpp (Release)..."
cmake --build build-macos --config Release -- -quiet

# Setup framework structure
echo "INFO: Setting up framework structure..."
framework_name="llama"
build_dir="build-macos"
min_os_version="${MACOS_MIN_OS_VERSION}"

# macOS versioned structure
mkdir -p ${build_dir}/framework/${framework_name}.framework/Versions/A/Headers
mkdir -p ${build_dir}/framework/${framework_name}.framework/Versions/A/Modules
mkdir -p ${build_dir}/framework/${framework_name}.framework/Versions/A/Resources

# Create symbolic links
ln -sf A ${build_dir}/framework/${framework_name}.framework/Versions/Current
ln -sf Versions/Current/Headers ${build_dir}/framework/${framework_name}.framework/Headers
ln -sf Versions/Current/Modules ${build_dir}/framework/${framework_name}.framework/Modules
ln -sf Versions/Current/Resources ${build_dir}/framework/${framework_name}.framework/Resources
ln -sf Versions/Current/${framework_name} ${build_dir}/framework/${framework_name}.framework/${framework_name}

# Copy headers
header_path=${build_dir}/framework/${framework_name}.framework/Versions/A/Headers/
cp include/llama.h             ${header_path}
cp ggml/include/ggml.h         ${header_path}
cp ggml/include/ggml-opt.h     ${header_path}
cp ggml/include/ggml-alloc.h   ${header_path}
cp ggml/include/ggml-backend.h ${header_path}
cp ggml/include/ggml-metal.h   ${header_path}
cp ggml/include/ggml-cpu.h     ${header_path}
cp ggml/include/ggml-blas.h    ${header_path}
cp ggml/include/gguf.h         ${header_path}

# Create module map
module_path=${build_dir}/framework/${framework_name}.framework/Versions/A/Modules/
cat > ${module_path}module.modulemap << 'EOF'
framework module llama {
    header "llama.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
EOF

# Create Info.plist
cat > ${build_dir}/framework/${framework_name}.framework/Versions/A/Resources/Info.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>llama</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.llama</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>llama</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${min_os_version}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>DTPlatformName</key>
    <string>macosx</string>
    <key>DTSDKName</key>
    <string>macosx</string>
</dict>
</plist>
EOF

# Create dynamic library from static libraries
echo "🔗 Creating dynamic library from static libraries..."
base_dir="$(pwd)"
output_lib="${build_dir}/framework/${framework_name}.framework/Versions/A/${framework_name}"

libs=(
    "${base_dir}/${build_dir}/src/Release/libllama.a"
    "${base_dir}/${build_dir}/ggml/src/Release/libggml.a"
    "${base_dir}/${build_dir}/ggml/src/Release/libggml-base.a"
    "${base_dir}/${build_dir}/ggml/src/Release/libggml-cpu.a"
    "${base_dir}/${build_dir}/ggml/src/ggml-metal/Release/libggml-metal.a"
    "${base_dir}/${build_dir}/ggml/src/ggml-blas/Release/libggml-blas.a"
)

# Create temporary directory
temp_dir="${base_dir}/${build_dir}/temp"
mkdir -p "${temp_dir}"

# Combine static libraries (suppress architecture warnings)
libtool -static -o "${temp_dir}/combined.a" "${libs[@]}" 2> /dev/null

# Link into dynamic library
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
install_name="@rpath/llama.framework/Versions/Current/llama"

# Use clang to create arm64-only dynamic library
clang -dynamiclib \
    -arch arm64 \
    -isysroot "${sdk_path}" \
    -mmacosx-version-min=${MACOS_MIN_OS_VERSION} \
    -framework Accelerate \
    -framework Foundation \
    -framework Metal \
    -framework MetalKit \
    -lc++ \
    -install_name "${install_name}" \
    -Wl,-force_load,"${temp_dir}/combined.a" \
    -o "${output_lib}"

# Generate debug symbols
echo "DEBUG: Generating debug symbols..."
mkdir -p ${build_dir}/dSYMS
dsymutil -o ${build_dir}/dSYMS/llama.dSYM ${output_lib}

# Create XCFramework
echo "INFO: Creating XCFramework..."
mkdir -p build-apple
xcodebuild -create-xcframework \
    -framework $(pwd)/build-macos/framework/llama.framework \
    -debug-symbols $(pwd)/build-macos/dSYMS/llama.dSYM \
    -output $(pwd)/build-apple/llama.xcframework

echo "SUCCESS: llama.cpp framework built successfully!"
echo "📍 Framework: build-apple/llama.xcframework"
echo "📍 macOS framework: build-apple/llama.xcframework/macos-arm64/llama.framework"
