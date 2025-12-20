// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import ConversationEngine

final class ConversationEngineTests: XCTestCase {
    @MainActor
    func testConversationModel() {
        /// ConversationModel is MainActor-isolated; run on MainActor.
        let model = ConversationModel()
        XCTAssertTrue(model.messages.isEmpty)

        model.addMessage(text: "Test message", isUser: true)
        XCTAssertEqual(model.messages.count, 1)
        /// EnhancedMessage fields were renamed to `content` and `isFromUser`.
        XCTAssertEqual(model.messages.first?.content, "Test message")
        XCTAssertTrue(model.messages.first?.isFromUser == true)
    }
}