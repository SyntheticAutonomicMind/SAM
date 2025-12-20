// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI

/// Preferences pane for SerpAPI configuration.
struct SerpAPIPreferencesPane: View {
    @AppStorage("serpAPIEnabled") private var isEnabled: Bool = false
    @AppStorage("serpAPIKey") private var apiKey: String = ""

    @State private var accountInfo: SerpAPIService.AccountInfo?
    @State private var isLoadingAccountInfo = false
    @State private var accountError: String?
    @State private var showingAPIKeyField = false

    nonisolated(unsafe) private let serpAPI = SerpAPIService()

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass.circle.fill")
                            .font(.title)
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading) {
                            Text("SerpAPI Integration")
                                .font(.headline)
                            Text("Enhanced web search with Google, Bing, Amazon, and more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.bottom, 4)

                    Text("SerpAPI provides professional search engine results from multiple sources. Get your API key at serpapi.com")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section(header: Text("Configuration")) {
                Toggle("Enable SerpAPI", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in
                        if newValue {
                            /// When enabling, refresh account info.
                            Task {
                                await loadAccountInfo()
                            }
                        }
                    }

                if isEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("API Key")
                                .frame(width: 80, alignment: .leading)

                            if showingAPIKeyField {
                                SecureField("Enter your SerpAPI key", text: $apiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: apiKey) { _, _ in
                                        /// Refresh account info when key changes.
                                        Task {
                                            try? await Task.sleep(nanoseconds: 500_000_000)
                                            await loadAccountInfo()
                                        }
                                    }

                                Button {
                                    showingAPIKeyField = false
                                } label: {
                                    Image(systemName: "eye.slash")
                                }
                                .buttonStyle(.borderless)
                                .help("Hide API key")
                            } else {
                                Text(apiKey.isEmpty ? "Not configured" : String(repeating: "•", count: 32))
                                    .foregroundColor(apiKey.isEmpty ? .secondary : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Button {
                                    showingAPIKeyField = true
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help("Edit API key")
                            }
                        }

                        HStack {
                            Link("Get API Key →", destination: URL(string: "https://serpapi.com/users/sign_up")!)
                                .font(.caption)

                            Spacer()

                            if !apiKey.isEmpty {
                                Button("Refresh Account Info") {
                                    Task {
                                        await loadAccountInfo()
                                    }
                                }
                                .font(.caption)
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            if isEnabled && !apiKey.isEmpty {
                Section(header: Text("Account Status")) {
                    if isLoadingAccountInfo {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading account information...")
                                .foregroundColor(.secondary)
                        }
                    } else if let error = accountError {
                        Label {
                            Text(error)
                                .foregroundColor(.red)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                        }
                    } else if let account = accountInfo {
                        accountInfoView(account)
                    }
                }

                Section(header: Text("Supported Search Engines")) {
                    ForEach(SerpAPIService.SearchEngine.allCases, id: \.self) { engine in
                        HStack {
                            Image(systemName: engine.icon)
                                .frame(width: 24)
                                .foregroundColor(.accentColor)
                            Text(engine.displayName)
                            Spacer()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 600)
        .onAppear {
            if isEnabled && !apiKey.isEmpty {
                Task {
                    await loadAccountInfo()
                }
            }
        }
    }

    @ViewBuilder
    private func accountInfoView(_ account: SerpAPIService.AccountInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let email = account.accountEmail {
                HStack {
                    Text("Account:")
                        .frame(width: 100, alignment: .leading)
                        .foregroundColor(.secondary)
                    Text(email)
                }
            }

            if let planName = account.planName {
                HStack {
                    Text("Plan:")
                        .frame(width: 100, alignment: .leading)
                        .foregroundColor(.secondary)
                    Text(planName)
                }
            }

            if let searches = account.searches {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Usage This Month")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if let thisMonth = searches.thisMonth,
                       let limit = searches.thisMonthLimit {
                        let remaining = limit - thisMonth
                        let percentage = Double(thisMonth) / Double(limit)

                        HStack {
                            Text("\(thisMonth)")
                                .font(.title2)
                                .fontWeight(.bold)
                            Text("/ \(limit)")
                                .foregroundColor(.secondary)

                            Spacer()

                            Text("\(remaining) remaining")
                                .foregroundColor(remaining > 100 ? .green : remaining > 10 ? .orange : .red)
                        }

                        ProgressView(value: percentage)
                            .tint(percentage < 0.7 ? .green : percentage < 0.9 ? .orange : .red)

                        if remaining <= 0 {
                            Label {
                                Text("Monthly limit reached. SerpAPI will not be available to SAM until next month.")
                                    .font(.caption)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            .foregroundColor(.red)
                        } else if remaining <= 10 {
                            Label {
                                Text("Low on searches. Consider upgrading your plan.")
                                    .font(.caption)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                            }
                            .foregroundColor(.orange)
                        }
                    }

                    if let total = searches.total {
                        Text("Total searches: \(total)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let rateLimit = account.accountRateLimitPerMonth {
                HStack {
                    Text("Rate Limit:")
                        .frame(width: 100, alignment: .leading)
                        .foregroundColor(.secondary)
                    Text("\(rateLimit) searches/month")
                }
            }
        }
    }

    private func loadAccountInfo() async {
        await MainActor.run {
            isLoadingAccountInfo = true
            accountError = nil
            accountInfo = nil
        }

        do {
            let info = try await serpAPI.getAccountInfo()
            await MainActor.run {
                self.accountInfo = info
                self.isLoadingAccountInfo = false
            }
        } catch {
            await MainActor.run {
                self.accountError = error.localizedDescription
                self.isLoadingAccountInfo = false
            }
        }
    }
}

// MARK: - UI Setup

#Preview {
    SerpAPIPreferencesPane()
        .frame(width: 600, height: 600)
}
