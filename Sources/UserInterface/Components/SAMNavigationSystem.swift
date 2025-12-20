// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging

// MARK: - UI Setup

// MARK: - Navigation Stack Manager

@MainActor
public class SAMNavigationManager: ObservableObject {
    @Published public var navigationPath = NavigationPath()
    @Published public var selectedSidebarItem: SidebarItem?
    @Published public var isShowingSheet = false
    @Published public var activeSheet: SheetType?

    private let logger = Logger(label: "com.sam.navigation.navigation")

    public enum SheetType: Identifiable {
        case preferences
        case documentImport
        case webResearch
        case automation
        case about

        public var id: String {
            switch self {
            case .preferences: return "preferences"
            case .documentImport: return "documentImport"
            case .webResearch: return "webResearch"
            case .automation: return "automation"
            case .about: return "about"
            }
        }
    }

    public enum SidebarItem: String, CaseIterable, Identifiable {
        case conversations = "conversations"
        case documents = "documents"
        case research = "research"
        case automation = "automation"
        case performance = "performance"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .conversations: return "Conversations"
            case .documents: return "Documents"
            case .research: return "Web Research"
            case .automation: return "Automation"
            case .performance: return "Performance"
            }
        }

        public var icon: String {
            switch self {
            case .conversations: return "message.badge"
            case .documents: return "doc.text"
            case .research: return "globe"
            case .automation: return "gearshape.2"
            case .performance: return "chart.line.uptrend.xyaxis"
            }
        }
    }

    public init() {
        selectedSidebarItem = .conversations
    }

    public func navigate(to item: SidebarItem) {
        logger.debug("Navigating to: \(item.title)")
        selectedSidebarItem = item
    }

    public func showSheet(_ sheet: SheetType) {
        logger.debug("Showing sheet: \(sheet.id)")
        activeSheet = sheet
        isShowingSheet = true
    }

    public func dismissSheet() {
        logger.debug("Dismissing sheet")
        isShowingSheet = false
        activeSheet = nil
    }

    public func pushToNavigationStack<T: Hashable>(_ value: T) {
        navigationPath.append(value)
    }

    public func popFromNavigationStack() {
        if !navigationPath.isEmpty {
            navigationPath.removeLast()
        }
    }

    public func popToRoot() {
        navigationPath = NavigationPath()
    }
}

// MARK: - Unified Sidebar Component

public struct SAMSidebar: View {
    @EnvironmentObject private var navigationManager: SAMNavigationManager
    @State private var expandedSections: Set<String> = ["main"]

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            /// Header.
            sidebarHeader
                .padding()

            Divider()

            /// Navigation Items.
            ScrollView {
                LazyVStack(spacing: SAMDesignSystem.Spacing.xs) {
                    ForEach(SAMNavigationManager.SidebarItem.allCases) { item in
                        sidebarItem(item)
                    }
                }
                .padding()
            }

            Spacer()

            /// Footer with quick actions.
            sidebarFooter
                .padding()
        }
        .frame(minWidth: 200, idealWidth: 260, maxWidth: 300)
        .background(SAMDesignSystem.Colors.surfaceDark)
    }

    private var sidebarHeader: some View {
        VStack(spacing: SAMDesignSystem.Spacing.md) {
            /// App Icon and Title.
            HStack {
                Image(systemName: "brain")
                    .font(.system(size: 24))
                    .foregroundColor(SAMDesignSystem.Colors.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("SAM")
                        .font(SAMDesignSystem.Typography.title3)
                        .fontWeight(.bold)

                    Text("Rewritten")
                        .font(SAMDesignSystem.Typography.caption)
                        .foregroundColor(SAMDesignSystem.Colors.secondary)
                }

                Spacer()
            }

            /// Quick Actions.
            HStack(spacing: SAMDesignSystem.Spacing.sm) {
                Button(action: {
                    /// New conversation action.
                }) {
                    Image(systemName: "plus.message")
                        .font(.system(size: 14))
                }
                .buttonStyle(SAMButtonStyle(variant: .ghost, size: .small))
                .help("New Conversation")

                Spacer()

                Button(action: {
                    navigationManager.showSheet(.preferences)
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                }
                .buttonStyle(SAMButtonStyle(variant: .ghost, size: .small))
                .help("Preferences")
            }
        }
    }

    private func sidebarItem(_ item: SAMNavigationManager.SidebarItem) -> some View {
        SAMListRow(
            isSelected: navigationManager.selectedSidebarItem == item,
            onTap: {
                navigationManager.navigate(to: item)
            }
        ) {
            HStack(spacing: SAMDesignSystem.Spacing.md) {
                Image(systemName: item.icon)
                    .font(.system(size: 16))
                    .foregroundColor(iconColor(for: item))
                    .frame(width: 20)

                Text(item.title)
                    .font(SAMDesignSystem.Typography.body)
                    .foregroundColor(textColor(for: item))

                Spacer()

                if navigationManager.selectedSidebarItem == item {
                    Circle()
                        .fill(SAMDesignSystem.Colors.accent)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .samAccessibility(
            label: item.title,
            hint: "Navigate to \(item.title)",
            isButton: true
        )
    }

    private func iconColor(for item: SAMNavigationManager.SidebarItem) -> Color {
        navigationManager.selectedSidebarItem == item
            ? SAMDesignSystem.Colors.accent
            : SAMDesignSystem.Colors.secondary
    }

    private func textColor(for item: SAMNavigationManager.SidebarItem) -> Color {
        navigationManager.selectedSidebarItem == item
            ? SAMDesignSystem.Colors.primary
            : SAMDesignSystem.Colors.secondary
    }

    private var sidebarFooter: some View {
        VStack(spacing: SAMDesignSystem.Spacing.sm) {
            Divider()

            HStack {
                Text("v2.0")
                    .font(SAMDesignSystem.Typography.caption2)
                    .foregroundColor(SAMDesignSystem.Colors.secondary)

                Spacer()

                Button(action: {
                    navigationManager.showSheet(.about)
                }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundColor(SAMDesignSystem.Colors.secondary)
                }
                .buttonStyle(.plain)
                .help("About SAM")
            }
        }
    }
}

// MARK: - UI Setup

public struct SAMLayoutContainer<Content: View>: View {
    let content: Content
    let title: String?
    let showsToolbar: Bool
    let toolbarContent: (() -> AnyView)?

    public init(
        title: String? = nil,
        showsToolbar: Bool = false,
        @ViewBuilder toolbarContent: @escaping () -> AnyView = { AnyView(EmptyView()) },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.showsToolbar = showsToolbar
        self.toolbarContent = toolbarContent
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            /// Title Bar.
            if title != nil {
                titleBar
                Divider()
            }

            /// Toolbar.
            if showsToolbar {
                toolbar
                Divider()
            }

            /// Main Content.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SAMDesignSystem.Colors.background)
    }

    private var titleBar: some View {
        HStack {
            if let title = title {
                Text(title)
                    .font(SAMDesignSystem.Typography.title2)
                    .foregroundColor(SAMDesignSystem.Colors.primary)
            }

            Spacer()
        }
        .padding()
        .background(SAMDesignSystem.Colors.surfaceLight)
    }

    private var toolbar: some View {
        HStack {
            toolbarContent?() ?? AnyView(EmptyView())
        }
        .padding(.horizontal)
        .padding(.vertical, SAMDesignSystem.Spacing.sm)
        .background(SAMDesignSystem.Colors.surfaceLight)
    }
}

// MARK: - Unified Window Management

@MainActor
public class SAMWindowManager: ObservableObject {
    @Published public var activeWindows: Set<WindowType> = []

    public enum WindowType: String, CaseIterable {
        case main = "main"
        case preferences = "preferences"
        case inspector = "inspector"
        case automation = "automation"

        public var title: String {
            switch self {
            case .main: return "SAM - Rewritten"
            case .preferences: return "Preferences"
            case .inspector: return "Inspector"
            case .automation: return "Automation"
            }
        }

        public var defaultSize: CGSize {
            switch self {
            case .main: return CGSize(width: 1200, height: 800)
            case .preferences: return CGSize(width: 800, height: 600)
            case .inspector: return CGSize(width: 400, height: 600)
            case .automation: return CGSize(width: 900, height: 700)
            }
        }
    }

    private let logger = Logger(label: "com.sam.window.window-manager")

    public func openWindow(_ type: WindowType) {
        logger.debug("Opening window: \(type.title)")
        activeWindows.insert(type)
    }

    public func closeWindow(_ type: WindowType) {
        logger.debug("Closing window: \(type.title)")
        activeWindows.remove(type)
    }

    public func isWindowOpen(_ type: WindowType) -> Bool {
        activeWindows.contains(type)
    }
}

// MARK: - Helper Methods

public struct SAMSheetPresentation: ViewModifier {
    @EnvironmentObject private var navigationManager: SAMNavigationManager

    public func body(content: Content) -> some View {
        content
            .sheet(isPresented: $navigationManager.isShowingSheet) {
                if let sheetType = navigationManager.activeSheet {
                    sheetContent(for: sheetType)
                }
            }
    }

    @ViewBuilder
    private func sheetContent(for type: SAMNavigationManager.SheetType) -> some View {
        switch type {
        case .preferences:
            PreferencesView()
                .environmentObject(navigationManager)

        case .documentImport:
            /// DocumentImportView() - would need to be implemented.
            Text("Document Import")

        case .webResearch:
            /// WebResearchView() - would need to be implemented.
            Text("Web Research")

        case .automation:
            /// AutomationView() - would need to be implemented.
            Text("Automation")

        case .about:
            AboutView()
        }
    }
}

// MARK: - UI Setup

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            /// App Icon - sparkles represent AI intelligence.
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 64))
                .foregroundColor(SAMDesignSystem.Colors.accent)

            /// App Name and Version.
            Text("Synthetic Autonomic Mind")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Version 2.0 (Rewritten)")
                .font(.headline)
                .foregroundColor(SAMDesignSystem.Colors.secondary)

            Text("Advanced AI Agent Platform")
                .font(.subheadline)
                .foregroundColor(SAMDesignSystem.Colors.secondary)

            /// Feature List.
            VStack(alignment: .leading, spacing: 8) {
                Text("Features:")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Text("• Multi-Provider AI Integration")
                    Text("• Autonomous Intelligence Engine")
                    Text("• Advanced Memory Systems")
                    Text("• Hardware Acceleration (MLX)")
                    Text("• Real-time Streaming")
                    Text("• Model Context Protocol Support")
                }
                .font(.body)
                .foregroundColor(SAMDesignSystem.Colors.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            /// Copyright.
            Text("Copyright © 2025 Fewtarius. All rights reserved.")
                .font(.footnote)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))

            /// Close Button.
            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(SAMButtonStyle(variant: .primary))
        }
        .padding(30)
        .frame(width: 400)
    }
}

// MARK: - UI Setup

extension View {
    public func samSheetPresentation() -> some View {
        modifier(SAMSheetPresentation())
    }

    public func samLayoutContainer(
        title: String? = nil,
        showsToolbar: Bool = false,
        @ViewBuilder toolbarContent: @escaping () -> AnyView = { AnyView(EmptyView()) }
    ) -> some View {
        SAMLayoutContainer(
            title: title,
            showsToolbar: showsToolbar,
            toolbarContent: toolbarContent
        ) {
            self
        }
    }
}
