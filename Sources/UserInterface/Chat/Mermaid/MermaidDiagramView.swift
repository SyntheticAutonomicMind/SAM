// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging

/// Main Mermaid diagram view - integrates parser and renderers
@MainActor
struct MermaidDiagramView: View {
    let code: String
    let showBackground: Bool
    private let logger = Logger(label: "com.sam.mermaid")
    @State private var diagram: MermaidDiagram?
    @State private var lastCodeLength: Int = 0  // Track code length changes
    private let preparsedDiagram: MermaidDiagram? // For PDF/print: skip async parsing

    /// Standard initializer - parses diagram on appear (for UI)
    init(code: String, showBackground: Bool = true) {
        self.code = code
        self.showBackground = showBackground
        self.preparsedDiagram = nil
    }

    /// Pre-parsed initializer - for PDF/print where we need immediate rendering
    init(code: String, diagram: MermaidDiagram, showBackground: Bool = true) {
        self.code = code
        self.showBackground = showBackground
        self.preparsedDiagram = diagram
        self._diagram = State(initialValue: diagram) // Initialize state immediately
    }

    var body: some View {
        Group {
            if let diagram = diagram {
                switch diagram {
                case .flowchart(let flowchart):
                    FlowchartRenderer(flowchart: flowchart)
                        .padding()
                        .conditionalBackground(showBackground)

                case .sequence(let sequence):
                    SequenceDiagramRenderer(diagram: sequence)
                        .padding()
                        .conditionalBackground(showBackground)

                case .classDiagram(let classDiagram):
                    ClassDiagramRenderer(diagram: classDiagram)
                        .padding()
                        .conditionalBackground(showBackground)

                case .stateDiagram(let stateDiagram):
                    StateDiagramRenderer(diagram: stateDiagram)
                        .padding()
                        .conditionalBackground(showBackground)

                case .erDiagram(let erDiagram):
                    ERDiagramRenderer(diagram: erDiagram)
                        .padding()
                        .conditionalBackground(showBackground)

                case .gantt(let gantt):
                    GanttRenderer(chart: gantt)
                        .padding()
                        .conditionalBackground(showBackground)

                case .pie(let pie):
                    PieChartRenderer(chart: pie)
                        .padding()
                        .conditionalBackground(showBackground)

                case .journey(let journey):
                    JourneyRenderer(journey: journey)
                        .padding()
                        .conditionalBackground(showBackground)

                case .mindmap(let mindmap):
                    MindmapRenderer(mindmap: mindmap)
                        .padding()
                        .conditionalBackground(showBackground)

                case .timeline(let timeline):
                    TimelineRenderer(timeline: timeline)
                        .padding()
                        .conditionalBackground(showBackground)

                case .quadrant(let quadrant):
                    QuadrantChartRenderer(chart: quadrant)
                        .padding()
                        .conditionalBackground(showBackground)

                case .requirement(let requirement):
                    RequirementDiagramRenderer(diagram: requirement)
                        .padding()
                        .conditionalBackground(showBackground)

                case .gitGraph(let gitGraph):
                    GitGraphRenderer(graph: gitGraph)
                        .padding()
                        .conditionalBackground(showBackground)

                case .xychart(let xychart):
                    XYChartRenderer(chart: xychart)
                        .padding()
                        .conditionalBackground(showBackground)

                case .unsupported:
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("MERMAID (unsupported type)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            Spacer()
                        }
                        .background(Color.secondary.opacity(0.1))

                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(code)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.primary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                }
            } else {
                ProgressView()
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .conditionalBackground(showBackground)

            }
        }
        .onAppear {
            // Skip parsing if we have a pre-parsed diagram (for PDF/print)
            if preparsedDiagram == nil {
                parseDiagram()
            }
        }
        .onChange(of: code) { _ in
            // Only re-parse if not using pre-parsed diagram
            if preparsedDiagram == nil {
                parseDiagram()
            }
        }
    }

    private func parseDiagram() {
        /// CRITICAL FIX: Only parse if not already parsed OR if previously unsupported
        /// Prevents re-parsing on every .onAppear (scroll into view)
        /// which was causing scroll bounce due to height recalculation
        /// STREAMING FIX: Allow re-parsing if:
        /// 1. Diagram is .unsupported (incomplete during streaming)
        /// 2. Diagram is empty (no content yet)
        /// 3. Code length is still changing (streaming in progress)
        if let currentDiagram = diagram {
            switch currentDiagram {
            case .unsupported:
                // Allow re-parsing for unsupported diagrams (likely incomplete during streaming)
                logger.debug("Re-parsing previously unsupported diagram, code length: \(code.count)")
            default:
                // Check if we have an empty diagram OR code is still changing
                let isEmpty = isDiagramEmpty(currentDiagram)
                let codeStillChanging = code.count != lastCodeLength

                if isEmpty {
                    logger.debug("Re-parsing empty diagram (minimum threshold not met), code length: \(code.count)")
                    break
                } else if codeStillChanging {
                    logger.debug("Re-parsing diagram (code still changing: \(lastCodeLength) → \(code.count))")
                    break
                }

                // Diagram is complete and code stopped changing
                logger.debug("Diagram complete, code stabilized at \(code.count) chars")
                return
            }
        }

        // Update code length tracker
        lastCodeLength = code.count

        let parser = MermaidParser()
        let newDiagram = parser.parse(code)

        // CRITICAL: Force SwiftUI to detect state change by wrapping in withAnimation
        // This ensures view updates when diagram changes from .unsupported to valid type
        withAnimation {
            diagram = newDiagram
        }

        switch diagram {
        case .flowchart(let fc):
            logger.info("Parsed flowchart with \(fc.nodes.count) nodes and \(fc.edges.count) edges")
        case .sequence(let seq):
            logger.info("Parsed sequence diagram with \(seq.participants.count) participants and \(seq.messages.count) messages")
        case .classDiagram(let cd):
            logger.info("Parsed class diagram with \(cd.classes.count) classes")
        case .stateDiagram(let sd):
            logger.info("Parsed state diagram with \(sd.states.count) states")
        case .erDiagram(let er):
            logger.info("Parsed ER diagram with \(er.entities.count) entities")
        case .gantt(let gantt):
            logger.info("Parsed Gantt chart with \(gantt.tasks.count) tasks")
        case .pie(let pie):
            logger.info("Parsed pie chart with \(pie.slices.count) slices")
        case .journey(let journey):
            logger.info("Parsed user journey with \(journey.sections.count) sections")
        case .mindmap:
            logger.info("Parsed mindmap")
        case .timeline(let timeline):
            logger.info("Parsed timeline with \(timeline.events.count) events")
        case .quadrant(let quadrant):
            logger.info("Parsed quadrant chart with \(quadrant.points.count) points")
        case .requirement(let req):
            logger.info("Parsed requirement diagram with \(req.requirements.count) requirements")
        case .gitGraph(let git):
            logger.info("Parsed git graph with \(git.commits.count) commits")
        case .xychart(let xy):
            logger.info("Parsed XY chart with \(xy.dataSeries.count) series")
        case .unsupported:
            logger.warning("Unsupported diagram type")
        case .none:
            logger.error("Failed to parse diagram")
        }
    }

    /// Check if diagram is empty (just type declaration, no actual content)
    /// Empty diagrams should be re-parsed when more content arrives
    /// STREAMING: Use minimum viable thresholds to avoid stopping too early
    private func isDiagramEmpty(_ diagram: MermaidDiagram) -> Bool {
        switch diagram {
        case .flowchart(let fc):
            // Need at least 2 nodes AND 1 edge for a viable flowchart
            return fc.nodes.count < 2 || fc.edges.isEmpty
        case .sequence(let seq):
            // Need at least 2 participants AND 1 message
            return seq.participants.count < 2 || seq.messages.isEmpty
        case .classDiagram(let cd):
            // Need at least 2 classes
            return cd.classes.count < 2
        case .stateDiagram(let sd):
            // Need at least 2 states
            return sd.states.count < 2
        case .erDiagram(let er):
            // Need at least 2 entities
            return er.entities.count < 2
        case .gantt(let gantt):
            // Need at least 2 tasks
            return gantt.tasks.count < 2
        case .pie(let pie):
            // Need at least 2 slices
            return pie.slices.count < 2
        case .journey(let journey):
            // Need at least 1 section with tasks
            return journey.sections.isEmpty || journey.sections.allSatisfy { $0.tasks.isEmpty }
        case .mindmap(let mindmap):
            // Need at least 1 child node
            return mindmap.root.children.isEmpty
        case .timeline(let timeline):
            // Need at least 2 events
            return timeline.events.count < 2
        case .quadrant(let quadrant):
            // Need at least 2 points
            return quadrant.points.count < 2
        case .requirement(let req):
            // Need at least 1 requirement
            return req.requirements.isEmpty
        case .gitGraph(let git):
            // Need at least 2 commits
            return git.commits.count < 2
        case .xychart(let xy):
            // Need at least 1 series with 2+ values
            return xy.dataSeries.isEmpty || xy.dataSeries.allSatisfy { $0.values.count < 2 }
        case .unsupported:
            return false // Will be handled separately
        }
    }
}

// MARK: - View Modifier

extension View {
    @ViewBuilder
    func conditionalBackground(_ showBackground: Bool) -> some View {
        if showBackground {
            self
                .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
        } else {
            self
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        Text("Flowchart Example")
            .font(.headline)

        MermaidDiagramView(code: """
        flowchart TD
            A[Start] --> B{Is it working?}
            B -->|Yes| C[Great!]
            B -->|No| D[Debug]
            D --> B
            C --> E[End]
        """)

        Text("Simple Flow")
            .font(.headline)

        MermaidDiagramView(code: """
        graph LR
            A[Input] --> B(Process)
            B --> C{Decision}
            C -->|Option 1| D[Result 1]
            C -->|Option 2| E[Result 2]
        """)
    }
    .padding()
    .frame(width: 700, height: 900)
}
