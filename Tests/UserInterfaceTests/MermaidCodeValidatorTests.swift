// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import UserInterface

/// Tests for MermaidCodeValidator - ensures streaming detection works correctly
/// and prevents partial/incomplete mermaid code from being sent to mermaid.js
final class MermaidCodeValidatorTests: XCTestCase {

    // MARK: - Empty / Minimal Input

    func testEmptyCodeIsIncomplete() {
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete(""))
    }

    func testWhitespaceOnlyIsIncomplete() {
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete("   \n  \n  "))
    }

    func testSingleLineIsIncomplete() {
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete("flowchart TD"))
    }

    func testTypeDeclarationOnlyIsIncomplete() {
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete("sequenceDiagram"))
    }

    // MARK: - Complete Diagrams

    func testSimpleFlowchartIsComplete() {
        let code = """
        flowchart TD
            A --> B
        """
        XCTAssertTrue(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testFlowchartWithLabelsIsComplete() {
        let code = """
        flowchart TD
            A[Start] --> B{Is it working?}
            B -->|Yes| C[Great!]
            B -->|No| D[Debug]
            D --> B
            C --> E[End]
        """
        XCTAssertTrue(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testSequenceDiagramIsComplete() {
        let code = """
        sequenceDiagram
            participant User
            participant SAM
            User->>SAM: Send message
            SAM-->>User: Display result
        """
        XCTAssertTrue(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testClassDiagramIsComplete() {
        let code = """
        classDiagram
            Animal <|-- Duck
            Animal <|-- Fish
            Animal : +int age
            Animal : +String gender
            Duck : +swim()
        """
        XCTAssertTrue(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testPieChartIsComplete() {
        let code = """
        pie title Pets
            "Dogs" : 386
            "Cats" : 85
            "Rats" : 15
        """
        XCTAssertTrue(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testGanttIsComplete() {
        let code = """
        gantt
            title A Gantt Diagram
            section Section
            A task :a1, 2024-01-01, 30d
            Another task :after a1, 20d
        """
        XCTAssertTrue(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testGitGraphIsComplete() {
        let code = """
        gitGraph
            commit
            branch develop
            checkout develop
            commit
            checkout main
            merge develop
        """
        XCTAssertTrue(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testStateDiagramIsComplete() {
        let code = """
        stateDiagram-v2
            [*] --> Still
            Still --> [*]
            Still --> Moving
            Moving --> Still
            Moving --> Crash
            Crash --> [*]
        """
        XCTAssertTrue(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testERDiagramIsComplete() {
        let code = """
        erDiagram
            CUSTOMER ||--o{ ORDER : places
            ORDER ||--|{ LINE-ITEM : contains
        """
        XCTAssertTrue(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testJourneyIsComplete() {
        let code = """
        journey
            title My working day
            section Go to work
                Make tea: 5: Me
                Go upstairs: 3: Me
        """
        XCTAssertTrue(MermaidCodeValidator.isLikelyComplete(code))
    }

    // MARK: - Incomplete Diagrams (Streaming Scenarios)

    func testUnmatchedSquareBracketIsIncomplete() {
        let code = """
        flowchart TD
            Start --> A[Process
        """
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testUnmatchedCurlyBraceIsIncomplete() {
        let code = """
        flowchart TD
            A --> B{Is it
        """
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testUnmatchedParenIsIncomplete() {
        let code = """
        flowchart TD
            A --> B(Round
        """
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testDanglingArrowIsIncomplete() {
        let code = """
        flowchart TD
            A -->
        """
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testDanglingDottedArrowIsIncomplete() {
        let code = """
        flowchart TD
            A -.->
        """
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testDanglingThickArrowIsIncomplete() {
        let code = """
        flowchart TD
            A ==>
        """
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testDanglingPipeIsIncomplete() {
        let code = """
        flowchart TD
            A -->|
        """
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testDanglingColonIsIncomplete() {
        let code = """
        sequenceDiagram
            User->>SAM:
        """
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testMidStreamFlowchartChunk() {
        // Simulates what happens when only the first few tokens have arrived
        let code = """
        flowchart TD
            Start --> A[Process A]
            A --> B[Process
        """
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testSequenceDiagramMidArrow() {
        let code = """
        sequenceDiagram
            participant User
            participant SAM
            User->>
        """
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testNestedBracketsPartiallyComplete() {
        // One pair complete, one not
        let code = """
        flowchart TD
            A[Done] --> B{Not done
        """
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete(code))
    }

    // MARK: - Edge Cases

    func testCommentsOnlyIsIncomplete() {
        let code = """
        flowchart TD
            %% This is a comment
        """
        // Comments are filtered out, leaving only 1 non-comment line
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testCodeWithCommentsAndContentIsComplete() {
        let code = """
        flowchart TD
            %% Setup
            A --> B
        """
        XCTAssertTrue(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testDanglingDoubleDashIsIncomplete() {
        let code = """
        flowchart TD
            A --
        """
        XCTAssertFalse(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testGraphDirectionVariantsComplete() {
        for direction in ["TD", "TB", "BT", "LR", "RL"] {
            let code = """
            graph \(direction)
                A --> B
            """
            XCTAssertTrue(
                MermaidCodeValidator.isLikelyComplete(code),
                "graph \(direction) should be complete"
            )
        }
    }

    func testMindmapIsComplete() {
        let code = """
        mindmap
            root((Central Idea))
                Branch 1
                Branch 2
        """
        XCTAssertTrue(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testTimelineIsComplete() {
        let code = """
        timeline
            title History
            2023 : Event A
            2024 : Event B
        """
        XCTAssertTrue(MermaidCodeValidator.isLikelyComplete(code))
    }

    func testXYChartIsComplete() {
        let code = """
        xychart-beta
            title "Sales Revenue"
            x-axis [jan, feb, mar]
            y-axis "Revenue (in $)" 4000 --> 11000
            bar [5000, 6000, 7500]
        """
        XCTAssertTrue(MermaidCodeValidator.isLikelyComplete(code))
    }

    // MARK: - Regression: Exact crash scenario from logs

    func testExactCrashScenarioPartialProcess() {
        // This is the exact code that caused the crash:
        // flowchart TD\n    Start --> A[Process
        let code = "flowchart TD\n    Start --> A[Process"
        XCTAssertFalse(
            MermaidCodeValidator.isLikelyComplete(code),
            "Partial 'A[Process' with unmatched bracket must be detected as incomplete"
        )
    }

    func testExactCrashScenarioPartialProcessA() {
        // Next streaming chunk: flowchart TD\n    Start --> A[Process A
        let code = "flowchart TD\n    Start --> A[Process A"
        XCTAssertFalse(
            MermaidCodeValidator.isLikelyComplete(code),
            "Partial 'A[Process A' with unmatched bracket must be detected as incomplete"
        )
    }
}
