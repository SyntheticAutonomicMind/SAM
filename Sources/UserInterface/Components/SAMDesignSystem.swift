// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging

// MARK: - UI Setup

// MARK: - Design System Configuration

public struct SAMDesignSystem {

    // MARK: - Color Palette
    public struct Colors {
        public static let primary = Color.primary
        public static let secondary = Color.secondary
        public static let accent = Color.accentColor

        /// Semantic Colors.
        public static let success = Color.green
        public static let warning = Color.orange
        public static let error = Color.red
        public static let info = Color.blue

        /// Background Colors.
        public static let background = Color(NSColor.controlBackgroundColor)
        public static let surfaceLight = Color(NSColor.controlBackgroundColor)
        public static let surfaceDark = Color(NSColor.windowBackgroundColor)

        /// Interactive Colors.
        public static let hoverOverlay = Color.primary.opacity(0.05)
        public static let selectedOverlay = Color.accentColor.opacity(0.15)
        public static let activeIndicator = Color.accentColor
    }

    // MARK: - Typography
    public struct Typography {
        public static let largeTitle = Font.largeTitle.weight(.bold)
        public static let title = Font.title.weight(.semibold)
        public static let title2 = Font.title2.weight(.semibold)
        public static let title3 = Font.title3.weight(.medium)
        public static let headline = Font.headline.weight(.semibold)
        public static let subheadline = Font.subheadline.weight(.medium)
        public static let body = Font.body
        public static let bodyMedium = Font.body.weight(.medium)
        public static let caption = Font.caption
        public static let caption2 = Font.caption2
    }

    // MARK: - Spacing
    public struct Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 24
        public static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radius
    public struct CornerRadius {
        public static let sm: CGFloat = 4
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16
    }

    // MARK: - Shadows
    public struct Shadows {
        nonisolated(unsafe) public static let small = Shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        nonisolated(unsafe) public static let medium = Shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        nonisolated(unsafe) public static let large = Shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Unified Card Component

public struct SAMCard<Content: View>: View {
    let content: Content
    let padding: CGFloat
    let cornerRadius: CGFloat
    let shadow: SAMDesignSystem.Shadows.Shadow?
    let backgroundColor: Color

    public init(
        padding: CGFloat = SAMDesignSystem.Spacing.lg,
        cornerRadius: CGFloat = SAMDesignSystem.CornerRadius.lg,
        shadow: SAMDesignSystem.Shadows.Shadow? = SAMDesignSystem.Shadows.medium,
        backgroundColor: Color = SAMDesignSystem.Colors.surfaceLight,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.backgroundColor = backgroundColor
    }

    public var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(backgroundColor)
                    .shadow(
                        color: shadow?.color ?? .clear,
                        radius: shadow?.radius ?? 0,
                        x: shadow?.x ?? 0,
                        y: shadow?.y ?? 0
                    )
            )
    }
}

// MARK: - Actions

public struct SAMButtonStyle: ButtonStyle {
    let variant: Variant
    let size: Size
    let isDisabled: Bool

    public enum Variant {
        case primary, secondary, ghost, destructive
    }

    public enum Size {
        case small, medium, large
    }

    public init(variant: Variant = .primary, size: Size = .medium, isDisabled: Bool = false) {
        self.variant = variant
        self.size = size
        self.isDisabled = isDisabled
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(fontForSize)
            .foregroundColor(foregroundColor(isPressed: configuration.isPressed))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: SAMDesignSystem.CornerRadius.md)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SAMDesignSystem.CornerRadius.md)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.6 : 1.0)
    }

    private var fontForSize: Font {
        switch size {
        case .small: return SAMDesignSystem.Typography.caption.weight(.medium)
        case .medium: return SAMDesignSystem.Typography.body.weight(.medium)
        case .large: return SAMDesignSystem.Typography.headline
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small: return SAMDesignSystem.Spacing.md
        case .medium: return SAMDesignSystem.Spacing.lg
        case .large: return SAMDesignSystem.Spacing.xl
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .small: return SAMDesignSystem.Spacing.xs
        case .medium: return SAMDesignSystem.Spacing.sm
        case .large: return SAMDesignSystem.Spacing.md
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        let opacity = isPressed ? 0.8 : 1.0

        switch variant {
        case .primary:
            return SAMDesignSystem.Colors.accent.opacity(opacity)

        case .secondary:
            return SAMDesignSystem.Colors.surfaceLight.opacity(opacity)

        case .ghost:
            return isPressed ? SAMDesignSystem.Colors.hoverOverlay : Color.clear

        case .destructive:
            return SAMDesignSystem.Colors.error.opacity(opacity)
        }
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary, .destructive:
            return .white

        case .secondary, .ghost:
            return SAMDesignSystem.Colors.primary
        }
    }

    private var borderColor: Color {
        switch variant {
        case .primary, .destructive, .ghost:
            return Color.clear

        case .secondary:
            return SAMDesignSystem.Colors.secondary.opacity(0.3)
        }
    }

    private var borderWidth: CGFloat {
        variant == .secondary ? 1 : 0
    }
}

// MARK: - Unified List Row Component

public struct SAMListRow<Content: View>: View {
    let content: Content
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    public init(
        isSelected: Bool = false,
        onTap: @escaping () -> Void = {},
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.isSelected = isSelected
        self.onTap = onTap
    }

    public var body: some View {
        content
            .padding(SAMDesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: SAMDesignSystem.CornerRadius.md)
                    .fill(backgroundColor)
            )
            .onTapGesture {
                onTap()
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }
    }

    private var backgroundColor: Color {
        if isSelected {
            return SAMDesignSystem.Colors.selectedOverlay
        } else if isHovered {
            return SAMDesignSystem.Colors.hoverOverlay
        } else {
            return Color.clear
        }
    }
}

// MARK: - Unified Section Header

public struct SAMSectionHeader: View {
    let title: String
    let subtitle: String?
    let action: (() -> Void)?
    let actionIcon: String?
    let actionLabel: String?

    public init(
        _ title: String,
        subtitle: String? = nil,
        actionIcon: String? = nil,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionIcon = actionIcon
        self.actionLabel = actionLabel
        self.action = action
    }

    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.xs) {
                Text(title)
                    .font(SAMDesignSystem.Typography.headline)
                    .foregroundColor(SAMDesignSystem.Colors.primary)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(SAMDesignSystem.Typography.caption)
                        .foregroundColor(SAMDesignSystem.Colors.secondary)
                }
            }

            Spacer()

            if let action = action {
                Button(action: action) {
                    HStack(spacing: SAMDesignSystem.Spacing.xs) {
                        if let actionIcon = actionIcon {
                            Image(systemName: actionIcon)
                        }

                        if let actionLabel = actionLabel {
                            Text(actionLabel)
                        }
                    }
                    .font(SAMDesignSystem.Typography.caption.weight(.medium))
                }
                .buttonStyle(SAMButtonStyle(variant: .ghost, size: .small))
            }
        }
    }
}

// MARK: - Unified Input Field

public struct SAMTextField: View {
    let title: String?
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool
    let validation: ValidationState?

    public enum ValidationState {
        case valid(String)
        case invalid(String)
        case warning(String)
    }

    public init(
        _ title: String? = nil,
        placeholder: String,
        text: Binding<String>,
        isSecure: Bool = false,
        validation: ValidationState? = nil
    ) {
        self.title = title
        self.placeholder = placeholder
        self._text = text
        self.isSecure = isSecure
        self.validation = validation
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.xs) {
            if let title = title {
                Text(title)
                    .font(SAMDesignSystem.Typography.caption.weight(.medium))
                    .foregroundColor(SAMDesignSystem.Colors.primary)
            }

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: 1)
            )

            if validation != nil {
                HStack(spacing: SAMDesignSystem.Spacing.xs) {
                    Image(systemName: validationIcon)
                        .foregroundColor(validationColor)
                        .font(.caption)

                    Text(validationMessage)
                        .font(SAMDesignSystem.Typography.caption)
                        .foregroundColor(validationColor)
                }
            }
        }
    }

    private var borderColor: Color {
        switch validation {
        case .valid: return SAMDesignSystem.Colors.success
        case .invalid: return SAMDesignSystem.Colors.error
        case .warning: return SAMDesignSystem.Colors.warning
        case .none: return Color.clear
        }
    }

    private var validationIcon: String {
        switch validation {
        case .valid: return "checkmark.circle"
        case .invalid: return "exclamationmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .none: return ""
        }
    }

    private var validationColor: Color {
        switch validation {
        case .valid: return SAMDesignSystem.Colors.success
        case .invalid: return SAMDesignSystem.Colors.error
        case .warning: return SAMDesignSystem.Colors.warning
        case .none: return SAMDesignSystem.Colors.secondary
        }
    }

    private var validationMessage: String {
        switch validation {
        case .valid(let message): return message
        case .invalid(let message): return message
        case .warning(let message): return message
        case .none: return ""
        }
    }
}

// MARK: - Unified Loading States

public struct SAMLoadingView: View {
    let message: String?
    let style: Style

    public enum Style {
        case spinner, pulse, skeleton
    }

    public init(_ message: String? = nil, style: Style = .spinner) {
        self.message = message
        self.style = style
    }

    public var body: some View {
        VStack(spacing: SAMDesignSystem.Spacing.lg) {
            switch style {
            case .spinner:
                ProgressView()
                    .scaleEffect(1.2)

            case .pulse:
                Circle()
                    .fill(SAMDesignSystem.Colors.accent)
                    .frame(width: 20, height: 20)
                    .scaleEffect(1.0)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: true
                    )

            case .skeleton:
                RoundedRectangle(cornerRadius: SAMDesignSystem.CornerRadius.md)
                    .fill(SAMDesignSystem.Colors.secondary.opacity(0.2))
                    .frame(height: 60)
                    .overlay(
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.3), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .animation(
                                .linear(duration: 1.5).repeatForever(autoreverses: false),
                                value: true
                            )
                    )
                    .clipped()
            }

            if let message = message {
                Text(message)
                    .font(SAMDesignSystem.Typography.caption)
                    .foregroundColor(SAMDesignSystem.Colors.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(SAMDesignSystem.Spacing.xl)
    }
}

// MARK: - Unified Empty States

public struct SAMEmptyStateView: View {
    let icon: String
    let title: String
    let description: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(
        icon: String,
        title: String,
        description: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.description = description
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: SAMDesignSystem.Spacing.xl) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(SAMDesignSystem.Colors.secondary)

            VStack(spacing: SAMDesignSystem.Spacing.sm) {
                Text(title)
                    .font(SAMDesignSystem.Typography.title3)
                    .foregroundColor(SAMDesignSystem.Colors.primary)

                Text(description)
                    .font(SAMDesignSystem.Typography.body)
                    .foregroundColor(SAMDesignSystem.Colors.secondary)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle, action: action)
                    .buttonStyle(SAMButtonStyle(variant: .primary))
            }
        }
        .padding(SAMDesignSystem.Spacing.xxxl)
    }
}

// MARK: - Supporting Types

extension SAMDesignSystem.Shadows {
    public struct Shadow: Sendable {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }
}
