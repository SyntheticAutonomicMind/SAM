// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import SwiftUI

// MARK: - Mermaid Diagram Models

/// Represents a Mermaid diagram
enum MermaidDiagram {
    case flowchart(Flowchart)
    case sequence(SequenceDiagram)
    case classDiagram(ClassDiagram)
    case stateDiagram(StateDiagram)
    case erDiagram(ERDiagram)
    case gantt(GanttChart)
    case pie(PieChart)
    case journey(UserJourney)
    case mindmap(Mindmap)
    case timeline(Timeline)
    case quadrant(QuadrantChart)
    case requirement(RequirementDiagram)
    case gitGraph(GitGraph)
    case xychart(XYChart)
    case unsupported(String)
}

// MARK: - Flowchart Models

/// Flowchart diagram
struct Flowchart {
    let direction: FlowchartDirection
    var nodes: [FlowchartNode]
    let edges: [FlowchartEdge]
    var nodeStyles: [String: NodeStyle] = [:]  // nodeId -> style
    var linkStyles: [Int: EdgeStyleProperties] = [:]  // edge index -> style
}

/// Flowchart direction
enum FlowchartDirection: String {
    case topDown = "TD"
    case topToBottom = "TB"
    case bottomToTop = "BT"
    case leftToRight = "LR"
    case rightToLeft = "RL"

    var isHorizontal: Bool {
        self == .leftToRight || self == .rightToLeft
    }
}

/// Flowchart node
struct FlowchartNode: Identifiable, Hashable {
    let id: String
    let label: String
    let shape: NodeShape
    var style: NodeStyle?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FlowchartNode, rhs: FlowchartNode) -> Bool {
        lhs.id == rhs.id
    }
}

/// Node styling
struct NodeStyle {
    var fill: String?        // fill color
    var stroke: String?      // border color
    var strokeWidth: String? // border width
    var color: String?       // text color
}

/// Node shape types
enum NodeShape {
    case rectangle      // [text]
    case roundedRect    // (text)
    case stadium        // ([text])
    case subroutine     // [[text]]
    case cylinder       // [(text)]
    case circle         // ((text))
    case asymmetric     // >text]
    case rhombus        // {text}
    case hexagon        // {{text}}
    case parallelogram  // [/text/]
    case trapezoid      // [\\text\\]
}

/// Flowchart edge (connection between nodes)
struct FlowchartEdge: Identifiable {
    let id: UUID = UUID()
    let from: String  // Node ID
    let to: String    // Node ID
    let label: String?
    let style: EdgeStyle
    let color: String?  // Optional color specification (e.g., "red", "#FF0000")
}

/// Edge style
enum EdgeStyle {
    case solid          // -->
    case dotted         // .->
    case thick          // ==>
}

/// Edge styling properties
struct EdgeStyleProperties {
    var stroke: String?      // line color
    var strokeWidth: String? // line width  
}

// MARK: - Sequence Diagram Models

/// Sequence diagram
struct SequenceDiagram {
    let participants: [Participant]
    let messages: [SequenceMessage]
    let notes: [Note]
    let activations: [Activation]
    let boxes: [Box]  // Swimlane boxes
}

/// Box (swimlane) in a sequence diagram
struct Box: Identifiable, Hashable {
    let id: UUID = UUID()
    let name: String?  // Optional box label
    let color: String?  // Optional box color
    let participantIds: [String]  // Participants in this box

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Box, rhs: Box) -> Bool {
        lhs.id == rhs.id
    }
}

/// Participant in a sequence diagram
struct Participant: Identifiable, Hashable {
    let id: String
    let label: String
    let type: ParticipantType

    enum ParticipantType {
        case participant
        case actor
    }
}

/// Message between participants
struct SequenceMessage: Identifiable, Hashable {
    let id: UUID = UUID()
    let from: String
    let to: String
    let text: String
    let type: MessageType

    enum MessageType {
        case solid          // ->>
        case dotted         // -->>
        case async          // --)
        case solidArrow     // ->
        case dottedArrow    // -->
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SequenceMessage, rhs: SequenceMessage) -> Bool {
        lhs.id == rhs.id
    }
}

/// Note in a sequence diagram
struct Note: Identifiable, Hashable {
    let id: UUID = UUID()
    let text: String
    let position: NotePosition

    enum NotePosition {
        case over([String])
        case left(String)
        case right(String)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Note, rhs: Note) -> Bool {
        lhs.id == rhs.id
    }
}

/// Activation box in a sequence diagram
struct Activation: Identifiable, Hashable {
    let id: UUID = UUID()
    let participant: String
    let startIndex: Int
    let endIndex: Int

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Activation, rhs: Activation) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Class Diagram Models

/// Class diagram
struct ClassDiagram {
    let classes: [ClassNode]
    let relationships: [ClassRelationship]
}

/// Class node
struct ClassNode: Identifiable, Hashable {
    let id: String
    let name: String
    let attributes: [String]
    let methods: [String]
    let stereotype: String?
}

/// Relationship between classes
struct ClassRelationship: Identifiable, Hashable {
    let id: UUID = UUID()
    let from: String
    let to: String
    let type: RelationType
    let label: String?

    enum RelationType {
        case inheritance    // <|--
        case composition    // *--
        case aggregation    // o--
        case association    // --
        case dependency     // ..>
        case realization    // ..|>
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ClassRelationship, rhs: ClassRelationship) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - State Diagram Models

/// State diagram
struct StateDiagram {
    let states: [StateNode]
    let transitions: [StateTransition]
}

/// State node
struct StateNode: Identifiable, Hashable {
    let id: String
    let label: String
    let type: StateType

    enum StateType {
        case normal
        case start
        case end
        case choice
    }
}

/// Transition between states
struct StateTransition: Identifiable, Hashable {
    let id: UUID = UUID()
    let from: String
    let to: String
    let label: String?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: StateTransition, rhs: StateTransition) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ER Diagram Models

/// Entity-Relationship diagram
struct ERDiagram {
    let entities: [Entity]
    let relationships: [ERRelationship]
}

/// Entity in ER diagram
struct Entity: Identifiable, Hashable {
    let id: String
    let name: String
    let attributes: [ERAttribute]
}

/// Attribute of an entity
struct ERAttribute: Identifiable, Hashable {
    let id: UUID = UUID()
    let name: String
    let type: String?
    let isKey: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ERAttribute, rhs: ERAttribute) -> Bool {
        lhs.id == rhs.id
    }
}

/// Relationship between entities
struct ERRelationship: Identifiable, Hashable {
    let id: UUID = UUID()
    let from: String
    let to: String
    let label: String
    let fromCardinality: String
    let toCardinality: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ERRelationship, rhs: ERRelationship) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Gantt Chart Models

/// Gantt chart
struct GanttChart {
    let title: String?
    let dateFormat: String?
    let tasks: [GanttTask]
}

/// Task in a Gantt chart
struct GanttTask: Identifiable, Hashable {
    let id: String
    let name: String
    let startDate: Date?
    let duration: Int?
    let status: TaskStatus
    let dependencies: [String]

    enum TaskStatus {
        case active
        case done
        case crit
        case milestone
    }
}

// MARK: - Pie Chart Models

/// Pie chart
struct PieChart {
    let title: String?
    let slices: [PieSlice]
}

/// Slice in a pie chart
struct PieSlice: Identifiable, Hashable {
    let id: UUID = UUID()
    let label: String
    let value: Double

    var percentage: Double {
        0.0 // Will be calculated by renderer
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PieSlice, rhs: PieSlice) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - User Journey Models

/// User journey
struct UserJourney {
    let title: String?
    let sections: [JourneySection]
}

/// Section in a user journey
struct JourneySection: Identifiable, Hashable {
    let id: UUID = UUID()
    let name: String
    let tasks: [JourneyTask]

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: JourneySection, rhs: JourneySection) -> Bool {
        lhs.id == rhs.id
    }
}

/// Task in a journey
struct JourneyTask: Identifiable, Hashable {
    let id: UUID = UUID()
    let name: String
    let score: Int
    let actors: [String]

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: JourneyTask, rhs: JourneyTask) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Mindmap Models

/// Mindmap
struct Mindmap {
    let root: MindmapNode
}

/// Node in a mindmap
struct MindmapNode: Identifiable, Hashable {
    let id: String
    let label: String
    let children: [MindmapNode]
    let level: Int
}

// MARK: - Timeline Models

/// Timeline
struct Timeline {
    let title: String?
    let events: [MermaidTimelineEvent]
}

/// Event in a timeline
struct MermaidTimelineEvent: Identifiable, Hashable {
    let id: UUID = UUID()
    let period: String
    let events: [String]

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MermaidTimelineEvent, rhs: MermaidTimelineEvent) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Quadrant Chart Models

/// Quadrant chart
struct QuadrantChart {
    let title: String?
    let xAxisLabel: String?
    let yAxisLabel: String?
    let quadrants: [String]
    let points: [QuadrantPoint]
}

/// Point in a quadrant chart
struct QuadrantPoint: Identifiable, Hashable {
    let id: UUID = UUID()
    let label: String
    let x: Double
    let y: Double

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: QuadrantPoint, rhs: QuadrantPoint) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Requirement Diagram Models

/// Requirement diagram
struct RequirementDiagram {
    let requirements: [Requirement]
    let relationships: [RequirementRelationship]
}

/// Requirement node
struct Requirement: Identifiable, Hashable {
    let id: String
    let type: RequirementType
    let text: String
    let riskLevel: String?
    let verifyMethod: String?

    enum RequirementType {
        case requirement
        case functionalRequirement
        case performanceRequirement
        case interfaceRequirement
        case designConstraint
    }
}

/// Relationship between requirements
struct RequirementRelationship: Identifiable, Hashable {
    let id: UUID = UUID()
    let from: String
    let to: String
    let type: RelationType

    enum RelationType {
        case contains
        case copies
        case derives
        case satisfies
        case verifies
        case refines
        case traces
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: RequirementRelationship, rhs: RequirementRelationship) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Git Graph Models

/// Git graph
struct GitGraph {
    let commits: [GitCommit]
    let branches: [GitBranch]
}

/// Commit in a git graph
struct GitCommit: Identifiable, Hashable {
    let id: String
    let message: String?
    let branch: String
    let tag: String?
    let type: CommitType

    enum CommitType {
        case normal
        case merge
        case cherry
    }
}

/// Branch in a git graph
struct GitBranch: Identifiable, Hashable {
    let id: String
    let name: String
    let order: Int
}

// MARK: - XY Chart Models (Bar/Line Charts)

/// XY Chart (xychart-beta) - supports bar and line charts
struct XYChart {
    let title: String?
    let xAxisLabel: String?
    let yAxisLabel: String?
    let xAxisCategories: [String]  // Category labels for x-axis
    let dataSeries: [XYDataSeries]
    let orientation: XYChartOrientation
}

/// Chart orientation
enum XYChartOrientation {
    case horizontal  // Default
    case vertical
}

/// A data series in an XY chart (can be bar or line)
struct XYDataSeries: Identifiable, Hashable {
    let id: UUID = UUID()
    let type: XYSeriesType
    let values: [Double]
    let label: String?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: XYDataSeries, rhs: XYDataSeries) -> Bool {
        lhs.id == rhs.id
    }
}

/// Type of data series
enum XYSeriesType {
    case bar
    case line
}
