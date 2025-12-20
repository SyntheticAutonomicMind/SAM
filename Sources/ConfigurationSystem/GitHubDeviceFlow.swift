// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Service for GitHub OAuth Device Code Flow authentication.
/// This is the recommended approach for desktop applications per GitHub documentation.
@MainActor
public class GitHubDeviceFlowService: ObservableObject {
    private static let logger = Logger(label: "com.sam.config.github-device-flow")

    @Published public var isAuthenticating = false
    @Published public var deviceCode: String?
    @Published public var userCode: String?
    @Published public var verificationUri: String?
    @Published public var authError: String?
    @Published public var authSuccess: Bool = false

    private let clientId: String
    private var pollingTask: Task<Void, Never>?

    public init(clientId: String = "Ov23lix5mfpW4hHM7y9G") {
        self.clientId = clientId
    }

    /// Start the device authorization flow.
    public func startDeviceFlow() async throws -> String {
        Self.logger.info("Starting GitHub device authorization flow")
        isAuthenticating = true
        authError = nil
        authSuccess = false

        defer {
            if !authSuccess {
                isAuthenticating = false
            }
        }

        do {
            /// Step 1: Request device and user codes.
            let deviceData = try await requestDeviceCodes()

            await MainActor.run {
                self.deviceCode = deviceData.deviceCode
                self.userCode = deviceData.userCode
                self.verificationUri = deviceData.verificationUri
            }

            Self.logger.info("Device code obtained. User code: \(deviceData.userCode)")

            /// Step 2: Poll for access token.
            let token = try await pollForAccessToken(
                deviceCode: deviceData.deviceCode,
                interval: deviceData.interval
            )

            authSuccess = true
            isAuthenticating = false
            Self.logger.info("GitHub device authorization successful")

            return token

        } catch {
            authError = error.localizedDescription
            Self.logger.error("GitHub device authorization failed: \(error)")
            throw error
        }
    }

    /// Cancel ongoing authentication.
    public func cancelAuth() {
        pollingTask?.cancel()
        pollingTask = nil
        isAuthenticating = false
        deviceCode = nil
        userCode = nil
        verificationUri = nil
    }

    /// Request device and user codes from GitHub.
    private func requestDeviceCodes() async throws -> DeviceCodeResponse {
        let url = URL(string: "https://github.com/login/device/code")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": clientId,
            "scope": "read:user copilot"
        ]

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubDeviceFlowError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            Self.logger.error("Device code request failed with status: \(httpResponse.statusCode)")
            throw GitHubDeviceFlowError.requestFailed(statusCode: httpResponse.statusCode)
        }

        let deviceResponse = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        return deviceResponse
    }

    /// Poll GitHub for access token.
    private func pollForAccessToken(deviceCode: String, interval: Int) async throws -> String {
        let url = URL(string: "https://github.com/login/oauth/access_token")!
        let pollInterval = TimeInterval(max(interval, 5))

        /// Maximum polling time: 15 minutes (GitHub tokens expire after 15 min).
        let timeout = Date.now.addingTimeInterval(900)

        while Date.now < timeout {
            /// Check if task was cancelled.
            try Task.checkCancellation()

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: String] = [
                "client_id": clientId,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ]

            request.httpBody = try JSONEncoder().encode(body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GitHubDeviceFlowError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                /// Exponential backoff on rate limit.
                try await Task.sleep(for: .seconds(pollInterval))
                continue
            }

            let tokenResponse = try JSONDecoder().decode(TokenPollResponse.self, from: data)

            /// Check response status.
            if let error = tokenResponse.error {
                switch error {
                case "authorization_pending":
                    /// User hasn't authorized yet, keep polling.
                    Self.logger.debug("Authorization pending, continuing to poll")
                    try await Task.sleep(for: .seconds(pollInterval))
                    continue

                case "slow_down":
                    /// We're polling too fast, increase interval.
                    Self.logger.warning("Polling too fast, slowing down")
                    try await Task.sleep(for: .seconds(pollInterval + 5))
                    continue

                case "expired_token":
                    /// Device code expired.
                    Self.logger.error("Device code expired")
                    throw GitHubDeviceFlowError.deviceCodeExpired

                case "access_denied":
                    /// User denied authorization.
                    Self.logger.error("User denied authorization")
                    throw GitHubDeviceFlowError.authorizationDenied

                default:
                    /// Unknown error.
                    Self.logger.error("Token poll error: \(error)")
                    throw GitHubDeviceFlowError.unknownError(error)
                }
            }

            /// Success! We have the access token.
            if let accessToken = tokenResponse.access_token {
                Self.logger.info("Access token obtained successfully")
                return accessToken
            }

            /// No error and no token, keep polling.
            try await Task.sleep(for: .seconds(pollInterval))
        }

        /// Timeout reached.
        throw GitHubDeviceFlowError.timeout
    }
}

// MARK: - Response Models

struct DeviceCodeResponse: Codable {
    let device_code: String
    let user_code: String
    let verification_uri: String
    let expires_in: Int
    let interval: Int

    var deviceCode: String { device_code }
    var userCode: String { user_code }
    var verificationUri: String { verification_uri }
}

struct TokenPollResponse: Codable {
    let access_token: String?
    let token_type: String?
    let scope: String?
    let error: String?
    let error_description: String?
    let error_uri: String?
}

// MARK: - Errors

public enum GitHubDeviceFlowError: LocalizedError {
    case invalidResponse
    case requestFailed(statusCode: Int)
    case deviceCodeExpired
    case authorizationDenied
    case timeout
    case unknownError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from GitHub"

        case .requestFailed(let statusCode):
            return "Request failed with status code: \(statusCode)"

        case .deviceCodeExpired:
            return "Device code expired. Please try again."

        case .authorizationDenied:
            return "Authorization denied by user"

        case .timeout:
            return "Authorization timed out after 15 minutes. Please try again."

        case .unknownError(let error):
            return "Unknown error: \(error)"
        }
    }
}
