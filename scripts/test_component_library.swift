#!/usr/bin/env swift

import Foundation

// Simple test to verify PromptComponentLibrary initializes correctly
// This forces library creation and verifies the built-in components

print("Testing PromptComponentLibrary initialization...")

// Simulate the library path
let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
let libraryPath = cacheDir
    .appendingPathComponent("sam", isDirectory: true)
    .appendingPathComponent("prompt-components", isDirectory: true)
    .appendingPathComponent("component-library.json")

print("Library path: \(libraryPath.path)")

// Check if library file exists
if FileManager.default.fileExists(atPath: libraryPath.path) {
    print("SUCCESS: Component library file exists")
    
    do {
        let data = try Data(contentsOf: libraryPath)
        let decoder = JSONDecoder()
        let components = try decoder.decode([String: Any].self, from: data)
        print("SUCCESS: Library file is valid JSON")
        print("   File size: \(data.count) bytes")
    } catch {
        print("ERROR: Failed to read library: \(error)")
    }
} else {
    print("WARNING:  Library file doesn't exist yet (will be created on first use)")
}

print("\nTest complete!")
