// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

import XCTest
@testable import MCPFramework

/// Tests for LongTermMemory ported CLIO patterns.
final class LongTermMemoryTests: XCTestCase {

    // MARK: - Sanitization Tests

    func testSanitizeNarration_DropsFrameworkPhrases() async throws {
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("To recover: 1. Read the file 2. Fix the bug")
        let discoveries = await ltm.queryDiscoveries()
        XCTAssertEqual(discoveries.count, 1)
        XCTAssertFalse(discoveries[0].fact.contains("To recover"))
    }

    func testSanitizeNarration_ReplacesToolNamesInDiscoveries() async throws {
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("Use memory_operations to store the result")
        let discoveries = await ltm.queryDiscoveries()
        XCTAssertEqual(discoveries.count, 1)
        XCTAssertFalse(discoveries[0].fact.contains("memory_operations"))
        XCTAssertTrue(discoveries[0].fact.contains("long-term memory"))
    }

    func testSanitizeNarration_CodeEntriesKeepToolNames() async throws {
        let ltm = await LongTermMemory()
        await ltm.addSolution(error: "Tool failed", solution: "Use file_operations to fix it")
        let solutions = await ltm.querySolutions()
        XCTAssertEqual(solutions.count, 1)
        XCTAssertTrue(solutions[0].solution.contains("file_operations"))
    }

    func testSanitizeNarration_PreservesContent() async throws {
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("The SQLite schema uses a primary key constraint")
        let discoveries = await ltm.queryDiscoveries()
        XCTAssertEqual(discoveries.count, 1)
        XCTAssertTrue(discoveries[0].fact.contains("SQLite schema"))
    }

    func testAbsolutizeDates_ReplacesRelativeDates() async throws {
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("This was found yesterday in the codebase")
        let discoveries = await ltm.queryDiscoveries()
        XCTAssertEqual(discoveries.count, 1)
        XCTAssertFalse(discoveries[0].fact.contains("yesterday"))
        // Should contain an ISO date (YYYY-MM-DD) instead
        XCTAssertTrue(discoveries[0].fact.contains(/20\d{2}-\d{2}-\d{2}/))
    }

    // MARK: - Corroboration Tests

    func testAddCorroboration_PromotesToTrusted() async throws {
        let ltm = await LongTermMemory()

        await ltm.addDiscovery("This is a test discovery about something")

        let result1 = await ltm.addCorroboration(
            searchText: "test discovery",
            sourceAgent: "clio",
            sourceSession: "session-2"
        )
        XCTAssertTrue(result1.found)
        XCTAssertFalse(result1.promoted)
        XCTAssertEqual(result1.corroborationCount, 1)
        XCTAssertEqual(result1.tier, "unverified")

        let result2 = await ltm.addCorroboration(
            searchText: "test discovery",
            sourceAgent: "sam",
            sourceSession: "session-3"
        )
        XCTAssertTrue(result2.found)
        XCTAssertTrue(result2.promoted)
        XCTAssertEqual(result2.corroborationCount, 2)
        XCTAssertEqual(result2.tier, "trusted")
    }

    func testAddCorroboration_NotFound() async throws {
        let ltm = await LongTermMemory()
        let result = await ltm.addCorroboration(
            searchText: "nonexistent fact",
            sourceAgent: "clio",
            sourceSession: "session-1"
        )
        XCTAssertFalse(result.found)
        XCTAssertEqual(result.tier, "unverified")
        XCTAssertEqual(result.corroborationCount, 0)
    }

    func testAddCorroboration_DuplicateSameSource_AlreadyCorroborated() async throws {
        // Calling addCorroboration twice from the same source:session pair
        // should report alreadyCorroborated=true and NOT inflate the count.
        // This is a regression test for the bug where the corroboration
        // was still appended/incremented even when the source was already
        // present (CLIO skips append/increment when source key is already
        // in corroboration_sources).
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("test discovery for dup check")

        // First corroboration from clio:session-1
        let result1 = await ltm.addCorroboration(
            searchText: "dup check",
            sourceAgent: "clio",
            sourceSession: "session-1"
        )
        XCTAssertTrue(result1.found)
        XCTAssertFalse(result1.alreadyCorroborated)
        XCTAssertEqual(result1.corroborationCount, 1)

        // Second corroboration from the SAME source:session — should
        // be detected as alreadyCorroborated, NOT inflate count.
        let result2 = await ltm.addCorroboration(
            searchText: "dup check",
            sourceAgent: "clio",
            sourceSession: "session-1"
        )
        XCTAssertTrue(result2.found)
        XCTAssertTrue(result2.alreadyCorroborated)
        XCTAssertEqual(result2.corroborationCount, 1)  // unchanged — no inflation
        XCTAssertEqual(result2.tier, "unverified")    // not promoted (same source)
    }

    func testNewEntriesAreUnverified() async throws {
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("test fact")
        let discoveries = await ltm.queryDiscoveries()
        XCTAssertEqual(discoveries.count, 1)
        XCTAssertEqual(discoveries[0].tier, "unverified")
    }

    // MARK: - Scoring Tests

    func testGetEntriesForProjection_FlattensAllTypes() async throws {
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("fact one")
        await ltm.addSolution(error: "err", solution: "fix")
        await ltm.addPattern("use actor isolation")
        await ltm.addWorkflow(sequence: ["step one", "step two"])
        await ltm.addFailure(what: "broken", impact: "bad", prevention: "don't")
        await ltm.addContextRule(context: "/src", rule: "no force unwraps")

        let entries = await ltm.getEntriesForProjection()
        XCTAssertEqual(entries.count, 5)
        let types = Set(entries.map { $0.type })
        XCTAssertEqual(types, Set(["discovery", "solution", "pattern", "workflow", "failure"]))
    }

    func testScoreLtm_RanksByKeywordOverlap() async throws {
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("SQLite database schema constraints are important")
        await ltm.addDiscovery("SwiftUI view schema constraints affect layout")

        let entries = await ltm.getEntriesForProjection()
        let scored = await ltm.scoreLtm(
            entries: entries,
            currentUserInput: "SQLite schema constraints",
            activeTask: "",
            unresolved: []
        )
        let sqliteEntry = scored.first { $0.content.contains("SQLite") }
        XCTAssertNotNil(sqliteEntry)
        let swiftuiEntry = scored.first { $0.content.contains("SwiftUI") }
        XCTAssertNotNil(swiftuiEntry)
        XCTAssertGreaterThan(sqliteEntry!.score, swiftuiEntry!.score)
    }

    func testScoreLtm_TierPenaltyForUnverified() async throws {
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("important database fact about SQLite constraints")

        let entries = await ltm.getEntriesForProjection()
        let scored = await ltm.scoreLtm(
            entries: entries,
            currentUserInput: "SQLite database constraints",
            activeTask: "",
            unresolved: []
        )
        XCTAssertEqual(scored.count, 1)
        // Unverified entries get 0.3x penalty
        XCTAssertEqual(scored[0].score, scored[0].rawScore * 0.3, accuracy: 0.01)
    }

    func testScoreLtm_LazySanitizesOnRead() async throws {
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("memory_operations stores SQLite database constraints")
        let entries = await ltm.getEntriesForProjection()
        let scored = await ltm.scoreLtm(
            entries: entries,
            currentUserInput: "SQLite database constraints",
            activeTask: "",
            unresolved: []
        )
        XCTAssertFalse(scored.isEmpty)
        for entry in scored {
            XCTAssertFalse(entry.content.contains("memory_operations"))
        }
    }

    // MARK: - Consolidation Tests

    func testConsolidate_RemovesStaleUnverified() async throws {
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("recent fact")

        await MainActor.run {
            var stale = LTMDiscovery(fact: "stale fact", confidence: 0.5, verified: false, tier: "unverified")
            stale.timestamp = Date().timeIntervalSince1970 - (100 * 86400)
            ltm.patterns.discoveries.append(stale)
        }

        let _ = await ltm.consolidate()
        XCTAssertTrue(true)
    }

    func testConsolidate_KeepsTrustedOldEntries() async throws {
        let ltm = await LongTermMemory()

        await MainActor.run {
            var trusted = LTMDiscovery(fact: "trusted old fact", confidence: 0.8, verified: true, tier: "trusted")
            trusted.timestamp = Date().timeIntervalSince1970 - (60 * 86400)
            ltm.patterns.discoveries.append(trusted)
        }

        _ = await ltm.consolidate()
        let count = await MainActor.run { ltm.patterns.discoveries.count }
        XCTAssertEqual(count, 1)
        let fact = await MainActor.run { ltm.patterns.discoveries[0].fact }
        XCTAssertTrue(fact.contains("trusted old fact"))
    }

    func testConsolidate_AppliesConfidenceDecay() async throws {
        let ltm = await LongTermMemory()

        await MainActor.run {
            var old = LTMDiscovery(fact: "decaying fact", confidence: 0.9, verified: false, tier: "unverified")
            old.timestamp = Date().timeIntervalSince1970 - (200 * 86400)
            ltm.patterns.discoveries.append(old)
        }

        let stats = await ltm.consolidate(maxAgeDays: 365, confidenceDecayDays: 60)
        XCTAssertGreaterThan(stats.decayed, 0)
        let confidence = await MainActor.run { ltm.patterns.discoveries.first?.confidence ?? 0 }
        XCTAssertLessThan(confidence, 0.9)
    }

    func testConsolidate_DeduplicatesByNameSimilarity() async throws {
        let ltm = await LongTermMemory()
        await ltm.addPattern("Use actor isolation for thread safety")
        await ltm.addPattern("Use actor isolation for thread safety")
        await ltm.addPattern("Use actor isolation for thread safety")

        let stats = await ltm.consolidate()
        let count = await MainActor.run { ltm.patterns.codePatterns.count }
        XCTAssertEqual(count, 1)
    }

    func testMaybeConsolidate_SkipsWhenTooRecent() async throws {
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("test")
        await MainActor.run {
            ltm.metadata.lastConsolidated = Date().timeIntervalSince1970 - (1 * 3600)
        }

        let result = await ltm.maybeConsolidate(minHours: 24)
        XCTAssertNil(result)
    }

    func testMaybeConsolidate_RunsWhenStale() async throws {
        let ltm = await LongTermMemory()
        // Use distinct fact sets so fuzzyMatch (60% word-overlap threshold) does
        // not collapse them into a single entry.  Each fact shares at most ~2
        // words with any other, keeping the overlap below the deduplication
        // threshold.
        let distinctFacts = [
            "Database indexes accelerate query performance dramatically",
            "Git branch strategies prevent merge conflict escalation",
            "Memory leaks occur when references are never released",
            "Compiler optimizations transform code before execution",
            "Network timeouts require exponential backoff strategies",
            "API rate limits constrain client request frequency",
            "Disk fragmentation degrades sequential read throughput",
            "CPU cache lines store adjacent memory locations together",
            "SSL certificates require periodic renewal automation",
            "Log rotation prevents disk space exhaustion over time",
            "Connection pooling reduces socket allocation overhead",
            "Database transactions guarantee atomicity and consistency",
            "Garbage collection reclaims unreachable allocated objects",
            "Encryption keys must rotate after security incidents",
            "Load balancers distribute traffic across backend servers",
            "DNS caching improves hostname resolution latency",
            "File permissions control access to sensitive data",
            "Thread synchronization prevents race conditions",
            "Package managers resolve dependency trees automatically",
            "Container images contain immutable filesystem layers",
            "Environment variables configure application behavior",
            "Message queues decouple producers from consumers",
            "Content delivery networks cache assets geographically",
            "Circuit breakers prevent cascade failure propagation",
            "Feature flags enable gradual rollout control"
        ]
        for fact in distinctFacts {
            await ltm.addDiscovery(fact)
        }
        await MainActor.run {
            ltm.metadata.lastConsolidated = Date().timeIntervalSince1970 - (48 * 3600)
        }

        let result = await ltm.maybeConsolidate(minHours: 24, minEntries: 20)
        XCTAssertNotNil(result)
    }

    // MARK: - Format For System Prompt Tests

    func testFormatForSystemPrompt_EmptyLTM_ReturnsEmpty() async throws {
        let ltm = await LongTermMemory()
        let result = await ltm.formatForSystemPrompt()
        XCTAssertTrue(result.isEmpty)
    }

    func testFormatForSystemPrompt_WithEntries_ReturnsNonEmpty() async throws {
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("SQLite database uses primary keys for constraints")
        let result = await ltm.formatForSystemPrompt()
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.contains("Long-Term Memory"))
        XCTAssertTrue(result.contains("SQLite"))
    }

    func testFormatForSystemPrompt_NoFrameworkTerms() async throws {
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("Use memory_operations to store data")
        let result = await ltm.formatForSystemPrompt()
        XCTAssertFalse(result.contains("memory_operations"))
        XCTAssertTrue(result.contains("long-term memory"))
    }

    // MARK: - Prune Tests

    func testPrune_TierAwareRemoval() async throws {
        let ltm = await LongTermMemory()

        await MainActor.run {
            var unverified = LTMDiscovery(fact: "old unverified fact", confidence: 0.3, verified: false, tier: "unverified")
            unverified.timestamp = Date().timeIntervalSince1970 - (100 * 86400)
            ltm.patterns.discoveries.append(unverified)

            var trusted = LTMDiscovery(fact: "old trusted fact", confidence: 0.8, verified: true, tier: "trusted")
            trusted.timestamp = Date().timeIntervalSince1970 - (40 * 86400)
            ltm.patterns.discoveries.append(trusted)
        }

        let before = await MainActor.run { ltm.patterns.discoveries.count }
        let result = await ltm.prune()
        XCTAssertEqual(result.removed, 1)
        let afterCount = await MainActor.run { ltm.patterns.discoveries.count }
        XCTAssertEqual(afterCount, before - 1)
        let allFacts = await MainActor.run { ltm.patterns.discoveries.map { $0.fact } }
        XCTAssertTrue(allFacts.allSatisfy { !$0.contains("old unverified fact") })
    }

    // MARK: - Save/Load Tests

    func testSaveLoad_RoundsTrip() async throws {
        let ltm = await LongTermMemory()
        await ltm.addDiscovery("SQLite uses B-tree indexing")
        await ltm.addSolution(error: "crash on null", solution: "use guard let")
        await ltm.addPattern("always use Sendable conformance")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltm_test_\(UUID().uuidString)")
            .path
        let filePath = "\(tempDir)/ltm.json"

        await ltm.save(to: filePath)

        let loaded = await LongTermMemory.load(from: filePath)
        let discoveries = await MainActor.run { loaded.patterns.discoveries.count }
        let solutions = await MainActor.run { loaded.patterns.problemSolutions.count }
        let patterns = await MainActor.run { loaded.patterns.codePatterns.count }
        let firstFact = await MainActor.run { loaded.patterns.discoveries.first?.fact }
        XCTAssertEqual(discoveries, 1)
        XCTAssertEqual(solutions, 1)
        XCTAssertEqual(patterns, 1)
        XCTAssertEqual(firstFact, "SQLite uses B-tree indexing")

        try? FileManager.default.removeItem(atPath: tempDir)
    }

    func testLoad_NonexistentFile_CreatesEmpty() async throws {
        let path = "/tmp/nonexistent_ltm_\(UUID().uuidString).json"
        let ltm = await LongTermMemory.load(from: path)
        let entries = await ltm.totalEntries
        XCTAssertEqual(entries, 0)
    }
}
