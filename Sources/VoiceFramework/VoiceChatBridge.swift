// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Combine

/// Bridge class to handle voice callbacks for ChatWidget
/// Needed because ChatWidget is a struct and cannot be captured weakly
@MainActor
public class VoiceChatBridge: ObservableObject {
    @Published public var transcribedText: String = ""
    @Published public var shouldSendMessage: Bool = false
    @Published public var shouldClearMessage: Bool = false
    @Published public var currentMessageText: String = ""

    public init() {}

    /// Reset all triggers
    public func reset() {
        transcribedText = ""
        shouldSendMessage = false
        shouldClearMessage = false
    }
}
