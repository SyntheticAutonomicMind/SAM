#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

#
# Build CachyLLama's llama-server binary for SAM.
#
# Produces a standalone arm64 binary at external/llama.cpp/build-server/llama-server.
# The binary is a self-contained OpenAI-compatible HTTP server that SAM can
# spawn as a child process to gain access to CachyLLama's server-only features:
#   - SSD-backed KV cache (--cache-ssd-hot-ram / --cache-ssd-warm-ram)
#   - Per-conversation slot affinity (llama_user_id)
#   - System prompt KV cache (--system-prompt-cache)
#   - Per-user concurrency cap (--max-concurrent-per-user)
#   - Idle-slot save / clear (--cache-idle-slots)
#
# The C library path is already built by build-llama-macos.sh and embedded in
# SAM. The server binary is a separate deliverable that runs out-of-process.

set -e

cd "$(dirname "$0")/../external/llama.cpp"

echo "Building CachyLLama llama-server (macOS arm64)..."

if ! command -v cmake &> /dev/null; then
    echo "ERROR: cmake is required but not found"
    exit 1
fi

# Build configuration: match the framework build so both share the same Metal/BLAS.
MACOS_MIN_OS_VERSION=13.3
BUILD_DIR="build-server"
OUTPUT="${BUILD_DIR}/bin/llama-server"

rm -rf "${BUILD_DIR}"

cmake -B "${BUILD_DIR}" -G "Unix Makefiles" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION} \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_C_FLAGS="-Wno-macro-redefined" \
    -DCMAKE_CXX_FLAGS="-Wno-macro-redefined" \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TOOLS=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_CURL=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS_DEFAULT=ON \
    -DGGML_METAL_USE_BF16=ON \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF \
    .

cmake --build "${BUILD_DIR}" --config Release --target llama-server -- -j$(sysctl -n hw.ncpu)

if [ ! -f "${OUTPUT}" ]; then
    echo "ERROR: llama-server binary not found at ${OUTPUT}"
    exit 1
fi

# Code sign with the local development identity so it can run on the user's Mac.
codesign --force --sign - "${OUTPUT}" 2>/dev/null || true

echo "SUCCESS: llama-server built at $(pwd)/${OUTPUT}"
file "${OUTPUT}"
