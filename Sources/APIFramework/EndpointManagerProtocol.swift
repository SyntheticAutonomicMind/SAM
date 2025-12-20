// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation

@MainActor
public protocol EndpointManagerProtocol: AnyObject {
    /// Get endpoint provider information as dictionaries (to avoid circular dependency) - Returns: Array of dictionaries containing endpoint metadata.
    func getEndpointInfo() -> [[String: Any]]
}
