// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework

final class APIFrameworkTests: XCTestCase {
    func testOpenAIModelsCreation() throws {
        let model = ServerOpenAIModel(
            id: "test-model",
            object: "model",
            created: 1234567890,
            ownedBy: "sam"
        )
        
        XCTAssertEqual(model.id, "test-model")
        XCTAssertEqual(model.object, "model")
        XCTAssertEqual(model.ownedBy, "sam")
    }
    
    func testOpenAIChatRequestCreation() throws {
        let message = OpenAIChatMessage(role: "user", content: "Hello")
        let request = OpenAIChatRequest(
            model: "gpt-4",
            messages: [message],
            temperature: 0.7,
            maxTokens: 100,
            stream: false,
            samConfig: nil,
            contextId: nil,
            enableMemory: nil
        )
        
        XCTAssertEqual(request.model, "gpt-4")
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.messages.first?.content, "Hello")
        XCTAssertEqual(request.temperature, 0.7)
    }
}