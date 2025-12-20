// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

// MARK: - UI Setup

// MARK: - UI Setup

public struct SAMComponentLibrary: View {
    @StateObject private var navigationManager = SAMNavigationManager()
    @State private var selectedDemo: DemoSection = .buttons
    @State private var isLoading = false
    @State private var formText = ""
    @State private var showError = false

    public init() {}

    public var body: some View {
        NavigationSplitView {
            /// Demo Navigation Sidebar.
            demoSidebar
        } detail: {
            /// Demo Content.
            demoContent
                .samLayoutContainer(
                    title: selectedDemo.title,
                    showsToolbar: true,
                    toolbarContent: { AnyView(demoToolbar) }
                )
        }
        .environmentObject(navigationManager)
        .samSheetPresentation()
    }

    private var demoSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SAMSectionHeader(
                "Component Library",
                subtitle: "Unified SwiftUI Architecture"
            )
            .padding()

            Divider()

            ScrollView {
                LazyVStack(spacing: SAMDesignSystem.Spacing.xs) {
                    ForEach(DemoSection.allCases) { section in
                        SAMListRow(
                            isSelected: selectedDemo == section,
                            onTap: {
                                selectedDemo = section
                            }
                        ) {
                            HStack {
                                Image(systemName: section.icon)
                                    .foregroundColor(SAMDesignSystem.Colors.accent)
                                    .frame(width: 20)

                                Text(section.title)
                                    .font(SAMDesignSystem.Typography.body)

                                Spacer()
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 200, idealWidth: 250)
    }

    private var demoContent: some View {
        ScrollView {
            LazyVStack(spacing: SAMDesignSystem.Spacing.xl) {
                switch selectedDemo {
                case .buttons:
                    buttonDemos

                case .cards:
                    cardDemos

                case .forms:
                    formDemos

                case .loading:
                    loadingDemos

                case .navigation:
                    navigationDemos

                case .typography:
                    typographyDemos
                }
            }
            .padding()
        }
        .samLoadingOverlay(isLoading: isLoading, message: "Loading demo...")
        .samErrorBoundary { error in
            SAMEmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Demo Error",
                description: error.localizedDescription,
                actionTitle: "Retry",
                action: {
                    showError = false
                }
            )
        }
    }

    private var demoToolbar: some View {
        HStack {
            Button("Toggle Loading") {
                withAnimation {
                    isLoading.toggle()
                }
            }
            .buttonStyle(SAMButtonStyle(variant: .secondary, size: .small))

            Button("Show Error") {
                showError.toggle()
                NotificationCenter.default.post(
                    name: .samComponentError,
                    object: DemoError.sampleError
                )
            }
            .buttonStyle(SAMButtonStyle(variant: .ghost, size: .small))

            Spacer()

            Button("Preferences") {
                navigationManager.showSheet(.preferences)
            }
            .buttonStyle(SAMButtonStyle(variant: .primary, size: .small))
        }
    }

    // MARK: - Actions

    private var buttonDemos: some View {
        VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.xl) {
            SAMSectionHeader(
                "Button Styles",
                subtitle: "Unified button component with multiple variants and sizes"
            )

            SAMCard {
                VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.lg) {
                    Text("Button Variants")
                        .font(SAMDesignSystem.Typography.headline)

                    HStack(spacing: SAMDesignSystem.Spacing.md) {
                        Button("Primary") {}
                            .buttonStyle(SAMButtonStyle(variant: .primary))

                        Button("Secondary") {}
                            .buttonStyle(SAMButtonStyle(variant: .secondary))

                        Button("Ghost") {}
                            .buttonStyle(SAMButtonStyle(variant: .ghost))

                        Button("Destructive") {}
                            .buttonStyle(SAMButtonStyle(variant: .destructive))
                    }

                    Text("Button Sizes")
                        .font(SAMDesignSystem.Typography.headline)

                    VStack(spacing: SAMDesignSystem.Spacing.md) {
                        HStack(spacing: SAMDesignSystem.Spacing.md) {
                            Button("Small") {}
                                .buttonStyle(SAMButtonStyle(size: .small))

                            Button("Medium") {}
                                .buttonStyle(SAMButtonStyle(size: .medium))

                            Button("Large") {}
                                .buttonStyle(SAMButtonStyle(size: .large))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Card Demos

    private var cardDemos: some View {
        VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.xl) {
            SAMSectionHeader(
                "Card Components",
                subtitle: "Flexible card containers with consistent styling"
            )

            /// Default Card.
            SAMCard {
                VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.md) {
                    Text("Default Card")
                        .font(SAMDesignSystem.Typography.headline)

                    Text("This is a default card with standard padding, corner radius, and shadow.")
                        .font(SAMDesignSystem.Typography.body)
                        .foregroundColor(SAMDesignSystem.Colors.secondary)
                }
            }

            /// Custom Card.
            SAMCard(
                padding: SAMDesignSystem.Spacing.xl,
                cornerRadius: SAMDesignSystem.CornerRadius.xl,
                shadow: SAMDesignSystem.Shadows.large
            ) {
                VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.md) {
                    Text("Custom Card")
                        .font(SAMDesignSystem.Typography.headline)

                    Text("This card uses custom padding, corner radius, and shadow settings.")
                        .font(SAMDesignSystem.Typography.body)
                        .foregroundColor(SAMDesignSystem.Colors.secondary)
                }
            }

            /// Interactive Card.
            SAMCard {
                HStack {
                    VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.sm) {
                        Text("Interactive Card")
                            .font(SAMDesignSystem.Typography.headline)

                        Text("This card responds to hover and tap interactions.")
                            .font(SAMDesignSystem.Typography.caption)
                            .foregroundColor(SAMDesignSystem.Colors.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .foregroundColor(SAMDesignSystem.Colors.secondary)
                }
            }
            .samInteractive(
                onTap: {
                    /// Handle tap.
                },
                onHover: { _ in
                    /// Handle hover.
                }
            )
            .samHoverAnimation()
        }
    }

    // MARK: - Form Demos

    private var formDemos: some View {
        VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.xl) {
            SAMSectionHeader(
                "Form Components",
                subtitle: "Unified form inputs with validation and accessibility"
            )

            SAMCard {
                VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.lg) {
                    SAMTextField(
                        "Username",
                        placeholder: "Enter your username",
                        text: $formText,
                        validation: .valid("Username is available")
                    )

                    SAMTextField(
                        "Password",
                        placeholder: "Enter your password",
                        text: $formText,
                        isSecure: true,
                        validation: .invalid("Password must be at least 8 characters")
                    )

                    SAMTextField(
                        "Email",
                        placeholder: "Enter your email",
                        text: $formText,
                        validation: .warning("Please verify your email address")
                    )

                    HStack {
                        Button("Submit") {}
                            .buttonStyle(SAMButtonStyle(variant: .primary))

                        Button("Cancel") {}
                            .buttonStyle(SAMButtonStyle(variant: .secondary))
                    }
                }
            }
        }
    }

    // MARK: - Loading Demos

    private var loadingDemos: some View {
        VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.xl) {
            SAMSectionHeader(
                "Loading States",
                subtitle: "Various loading indicators and skeleton states"
            )

            HStack(spacing: SAMDesignSystem.Spacing.xl) {
                SAMCard {
                    VStack {
                        Text("Spinner Loading")
                            .font(SAMDesignSystem.Typography.headline)

                        SAMLoadingView("Processing...", style: .spinner)
                    }
                }

                SAMCard {
                    VStack {
                        Text("Pulse Loading")
                            .font(SAMDesignSystem.Typography.headline)

                        SAMLoadingView("Connecting...", style: .pulse)
                    }
                }

                SAMCard {
                    VStack {
                        Text("Skeleton Loading")
                            .font(SAMDesignSystem.Typography.headline)

                        SAMLoadingView(style: .skeleton)
                    }
                }
            }
        }
    }

    // MARK: - Navigation Demos

    private var navigationDemos: some View {
        VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.xl) {
            SAMSectionHeader(
                "Navigation Patterns",
                subtitle: "Sidebar navigation and list row interactions"
            )

            SAMCard {
                VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.md) {
                    Text("Navigation Items")
                        .font(SAMDesignSystem.Typography.headline)

                    ForEach(SAMNavigationManager.SidebarItem.allCases) { item in
                        SAMListRow(
                            isSelected: false,
                            onTap: {
                                /// Handle navigation.
                            }
                        ) {
                            HStack {
                                Image(systemName: item.icon)
                                    .foregroundColor(SAMDesignSystem.Colors.accent)
                                    .frame(width: 20)

                                Text(item.title)
                                    .font(SAMDesignSystem.Typography.body)

                                Spacer()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Typography Demos

    private var typographyDemos: some View {
        VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.xl) {
            SAMSectionHeader(
                "Typography Scale",
                subtitle: "Consistent font styles throughout the application"
            )

            SAMCard {
                VStack(alignment: .leading, spacing: SAMDesignSystem.Spacing.md) {
                    Group {
                        Text("Large Title")
                            .font(SAMDesignSystem.Typography.largeTitle)

                        Text("Title")
                            .font(SAMDesignSystem.Typography.title)

                        Text("Title 2")
                            .font(SAMDesignSystem.Typography.title2)

                        Text("Title 3")
                            .font(SAMDesignSystem.Typography.title3)

                        Text("Headline")
                            .font(SAMDesignSystem.Typography.headline)

                        Text("Subheadline")
                            .font(SAMDesignSystem.Typography.subheadline)

                        Text("Body")
                            .font(SAMDesignSystem.Typography.body)

                        Text("Caption")
                            .font(SAMDesignSystem.Typography.caption)

                        Text("Caption 2")
                            .font(SAMDesignSystem.Typography.caption2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Demo Section Enum

private enum DemoSection: String, CaseIterable, Identifiable {
    case buttons = "buttons"
    case cards = "cards"
    case forms = "forms"
    case loading = "loading"
    case navigation = "navigation"
    case typography = "typography"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .buttons: return "Buttons"
        case .cards: return "Cards"
        case .forms: return "Forms"
        case .loading: return "Loading States"
        case .navigation: return "Navigation"
        case .typography: return "Typography"
        }
    }

    var icon: String {
        switch self {
        case .buttons: return "button.programmable"
        case .cards: return "rectangle.stack"
        case .forms: return "list.clipboard"
        case .loading: return "arrow.triangle.2.circlepath"
        case .navigation: return "sidebar.left"
        case .typography: return "textformat"
        }
    }
}

// MARK: - Demo Error

private enum DemoError: Error, LocalizedError {
    case sampleError

    var errorDescription: String? {
        switch self {
        case .sampleError:
            return "This is a sample error for demonstration purposes."
        }
    }
}

// MARK: - UI Setup

#if DEBUG
struct SAMComponentLibrary_Previews: PreviewProvider {
    static var previews: some View {
        SAMComponentLibrary()
            .frame(width: 1000, height: 700)
    }
}
#endif
