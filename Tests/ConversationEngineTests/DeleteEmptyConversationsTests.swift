// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import ConversationEngine

/// Tests for ConversationManager.deleteEmptyConversations and
/// getEmptyConversationsInfo.
///
/// "Empty" means conversation.messages.isEmpty. Pinned conversations and
/// shared-data conversations are always preserved.
final class DeleteEmptyConversationsTests: XCTestCase {

    @MainActor
    private func makeConversation(title: String, isPinned: Bool = false, useSharedData: Bool = false) -> ConversationModel {
        let conversation = ConversationModel(title: title)
        conversation.isPinned = isPinned
        conversation.settings.useSharedData = useSharedData
        return conversation
    }

    // MARK: - getEmptyConversationsInfo

    @MainActor
    func testGetEmptyConversationsInfo_NoConversations_ReturnsZeros() {
        let manager = ConversationManager()
        manager.conversations.removeAll()
        let info = manager.getEmptyConversationsInfo()
        XCTAssertEqual(info.emptyToDelete, 0)
        XCTAssertEqual(info.withDirectories, 0)
        XCTAssertEqual(info.pinnedProtected, 0)
    }

    @MainActor
    func testGetEmptyConversationsInfo_OnlyEmptyUnpinned_ReturnsCorrectCount() {
        let manager = ConversationManager()
        let empty1 = makeConversation(title: "Empty 1")
        let empty2 = makeConversation(title: "Empty 2")
        manager.conversations = [empty1, empty2]

        let info = manager.getEmptyConversationsInfo()
        XCTAssertEqual(info.emptyToDelete, 2)
        XCTAssertEqual(info.withDirectories, 2)
        XCTAssertEqual(info.pinnedProtected, 0)
    }

    @MainActor
    func testGetEmptyConversationsInfo_PinnedEmpty_NotCountedInEmpty() {
        let manager = ConversationManager()
        let pinned = makeConversation(title: "Pinned", isPinned: true)
        manager.conversations = [pinned]

        let info = manager.getEmptyConversationsInfo()
        XCTAssertEqual(info.emptyToDelete, 0, "Pinned empty conversations are not deletable")
        XCTAssertEqual(info.pinnedProtected, 1)
    }

    @MainActor
    func testGetEmptyConversationsInfo_SharedEmpty_NotCountedInEmpty() {
        let manager = ConversationManager()
        let shared = makeConversation(title: "Shared", useSharedData: true)
        manager.conversations = [shared]

        let info = manager.getEmptyConversationsInfo()
        XCTAssertEqual(info.emptyToDelete, 0, "Shared-data empty conversations are not deletable")
        XCTAssertEqual(info.withDirectories, 0)
    }

    // MARK: - deleteEmptyConversations

    @MainActor
    func testDeleteEmptyConversations_NoConversations_ReturnsZero() {
        let manager = ConversationManager()
        manager.conversations.removeAll()
        let deleted = manager.deleteEmptyConversations()
        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(manager.conversations.count, 0)
    }

    @MainActor
    func testDeleteEmptyConversations_EmptyUnpinned_DeletesAndReturnsCount() {
        let manager = ConversationManager()
        let empty1 = makeConversation(title: "Empty 1")
        let empty2 = makeConversation(title: "Empty 2")
        manager.conversations = [empty1, empty2]

        let deleted = manager.deleteEmptyConversations()
        XCTAssertEqual(deleted, 2)
        XCTAssertEqual(manager.conversations.count, 0)
    }

    @MainActor
    func testDeleteEmptyConversations_NonEmpty_NotDeleted() {
        let manager = ConversationManager()
        let populated = makeConversation(title: "Populated")
        populated.addMessage(text: "Hello", isUser: true)
        manager.conversations = [populated]

        let deleted = manager.deleteEmptyConversations()
        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(manager.conversations.count, 1)
        XCTAssertEqual(manager.conversations.first?.title, "Populated")
    }

    @MainActor
    func testDeleteEmptyConversations_PinnedEmpty_Preserved() {
        let manager = ConversationManager()
        let pinned = makeConversation(title: "Pinned", isPinned: true)
        let empty = makeConversation(title: "Empty")
        manager.conversations = [pinned, empty]

        let deleted = manager.deleteEmptyConversations()
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(manager.conversations.count, 1)
        XCTAssertEqual(manager.conversations.first?.title, "Pinned")
    }

    @MainActor
    func testDeleteEmptyConversations_SharedEmpty_Preserved() {
        let manager = ConversationManager()
        let shared = makeConversation(title: "Shared", useSharedData: true)
        let empty = makeConversation(title: "Empty")
        manager.conversations = [shared, empty]

        let deleted = manager.deleteEmptyConversations()
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(manager.conversations.count, 1)
        XCTAssertEqual(manager.conversations.first?.title, "Shared")
    }

    @MainActor
    func testDeleteEmptyConversations_ActiveConversationDeleted_ReassignedToFirstRemaining() {
        let manager = ConversationManager()
        let empty = makeConversation(title: "Empty")
        let kept = makeConversation(title: "Kept")
        kept.addMessage(text: "Hello", isUser: true)
        manager.conversations = [empty, kept]
        manager.activeConversation = empty

        let deleted = manager.deleteEmptyConversations()
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(manager.conversations.count, 1)
        XCTAssertNotNil(manager.activeConversation, "Active conversation must be reassigned when deleted")
        XCTAssertEqual(manager.activeConversation?.id, kept.id)
    }

    @MainActor
    func testDeleteEmptyConversations_AllEmpty_ActiveReassignedToNil() {
        let manager = ConversationManager()
        let empty = makeConversation(title: "Empty")
        manager.conversations = [empty]
        manager.activeConversation = empty

        let deleted = manager.deleteEmptyConversations()
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(manager.conversations.count, 0)
        // When all conversations are deleted, active is set to nil (no first to fall back to)
        XCTAssertNil(manager.activeConversation)
    }

    @MainActor
    func testDeleteEmptyConversations_MixedTypes_OnlyEmptyUnpinnedDeleted() {
        let manager = ConversationManager()
        let empty = makeConversation(title: "Empty A")
        let pinned = makeConversation(title: "Pinned B", isPinned: true)
        let shared = makeConversation(title: "Shared C", useSharedData: true)
        let populated = makeConversation(title: "Populated D")
        populated.addMessage(text: "Hi", isUser: true)
        manager.conversations = [empty, pinned, shared, populated]

        let deleted = manager.deleteEmptyConversations()
        XCTAssertEqual(deleted, 1, "Only the empty unpinned conversation should be deleted")
        XCTAssertEqual(manager.conversations.count, 3)
        XCTAssertFalse(manager.conversations.contains { $0.title == "Empty A" })
        XCTAssertTrue(manager.conversations.contains { $0.title == "Pinned B" })
        XCTAssertTrue(manager.conversations.contains { $0.title == "Shared C" })
        XCTAssertTrue(manager.conversations.contains { $0.title == "Populated D" })
    }

    // MARK: - Working directory deletion

    @MainActor
    func testDeleteEmptyConversations_EmptyWorkingDirectory_DeletesIt() throws {
        let manager = ConversationManager()
        let empty = makeConversation(title: "Empty With Dir")

        // Create a real empty directory at the working directory path.
        let fm = FileManager.default
        let dirPath = empty.workingDirectory
        try? fm.removeItem(atPath: dirPath)
        try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        XCTAssertTrue(fm.fileExists(atPath: dirPath))

        manager.conversations = [empty]
        let deleted = manager.deleteEmptyConversations(deleteDirectories: true)

        XCTAssertEqual(deleted, 1)
        XCTAssertFalse(fm.fileExists(atPath: dirPath), "Empty working directory should have been deleted")
    }

    @MainActor
    func testDeleteEmptyConversations_NonEmptyWorkingDirectory_Preserved() throws {
        let manager = ConversationManager()
        let empty = makeConversation(title: "Empty With Files")

        let fm = FileManager.default
        let dirPath = empty.workingDirectory
        try? fm.removeItem(atPath: dirPath)
        try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        let filePath = (dirPath as NSString).appendingPathComponent("important.txt")
        try "important data".write(toFile: filePath, atomically: true, encoding: .utf8)

        manager.conversations = [empty]
        let deleted = manager.deleteEmptyConversations(deleteDirectories: true)

        XCTAssertEqual(deleted, 1, "Conversation should be deleted even if working dir preserved")
        XCTAssertTrue(fm.fileExists(atPath: dirPath), "Non-empty directory should be preserved")
        XCTAssertTrue(fm.fileExists(atPath: filePath), "Files in directory should be preserved")

        // Cleanup
        try? fm.removeItem(atPath: dirPath)
    }
}
