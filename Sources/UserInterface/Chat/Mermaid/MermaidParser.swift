// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Parses Mermaid diagram syntax
struct MermaidParser {
    private let logger = Logger(label: "com.sam.mermaid.parser")

    /// Parse Mermaid code into a diagram structure
    func parse(_ code: String) -> MermaidDiagram {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)

        // Detect diagram type
        if trimmed.starts(with: "graph ") || trimmed.starts(with: "flowchart ") {
            return parseFlowchart(trimmed)
        } else if trimmed.starts(with: "sequenceDiagram") {
            return parseSequenceDiagram(trimmed)
        } else if trimmed.starts(with: "classDiagram") {
            return parseClassDiagram(trimmed)
        } else if trimmed.starts(with: "stateDiagram") {
            // Temporarily disabled - rendering issues
            logger.warning("State diagrams temporarily disabled")
            return .unsupported(code)
        } else if trimmed.starts(with: "erDiagram") {
            // Temporarily disabled - rendering issues
            logger.warning("ER diagrams temporarily disabled")
            return .unsupported(code)
        } else if trimmed.starts(with: "gantt") {
            return parseGantt(trimmed)
        } else if trimmed.starts(with: "pie") {
            return parsePie(trimmed)
        } else if trimmed.starts(with: "journey") {
            return parseJourney(trimmed)
        } else if trimmed.starts(with: "mindmap") {
            return parseMindmap(trimmed)
        } else if trimmed.starts(with: "timeline") {
            return parseTimeline(trimmed)
        } else if trimmed.starts(with: "quadrantChart") {
            return parseQuadrantChart(trimmed)
        } else if trimmed.starts(with: "requirementDiagram") {
            return parseRequirementDiagram(trimmed)
        } else if trimmed.starts(with: "gitGraph") {
            return parseGitGraph(trimmed)
        } else if trimmed.starts(with: "xychart-beta") {
            return parseXYChart(trimmed)
        } else if trimmed.starts(with: "barChart") {
            return parseBarChart(trimmed)
        } else {
            logger.warning("Unsupported diagram type, showing as code")
            return .unsupported(code)
        }
    }

    // MARK: - Flowchart Parsing

    private func parseFlowchart(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let firstLine = lines.first else {
            return .unsupported(code)
        }

        // Parse direction
        let direction = parseDirection(from: firstLine)

        var nodes: [FlowchartNode] = []
        var edges: [FlowchartEdge] = []
        var nodeIds: Set<String> = []
        var nodeStyles: [String: NodeStyle] = [:]
        var linkStyles: [Int: EdgeStyleProperties] = [:]

        // Parse remaining lines
        for line in lines.dropFirst() {
            // Skip comments
            if line.hasPrefix("%%") {
                continue
            }

            // Check for style command
            if line.hasPrefix("style ") {
                if let (nodeId, style) = parseStyleCommand(line) {
                    nodeStyles[nodeId] = style
                }
            }
            // Check for linkStyle command
            else if line.hasPrefix("linkStyle ") {
                if let (index, style) = parseLinkStyleCommand(line) {
                    linkStyles[index] = style
                }
            }
            // Check if line contains an edge
            else if line.contains("-->") || line.contains("-.->") || line.contains("==>") {
                if let edge = parseEdge(line, existingNodes: &nodeIds, nodes: &nodes) {
                    edges.append(edge)
                }
            } else {
                // Standalone node declaration
                if let node = parseNode(line) {
                    if !nodeIds.contains(node.id) {
                        nodes.append(node)
                        nodeIds.insert(node.id)
                    }
                }
            }
        }

        var flowchart = Flowchart(direction: direction, nodes: nodes, edges: edges, nodeStyles: nodeStyles, linkStyles: linkStyles)
        return .flowchart(flowchart)
    }

    private func parseDirection(from line: String) -> FlowchartDirection {
        if line.contains(" TD") || line.hasSuffix(" TD") {
            return .topDown
        } else if line.contains(" TB") || line.hasSuffix(" TB") {
            return .topToBottom
        } else if line.contains(" BT") || line.hasSuffix(" BT") {
            return .bottomToTop
        } else if line.contains(" LR") || line.hasSuffix(" LR") {
            return .leftToRight
        } else if line.contains(" RL") || line.hasSuffix(" RL") {
            return .rightToLeft
        }
        // Default to top-to-bottom (standard Mermaid behavior for flowchart/graph)
        return .topToBottom
    }

    private func parseEdge(_ line: String, existingNodes: inout Set<String>, nodes: inout [FlowchartNode]) -> FlowchartEdge? {
        // Determine edge style and check for -- label --> format
        let style: EdgeStyle
        var separator: String
        var preSeparatorLabel: String?
        var workingLine = line

        // Check for -- label --> format (e.g., "A -- Yes --> B")
        if let labelMatch = line.range(of: #"--\s*([^-]+?)\s*-->"#, options: .regularExpression) {
            let labelText = String(line[labelMatch])
                .replacingOccurrences(of: "-->", with: "")
                .replacingOccurrences(of: "--", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !labelText.isEmpty {
                preSeparatorLabel = labelText
                // Replace the labeled edge with simple edge for parsing
                workingLine = line.replacingOccurrences(of: #"--\s*[^-]+?\s*-->"#, with: "-->", options: .regularExpression)
            }
            style = .solid
            separator = "-->"
        } else if line.contains("==>") {
            style = .thick
            separator = "==>"
        } else if line.contains("-.->") {
            style = .dotted
            separator = ".->"
        } else if line.contains("-->") {
            style = .solid
            separator = "-->"
        } else {
            return nil
        }

        // Split by separator
        let parts = workingLine.components(separatedBy: separator)
        guard parts.count >= 2 else { return nil }

        // Parse from node
        let fromPart = parts[0].trimmingCharacters(in: .whitespaces)
        guard let fromNode = parseNode(fromPart) else { return nil }
        if !existingNodes.contains(fromNode.id) {
            nodes.append(fromNode)
            existingNodes.insert(fromNode.id)
        }

        // Parse to node (might have label)
        let toPart = parts[1].trimmingCharacters(in: .whitespaces)
        var label: String? = preSeparatorLabel  // Start with -- label --> format if found
        var color: String?
        var toNodePart = toPart

        // Check for edge label: --> |label| node (only if we don't already have one)
        if label == nil, let labelMatch = toPart.range(of: #"\|([^|]+)\|"#, options: .regularExpression) {
            label = String(toPart[labelMatch]).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            toNodePart = toPart.replacingOccurrences(of: #"\|[^|]+\|"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }

        // Check for color specification in remaining parts (e.g., "red", "#FF0000")
        // Support syntax like: A --> B:::red or A -->|label| B:::red
        if let colorRange = toPart.range(of: #":::(\w+|#[0-9A-Fa-f]{3,6})$"#, options: .regularExpression) {
            color = String(toPart[colorRange]).replacingOccurrences(of: ":::", with: "")
            toNodePart = toPart.replacingOccurrences(of: #":::(\w+|#[0-9A-Fa-f]{3,6})$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            // Remove color from label part if it exists
            if let labelMatch = toNodePart.range(of: #"\|([^|]+)\|"#, options: .regularExpression) {
                label = String(toNodePart[labelMatch]).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                toNodePart = toNodePart.replacingOccurrences(of: #"\|[^|]+\|"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        guard let toNode = parseNode(toNodePart) else { return nil }
        if !existingNodes.contains(toNode.id) {
            nodes.append(toNode)
            existingNodes.insert(toNode.id)
        }

        return FlowchartEdge(from: fromNode.id, to: toNode.id, label: label, style: style, color: color)
    }

    private func parseNode(_ text: String) -> FlowchartNode? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // Match different node shapes
        // Rhombus: A{text}
        if let range = trimmed.range(of: #"^([A-Za-z0-9_]+)\{(.+?)\}$"#, options: .regularExpression) {
            let parts = extractNodeParts(trimmed, pattern: #"^([A-Za-z0-9_]+)\{(.+?)\}$"#)
            if let (id, label) = parts {
                return FlowchartNode(id: id, label: label, shape: .rhombus)
            }
        }

        // Hexagon: A{{text}}
        if let range = trimmed.range(of: #"^([A-Za-z0-9_]+)\{\{(.+?)\}\}$"#, options: .regularExpression) {
            let parts = extractNodeParts(trimmed, pattern: #"^([A-Za-z0-9_]+)\{\{(.+?)\}\}$"#)
            if let (id, label) = parts {
                return FlowchartNode(id: id, label: label, shape: .hexagon)
            }
        }

        // Stadium: A([text])
        if let range = trimmed.range(of: #"^([A-Za-z0-9_]+)\(\[(.+?)\]\)$"#, options: .regularExpression) {
            let parts = extractNodeParts(trimmed, pattern: #"^([A-Za-z0-9_]+)\(\[(.+?)\]\)$"#)
            if let (id, label) = parts {
                return FlowchartNode(id: id, label: label, shape: .stadium)
            }
        }

        // Subroutine: A[[text]]
        if let range = trimmed.range(of: #"^([A-Za-z0-9_]+)\[\[(.+?)\]\]$"#, options: .regularExpression) {
            let parts = extractNodeParts(trimmed, pattern: #"^([A-Za-z0-9_]+)\[\[(.+?)\]\]$"#)
            if let (id, label) = parts {
                return FlowchartNode(id: id, label: label, shape: .subroutine)
            }
        }

        // Rounded: A(text)
        if let range = trimmed.range(of: #"^([A-Za-z0-9_]+)\((.+?)\)$"#, options: .regularExpression) {
            let parts = extractNodeParts(trimmed, pattern: #"^([A-Za-z0-9_]+)\((.+?)\)$"#)
            if let (id, label) = parts {
                return FlowchartNode(id: id, label: label, shape: .roundedRect)
            }
        }

        // Rectangle: A[text]
        if let range = trimmed.range(of: #"^([A-Za-z0-9_]+)\[(.+?)\]$"#, options: .regularExpression) {
            let parts = extractNodeParts(trimmed, pattern: #"^([A-Za-z0-9_]+)\[(.+?)\]$"#)
            if let (id, label) = parts {
                return FlowchartNode(id: id, label: label, shape: .rectangle)
            }
        }

        // Circle: A((text))
        if let range = trimmed.range(of: #"^([A-Za-z0-9_]+)\(\((.+?)\)\)$"#, options: .regularExpression) {
            let parts = extractNodeParts(trimmed, pattern: #"^([A-Za-z0-9_]+)\(\((.+?)\)\)$"#)
            if let (id, label) = parts {
                return FlowchartNode(id: id, label: label, shape: .circle)
            }
        }

        // Plain node ID (no label)
        if trimmed.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil {
            return FlowchartNode(id: trimmed, label: trimmed, shape: .rectangle)
        }

        return nil
    }

    private func extractNodeParts(_ text: String, pattern: String) -> (id: String, label: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange) else { return nil }

        if match.numberOfRanges >= 3 {
            if let idRange = Range(match.range(at: 1), in: text),
               let labelRange = Range(match.range(at: 2), in: text) {
                return (String(text[idRange]), String(text[labelRange]))
            }
        }
        return nil
    }

    /// Parse style command: style A fill:#00bfae,stroke:#333,stroke-width:2px,color:#fff
    private func parseStyleCommand(_ line: String) -> (nodeId: String, style: NodeStyle)? {
        // Format: style NODEID PROPERTIES
        let parts = line.components(separatedBy: " ")
        guard parts.count >= 3, parts[0] == "style" else { return nil }

        let nodeId = parts[1]
        let propertiesString = parts[2...].joined(separator: " ")

        // Parse CSS-like properties
        var style = NodeStyle()
        let properties = propertiesString.components(separatedBy: ",")

        for property in properties {
            let keyValue = property.components(separatedBy: ":")
            guard keyValue.count == 2 else { continue }

            let key = keyValue[0].trimmingCharacters(in: .whitespaces)
            let value = keyValue[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "fill":
                style.fill = value
            case "stroke":
                style.stroke = value
            case "stroke-width":
                style.strokeWidth = value
            case "color":
                style.color = value
            default:
                break
            }
        }

        return (nodeId, style)
    }

    /// Parse linkStyle command: linkStyle 0 stroke:#ff3,stroke-width:3px
    private func parseLinkStyleCommand(_ line: String) -> (index: Int, style: EdgeStyleProperties)? {
        // Format: linkStyle INDEX PROPERTIES
        let parts = line.components(separatedBy: " ")
        guard parts.count >= 3, parts[0] == "linkStyle" else { return nil }
        guard let index = Int(parts[1]) else { return nil }

        let propertiesString = parts[2...].joined(separator: " ")

        // Parse CSS-like properties
        var style = EdgeStyleProperties()
        let properties = propertiesString.components(separatedBy: ",")

        for property in properties {
            let keyValue = property.components(separatedBy: ":")
            guard keyValue.count == 2 else { continue }

            let key = keyValue[0].trimmingCharacters(in: .whitespaces)
            let value = keyValue[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "stroke":
                style.stroke = value
            case "stroke-width":
                style.strokeWidth = value
            default:
                break
            }
        }

        return (index, style)
    }

    // MARK: - Sequence Diagram Parsing

    private func parseSequenceDiagram(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "sequenceDiagram" && !$0.hasPrefix("%%") }

        var participants: [Participant] = []
        var messages: [SequenceMessage] = []
        var notes: [Note] = []
        var activations: [Activation] = []
        var boxes: [Box] = []
        var participantIds: Set<String> = []

        // Track current box being parsed
        var currentBox: (name: String?, color: String?, participants: [String])?

        for line in lines {
            // Parse box start
            if line.hasPrefix("box ") {
                let rest = line.replacingOccurrences(of: "box ", with: "")
                    .trimmingCharacters(in: .whitespaces)

                // Parse optional color and name
                // Formats: "box rgb(255,0,0) My Box", "box #FF0000 My Box", "box My Box", "box"
                var boxName: String?
                var boxColor: String?

                if rest.hasPrefix("rgb(") {
                    // Parse rgb color
                    if let colorEnd = rest.firstIndex(of: ")") {
                        let colorStart = rest.index(rest.startIndex, offsetBy: 0)
                        let endIndex = rest.index(after: colorEnd)
                        boxColor = String(rest[colorStart..<endIndex])
                        let remaining = String(rest[endIndex...]).trimmingCharacters(in: .whitespaces)
                        if !remaining.isEmpty {
                            boxName = remaining
                        }
                    }
                } else if rest.hasPrefix("#") {
                    // Parse hex color
                    let parts = rest.components(separatedBy: " ")
                    if let first = parts.first, first.hasPrefix("#") {
                        boxColor = first
                        boxName = parts.dropFirst().joined(separator: " ")
                    }
                } else if !rest.isEmpty {
                    // Check if first word is a CSS color name
                    let words = rest.components(separatedBy: " ")
                    if let firstWord = words.first {
                        // Common CSS color names
                        let colorNames = ["red", "blue", "green", "purple", "yellow", "orange", "pink", "brown", "gray", "grey", "black", "white"]
                        if colorNames.contains(firstWord.lowercased()) {
                            boxColor = firstWord
                            boxName = words.dropFirst().joined(separator: " ")
                        } else {
                            // No color, just name
                            boxName = rest
                        }
                    }
                }

                currentBox = (name: boxName, color: boxColor, participants: [])
            }
            // Parse box end
            else if line == "end" {
                if let box = currentBox {
                    let newBox = Box(
                        name: box.name,
                        color: box.color,
                        participantIds: box.participants
                    )
                    boxes.append(newBox)
                }
                currentBox = nil
            }
            // Parse participant
            else if line.hasPrefix("participant ") || line.hasPrefix("actor ") {
                let isActor = line.hasPrefix("actor ")
                let rest = line.replacingOccurrences(of: isActor ? "actor " : "participant ", with: "")

                // Handle "participant A as Alice" format
                let parts = rest.components(separatedBy: " as ")
                let id = parts[0].trimmingCharacters(in: .whitespaces)
                let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : id

                let participant = Participant(
                    id: id,
                    label: label,
                    type: isActor ? .actor : .participant
                )
                participants.append(participant)
                participantIds.insert(id)

                // Add to current box if we're inside one
                if currentBox != nil {
                    currentBox?.participants.append(id)
                }
            }
            // Parse message
            else if line.contains("->>") || line.contains("-->>") || line.contains("--)") ||
                    line.contains("->") || line.contains("-->") {
                if let message = parseSequenceMessage(line, participantIds: &participantIds, participants: &participants) {
                    messages.append(message)
                }
            }
            // Parse note
            else if line.hasPrefix("Note ") {
                if let note = parseNote(line) {
                    notes.append(note)
                }
            }
        }

        let diagram = SequenceDiagram(
            participants: participants,
            messages: messages,
            notes: notes,
            activations: activations,
            boxes: boxes
        )
        return .sequence(diagram)
    }

    private func parseSequenceMessage(_ line: String, participantIds: inout Set<String>, participants: inout [Participant]) -> SequenceMessage? {
        let type: SequenceMessage.MessageType
        let separator: String

        // Check longer patterns first to avoid false matches
        if line.contains("-->>") {
            type = .dotted
            separator = "-->>"
        } else if line.contains("->>") {
            type = .solid
            separator = "->>"
        } else if line.contains("--)") {
            type = .async
            separator = "--)"
        } else if line.contains("-->") {
            type = .dottedArrow
            separator = "-->"
        } else if line.contains("->") {
            type = .solidArrow
            separator = "->"
        } else {
            return nil
        }

        let parts = line.components(separatedBy: separator)
        guard parts.count == 2 else { return nil }

        let from = parts[0].trimmingCharacters(in: .whitespaces)
        let toPart = parts[1].trimmingCharacters(in: .whitespaces)

        let toAndMessage = toPart.components(separatedBy: ":")
        guard toAndMessage.count >= 2 else { return nil }

        let to = toAndMessage[0].trimmingCharacters(in: .whitespaces)
        let text = toAndMessage.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)

        // Auto-add participants if not explicitly declared
        if !participantIds.contains(from) {
            participants.append(Participant(id: from, label: from, type: .participant))
            participantIds.insert(from)
        }
        if !participantIds.contains(to) {
            participants.append(Participant(id: to, label: to, type: .participant))
            participantIds.insert(to)
        }

        return SequenceMessage(from: from, to: to, text: text, type: type)
    }

    private func parseNote(_ line: String) -> Note? {
        // Note over Alice, Bob: text
        // Note right of Alice: text
        // Note left of Alice: text

        if line.hasPrefix("Note over ") {
            let rest = line.replacingOccurrences(of: "Note over ", with: "")
            let parts = rest.components(separatedBy: ":")
            guard parts.count >= 2 else { return nil }

            let participants = parts[0].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let text = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)

            return Note(text: text, position: .over(participants))
        } else if line.hasPrefix("Note right of ") {
            let rest = line.replacingOccurrences(of: "Note right of ", with: "")
            let parts = rest.components(separatedBy: ":")
            guard parts.count >= 2 else { return nil }

            let participant = parts[0].trimmingCharacters(in: .whitespaces)
            let text = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)

            return Note(text: text, position: .right(participant))
        } else if line.hasPrefix("Note left of ") {
            let rest = line.replacingOccurrences(of: "Note left of ", with: "")
            let parts = rest.components(separatedBy: ":")
            guard parts.count >= 2 else { return nil }

            let participant = parts[0].trimmingCharacters(in: .whitespaces)
            let text = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)

            return Note(text: text, position: .left(participant))
        }

        return nil
    }

    // MARK: - Class Diagram Parsing

    private func parseClassDiagram(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "classDiagram" && !$0.hasPrefix("%%") }

        var classes: [ClassNode] = []
        var relationships: [ClassRelationship] = []
        var classMap: [String: ClassNode] = [:]
        var currentClass: String?
        var currentAttributes: [String] = []
        var currentMethods: [String] = []

        for line in lines {
            // Check if we're ending a class definition
            if line == "}" && currentClass != nil {
                // Save the class with its attributes and methods
                if let className = currentClass {
                    let classNode = ClassNode(
                        id: className,
                        name: className,
                        attributes: currentAttributes,
                        methods: currentMethods,
                        stereotype: nil
                    )
                    if let existingIndex = classes.firstIndex(where: { $0.id == className }) {
                        classes[existingIndex] = classNode
                    } else {
                        classes.append(classNode)
                    }
                    classMap[className] = classNode
                }
                currentClass = nil
                currentAttributes = []
                currentMethods = []
            }
            // Parse class definition start
            else if line.hasPrefix("class ") {
                let className = line.replacingOccurrences(of: "class ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: "{")[0]
                    .trimmingCharacters(in: .whitespaces)

                currentClass = className
                currentAttributes = []
                currentMethods = []
            }
            // Parse attributes and methods inside class body
            else if currentClass != nil {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("(") {
                    // It's a method
                    currentMethods.append(trimmed)
                } else if !trimmed.isEmpty && trimmed != "{" {
                    // It's an attribute
                    currentAttributes.append(trimmed)
                }
            }
            // Parse relationship
            // Check for specific arrows first to avoid false matches
            // (e.g., "-->" in state diagrams vs "--" in class diagrams)
            else if line.contains("<|--") || line.contains("*--") || line.contains("o--") ||
                    line.contains("..>") || line.contains("..|>") ||
                    (line.contains("--") && !line.contains("-->")) {
                if let relationship = parseClassRelationship(line, classMap: &classMap, classes: &classes) {
                    relationships.append(relationship)
                }
            }
        }

        // Handle case where class definition doesn't have closing brace
        if let className = currentClass {
            let classNode = ClassNode(
                id: className,
                name: className,
                attributes: currentAttributes,
                methods: currentMethods,
                stereotype: nil
            )
            if let existingIndex = classes.firstIndex(where: { $0.id == className }) {
                classes[existingIndex] = classNode
            } else {
                classes.append(classNode)
            }
            classMap[className] = classNode
        }

        let diagram = ClassDiagram(classes: classes, relationships: relationships)
        return .classDiagram(diagram)
    }

    private func parseClassRelationship(_ line: String, classMap: inout [String: ClassNode], classes: inout [ClassNode]) -> ClassRelationship? {
        let type: ClassRelationship.RelationType
        let separator: String

        if line.contains("<|--") {
            type = .inheritance
            separator = "<|--"
        } else if line.contains("*--") {
            type = .composition
            separator = "*--"
        } else if line.contains("o--") {
            type = .aggregation
            separator = "o--"
        } else if line.contains("..>") {
            type = .dependency
            separator = "..>"
        } else if line.contains("..|>") {
            type = .realization
            separator = "..|>"
        } else if line.contains("--") {
            type = .association
            separator = "--"
        } else {
            return nil
        }

        let parts = line.components(separatedBy: separator)
        guard parts.count >= 2 else { return nil }

        let from = parts[0].trimmingCharacters(in: .whitespaces)
        let to = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: ":")[0].trimmingCharacters(in: .whitespaces)

        // Ensure classes exist
        if classMap[from] == nil {
            let classNode = ClassNode(id: from, name: from, attributes: [], methods: [], stereotype: nil)
            classes.append(classNode)
            classMap[from] = classNode
        }
        if classMap[to] == nil {
            let classNode = ClassNode(id: to, name: to, attributes: [], methods: [], stereotype: nil)
            classes.append(classNode)
            classMap[to] = classNode
        }

        return ClassRelationship(from: from, to: to, type: type, label: nil)
    }

    // MARK: - State Diagram Parsing

    private func parseStateDiagram(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("stateDiagram") && !$0.hasPrefix("%%") }

        var states: [StateNode] = []
        var transitions: [StateTransition] = []
        var stateIds: Set<String> = []

        // Add default start and end states
        let startState = StateNode(id: "[*]", label: "Start", type: .start)
        states.append(startState)
        stateIds.insert("[*]")

        for line in lines {
            // Parse transition
            if line.contains("-->") {
                if let transition = parseStateTransition(line, stateIds: &stateIds, states: &states) {
                    transitions.append(transition)
                }
            }
        }

        let diagram = StateDiagram(states: states, transitions: transitions)
        return .stateDiagram(diagram)
    }

    private func parseStateTransition(_ line: String, stateIds: inout Set<String>, states: inout [StateNode]) -> StateTransition? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }

        let from = parts[0].trimmingCharacters(in: .whitespaces)
        let toPart = parts[1].trimmingCharacters(in: .whitespaces)

        // Extract label if present
        var label: String?
        var to = toPart

        if toPart.contains(":") {
            let labelParts = toPart.components(separatedBy: ":")
            to = labelParts[0].trimmingCharacters(in: .whitespaces)
            label = labelParts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
        }

        // Add states if they don't exist
        if !stateIds.contains(from) && from != "[*]" {
            let state = StateNode(id: from, label: from, type: .normal)
            states.append(state)
            stateIds.insert(from)
        }
        if !stateIds.contains(to) && to != "[*]" {
            let stateType: StateNode.StateType = to == "[*]" ? .end : .normal
            let state = StateNode(id: to, label: to, type: stateType)
            states.append(state)
            stateIds.insert(to)
        }

        return StateTransition(from: from, to: to, label: label)
    }

    // MARK: - ER Diagram Parsing

    private func parseERDiagram(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "erDiagram" && !$0.hasPrefix("%%") }

        var entities: [Entity] = []
        var relationships: [ERRelationship] = []
        var entityMap: [String: Entity] = [:]

        for line in lines {
            // Parse relationship: ENTITY1 ||--o{ ENTITY2 : "label"
            if line.contains("||") || line.contains("o{") || line.contains("}o") {
                if let relationship = parseERRelationship(line, entityMap: &entityMap, entities: &entities) {
                    relationships.append(relationship)
                }
            }
        }

        let diagram = ERDiagram(entities: entities, relationships: relationships)
        return .erDiagram(diagram)
    }

    private func parseERRelationship(_ line: String, entityMap: inout [String: Entity], entities: inout [Entity]) -> ERRelationship? {
        // Simplified parsing - match pattern: EntityA relationship EntityB : "label"
        let pattern = #"(\w+)\s+([\|\}o\{]+--[\|\}o\{]+)\s+(\w+)\s*:\s*"?([^"]*)"?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: nsRange) else { return nil }

        guard match.numberOfRanges >= 5 else { return nil }

        guard let entity1Range = Range(match.range(at: 1), in: line),
              let relTypeRange = Range(match.range(at: 2), in: line),
              let entity2Range = Range(match.range(at: 3), in: line),
              let labelRange = Range(match.range(at: 4), in: line) else { return nil }

        let entity1 = String(line[entity1Range])
        let entity2 = String(line[entity2Range])
        let label = String(line[labelRange])

        // Ensure entities exist
        if entityMap[entity1] == nil {
            let entity = Entity(id: entity1, name: entity1, attributes: [])
            entities.append(entity)
            entityMap[entity1] = entity
        }
        if entityMap[entity2] == nil {
            let entity = Entity(id: entity2, name: entity2, attributes: [])
            entities.append(entity)
            entityMap[entity2] = entity
        }

        return ERRelationship(
            from: entity1,
            to: entity2,
            label: label,
            fromCardinality: "1",
            toCardinality: "N"
        )
    }

    // MARK: - Gantt Chart Parsing

    private func parseGantt(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }

        var title: String?
        var dateFormat: String?
        var tasks: [GanttTask] = []

        for line in lines {
            if line.hasPrefix("title ") {
                title = line.replacingOccurrences(of: "title ", with: "")
            } else if line.hasPrefix("dateFormat ") {
                dateFormat = line.replacingOccurrences(of: "dateFormat ", with: "")
            } else if line.contains(":") && !line.hasPrefix("gantt") {
                if let task = parseGanttTask(line) {
                    tasks.append(task)
                }
            }
        }

        let chart = GanttChart(title: title, dateFormat: dateFormat, tasks: tasks)
        return .gantt(chart)
    }

    private func parseGanttTask(_ line: String) -> GanttTask? {
        // Simplified: TaskName : status, id, startDate, duration
        let parts = line.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }

        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let details = parts[1].trimmingCharacters(in: .whitespaces)

        var status: GanttTask.TaskStatus = .active
        if details.contains("done") {
            status = .done
        } else if details.contains("crit") {
            status = .crit
        } else if details.contains("milestone") {
            status = .milestone
        }

        return GanttTask(
            id: name,
            name: name,
            startDate: nil,
            duration: nil,
            status: status,
            dependencies: []
        )
    }

    // MARK: - Pie Chart Parsing

    private func parsePie(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }

        var title: String?
        var slices: [PieSlice] = []

        for line in lines {
            if line.hasPrefix("pie") {
                // Check for title in pie line
                if line.contains("title ") {
                    title = line.replacingOccurrences(of: "pie", with: "")
                        .replacingOccurrences(of: "title", with: "")
                        .trimmingCharacters(in: .whitespaces)
                }
            } else if line.hasPrefix("title ") {
                title = line.replacingOccurrences(of: "title ", with: "")
            } else if line.contains(":") {
                if let slice = parsePieSlice(line) {
                    slices.append(slice)
                }
            }
        }

        let chart = PieChart(title: title, slices: slices)
        return .pie(chart)
    }

    private func parsePieSlice(_ line: String) -> PieSlice? {
        let parts = line.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }

        let label = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let valueStr = parts[1].trimmingCharacters(in: .whitespaces)

        guard let value = Double(valueStr) else { return nil }

        return PieSlice(label: label, value: value)
    }

    // MARK: - User Journey Parsing

    private func parseJourney(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }

        var title: String?
        var sections: [JourneySection] = []
        var currentSection: String?
        var currentTasks: [JourneyTask] = []

        for line in lines {
            if line.hasPrefix("title ") {
                title = line.replacingOccurrences(of: "title ", with: "")
            } else if line.hasPrefix("section ") {
                // Save previous section
                if let sectionName = currentSection {
                    sections.append(JourneySection(name: sectionName, tasks: currentTasks))
                    currentTasks = []
                }
                currentSection = line.replacingOccurrences(of: "section ", with: "")
            } else if line.contains(":") && !line.hasPrefix("journey") {
                if let task = parseJourneyTask(line) {
                    currentTasks.append(task)
                }
            }
        }

        // Save last section
        if let sectionName = currentSection {
            sections.append(JourneySection(name: sectionName, tasks: currentTasks))
        }

        let journey = UserJourney(title: title, sections: sections)
        return .journey(journey)
    }

    private func parseJourneyTask(_ line: String) -> JourneyTask? {
        // Format: TaskName: score: Actor1, Actor2
        let parts = line.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }

        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let scoreStr = parts[1].trimmingCharacters(in: .whitespaces)

        let score = Int(scoreStr) ?? 3
        var actors: [String] = []

        if parts.count >= 3 {
            actors = parts[2].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        return JourneyTask(name: name, score: score, actors: actors)
    }

    // MARK: - Mindmap Parsing

    private func parseMindmap(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty &&
                      $0.trimmingCharacters(in: .whitespaces) != "mindmap" &&
                      !$0.trimmingCharacters(in: .whitespaces).hasPrefix("%%") }

        guard let rootLine = lines.first else {
            return .unsupported(code)
        }

        // Find minimum leading whitespace to normalize indentation
        let minLeadingSpaces = lines.map { line in
            line.prefix(while: { $0 == " " }).count
        }.min() ?? 0

        // Parse root node (remove shape indicators)
        // Mindmap format: "root((text))" or "id(text)" or just "text"
        var rootLabel = rootLine.trimmingCharacters(in: .whitespaces)
        
        // Extract text from parentheses: "root((Project))" -> "Project"
        if let openParen = rootLabel.firstIndex(of: "("),
           let closeParen = rootLabel.lastIndex(of: ")") {
            let labelStart = rootLabel.index(after: openParen)
            let labelEnd = closeParen
            rootLabel = String(rootLabel[labelStart..<labelEnd])
                .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                .trimmingCharacters(in: .whitespaces)
        }

        // Parse hierarchy - build list of (label, level) pairs
        var nodeData: [(label: String, level: Int)] = [(rootLabel, 0)]

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Normalize indentation by subtracting minimum leading spaces
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            let normalizedSpaces = leadingSpaces - minLeadingSpaces
            let level = normalizedSpaces / 2  // Each 2 spaces = 1 level (root is 0, first indent is 1)

            nodeData.append((trimmed, level))
        }

        // Build tree recursively
        let (root, _) = buildMindmapTree(nodeData: nodeData, startIndex: 0, parentLevel: -1)

        let mindmap = Mindmap(root: root)
        return .mindmap(mindmap)
    }

    /// Recursively build mindmap tree from flat node data
    private func buildMindmapTree(nodeData: [(label: String, level: Int)], startIndex: Int, parentLevel: Int) -> (MindmapNode, Int) {
        guard startIndex < nodeData.count else {
            return (MindmapNode(id: "empty", label: "", children: [], level: 0), startIndex)
        }

        let (label, level) = nodeData[startIndex]
        let nodeId = "node_\(startIndex)"

        var children: [MindmapNode] = []
        var currentIndex = startIndex + 1

        // Collect all direct children (level = current + 1)
        while currentIndex < nodeData.count && nodeData[currentIndex].level > level {
            if nodeData[currentIndex].level == level + 1 {
                let (child, nextIndex) = buildMindmapTree(nodeData: nodeData, startIndex: currentIndex, parentLevel: level)
                children.append(child)
                currentIndex = nextIndex
            } else {
                currentIndex += 1
            }
        }

        let node = MindmapNode(id: nodeId, label: label, children: children, level: level)
        return (node, currentIndex)
    }

    // MARK: - Timeline Parsing

    private func parseTimeline(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "timeline" && !$0.hasPrefix("%%") }

        var title: String?
        var events: [MermaidTimelineEvent] = []

        for line in lines {
            if line.hasPrefix("title ") {
                title = line.replacingOccurrences(of: "title ", with: "")
            } else if line.contains(":") {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    let period = parts[0].trimmingCharacters(in: .whitespaces)
                    let eventList = parts.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
                    events.append(MermaidTimelineEvent(period: period, events: eventList))
                }
            }
        }

        let timeline = Timeline(title: title, events: events)
        return .timeline(timeline)
    }

    // MARK: - Quadrant Chart Parsing

    private func parseQuadrantChart(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }

        var title: String?
        var xAxisLabel: String?
        var yAxisLabel: String?
        var quadrants: [String] = []
        var points: [QuadrantPoint] = []

        for line in lines {
            if line.hasPrefix("title ") {
                title = line.replacingOccurrences(of: "title ", with: "")
            } else if line.hasPrefix("x-axis ") {
                xAxisLabel = line.replacingOccurrences(of: "x-axis ", with: "")
            } else if line.hasPrefix("y-axis ") {
                yAxisLabel = line.replacingOccurrences(of: "y-axis ", with: "")
            } else if line.hasPrefix("quadrant-") {
                quadrants.append(line)
            } else if line.contains(":") && !line.hasPrefix("quadrantChart") {
                // Parse point: Label: [x, y]
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    let label = parts[0].trimmingCharacters(in: .whitespaces)
                    let coords = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " []"))
                        .components(separatedBy: ",")

                    if coords.count >= 2,
                       let x = Double(coords[0].trimmingCharacters(in: .whitespaces)),
                       let y = Double(coords[1].trimmingCharacters(in: .whitespaces)) {
                        points.append(QuadrantPoint(label: label, x: x, y: y))
                    }
                }
            }
        }

        let chart = QuadrantChart(
            title: title,
            xAxisLabel: xAxisLabel,
            yAxisLabel: yAxisLabel,
            quadrants: quadrants,
            points: points
        )
        return .quadrant(chart)
    }

    // MARK: - Requirement Diagram Parsing

    private func parseRequirementDiagram(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "requirementDiagram" && !$0.hasPrefix("%%") }

        var requirements: [Requirement] = []
        var relationships: [RequirementRelationship] = []

        for line in lines {
            if line.hasPrefix("requirement ") || line.hasPrefix("functionalRequirement ") ||
               line.hasPrefix("performanceRequirement ") {
                let parts = line.components(separatedBy: .whitespaces)
                if parts.count >= 2 {
                    let type: Requirement.RequirementType = parts[0] == "functionalRequirement" ? .functionalRequirement :
                                                           parts[0] == "performanceRequirement" ? .performanceRequirement : .requirement
                    let id = parts[1]
                    let req = Requirement(id: id, type: type, text: id, riskLevel: nil, verifyMethod: nil)
                    requirements.append(req)
                }
            }
        }

        let diagram = RequirementDiagram(requirements: requirements, relationships: relationships)
        return .requirement(diagram)
    }

    // MARK: - Git Graph Parsing

    private func parseGitGraph(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "gitGraph" && !$0.hasPrefix("%%") }

        var commits: [GitCommit] = []
        var branches: [GitBranch] = []
        var currentBranch = "main"
        var commitCount = 0

        branches.append(GitBranch(id: "main", name: "main", order: 0))

        for line in lines {
            if line.hasPrefix("branch ") {
                let branchName = line.replacingOccurrences(of: "branch ", with: "")
                branches.append(GitBranch(id: branchName, name: branchName, order: branches.count))
            } else if line.hasPrefix("checkout ") {
                currentBranch = line.replacingOccurrences(of: "checkout ", with: "")
            } else if line.hasPrefix("commit") {
                commitCount += 1
                let commitId = "commit\(commitCount)"
                let commit = GitCommit(
                    id: commitId,
                    message: nil,
                    branch: currentBranch,
                    tag: nil,
                    type: .normal
                )
                commits.append(commit)
            } else if line.hasPrefix("merge ") {
                commitCount += 1
                let commitId = "merge\(commitCount)"
                let commit = GitCommit(
                    id: commitId,
                    message: nil,
                    branch: currentBranch,
                    tag: nil,
                    type: .merge
                )
                commits.append(commit)
            }
        }

        let graph = GitGraph(commits: commits, branches: branches)
        return .gitGraph(graph)
    }

    // MARK: - Bar Chart Parsing (LLM-friendly format)

    /// Parse bar chart with simple "bar Label: value" format that LLMs often generate
    private func parseBarChart(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }

        var title: String?
        var xAxisLabel: String?
        var yAxisLabel: String?
        var categories: [String] = []
        var dataSeries: [XYDataSeries] = []
        var legacyValues: [Double] = []  // For old format compatibility

        for line in lines {
            // Skip the barChart declaration line
            if line.hasPrefix("barChart") {
                continue
            }
            // Parse title
            else if line.hasPrefix("title ") {
                title = line.replacingOccurrences(of: "title ", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            // Parse x-axis with categories
            else if line.hasPrefix("x-axis ") {
                let rest = line.replacingOccurrences(of: "x-axis ", with: "")
                // Check if it's space-separated categories (e.g., "x-axis Q1 Q2 Q3 Q4")
                let parts = rest.components(separatedBy: " ").filter { !$0.isEmpty }
                if parts.count > 1 {
                    categories = parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                } else {
                    // Just a label
                    xAxisLabel = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
            // Parse y-axis
            else if line.hasPrefix("y-axis ") {
                yAxisLabel = line.replacingOccurrences(of: "y-axis ", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            // Parse series data (e.g., "series 2025: 30 40 50 60")
            else if line.hasPrefix("series ") {
                let rest = line.replacingOccurrences(of: "series ", with: "")
                if let colonIndex = rest.firstIndex(of: ":") {
                    let seriesLabel = String(rest[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    let dataStr = String(rest[rest.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                    
                    // Parse space-separated numeric values
                    let values = dataStr.components(separatedBy: " ")
                        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    
                    if !values.isEmpty {
                        let series = XYDataSeries(type: .bar, values: values, label: seriesLabel)
                        dataSeries.append(series)
                    }
                }
            }
            // Fallback: Parse data with label:value format (e.g., "Apples: 35")
            // Note: barChart syntax does NOT require "bar" prefix
            else if line.contains(":") && !line.hasPrefix("title") && !line.hasPrefix("x-axis") && !line.hasPrefix("y-axis") {
                if let colonIndex = line.lastIndex(of: ":") {
                    let label = String(line[..<colonIndex])
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    let valueStr = String(line[line.index(after: colonIndex)...])
                        .trimmingCharacters(in: .whitespaces)

                    if let value = Double(valueStr), !label.isEmpty {
                        // Legacy single-value format
                        categories.append(label)
                        legacyValues.append(value)
                    }
                }
            }
        }

        // If using legacy format, create a single series from accumulated values
        if !legacyValues.isEmpty && dataSeries.isEmpty {
            dataSeries = [XYDataSeries(type: .bar, values: legacyValues, label: nil)]
        }

        let chart = XYChart(
            title: title,
            xAxisLabel: xAxisLabel,
            yAxisLabel: yAxisLabel,
            xAxisCategories: categories,
            dataSeries: dataSeries,
            orientation: .horizontal
        )
        return .xychart(chart)
    }

    // MARK: - XY Chart Parsing (Bar/Line Charts)

    private func parseXYChart(_ code: String) -> MermaidDiagram {
        let lines = code.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }

        var title: String?
        var xAxisLabel: String?
        var yAxisLabel: String?
        var xAxisCategories: [String] = []
        var dataSeries: [XYDataSeries] = []
        var orientation: XYChartOrientation = .horizontal

        for line in lines {
            // Parse first line for orientation
            if line.hasPrefix("xychart-beta") {
                if line.contains("horizontal") {
                    orientation = .horizontal
                } else if line.contains("vertical") {
                    orientation = .vertical
                }
            }
            // Parse title
            else if line.hasPrefix("title ") {
                title = line.replacingOccurrences(of: "title ", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            // Parse x-axis with categories
            else if line.hasPrefix("x-axis ") {
                let rest = line.replacingOccurrences(of: "x-axis ", with: "")
                // Check for array format: x-axis [Jan, Feb, Mar]
                if let bracketStart = rest.firstIndex(of: "["),
                   let bracketEnd = rest.lastIndex(of: "]") {
                    // Extract label (before brackets)
                    let labelPart = String(rest[..<bracketStart]).trimmingCharacters(in: .whitespaces)
                    if !labelPart.isEmpty {
                        xAxisLabel = labelPart.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    }
                    // Extract categories
                    let categoriesStr = String(rest[rest.index(after: bracketStart)..<bracketEnd])
                    xAxisCategories = categoriesStr.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                } else {
                    // Check if it's space-separated categories (e.g., "x-axis Q1 Q2 Q3 Q4")
                    let parts = rest.components(separatedBy: " ").filter { !$0.isEmpty }
                    // If all parts could be categories (not all are quotes), treat as categories
                    if parts.count > 1 {
                        xAxisCategories = parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                    } else {
                        // Just a label
                        xAxisLabel = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    }
                }
            }
            // Parse y-axis
            else if line.hasPrefix("y-axis ") {
                let rest = line.replacingOccurrences(of: "y-axis ", with: "")
                // Check for range format: y-axis "Label" 0 --> 100
                if let arrowRange = rest.range(of: "-->") {
                    // Has range specification, extract label
                    let labelPart = String(rest[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    yAxisLabel = labelPart.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        .components(separatedBy: " ")
                        .filter { !$0.isEmpty && Double($0) == nil }
                        .joined(separator: " ")
                } else {
                    yAxisLabel = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
            // Parse bar data
            else if line.hasPrefix("bar ") {
                let rest = line.replacingOccurrences(of: "bar ", with: "")
                if let series = parseDataSeries(rest, type: .bar) {
                    dataSeries.append(series)
                }
            }
            // Parse line data
            else if line.hasPrefix("line ") {
                let rest = line.replacingOccurrences(of: "line ", with: "")
                if let series = parseDataSeries(rest, type: .line) {
                    dataSeries.append(series)
                }
            }
            // Parse series data (e.g., "series 2025: 30 40 50 60" or "series John: 170,70 180,75")
            else if line.hasPrefix("series ") {
                let rest = line.replacingOccurrences(of: "series ", with: "")
                if let colonIndex = rest.firstIndex(of: ":") {
                    let seriesLabel = String(rest[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    let dataStr = String(rest[rest.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                    
                    // Check if data contains comma-separated coordinate pairs (e.g., "170,70 180,75")
                    if dataStr.contains(",") {
                        // Parse coordinate pairs: x,y x,y x,y
                        let pairs = dataStr.components(separatedBy: " ").filter { !$0.isEmpty }
                        var values: [Double] = []
                        for pair in pairs {
                            let coords = pair.components(separatedBy: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                            values.append(contentsOf: coords)
                        }
                        if !values.isEmpty {
                            let series = XYDataSeries(type: .line, values: values, label: seriesLabel)
                            dataSeries.append(series)
                        }
                    } else {
                        // Parse space-separated numeric values (e.g., "30 40 50 60")
                        let values = dataStr.components(separatedBy: " ")
                            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                        
                        if !values.isEmpty {
                            // Default to bar type for barChart, could be line for xychart-beta
                            let series = XYDataSeries(type: .bar, values: values, label: seriesLabel)
                            dataSeries.append(series)
                        }
                    }
                }
            }
            // Parse series data with label (e.g., "Series1: [1, 20], [2, 22], [3, 21]")
            else if line.contains(":") && line.contains("[") {
                // Extract series label and data
                if let colonIndex = line.firstIndex(of: ":") {
                    let seriesLabel = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    let dataStr = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                    
                    // Check if this is coordinate pairs format: [x, y], [x, y]
                    if let series = parseCoordinatePairs(dataStr, label: seriesLabel) {
                        dataSeries.append(series)
                    }
                }
            }
        }

        let chart = XYChart(
            title: title,
            xAxisLabel: xAxisLabel,
            yAxisLabel: yAxisLabel,
            xAxisCategories: xAxisCategories,
            dataSeries: dataSeries,
            orientation: orientation
        )
        return .xychart(chart)
    }

    /// Parse data series from line like: [12, 34, 56, 78] or "Label" [12, 34, 56]
    private func parseDataSeries(_ line: String, type: XYSeriesType) -> XYDataSeries? {
        var label: String?
        var valuesStr = line

        // Check for label before brackets
        if let bracketStart = line.firstIndex(of: "[") {
            let labelPart = String(line[..<bracketStart]).trimmingCharacters(in: .whitespaces)
            if !labelPart.isEmpty {
                label = labelPart.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            valuesStr = String(line[bracketStart...])
        }

        // Parse values from brackets
        guard let bracketStart = valuesStr.firstIndex(of: "["),
              let bracketEnd = valuesStr.lastIndex(of: "]") else {
            return nil
        }

        let numbersStr = String(valuesStr[valuesStr.index(after: bracketStart)..<bracketEnd])
        let values = numbersStr.components(separatedBy: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

        guard !values.isEmpty else { return nil }

        return XYDataSeries(type: type, values: values, label: label)
    }
    
    /// Parse coordinate pairs format: [1, 20], [2, 22], [3, 21], [4, 23]
    /// Extracts just the Y values since X values are typically sequential
    private func parseCoordinatePairs(_ line: String, label: String) -> XYDataSeries? {
        // Match all [x, y] pairs
        let pattern = "\\[(\\d+(?:\\.\\d+)?),\\s*(\\d+(?:\\.\\d+)?)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        
        let nsString = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsString.length))
        
        var yValues: [Double] = []
        for match in matches {
            // Extract Y value (second capture group)
            if match.numberOfRanges >= 3 {
                let yRange = match.range(at: 2)
                if let yValue = Double(nsString.substring(with: yRange)) {
                    yValues.append(yValue)
                }
            }
        }
        
        guard !yValues.isEmpty else { return nil }
        
        return XYDataSeries(type: .line, values: yValues, label: label)
    }
}
