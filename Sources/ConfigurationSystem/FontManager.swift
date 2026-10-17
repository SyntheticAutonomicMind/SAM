// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Foundation

/// Environment key for font size scaling throughout the app.
/// Applied at the window level via `.environment(\.fontSizeScale, ...)` in MainWindowView.
public struct FontSizeScaleKey: EnvironmentKey {
    /// Default scale factor is 1.0 (no change).
    public static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    var fontSizeScale: Double {
        get { self[FontSizeScaleKey.self] }
        set { self[FontSizeScaleKey.self] = newValue }
    }
}

/// FontManager provides scaled Font instances based on a scale factor.
///
/// Usage:
/// - Inject into environment: `.environment(\.fontSizeScale, 1.15)` at the window root
/// - Read in views: `@Environment(\.fontSizeScale) private var fontSizeScale`
/// - Get scaled fonts: `FontManager.shared.body(fontSizeScale)`
///
/// Scale options: 0.85, 1.0, 1.15, 1.3 (stored in AppStorage "fontSizeScale")
@MainActor
public final class FontManager {
    public static let shared = FontManager()

    /// AppStorage key for the font size scale setting.
    public static let storageKey = "fontSizeScale"

    /// Available font size scale options (used in preferences picker).
    public static let scaleOptions: [(label: String, value: Double)] = [
        (label: "Smaller", value: 0.85),
        (label: "Default", value: 1.0),
        (label: "Larger", value: 1.15),
        (label: "Largest", value: 1.3)
    ]

    /// Default scale value (matches AppStorage default).
    public static let defaultScale: Double = 1.0

    private init() {}

    /// Scale a point size by the given factor, clamped to a minimum readable size.
    private func scaled(_ size: CGFloat, _ scale: Double) -> CGFloat {
        let result = size * CGFloat(scale)
        return max(result, 4.0)
    }

    // MARK: - Scaled System Fonts

    public func largeTitle(_ scale: Double) -> Font { .system(size: scaled(34, scale), weight: .bold, design: .default) }
    public func title(_ scale: Double) -> Font { .system(size: scaled(28, scale), weight: .bold, design: .default) }
    public func title2(_ scale: Double) -> Font { .system(size: scaled(24, scale), weight: .bold, design: .default) }
    public func title3(_ scale: Double) -> Font { .system(size: scaled(20, scale), weight: .semibold, design: .default) }
    public func headline(_ scale: Double) -> Font { .system(size: scaled(17, scale), weight: .semibold, design: .default) }
    public func subheadline(_ scale: Double) -> Font { .system(size: scaled(15, scale), weight: .medium, design: .default) }
    public func body(_ scale: Double) -> Font { .system(size: scaled(17, scale), weight: .regular, design: .default) }
    public func callout(_ scale: Double) -> Font { .system(size: scaled(16, scale), weight: .regular, design: .default) }
    public func footnote(_ scale: Double) -> Font { .system(size: scaled(14, scale), weight: .regular, design: .default) }
    public func caption(_ scale: Double) -> Font { .system(size: scaled(12, scale), weight: .regular, design: .default) }
    public func caption2(_ scale: Double) -> Font { .system(size: scaled(11, scale), weight: .regular, design: .default) }

    /// Scale a specific font size (for arbitrary .system(size:) calls).
    public func customSize(_ size: CGFloat, _ scale: Double) -> CGFloat {
        scaled(size, scale)
    }

    /// Scale a monospaced body font for code blocks.
    public func monospacedBody(_ scale: Double) -> Font {
        .system(size: scaled(13, scale), weight: .regular, design: .monospaced)
    }
}
