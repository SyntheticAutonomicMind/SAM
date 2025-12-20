// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging

/// Native SwiftUI renderer for Mermaid flowcharts
struct FlowchartRenderer: View {
    let flowchart: Flowchart
    private let logger = Logger(label: "com.sam.mermaid.flowchart")

    // Calculate positions ONCE as a let property
    private let nodePositions: [String: CGPoint]
    private let diagramWidth: CGFloat
    private let diagramHeight: CGFloat

    init(flowchart: Flowchart) {
        self.flowchart = flowchart
        // Calculate positions synchronously during init
        let layout = Self.calculateInitialLayout(for: flowchart)
        self.nodePositions = layout.positions
        self.diagramWidth = layout.width
        self.diagramHeight = layout.height

        // Debug: Log calculated dimensions
        let logger = Logger(label: "com.sam.mermaid.flowchart")
        logger.info("FlowchartRenderer init: direction=\(flowchart.direction.rawValue), nodes=\(flowchart.nodes.count), width=\(layout.width), height=\(layout.height)")
    }

    // Layout configuration - larger nodes for better readability
    private let nodeWidth: CGFloat = 180
    private let nodeHeight: CGFloat = 60
    private let horizontalSpacing: CGFloat = 100
    private let verticalSpacing: CGFloat = 80

    var body: some View {
        // Render at natural size - let parent handle scrolling/clipping if needed
        // Minimum width ensures narrow vertical flowcharts are still readable
        let displayWidth = max(diagramWidth, 500)

        diagramContent
            .frame(width: displayWidth, height: diagramHeight)
    }

    /// The actual diagram content (nodes and edges)
    @ViewBuilder
    private var diagramContent: some View {
        ZStack {
            // Render edges (connections) first
            ForEach(Array(flowchart.edges.enumerated()), id: \.element.id) { index, edge in
                if let fromPos = nodePositions[edge.from],
                   let toPos = nodePositions[edge.to],
                   let fromNode = flowchart.nodes.first(where: { $0.id == edge.from }),
                   let toNode = flowchart.nodes.first(where: { $0.id == edge.to }) {
                    EdgeView(
                        from: fromPos,
                        to: toPos,
                        edge: edge,
                        nodeWidth: nodeWidth,
                        nodeHeight: nodeHeight,
                        allNodePositions: nodePositions,
                        fromNode: fromNode,
                        toNode: toNode,
                        linkStyle: flowchart.linkStyles[index]
                    )
                }
            }

            // Render nodes on top
            ForEach(flowchart.nodes) { node in
                if let position = nodePositions[node.id] {
                    NodeView(
                        node: node,
                        width: nodeWidth,
                        height: nodeHeight,
                        style: flowchart.nodeStyles[node.id]
                    )
                    .position(position)
                }
            }
        }
    }

    /// Calculate scale to fit diagram within reasonable bounds
    private var calculatedScale: CGFloat {
        let maxWidth: CGFloat = 1000
        let maxHeight: CGFloat = 800

        let widthScale = diagramWidth > maxWidth ? maxWidth / diagramWidth : 1.0
        let heightScale = diagramHeight > maxHeight ? maxHeight / diagramHeight : 1.0

        return min(widthScale, heightScale)
    }

    /// Static method to calculate initial layout
    private static func calculateInitialLayout(for flowchart: Flowchart) -> (positions: [String: CGPoint], width: CGFloat, height: CGFloat) {
        // Layout configuration - must match instance properties
        let nodeWidth: CGFloat = 180
        let nodeHeight: CGFloat = 60
        let horizontalSpacing: CGFloat = 100
        let verticalSpacing: CGFloat = 80

        return calculatePositionsAndSize(for: flowchart, nodeWidth: nodeWidth, nodeHeight: nodeHeight, horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing)
    }

    /// Calculate node positions and diagram dimensions using hierarchical layout
    private static func calculatePositionsAndSize(for flowchart: Flowchart, nodeWidth: CGFloat, nodeHeight: CGFloat, horizontalSpacing: CGFloat, verticalSpacing: CGFloat) -> (positions: [String: CGPoint], width: CGFloat, height: CGFloat) {

        // Build adjacency list for topological sort
        var graph: [String: [String]] = [:]
        var inDegree: [String: Int] = [:]

        for node in flowchart.nodes {
            graph[node.id] = []
            inDegree[node.id] = 0
        }

        for edge in flowchart.edges {
            graph[edge.from, default: []].append(edge.to)
            inDegree[edge.to, default: 0] += 1
        }

        // Topological sort to determine layers
        var layers: [[String]] = []
        var currentLayer: [String] = inDegree.filter { $0.value == 0 }.map { $0.key }
        var processed: Set<String> = []
        var tempInDegree = inDegree

        while !currentLayer.isEmpty {
            layers.append(currentLayer.sorted())  // Sort for consistency
            processed.formUnion(currentLayer)

            var nextLayer: [String] = []
            for nodeId in currentLayer {
                for neighbor in graph[nodeId, default: []] {
                    tempInDegree[neighbor, default: 0] -= 1
                    if tempInDegree[neighbor] == 0 && !processed.contains(neighbor) {
                        nextLayer.append(neighbor)
                    }
                }
            }
            currentLayer = nextLayer
        }

        // Handle any remaining nodes (cycles)
        let unprocessed = Set(flowchart.nodes.map(\.id)).subtracting(processed)
        if !unprocessed.isEmpty {
            layers.append(Array(unprocessed).sorted())
        }

        // Optimize layer ordering to minimize edge crossings using barycenter method
        layers = minimizeCrossings(layers: layers, edges: flowchart.edges)

        // Calculate actual diagram dimensions based on layers
        let actualWidth: CGFloat
        let actualHeight: CGFloat
        var maxNodesInLayer = 1
        for layer in layers {
            maxNodesInLayer = max(maxNodesInLayer, layer.count)
        }

        if flowchart.direction.isHorizontal {
            actualWidth = CGFloat(layers.count) * nodeWidth + CGFloat(max(0, layers.count - 1)) * horizontalSpacing + 100  // padding
            actualHeight = CGFloat(maxNodesInLayer) * nodeHeight + CGFloat(max(0, maxNodesInLayer - 1)) * verticalSpacing + 100  // padding
        } else {
            // Vertical layout needs minimum width for readability
            let calculatedWidth = CGFloat(maxNodesInLayer) * nodeWidth + CGFloat(max(0, maxNodesInLayer - 1)) * horizontalSpacing + 100
            actualWidth = max(calculatedWidth, 500)  // Minimum 500px width for vertical flowcharts
            actualHeight = CGFloat(layers.count) * nodeHeight + CGFloat(max(0, layers.count - 1)) * verticalSpacing + 100  // padding
        }

        // Calculate positions based on direction
        var positions: [String: CGPoint] = [:]

        if flowchart.direction.isHorizontal {
            // Horizontal layout (LR or RL)
            let totalWidth = CGFloat(layers.count - 1) * (nodeWidth + horizontalSpacing) + nodeWidth
            let startX = (actualWidth - totalWidth) / 2 + nodeWidth / 2

            for (layerIndex, layer) in layers.enumerated() {
                let x = flowchart.direction == .leftToRight ?
                    startX + CGFloat(layerIndex) * (nodeWidth + horizontalSpacing) :
                    actualWidth - (startX + CGFloat(layerIndex) * (nodeWidth + horizontalSpacing))

                let totalHeight = CGFloat(layer.count - 1) * (nodeHeight + verticalSpacing) + nodeHeight
                let startY = (actualHeight - totalHeight) / 2 + nodeHeight / 2

                for (nodeIndex, nodeId) in layer.enumerated() {
                    let y = startY + CGFloat(nodeIndex) * (nodeHeight + verticalSpacing)
                    positions[nodeId] = CGPoint(x: x, y: y)
                }
            }
        } else {
            // Vertical layout (TD, TB, or BT)
            let totalHeight = CGFloat(layers.count - 1) * (nodeHeight + verticalSpacing) + nodeHeight
            let startY = (actualHeight - totalHeight) / 2 + nodeHeight / 2

            for (layerIndex, layer) in layers.enumerated() {
                let y = flowchart.direction == .bottomToTop ?
                    actualHeight - (startY + CGFloat(layerIndex) * (nodeHeight + verticalSpacing)) :
                    startY + CGFloat(layerIndex) * (nodeHeight + verticalSpacing)

                let totalWidth = CGFloat(layer.count - 1) * (nodeWidth + horizontalSpacing) + nodeWidth
                let startX = (actualWidth - totalWidth) / 2 + nodeWidth / 2

                for (nodeIndex, nodeId) in layer.enumerated() {
                    let x = startX + CGFloat(nodeIndex) * (nodeWidth + horizontalSpacing)
                    positions[nodeId] = CGPoint(x: x, y: y)
                }
            }
        }

        return (positions: positions, width: actualWidth, height: actualHeight)
    }

    /// Minimize edge crossings using barycenter method
    private static func minimizeCrossings(layers: [[String]], edges: [FlowchartEdge]) -> [[String]] {
        guard layers.count > 1 else { return layers }

        var optimizedLayers = layers
        let maxIterations = 4  // Limit iterations for performance

        // Build edge maps for quick lookup
        var edgesFrom: [String: [String]] = [:]
        var edgesTo: [String: [String]] = [:]

        for edge in edges {
            edgesFrom[edge.from, default: []].append(edge.to)
            edgesTo[edge.to, default: []].append(edge.from)
        }

        // Perform multiple passes to iteratively reduce crossings
        for _ in 0..<maxIterations {
            // Forward pass: reorder based on parent positions
            for layerIndex in 1..<optimizedLayers.count {
                optimizedLayers[layerIndex] = reorderLayerByBarycenter(
                    layer: optimizedLayers[layerIndex],
                    previousLayer: optimizedLayers[layerIndex - 1],
                    edgesTo: edgesTo
                )
            }

            // Backward pass: reorder based on child positions
            for layerIndex in (0..<optimizedLayers.count - 1).reversed() {
                optimizedLayers[layerIndex] = reorderLayerByBarycenter(
                    layer: optimizedLayers[layerIndex],
                    previousLayer: optimizedLayers[layerIndex + 1],
                    edgesTo: edgesFrom
                )
            }
        }

        return optimizedLayers
    }

    /// Reorder a layer based on barycenter of connected nodes in previous layer
    private static func reorderLayerByBarycenter(layer: [String], previousLayer: [String], edgesTo: [String: [String]]) -> [String] {
        // Calculate barycenter (average position) for each node
        var barycenters: [(nodeId: String, barycenter: Double)] = []

        for nodeId in layer {
            let connectedNodes = edgesTo[nodeId, default: []]
            let positions = connectedNodes.compactMap { id in
                previousLayer.firstIndex(of: id)
            }

            if positions.isEmpty {
                // No connections, keep at end
                barycenters.append((nodeId, Double(layer.count)))
            } else {
                // Average position of connected nodes
                let avg = Double(positions.reduce(0, +)) / Double(positions.count)
                barycenters.append((nodeId, avg))
            }
        }

        // Sort by barycenter value
        return barycenters.sorted { $0.barycenter < $1.barycenter }.map { $0.nodeId }
    }
}

// MARK: - Node View

struct NodeView: View {
    let node: FlowchartNode
    let width: CGFloat
    let height: CGFloat
    let style: NodeStyle?

    var body: some View {
        ZStack {
            // Use Canvas or simple shapes
            switch node.shape {
            case .rectangle, .subroutine:
                Rectangle()
                    .fill(fillColor)
                Rectangle()
                    .strokeBorder(strokeColor, lineWidth: strokeWidth)

            case .roundedRect, .stadium:
                RoundedRectangle(cornerRadius: min(height / 2, 12))
                    .fill(fillColor)
                RoundedRectangle(cornerRadius: min(height / 2, 12))
                    .strokeBorder(strokeColor, lineWidth: strokeWidth)

            case .rhombus:
                DiamondShape()
                    .fill(fillColor)
                DiamondShape()
                    .stroke(strokeColor, lineWidth: strokeWidth)

            case .hexagon:
                HexagonShape()
                    .fill(fillColor)
                HexagonShape()
                    .stroke(strokeColor, lineWidth: strokeWidth)

            case .circle:
                Circle()
                    .fill(fillColor)
                Circle()
                    .strokeBorder(strokeColor, lineWidth: strokeWidth)

            default:
                RoundedRectangle(cornerRadius: 8)
                    .fill(fillColor)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(strokeColor, lineWidth: strokeWidth)
            }

            // Label on top
            Text(node.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 8)
                .frame(width: width - 16)
        }
        .frame(width: width, height: height)
    }

    private var fillColor: Color {
        if let fill = style?.fill {
            return parseColor(fill)
        }
        return Color(NSColor.controlBackgroundColor)
    }

    private var strokeColor: Color {
        if let stroke = style?.stroke {
            return parseColor(stroke)
        }
        return Color.accentColor
    }

    private var strokeWidth: CGFloat {
        if let width = style?.strokeWidth, let value = parseStrokeWidth(width) {
            return value
        }
        return 2
    }

    private var textColor: Color {
        if let color = style?.color {
            return parseColor(color)
        }
        return .primary
    }

    private func parseStrokeWidth(_ value: String) -> CGFloat? {
        let cleaned = value.replacingOccurrences(of: "px", with: "")
        return Double(cleaned).map { CGFloat($0) }
    }

    private func parseColor(_ colorString: String) -> Color {
        let trimmed = colorString.trimmingCharacters(in: .whitespaces).lowercased()

        // Handle hex colors (#RGB or #RRGGBB)
        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            if hex.count == 6 {
                let scanner = Scanner(string: hex)
                var hexNumber: UInt64 = 0
                if scanner.scanHexInt64(&hexNumber) {
                    let r = Double((hexNumber & 0xFF0000) >> 16) / 255.0
                    let g = Double((hexNumber & 0x00FF00) >> 8) / 255.0
                    let b = Double(hexNumber & 0x0000FF) / 255.0
                    return Color(red: r, green: g, blue: b)
                }
            } else if hex.count == 3 {
                let scanner = Scanner(string: hex)
                var hexNumber: UInt64 = 0
                if scanner.scanHexInt64(&hexNumber) {
                    let r = Double(((hexNumber & 0xF00) >> 8) * 17) / 255.0
                    let g = Double(((hexNumber & 0x0F0) >> 4) * 17) / 255.0
                    let b = Double((hexNumber & 0x00F) * 17) / 255.0
                    return Color(red: r, green: g, blue: b)
                }
            }
        }

        // Named colors - return defaults for common names
        switch trimmed {
        case "red": return .red
        case "blue": return .blue
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "purple": return .purple
        case "pink": return .pink
        case "gray", "grey": return .gray
        case "black": return .black
        case "white": return .white
        default: return .accentColor
        }
    }
}

// MARK: - Edge View

struct EdgeView: View {
    let from: CGPoint
    let to: CGPoint
    let edge: FlowchartEdge
    let nodeWidth: CGFloat
    let nodeHeight: CGFloat
    let allNodePositions: [String: CGPoint]
    let fromNode: FlowchartNode
    let toNode: FlowchartNode
    let linkStyle: EdgeStyleProperties?

    var body: some View {
        let anchors = calculateAnchors()
        let routedPath = calculateRoutedPath(from: anchors.from, to: anchors.to)

        ZStack {
            // Connection line with smart routing
            Path { path in
                if routedPath.isEmpty {
                    // Simple path
                    path.move(to: anchors.from)
                    path.addLine(to: anchors.to)
                } else {
                    // Routed path with waypoints
                    path.move(to: anchors.from)
                    for waypoint in routedPath {
                        path.addLine(to: waypoint)
                    }
                    path.addLine(to: anchors.to)
                }
            }
            .stroke(edgeColor, style: strokeStyle)

            // Arrow head at target anchor point
            ArrowHead(at: anchors.to, from: routedPath.last ?? anchors.from)
                .fill(edgeColor)

            // Edge label
            if let label = edge.label {
                Text(label)
                    .font(.caption)
                    .padding(4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
                    .position(midpoint)
            }
        }
    }

    /// Calculate anchor points at node edges based on connection direction
    private func calculateAnchors() -> (from: CGPoint, to: CGPoint) {
        let deltaX = to.x - from.x
        let deltaY = to.y - from.y

        // Calculate exit point from source node
        let fromAnchor = calculateExitPoint(
            center: from,
            shape: fromNode.shape,
            deltaX: deltaX,
            deltaY: deltaY
        )

        // Calculate entry point to target node
        let toAnchor = calculateEntryPoint(
            center: to,
            shape: toNode.shape,
            deltaX: -deltaX,  // Reverse direction for entry
            deltaY: -deltaY
        )

        return (fromAnchor, toAnchor)
    }

    /// Calculate routed path with waypoints to avoid overlapping nodes
    private func calculateRoutedPath(from: CGPoint, to: CGPoint) -> [CGPoint] {
        // Check if direct path intersects any intermediate nodes
        var waypoints: [CGPoint] = []

        // Get list of all nodes except source and target
        let intermediateNodes = allNodePositions.filter { nodeId, _ in
            nodeId != edge.from && nodeId != edge.to
        }

        // Check if any intermediate node is in the path
        for (_, nodePos) in intermediateNodes {
            if lineIntersectsNode(from: from, to: to, nodeCenter: nodePos) {
                // Create orthogonal waypoints to route around the obstacle
                let isVerticalPath = abs(to.y - from.y) > abs(to.x - from.x)

                if isVerticalPath {
                    // Route horizontally first, then vertically
                    let midX = (from.x + to.x) / 2
                    // Offset to avoid the node
                    let offsetX = nodePos.x > midX ? -nodeWidth : nodeWidth
                    waypoints = [
                        CGPoint(x: from.x, y: (from.y + nodePos.y) / 2),
                        CGPoint(x: nodePos.x + offsetX, y: (from.y + nodePos.y) / 2),
                        CGPoint(x: nodePos.x + offsetX, y: (to.y + nodePos.y) / 2),
                        CGPoint(x: to.x, y: (to.y + nodePos.y) / 2)
                    ]
                } else {
                    // Route vertically first, then horizontally
                    let midY = (from.y + to.y) / 2
                    // Offset to avoid the node
                    let offsetY = nodePos.y > midY ? -nodeHeight : nodeHeight
                    waypoints = [
                        CGPoint(x: (from.x + nodePos.x) / 2, y: from.y),
                        CGPoint(x: (from.x + nodePos.x) / 2, y: nodePos.y + offsetY),
                        CGPoint(x: (to.x + nodePos.x) / 2, y: nodePos.y + offsetY),
                        CGPoint(x: (to.x + nodePos.x) / 2, y: to.y)
                    ]
                }
                break  // Use first waypoint solution found
            }
        }

        return waypoints
    }

    /// Check if a line segment intersects with a node's bounding box
    private func lineIntersectsNode(from: CGPoint, to: CGPoint, nodeCenter: CGPoint) -> Bool {
        let halfWidth = nodeWidth / 2
        let halfHeight = nodeHeight / 2

        // Node bounding box
        let nodeLeft = nodeCenter.x - halfWidth
        let nodeRight = nodeCenter.x + halfWidth
        let nodeTop = nodeCenter.y - halfHeight
        let nodeBottom = nodeCenter.y + halfHeight

        // Check if line passes through node area (simple box check)
        // Using midpoint for simplicity
        let midX = (from.x + to.x) / 2
        let midY = (from.y + to.y) / 2

        return midX >= nodeLeft && midX <= nodeRight && midY >= nodeTop && midY <= nodeBottom
    }

    /// Calculate exit point from a node based on direction
    private func calculateExitPoint(center: CGPoint, shape: NodeShape, deltaX: CGFloat, deltaY: CGFloat) -> CGPoint {
        switch shape {
        case .rectangle, .roundedRect, .subroutine, .cylinder, .asymmetric:
            return rectangleAnchor(center: center, deltaX: deltaX, deltaY: deltaY)
        case .circle, .stadium:
            return ovalAnchor(center: center, deltaX: deltaX, deltaY: deltaY, width: nodeWidth, height: nodeHeight)
        case .rhombus:
            return diamondAnchor(center: center, deltaX: deltaX, deltaY: deltaY)
        case .hexagon:
            return hexagonAnchor(center: center, deltaX: deltaX, deltaY: deltaY)
        case .parallelogram, .trapezoid:
            return rectangleAnchor(center: center, deltaX: deltaX, deltaY: deltaY)
        }
    }

    /// Calculate entry point to a node (same as exit, direction already reversed)
    private func calculateEntryPoint(center: CGPoint, shape: NodeShape, deltaX: CGFloat, deltaY: CGFloat) -> CGPoint {
        return calculateExitPoint(center: center, shape: shape, deltaX: deltaX, deltaY: deltaY)
    }

    /// Calculate anchor point on rectangle edge
    private func rectangleAnchor(center: CGPoint, deltaX: CGFloat, deltaY: CGFloat) -> CGPoint {
        let halfWidth = nodeWidth / 2
        let halfHeight = nodeHeight / 2

        if abs(deltaX) > abs(deltaY) {
            // Horizontal connection
            if deltaX > 0 {
                return CGPoint(x: center.x + halfWidth, y: center.y)
            } else {
                return CGPoint(x: center.x - halfWidth, y: center.y)
            }
        } else {
            // Vertical connection
            if deltaY > 0 {
                return CGPoint(x: center.x, y: center.y + halfHeight)
            } else {
                return CGPoint(x: center.x, y: center.y - halfHeight)
            }
        }
    }

    /// Calculate anchor point on oval/circle edge
    private func ovalAnchor(center: CGPoint, deltaX: CGFloat, deltaY: CGFloat, width: CGFloat, height: CGFloat) -> CGPoint {
        let angle = atan2(deltaY, deltaX)
        let radiusX = width / 2
        let radiusY = height / 2

        return CGPoint(
            x: center.x + radiusX * cos(angle),
            y: center.y + radiusY * sin(angle)
        )
    }

    /// Calculate anchor point on diamond edge
    private func diamondAnchor(center: CGPoint, deltaX: CGFloat, deltaY: CGFloat) -> CGPoint {
        let halfWidth = nodeWidth / 2
        let halfHeight = nodeHeight / 2

        // Diamond has 4 sides, find which one we're exiting from
        if abs(deltaX) > abs(deltaY) {
            // Horizontal
            if deltaX > 0 {
                return CGPoint(x: center.x + halfWidth, y: center.y)
            } else {
                return CGPoint(x: center.x - halfWidth, y: center.y)
            }
        } else {
            // Vertical
            if deltaY > 0 {
                return CGPoint(x: center.x, y: center.y + halfHeight)
            } else {
                return CGPoint(x: center.x, y: center.y - halfHeight)
            }
        }
    }

    /// Calculate anchor point on hexagon edge
    private func hexagonAnchor(center: CGPoint, deltaX: CGFloat, deltaY: CGFloat) -> CGPoint {
        let sideWidth = nodeWidth * 0.2
        let halfWidth = nodeWidth / 2
        let halfHeight = nodeHeight / 2

        let angle = atan2(deltaY, deltaX)
        let degrees = angle * 180 / .pi

        // Hexagon has 6 sides
        if degrees >= -30 && degrees < 30 {
            // Right side
            return CGPoint(x: center.x + halfWidth, y: center.y)
        } else if degrees >= 30 && degrees < 90 {
            // Bottom-right diagonal
            return CGPoint(x: center.x + halfWidth - sideWidth, y: center.y + halfHeight)
        } else if degrees >= 90 && degrees < 150 {
            // Bottom-left diagonal
            return CGPoint(x: center.x - halfWidth + sideWidth, y: center.y + halfHeight)
        } else if degrees >= 150 || degrees < -150 {
            // Left side
            return CGPoint(x: center.x - halfWidth, y: center.y)
        } else if degrees >= -150 && degrees < -90 {
            // Top-left diagonal
            return CGPoint(x: center.x - halfWidth + sideWidth, y: center.y - halfHeight)
        } else {
            // Top-right diagonal
            return CGPoint(x: center.x + halfWidth - sideWidth, y: center.y - halfHeight)
        }
    }

    private var edgeColor: Color {
        // Priority: linkStyle > inline edge color > default
        if let stroke = linkStyle?.stroke {
            return parseColor(stroke)
        }
        if let colorString = edge.color {
            return parseColor(colorString)
        }
        return Color.accentColor.opacity(0.6)
    }

    /// Parse color string to SwiftUI Color
    private func parseColor(_ colorString: String) -> Color {
        let trimmed = colorString.trimmingCharacters(in: .whitespaces).lowercased()

        // Handle hex colors (#RGB or #RRGGBB)
        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            if hex.count == 6 {
                let scanner = Scanner(string: hex)
                var hexNumber: UInt64 = 0
                if scanner.scanHexInt64(&hexNumber) {
                    let r = Double((hexNumber & 0xFF0000) >> 16) / 255.0
                    let g = Double((hexNumber & 0x00FF00) >> 8) / 255.0
                    let b = Double(hexNumber & 0x0000FF) / 255.0
                    return Color(red: r, green: g, blue: b)
                }
            } else if hex.count == 3 {
                // Short form #RGB -> #RRGGBB
                let scanner = Scanner(string: hex)
                var hexNumber: UInt64 = 0
                if scanner.scanHexInt64(&hexNumber) {
                    let r = Double(((hexNumber & 0xF00) >> 8) * 17) / 255.0
                    let g = Double(((hexNumber & 0x0F0) >> 4) * 17) / 255.0
                    let b = Double((hexNumber & 0x00F) * 17) / 255.0
                    return Color(red: r, green: g, blue: b)
                }
            }
        }

        // Handle named colors
        switch trimmed {
        case "red": return .red
        case "blue": return .blue
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "purple": return .purple
        case "pink": return .pink
        case "gray", "grey": return .gray
        case "black": return .black
        case "white": return .white
        case "brown": return .brown
        case "cyan": return .cyan
        case "mint": return .mint
        case "indigo": return .indigo
        case "teal": return .teal
        default: return Color.accentColor.opacity(0.6)
        }
    }

    private var strokeStyle: StrokeStyle {
        var lineWidth: CGFloat = 2

        // Check linkStyle for custom width
        if let widthString = linkStyle?.strokeWidth {
            let cleaned = widthString.replacingOccurrences(of: "px", with: "")
            if let width = Double(cleaned) {
                lineWidth = CGFloat(width)
            }
        }

        switch edge.style {
        case .solid:
            return StrokeStyle(lineWidth: lineWidth)
        case .dotted:
            return StrokeStyle(lineWidth: lineWidth, dash: [5, 5])
        case .thick:
            return StrokeStyle(lineWidth: max(lineWidth, 3))  // At least 3 for thick
        }
    }

    private var midpoint: CGPoint {
        let anchors = calculateAnchors()
        return CGPoint(
            x: (anchors.from.x + anchors.to.x) / 2,
            y: (anchors.from.y + anchors.to.y) / 2
        )
    }
}

// MARK: - Arrow Head

struct ArrowHead: Shape {
    let at: CGPoint
    let from: CGPoint

    func path(in rect: CGRect) -> Path {
        let angle = atan2(at.y - from.y, at.x - from.x)
        let arrowLength: CGFloat = 10
        let arrowAngle: CGFloat = .pi / 6

        var path = Path()
        path.move(to: at)
        path.addLine(to: CGPoint(
            x: at.x - arrowLength * cos(angle - arrowAngle),
            y: at.y - arrowLength * sin(angle - arrowAngle)
        ))
        path.move(to: at)
        path.addLine(to: CGPoint(
            x: at.x - arrowLength * cos(angle + arrowAngle),
            y: at.y - arrowLength * sin(angle + arrowAngle)
        ))

        return path
    }
}

// MARK: - Custom Shapes

struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let sideWidth = width * 0.2

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + sideWidth, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - sideWidth, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - sideWidth, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + sideWidth, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}
