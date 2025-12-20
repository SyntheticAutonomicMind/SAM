#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

set -euo pipefail

echo "Checking build environment for SAM (macOS)..."

fail=0

check() {
  if ! command -v "$1" &>/dev/null; then
    echo " ERROR: $1 -> MISSING"
    fail=1
  else
    echo " SUCCESS: $1 -> $(command -v $1)"
  fi
}

check cmake
check clang
check clang++
check xcodebuild
check xcrun
check libtool
check dsymutil
check git
check swift
check make

# ccache optional
if command -v ccache &>/dev/null; then
  echo " SUCCESS: ccache -> $(command -v ccache) (optional)"
else
  echo " ℹ️  ccache -> not found (optional, speeds up rebuilds). Install via: brew install ccache"
fi

# Check Xcode dev path
if xcode-select -p &>/dev/null; then
  echo " SUCCESS: xcode-select -> $(xcode-select -p)"
else
  echo " ERROR: xcode-select not configured. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  fail=1
fi

# Check metal toolchain presence
if xcrun --find metal &>/dev/null; then
  echo " SUCCESS: Metal toolchain (metal) -> $(xcrun --find metal)"
else
  echo " ERROR: Metal toolchain (metal) NOT FOUND"
  echo "    Install with: xcodebuild -downloadComponent \"MetalToolchain\" (no sudo required)"
  echo "    Or open Xcode and accept/install additional components, or run: xcodebuild -runFirstLaunch"
  fail=1
fi

# Check llama.xcframework
LLAMA_XCF="external/llama.cpp/build-apple/llama.xcframework"
if [ -d "$LLAMA_XCF" ]; then
  echo " SUCCESS: llama.xcframework -> $LLAMA_XCF"
else
  echo " ERROR: llama.xcframework missing -> $LLAMA_XCF"
  echo "    Build it by running: cd external/llama.cpp && ./build-xcframework.sh"
  fail=1
fi

# Check Swift packages resolved
if [ -f ".build/packageresolved" ] || [ -d ".build/SourcePackages" ] || swift package show-dependencies &>/dev/null; then
  echo " SUCCESS: Swift packages: swift package resolver state available"
else
  echo " ℹ️  Swift packages: consider running: swift package resolve"
fi

if [ $fail -ne 0 ]; then
  echo "\nOne or more checks failed. Fix the issues above and re-run this script."
  exit 2
else
  echo "\nAll checks passed (or non-fatal warnings shown). You may proceed to: git submodule update --init --recursive && make build-debug"
  exit 0
fi
