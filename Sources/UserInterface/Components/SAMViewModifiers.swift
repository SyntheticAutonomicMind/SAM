// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Accessibility

// MARK: - UI Setup

// MARK: - Animation Modifiers

public struct SAMScaleAnimation: ViewModifier {
    let isPressed: Bool
    let scale: CGFloat
    let duration: Double

    public init(isPressed: Bool, scale: CGFloat = 0.98, duration: Double = 0.1) {
        self.isPressed = isPressed
        self.scale = scale
        self.duration = duration
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? scale : 1.0)
            .animation(.easeInOut(duration: duration), value: isPressed)
    }
}

public struct SAMHoverAnimation: ViewModifier {
    @State private var isHovered = false
    let hoverScale: CGFloat
    let duration: Double

    public init(hoverScale: CGFloat = 1.02, duration: Double = 0.2) {
        self.hoverScale = hoverScale
        self.duration = duration
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? hoverScale : 1.0)
            .animation(.easeInOut(duration: duration), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

public struct SAMFadeInAnimation: ViewModifier {
    let delay: Double
    let duration: Double

    public init(delay: Double = 0, duration: Double = 0.3) {
        self.delay = delay
        self.duration = duration
    }

    public func body(content: Content) -> some View {
        content
            .opacity(0)
            .onAppear {
                withAnimation(.easeInOut(duration: duration).delay(delay)) {
                    /// Animation will be applied by the parent view.
                }
            }
    }
}

// MARK: - UI Setup

public struct SAMResponsiveFrame: ViewModifier {
    let minWidth: CGFloat?
    let idealWidth: CGFloat?
    let maxWidth: CGFloat?
    let minHeight: CGFloat?
    let idealHeight: CGFloat?
    let maxHeight: CGFloat?

    public init(
        minWidth: CGFloat? = nil,
        idealWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil,
        idealHeight: CGFloat? = nil,
        maxHeight: CGFloat? = nil
    ) {
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.idealHeight = idealHeight
        self.maxHeight = maxHeight
    }

    public func body(content: Content) -> some View {
        content
            .frame(
                minWidth: minWidth,
                idealWidth: idealWidth,
                maxWidth: maxWidth,
                minHeight: minHeight,
                idealHeight: idealHeight,
                maxHeight: maxHeight
            )
    }
}

// MARK: - Interactive Modifiers

public struct SAMInteractiveStyle: ViewModifier {
    let isSelected: Bool
    let onTap: (() -> Void)?
    let onHover: ((Bool) -> Void)?

    @State private var isHovered = false
    @State private var isPressed = false

    public init(
        isSelected: Bool = false,
        onTap: (() -> Void)? = nil,
        onHover: ((Bool) -> Void)? = nil
    ) {
        self.isSelected = isSelected
        self.onTap = onTap
        self.onHover = onHover
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: SAMDesignSystem.CornerRadius.md)
                    .fill(backgroundColor)
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
            .animation(.easeInOut(duration: 0.1), value: isHovered)
            .onTapGesture {
                onTap?()
            }
            .onLongPressGesture(minimumDuration: 0) {
                /// On press start.
            } onPressingChanged: { pressing in
                isPressed = pressing
            }
            .onHover { hovering in
                isHovered = hovering
                onHover?(hovering)
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

// MARK: - Accessibility Modifiers

public struct SAMAccessibilityStyle: ViewModifier {
    let label: String?
    let hint: String?
    let value: String?
    let isButton: Bool

    public init(
        label: String? = nil,
        hint: String? = nil,
        value: String? = nil,
        isButton: Bool = false
    ) {
        self.label = label
        self.hint = hint
        self.value = value
        self.isButton = isButton
    }

    public func body(content: Content) -> some View {
        content
            .accessibilityLabel(label ?? "")
            .accessibilityHint(hint ?? "")
            .accessibilityValue(value ?? "")
            .if(isButton) { view in
                view.accessibilityAddTraits(.isButton)
            }
    }
}

// MARK: - Error Handling Modifiers

public struct SAMErrorBoundary<ErrorContent: View>: ViewModifier {
    let errorContent: (Error) -> ErrorContent
    @State private var error: Error?

    public init(@ViewBuilder errorContent: @escaping (Error) -> ErrorContent) {
        self.errorContent = errorContent
    }

    public func body(content: Content) -> some View {
        Group {
            if let error = error {
                errorContent(error)
            } else {
                content
                    .onAppear {
                        self.error = nil
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .samComponentError)) { notification in
            if let error = notification.object as? Error {
                self.error = error
            }
        }
    }
}

// MARK: - Loading State Modifiers

public struct SAMLoadingOverlay: ViewModifier {
    let isLoading: Bool
    let message: String?
    let style: SAMLoadingView.Style

    public init(
        isLoading: Bool,
        message: String? = nil,
        style: SAMLoadingView.Style = .spinner
    ) {
        self.isLoading = isLoading
        self.message = message
        self.style = style
    }

    public func body(content: Content) -> some View {
        ZStack {
            content
                .disabled(isLoading)
                .blur(radius: isLoading ? 2 : 0)
                .animation(.easeInOut(duration: 0.2), value: isLoading)

            if isLoading {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                    .transition(.opacity)

                SAMLoadingView(message, style: style)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isLoading)
    }
}

// MARK: - Form Validation Modifiers

public struct SAMFormField: ViewModifier {
    let isRequired: Bool
    let validation: SAMTextField.ValidationState?

    public init(isRequired: Bool = false, validation: SAMTextField.ValidationState? = nil) {
        self.isRequired = isRequired
        self.validation = validation
    }

    public func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.xs) {
            content

            if isRequired {
                HStack {
                    Text("Required")
                        .font(SAMDesignSystem.Typography.caption2)
                        .foregroundColor(SAMDesignSystem.Colors.error)
                    Spacer()
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: SAMDesignSystem.CornerRadius.md)
                .stroke(borderColor, lineWidth: 1)
                .opacity(borderOpacity)
        )
    }

    private var borderColor: Color {
        switch validation {
        case .valid: return SAMDesignSystem.Colors.success
        case .invalid: return SAMDesignSystem.Colors.error
        case .warning: return SAMDesignSystem.Colors.warning
        case .none: return Color.clear
        }
    }

    private var borderOpacity: Double {
        validation != nil ? 1.0 : 0.0
    }
}

// MARK: - Context Menu Modifiers

public struct SAMContextMenu: ViewModifier {
    let menuItems: [SAMContextMenuItem]

    public init(menuItems: [SAMContextMenuItem]) {
        self.menuItems = menuItems
    }

    public func body(content: Content) -> some View {
        content
            .contextMenu {
                ForEach(menuItems, id: \.id) { item in
                    switch item.type {
                    case .action(let title, let icon, let action):
                        Button(action: action) {
                            Label(title, systemImage: icon)
                        }

                    case .destructive(let title, let icon, let action):
                        Button(action: action) {
                            Label(title, systemImage: icon)
                        }
                        .foregroundColor(.red)

                    case .separator:
                        Divider()
                    }
                }
            }
    }
}

public struct SAMContextMenuItem {
    let id = UUID()
    let type: MenuItemType

    public enum MenuItemType {
        case action(title: String, icon: String, action: () -> Void)
        case destructive(title: String, icon: String, action: () -> Void)
        case separator
    }

    public static func action(_ title: String, icon: String, action: @escaping () -> Void) -> SAMContextMenuItem {
        SAMContextMenuItem(type: .action(title: title, icon: icon, action: action))
    }

    public static func destructive(_ title: String, icon: String, action: @escaping () -> Void) -> SAMContextMenuItem {
        SAMContextMenuItem(type: .destructive(title: title, icon: icon, action: action))
    }

    nonisolated(unsafe) public static let separator = SAMContextMenuItem(type: .separator)
}

// MARK: - UI Setup

extension View {
    /// Animation modifiers.
    public func samScaleAnimation(isPressed: Bool, scale: CGFloat = 0.98, duration: Double = 0.1) -> some View {
        modifier(SAMScaleAnimation(isPressed: isPressed, scale: scale, duration: duration))
    }

    public func samHoverAnimation(hoverScale: CGFloat = 1.02, duration: Double = 0.2) -> some View {
        modifier(SAMHoverAnimation(hoverScale: hoverScale, duration: duration))
    }

    public func samFadeIn(delay: Double = 0, duration: Double = 0.3) -> some View {
        modifier(SAMFadeInAnimation(delay: delay, duration: duration))
    }

    /// Layout modifiers.
    public func samResponsiveFrame(
        minWidth: CGFloat? = nil,
        idealWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil,
        idealHeight: CGFloat? = nil,
        maxHeight: CGFloat? = nil
    ) -> some View {
        modifier(SAMResponsiveFrame(
            minWidth: minWidth,
            idealWidth: idealWidth,
            maxWidth: maxWidth,
            minHeight: minHeight,
            idealHeight: idealHeight,
            maxHeight: maxHeight
        ))
    }

    /// Interactive modifiers.
    public func samInteractive(
        isSelected: Bool = false,
        onTap: (() -> Void)? = nil,
        onHover: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(SAMInteractiveStyle(isSelected: isSelected, onTap: onTap, onHover: onHover))
    }

    /// Accessibility modifiers.
    public func samAccessibility(
        label: String? = nil,
        hint: String? = nil,
        value: String? = nil,
        isButton: Bool = false
    ) -> some View {
        modifier(SAMAccessibilityStyle(
            label: label,
            hint: hint,
            value: value,
            isButton: isButton
        ))
    }

    /// Error handling.
    public func samErrorBoundary<ErrorContent: View>(
        @ViewBuilder errorContent: @escaping (Error) -> ErrorContent
    ) -> some View {
        modifier(SAMErrorBoundary(errorContent: errorContent))
    }

    /// Loading states.
    public func samLoadingOverlay(
        isLoading: Bool,
        message: String? = nil,
        style: SAMLoadingView.Style = .spinner
    ) -> some View {
        modifier(SAMLoadingOverlay(isLoading: isLoading, message: message, style: style))
    }

    /// Form validation.
    public func samFormField(
        isRequired: Bool = false,
        validation: SAMTextField.ValidationState? = nil
    ) -> some View {
        modifier(SAMFormField(isRequired: isRequired, validation: validation))
    }

    /// Context menu.
    public func samContextMenu(menuItems: [SAMContextMenuItem]) -> some View {
        modifier(SAMContextMenu(menuItems: menuItems))
    }

    /// Conditional modifiers.
    @ViewBuilder
    public func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    @ViewBuilder
    public func `if`<T, Content: View>(_ optionalValue: T?, transform: (Self, T) -> Content) -> some View {
        if let value = optionalValue {
            transform(self, value)
        } else {
            self
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let samComponentError = Notification.Name("com.sam.component.error")
}
