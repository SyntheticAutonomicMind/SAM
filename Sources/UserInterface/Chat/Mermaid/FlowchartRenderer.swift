// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging

/// PreferenceKey to propagate calculated height to parent view
private struct HeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Native SwiftUI renderer for Mermaid flowcharts
struct FlowchartRenderer: View {
    let flowchart: Flowchart
    private let logger = Logger(label: "com.sam.mermaid.flowchart")

    // Metrics calculated once during init
    private let metrics: MermaidGraphAnalyzer.DiagramMetrics
    
    // Pre-calculated estimated height based on flowchart structure
    private let estimatedHeight: CGFloat
    
    // State to track actual height from rendering
    @State private var actualHeight: CGFloat?

    init(flowchart: Flowchart) {
        self.flowchart = flowchart
        
        // Analyze diagram complexity
        let metrics = MermaidGraphAnalyzer.analyze(flowchart: flowchart)
        self.metrics = metrics
        
        // Pre-calculate estimated height using reasonable width assumption
        // Most chat windows are 1000-1500px wide, so use 1200px as estimate
        let estimatedWidth: CGFloat = 1200
        let targetWidth = estimatedWidth * 0.95
        let spacingConfig = SpacingConfiguration.calculateDynamic(
            for: metrics,
            targetWidth: targetWidth
        )
        
        let layout = Self.calculateInitialLayout(
            for: flowchart,
            nodeWidth: spacingConfig.nodeWidth,
            nodeHeight: spacingConfig.nodeHeight,
            horizontalSpacing: spacingConfig.horizontalSpacing,
            verticalSpacing: spacingConfig.verticalSpacing
        )
        
        // TEMPORARY: Add extra height to diagnose clipping issue
        // If diagram appears fully with +64px, the issue is calculation/layout
        // If still clipped, the issue is elsewhere (parent container, clipping modifier, etc.)
        let debugHeightAddition: CGFloat = 64
        self.estimatedHeight = max(layout.height + debugHeightAddition, 200)
    }

    var body: some View {
        // Use GeometryReader to get actual available width
        GeometryReader { geometry in
            let availableWidth = geometry.size.width
            
            // Calculate spacing based on actual available width (95% usable)
            let targetWidth = availableWidth * 0.95
            let spacingConfig = SpacingConfiguration.calculateDynamic(
                for: metrics,
                targetWidth: targetWidth
            )
            
            // Calculate layout with dynamic spacing
            let layout = Self.calculateInitialLayout(
                for: flowchart,
                nodeWidth: spacingConfig.nodeWidth,
                nodeHeight: spacingConfig.nodeHeight,
                horizontalSpacing: spacingConfig.horizontalSpacing,
                verticalSpacing: spacingConfig.verticalSpacing
            )
            
            // Render the diagram  
            ZStack(alignment: .center) {  // Centered both vertically and horizontally
                // Render edges (connections) first
                ForEach(Array(flowchart.edges.enumerated()), id: \.element.id) { index, edge in
                    if let fromPos = layout.positions[edge.from],
                       let toPos = layout.positions[edge.to],
                       let fromNode = flowchart.nodes.first(where: { $0.id == edge.from }),
                       let toNode = flowchart.nodes.first(where: { $0.id == edge.to}) {
                        EdgeView(
                            from: fromPos,
                            to: toPos,
                            edge: edge,
                            nodeWidth: spacingConfig.nodeWidth,
                            nodeHeight: spacingConfig.nodeHeight,
                            allNodePositions: layout.positions,
                            fromNode: fromNode,
                            toNode: toNode,
                            linkStyle: flowchart.linkStyles[index]
                        )
                    }
                }

                // Render nodes on top
                ForEach(flowchart.nodes) { node in
                    if let position = layout.positions[node.id] {
                        NodeView(
                            node: node,
                            width: spacingConfig.nodeWidth,
                            height: spacingConfig.nodeHeight,
                            style: flowchart.nodeStyles[node.id]
                        )
                        .position(position)
                    }
                }
            }
            .frame(width: layout.width)
            // Note: No height constraint on inner ZStack - let content determine height naturally
            // The outer GeometryReader frame will use estimatedHeight/actualHeight
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: HeightPreferenceKey.self,
                        value: geo.size.height
                    )
                }
            )
            .onAppear {
                logger.info("FlowchartRenderer: availableWidth=\(availableWidth), targetWidth=\(targetWidth), nodeWidth=\(spacingConfig.nodeWidth), diagramWidth=\(layout.width), diagramHeight=\(layout.height), estimatedHeight=\(estimatedHeight)")
            }
        }
        .onPreferenceChange(HeightPreferenceKey.self) { height in
            if height > 0 && actualHeight != height {
                logger.info("FlowchartRenderer: Actual height changed from \(actualHeight ?? estimatedHeight) to \(height)")
                actualHeight = height
            }
        }
        .frame(height: actualHeight ?? estimatedHeight)
    }

    /// Static method to calculate initial layout with dynamic spacing
    private static func calculateInitialLayout(
        for flowchart: Flowchart,
        nodeWidth: CGFloat,
        nodeHeight: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat
    ) -> (positions: [String: CGPoint], width: CGFloat, height: CGFloat) {
        return calculatePositionsAndSize(
            for: flowchart,
            nodeWidth: nodeWidth,
            nodeHeight: nodeHeight,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        )
    }

    /// Calculate node positions and diagram dimensions using hierarchical layout
    private static func calculatePositionsAndSize(for flowchart: Flowchart, nodeWidth: CGFloat, nodeHeight: CGFloat, horizontalSpacing: CGFloat, verticalSpacing: CGFloat) -> (positions: [String: CGPoint], width: CGFloat, height: CGFloat) {

        let logger = Logger(label: "com.sam.mermaid.flowchart")
        
        // Build adjacency list
        var graph: [String: [String]] = [:]
        for node in flowchart.nodes {
            graph[node.id] = []
        }
        for edge in flowchart.edges {
            graph[edge.from, default: []].append(edge.to)
        }

        logger.debug("Flowchart layout: \(flowchart.nodes.count) nodes, \(flowchart.edges.count) edges")
        
        // Detect and break cycles using DFS-based back edge detection
        var backEdges: Set<String> = []  // Store "from->to" for back edges
        var visited: Set<String> = []
        var recursionStack: Set<String> = []
        
        func detectCycles(_ nodeId: String) {
            visited.insert(nodeId)
            recursionStack.insert(nodeId)
            
            for neighbor in graph[nodeId, default: []] {
                if !visited.contains(neighbor) {
                    detectCycles(neighbor)
                } else if recursionStack.contains(neighbor) {
                    // Back edge found - this creates a cycle
                    backEdges.insert("\(nodeId)->\(neighbor)")
                }
            }
            
            recursionStack.remove(nodeId)
        }
        
        // Run cycle detection from all unvisited nodes
        for node in flowchart.nodes {
            if !visited.contains(node.id) {
                detectCycles(node.id)
            }
        }
        
        if !backEdges.isEmpty {
            logger.info("Detected \(backEdges.count) back edges creating cycles: \(backEdges.joined(separator: ", "))")
        }
        
        // Build DAG by excluding back edges, and calculate in-degrees
        var inDegree: [String: Int] = [:]
        for node in flowchart.nodes {
            inDegree[node.id] = 0
        }
        
        for edge in flowchart.edges {
            let edgeKey = "\(edge.from)->\(edge.to)"
            if !backEdges.contains(edgeKey) {
                inDegree[edge.to, default: 0] += 1
            }
        }
        
        // Topological sort on the DAG (without back edges)
        var layers: [[String]] = []
        var currentLayer: [String] = inDegree.filter { $0.value == 0 }.map { $0.key }.sorted()
        var processed: Set<String> = []
        var tempInDegree = inDegree
        
        logger.debug("Initial layer (in-degree 0): \(currentLayer.joined(separator: ", "))")
        
        // If still no starting nodes (shouldn't happen after breaking cycles), use first node
        if currentLayer.isEmpty && !flowchart.nodes.isEmpty {
            currentLayer = [flowchart.nodes[0].id]
            logger.warning("No nodes with in-degree 0 after cycle breaking - using first node: \(currentLayer[0])")
        }
        
        while !currentLayer.isEmpty {
            layers.append(currentLayer)
            processed.formUnion(currentLayer)
            
            var nextLayer: [String] = []
            for nodeId in currentLayer {
                for neighbor in graph[nodeId, default: []] {
                    let edgeKey = "\(nodeId)->\(neighbor)"
                    if !backEdges.contains(edgeKey) {
                        tempInDegree[neighbor, default: 0] -= 1
                        if tempInDegree[neighbor] == 0 && !processed.contains(neighbor) {
                            nextLayer.append(neighbor)
                        }
                    }
                }
            }
            currentLayer = nextLayer.sorted()
        }
        
        // Handle any remaining unprocessed nodes (shouldn't happen, but safety net)
        let unprocessed = Set(flowchart.nodes.map(\.id)).subtracting(processed)
        if !unprocessed.isEmpty {
            logger.warning("Unprocessed nodes after topological sort: \(unprocessed.joined(separator: ", "))")
            layers.append(Array(unprocessed).sorted())
        }
        
        logger.info("Layer assignment: \(layers.count) layers - \(layers.map { "[\($0.joined(separator: ","))]" }.joined(separator: " -> "))")

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
            actualWidth = CGFloat(layers.count) * nodeWidth + CGFloat(max(0, layers.count - 1)) * horizontalSpacing + 40  // padding
            // Add extra height for potential orthogonal routing detours
            // Also add full nodeHeight since .position() centers views, so bottom nodes extend beyond their Y coordinate
            actualHeight = CGFloat(maxNodesInLayer) * nodeHeight + CGFloat(max(0, maxNodesInLayer - 1)) * verticalSpacing + 100 + nodeHeight
        } else {
            // Vertical layout - add extra padding for offset edge routing
            actualWidth = CGFloat(maxNodesInLayer) * nodeWidth + CGFloat(max(0, maxNodesInLayer - 1)) * horizontalSpacing + 100  // Increased padding for offset routing
            // Add extra height for potential orthogonal routing detours
            // Also add full nodeHeight since .position() centers views, so bottom nodes extend beyond their Y coordinate
            actualHeight = CGFloat(layers.count) * nodeHeight + CGFloat(max(0, layers.count - 1)) * verticalSpacing + 100 + nodeHeight
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
            // Vertical layout (TD, TB, or BT) with Phase 2: Coordinate Optimization
            let totalHeight = CGFloat(layers.count - 1) * (nodeHeight + verticalSpacing) + nodeHeight
            let startY = (actualHeight - totalHeight) / 2 + nodeHeight / 2

            // Build edge maps for coordinate optimization
            var edgesFrom: [String: [String]] = [:]
            var edgesTo: [String: [String]] = [:]
            for edge in flowchart.edges {
                edgesFrom[edge.from, default: []].append(edge.to)
                edgesTo[edge.to, default: []].append(edge.from)
            }

            for (layerIndex, layer) in layers.enumerated() {
                let y = flowchart.direction == .bottomToTop ?
                    actualHeight - (startY + CGFloat(layerIndex) * (nodeHeight + verticalSpacing)) :
                    startY + CGFloat(layerIndex) * (nodeHeight + verticalSpacing)

                // Phase 2: Optimize X coordinates to minimize edge lengths and overlaps
                let optimizedXPositions = assignOptimalCoordinates(
                    layer: layer,
                    layerIndex: layerIndex,
                    layers: layers,
                    edgesFrom: edgesFrom,
                    edgesTo: edgesTo,
                    positions: positions,
                    actualWidth: actualWidth,
                    nodeWidth: nodeWidth,
                    horizontalSpacing: horizontalSpacing
                )

                for (nodeId, x) in optimizedXPositions {
                    positions[nodeId] = CGPoint(x: x, y: y)
                }
            }
        }
        
        // Center the diagram horizontally within actualWidth
        if !positions.isEmpty {
            let xPositions = positions.values.map { $0.x }
            let minX = xPositions.min() ?? 0
            let maxX = xPositions.max() ?? 0
            let contentWidth = maxX - minX + nodeWidth
            
            // Calculate correct offset: where we want left edge vs where it currently is
            let currentLeftEdge = minX - nodeWidth / 2
            let desiredLeftEdge = (actualWidth - contentWidth) / 2
            let xOffset = desiredLeftEdge - currentLeftEdge
            
            // Shift all positions to center the content
            for (nodeId, pos) in positions {
                let newPos = CGPoint(x: pos.x + xOffset, y: pos.y)
                positions[nodeId] = newPos
            }
        }

        return (positions: positions, width: actualWidth, height: actualHeight)
    }

    /// Phase 2: Assign optimal X coordinates to minimize edge lengths (Priority Layout)
    private static func assignOptimalCoordinates(
        layer: [String],
        layerIndex: Int,
        layers: [[String]],
        edgesFrom: [String: [String]],
        edgesTo: [String: [String]],
        positions: [String: CGPoint],
        actualWidth: CGFloat,
        nodeWidth: CGFloat,
        horizontalSpacing: CGFloat
    ) -> [String: CGFloat] {
        var result: [String: CGFloat] = [:]
        
        // Calculate ideal X position for each node based on connected nodes
        var idealPositions: [(nodeId: String, idealX: CGFloat)] = []
        
        for nodeId in layer {
            var connectedXPositions: [CGFloat] = []
            
            // Get X positions of parent nodes (from previous layer)
            if layerIndex > 0 {
                let parents = edgesTo[nodeId, default: []]
                for parent in parents {
                    if let parentPos = positions[parent] {
                        connectedXPositions.append(parentPos.x)
                    }
                }
            }
            
            // Get X positions of child nodes (from next layer)
            if layerIndex < layers.count - 1 {
                let children = edgesFrom[nodeId, default: []]
                for child in children {
                    if let childPos = positions[child] {
                        connectedXPositions.append(childPos.x)
                    }
                }
            }
            
            // Calculate median position of connected nodes
            let idealX: CGFloat
            if connectedXPositions.isEmpty {
                // No connections - use center of diagram
                idealX = actualWidth / 2
            } else {
                // Use median of connected positions for better alignment
                connectedXPositions.sort()
                let mid = connectedXPositions.count / 2
                if connectedXPositions.count % 2 == 0 {
                    idealX = (connectedXPositions[mid - 1] + connectedXPositions[mid]) / 2
                } else {
                    idealX = connectedXPositions[mid]
                }
            }
            
            idealPositions.append((nodeId, idealX))
        }
        
        // Sort by ideal X position to determine left-to-right order
        idealPositions.sort { $0.idealX < $1.idealX }
        
        // Assign actual positions with minimum spacing constraints
        let minSpacing = nodeWidth + horizontalSpacing
        let totalRequiredWidth = CGFloat(layer.count - 1) * minSpacing + nodeWidth
        
        // Left-align instead of center-align to prevent overflow
        var startX = nodeWidth / 2 + 20  // 20px left margin
        
        var assignedPositions: [String: CGFloat] = [:]
        var currentX = startX
        
        for (index, item) in idealPositions.enumerated() {
            // Place nodes left-to-right with consistent spacing, ignoring ideal position
            // to prevent overflow when collision detection shifts nodes
            let finalX = currentX
            
            // Ensure we don't exceed right boundary
            let maxX = actualWidth - nodeWidth / 2 - 20  // 20px right margin
            if finalX > maxX {
                // If we've exceeded bounds, we need to scale down or wrap (for now, just clamp)
                assignedPositions[item.nodeId] = maxX
            } else {
                assignedPositions[item.nodeId] = finalX
            }
            
            // Update minimum X for next node
            currentX = finalX + minSpacing
        }
        
        // Post-process: Detect and fix any overlaps that slipped through
        let sortedNodes = idealPositions.map { $0.nodeId }
        for i in 0..<sortedNodes.count - 1 {
            let leftNode = sortedNodes[i]
            let rightNode = sortedNodes[i + 1]
            
            guard let leftX = assignedPositions[leftNode],
                  let rightX = assignedPositions[rightNode] else { continue }
            
            let actualGap = rightX - leftX
            if actualGap < minSpacing {
                // Overlap detected - shift right node
                assignedPositions[rightNode] = leftX + minSpacing
                
                // Cascade shift for all subsequent nodes
                for j in (i + 2)..<sortedNodes.count {
                    let nodeId = sortedNodes[j]
                    if let currentPos = assignedPositions[nodeId] {
                        assignedPositions[nodeId] = currentPos + (minSpacing - actualGap)
                    }
                }
            }
        }
        
        return assignedPositions
    }

    /// Minimize edge crossings using enhanced barycenter method with transpose optimization
    private static func minimizeCrossings(layers: [[String]], edges: [FlowchartEdge]) -> [[String]] {
        guard layers.count > 1 else { return layers }

        let logger = Logger(label: "com.sam.mermaid.flowchart.crossings")
        var optimizedLayers = layers
        let maxIterations = 10  // Increased from 4 for better convergence

        // Build edge maps for quick lookup
        var edgesFrom: [String: [String]] = [:]
        var edgesTo: [String: [String]] = [:]

        for edge in edges {
            edgesFrom[edge.from, default: []].append(edge.to)
            edgesTo[edge.to, default: []].append(edge.from)
        }

        // Count initial crossings for baseline
        let initialCrossings = countTotalCrossings(layers: optimizedLayers, edgesFrom: edgesFrom)
        logger.info("Initial edge crossings: \(initialCrossings)")

        // Perform multiple passes to iteratively reduce crossings
        for iteration in 0..<maxIterations {
            // Forward pass: reorder based on parent positions
            for layerIndex in 1..<optimizedLayers.count {
                optimizedLayers[layerIndex] = reorderLayerByBarycenter(
                    layer: optimizedLayers[layerIndex],
                    previousLayer: optimizedLayers[layerIndex - 1],
                    edgesTo: edgesTo
                )
                
                // Apply transpose heuristic for local optimization
                optimizedLayers[layerIndex] = transposeOptimize(
                    layer: optimizedLayers[layerIndex],
                    adjacentLayer: optimizedLayers[layerIndex - 1],
                    edges: edgesTo,
                    direction: .forward
                )
            }

            // Backward pass: reorder based on child positions
            for layerIndex in (0..<optimizedLayers.count - 1).reversed() {
                optimizedLayers[layerIndex] = reorderLayerByBarycenter(
                    layer: optimizedLayers[layerIndex],
                    previousLayer: optimizedLayers[layerIndex + 1],
                    edgesTo: edgesFrom
                )
                
                // Apply transpose heuristic for local optimization
                optimizedLayers[layerIndex] = transposeOptimize(
                    layer: optimizedLayers[layerIndex],
                    adjacentLayer: optimizedLayers[layerIndex + 1],
                    edges: edgesFrom,
                    direction: .backward
                )
            }
            
            // Log progress every few iterations
            if iteration % 3 == 0 || iteration == maxIterations - 1 {
                let currentCrossings = countTotalCrossings(layers: optimizedLayers, edgesFrom: edgesFrom)
                logger.debug("Iteration \(iteration + 1): \(currentCrossings) crossings")
            }
        }

        // Log final results
        let finalCrossings = countTotalCrossings(layers: optimizedLayers, edgesFrom: edgesFrom)
        let reduction = initialCrossings > 0 ? Int((1.0 - Double(finalCrossings) / Double(initialCrossings)) * 100) : 0
        logger.info("Final edge crossings: \(finalCrossings) (reduced by \(reduction)%)")

        return optimizedLayers
    }

    /// Count total edge crossings across all adjacent layer pairs
    private static func countTotalCrossings(layers: [[String]], edgesFrom: [String: [String]]) -> Int {
        var total = 0
        for i in 0..<layers.count - 1 {
            total += countCrossingsBetweenLayers(
                layer1: layers[i],
                layer2: layers[i + 1],
                edges: edgesFrom
            )
        }
        return total
    }
    
    /// Count edge crossings between two adjacent layers
    private static func countCrossingsBetweenLayers(
        layer1: [String],
        layer2: [String],
        edges: [String: [String]]
    ) -> Int {
        var crossings = 0
        
        // Build position maps for quick lookup
        let positions1 = Dictionary(uniqueKeysWithValues: layer1.enumerated().map { ($1, $0) })
        let positions2 = Dictionary(uniqueKeysWithValues: layer2.enumerated().map { ($1, $0) })
        
        // Check all pairs of edges between the layers
        for i in 0..<layer1.count {
            let node1 = layer1[i]
            let targets1 = edges[node1, default: []]
            
            for j in (i + 1)..<layer1.count {
                let node2 = layer1[j]
                let targets2 = edges[node2, default: []]
                
                // Check if any edge from node1 crosses any edge from node2
                for t1 in targets1 {
                    guard let pos1 = positions2[t1] else { continue }
                    
                    for t2 in targets2 {
                        guard let pos2 = positions2[t2] else { continue }
                        
                        // Crossing occurs when edge order is reversed
                        // node1 is left of node2 (i < j) but t1 is right of t2 (pos1 > pos2)
                        if pos1 > pos2 {
                            crossings += 1
                        }
                    }
                }
            }
        }
        
        return crossings
    }
    
    /// Direction for transpose optimization
    private enum TransposeDirection {
        case forward
        case backward
    }
    
    /// Transpose heuristic: swap adjacent nodes if it reduces crossings
    private static func transposeOptimize(
        layer: [String],
        adjacentLayer: [String],
        edges: [String: [String]],
        direction: TransposeDirection
    ) -> [String] {
        var optimized = layer
        var improved = true
        var iterations = 0
        let maxTransposeIterations = 5  // Limit to prevent excessive computation
        
        while improved && iterations < maxTransposeIterations {
            improved = false
            iterations += 1
            
            for i in 0..<optimized.count - 1 {
                // Try swapping adjacent nodes
                var testLayer = optimized
                testLayer.swapAt(i, i + 1)
                
                // Count crossings with current and test arrangements
                let currentCrossings: Int
                let testCrossings: Int
                
                if direction == .forward {
                    // Comparing layer with next layer (adjacentLayer is previous in forward pass)
                    currentCrossings = countCrossingsBetweenLayers(
                        layer1: adjacentLayer,
                        layer2: optimized,
                        edges: edges
                    )
                    testCrossings = countCrossingsBetweenLayers(
                        layer1: adjacentLayer,
                        layer2: testLayer,
                        edges: edges
                    )
                } else {
                    // Comparing layer with previous layer (adjacentLayer is next in backward pass)
                    currentCrossings = countCrossingsBetweenLayers(
                        layer1: optimized,
                        layer2: adjacentLayer,
                        edges: edges
                    )
                    testCrossings = countCrossingsBetweenLayers(
                        layer1: testLayer,
                        layer2: adjacentLayer,
                        edges: edges
                    )
                }
                
                // If swapping reduces crossings, keep the swap
                if testCrossings < currentCrossings {
                    optimized = testLayer
                    improved = true
                }
            }
        }
        
        return optimized
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
        // Calculate anchors first (at node edges)
        let anchors = calculateAnchors()
        
        // Then calculate routing between anchors
        let routedPath = calculateRoutedPath(from: anchors.from, to: anchors.to)

        ZStack {
            // Connection line with routing
            Path { path in
                path.move(to: anchors.from)
                
                if routedPath.count == 1 {
                    // Single control point - use Bezier curve (unobstructed path)
                    path.addQuadCurve(to: anchors.to, control: routedPath[0])
                } else if routedPath.count >= 2 {
                    // Multiple waypoints - use orthogonal segments with smooth corners
                    for (index, waypoint) in routedPath.enumerated() {
                        if index == 0 {
                            // First segment from start to first waypoint
                            path.addLine(to: waypoint)
                        } else {
                            // Subsequent segments with small arc transitions for smoothness
                            let prevPoint = routedPath[index - 1]
                            let arcRadius: CGFloat = 8
                            
                            // Calculate corner points for smooth transition
                            let dx = waypoint.x - prevPoint.x
                            let dy = waypoint.y - prevPoint.y
                            let distance = sqrt(dx * dx + dy * dy)
                            
                            if distance > arcRadius * 2 {
                                // Add small arc at corner
                                let normalizedX = dx / distance
                                let normalizedY = dy / distance
                                let cornerStart = CGPoint(
                                    x: prevPoint.x + normalizedX * arcRadius,
                                    y: prevPoint.y + normalizedY * arcRadius
                                )
                                path.addLine(to: cornerStart)
                                path.addQuadCurve(to: waypoint, control: prevPoint)
                            } else {
                                // Distance too short for arc, use straight line
                                path.addLine(to: waypoint)
                            }
                        }
                    }
                    
                    // Final segment to destination
                    if let lastWaypoint = routedPath.last {
                        path.addLine(to: anchors.to)
                    }
                } else {
                    // No waypoints - straight line
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
        
        // Special handling for vertically aligned nodes with obstacles in between
        let alignmentTolerance: CGFloat = 5
        if abs(deltaX) < alignmentTolerance && abs(deltaY) > nodeHeight * 2 {
            // Vertically aligned with significant distance - check for obstacles
            let obstacles = allNodePositions.filter { nodeId, pos in
                nodeId != edge.from && nodeId != edge.to &&
                abs(pos.x - from.x) < nodeWidth &&  // Within column
                ((from.y < to.y && pos.y > from.y && pos.y < to.y) || // Between nodes (downward)
                 (from.y > to.y && pos.y < from.y && pos.y > to.y))   // Between nodes (upward)
            }
            
            // If obstacles detected, use left/right routing
            if !obstacles.isEmpty {
                // Route around left side
                let fromAnchor = CGPoint(x: from.x - nodeWidth / 2, y: from.y)
                let toAnchor = CGPoint(x: to.x - nodeWidth / 2, y: to.y)
                return (fromAnchor, toAnchor)
            }
        }

        // Standard anchor calculation based on direction
        let fromAnchor = calculateExitPoint(
            center: from,
            shape: fromNode.shape,
            deltaX: deltaX,
            deltaY: deltaY
        )

        let toAnchor = calculateEntryPoint(
            center: to,
            shape: toNode.shape,
            deltaX: -deltaX,
            deltaY: -deltaY
        )

        return (fromAnchor, toAnchor)
    }

    private func calculateRoutedPath(from: CGPoint, to: CGPoint) -> [CGPoint] {
        // Get all intermediate nodes (exclude source and target)
        let obstacles = allNodePositions.filter { nodeId, _ in
            nodeId != edge.from && nodeId != edge.to
        }
        
        // Special case: If nodes are vertically or horizontally aligned AND path is clear, use straight path
        let dx = abs(to.x - from.x)
        let dy = abs(to.y - from.y)
        let alignmentTolerance: CGFloat = 5
        
        if dx < alignmentTolerance || dy < alignmentTolerance {
            // Check if path is clear
            let directPathClear = !pathIntersectsAnyObstacle(from: from, to: to, obstacles: obstacles)
            if directPathClear {
                // Aligned AND clear - use straight path
                return calculateSimpleBezierPath(from: from, to: to)
            } else {
                // Aligned but blocked - use offset routing to avoid flush-against-edge appearance
                if dx < alignmentTolerance {
                    // Vertically aligned (e.g., left edge to left edge)
                    // Route to the left, down, then back right
                    let offset: CGFloat = 30  // Offset to the left
                    let leftX = min(from.x, to.x) - offset
                    let waypoint1 = CGPoint(x: leftX, y: from.y)
                    let waypoint2 = CGPoint(x: leftX, y: to.y)
                    return [waypoint1, waypoint2]
                } else {
                    // Horizontally aligned - use orthogonal routing
                    return calculateOrthogonalRoutedPath(from: from, to: to, obstacles: obstacles)
                }
            }
        }
        
        // Check if direct path is clear
        let directPathClear = !pathIntersectsAnyObstacle(from: from, to: to, obstacles: obstacles)
        
        if directPathClear {
            // Use simple Bezier curve for clear paths
            return calculateSimpleBezierPath(from: from, to: to)
        }
        
        // Path blocked - use orthogonal routing with obstacle avoidance
        return calculateOrthogonalRoutedPath(from: from, to: to, obstacles: obstacles)
    }
    
    /// Simple Bezier curve for unobstructed paths
    private func calculateSimpleBezierPath(from: CGPoint, to: CGPoint) -> [CGPoint] {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = sqrt(dx * dx + dy * dy)
        
        // For perfectly aligned nodes (vertical or horizontal), use straight line (no control points)
        let alignmentTolerance: CGFloat = 5
        if abs(dx) < alignmentTolerance || abs(dy) < alignmentTolerance {
            // Straight line - return empty waypoints array (direct connection)
            return []
        }
        
        // For diagonal paths, use subtle Bezier curve
        let midX = (from.x + to.x) / 2
        let midY = (from.y + to.y) / 2
        let curveDepth = distance * 0.2
        
        // Perpendicular vector for visible curve
        let perpX = -dy / distance
        let perpY = dx / distance
        
        let controlPoint = CGPoint(
            x: midX + perpX * curveDepth,
            y: midY + perpY * curveDepth
        )
        
        return [controlPoint]
    }
    
    /// Orthogonal routing that avoids obstacles
    private func calculateOrthogonalRoutedPath(from: CGPoint, to: CGPoint, obstacles: [String: CGPoint]) -> [CGPoint] {
        let clearance: CGFloat = 20  // Minimum distance from node edges
        var waypoints: [CGPoint] = []
        
        // Determine primary direction
        let dx = to.x - from.x
        let dy = to.y - from.y
        let isVerticalPrimary = abs(dy) > abs(dx)
        
        if isVerticalPrimary {
            // Vertical-first routing: down/up then across
            waypoints = calculateVerticalFirstRoute(from: from, to: to, obstacles: obstacles, clearance: clearance)
        } else {
            // Horizontal-first routing: across then down/up
            waypoints = calculateHorizontalFirstRoute(from: from, to: to, obstacles: obstacles, clearance: clearance)
        }
        
        return waypoints
    }
    
    /// Calculate vertical-first orthogonal route
    private func calculateVerticalFirstRoute(from: CGPoint, to: CGPoint, obstacles: [String: CGPoint], clearance: CGFloat) -> [CGPoint] {
        let midY = (from.y + to.y) / 2
        
        // Try direct vertical-then-horizontal route
        var testPoint1 = CGPoint(x: from.x, y: midY)
        var testPoint2 = CGPoint(x: to.x, y: midY)
        
        // Check if this route intersects obstacles
        var needsDetour = false
        for (_, obstacleCenter) in obstacles {
            if lineIntersectsNodeBounds(from: from, to: testPoint1, nodeCenter: obstacleCenter) ||
               lineIntersectsNodeBounds(from: testPoint1, to: testPoint2, nodeCenter: obstacleCenter) ||
               lineIntersectsNodeBounds(from: testPoint2, to: to, nodeCenter: obstacleCenter) {
                needsDetour = true
                break
            }
        }
        
        if !needsDetour {
            return [testPoint1, testPoint2]
        }
        
        // Need to route around obstacles - find clear horizontal channel
        var clearY = midY
        let step: CGFloat = 30
        var attempts = 0
        let maxAttempts = 20
        
        while needsDetour && attempts < maxAttempts {
            attempts += 1
            // Try offset above/below
            let offset = step * CGFloat((attempts + 1) / 2) * (attempts % 2 == 0 ? 1 : -1)
            clearY = midY + offset
            
            testPoint1 = CGPoint(x: from.x, y: clearY)
            testPoint2 = CGPoint(x: to.x, y: clearY)
            
            needsDetour = false
            for (_, obstacleCenter) in obstacles {
                if lineIntersectsNodeBounds(from: from, to: testPoint1, nodeCenter: obstacleCenter) ||
                   lineIntersectsNodeBounds(from: testPoint1, to: testPoint2, nodeCenter: obstacleCenter) ||
                   lineIntersectsNodeBounds(from: testPoint2, to: to, nodeCenter: obstacleCenter) {
                    needsDetour = true
                    break
                }
            }
        }
        
        return [testPoint1, testPoint2]
    }
    
    /// Calculate horizontal-first orthogonal route
    private func calculateHorizontalFirstRoute(from: CGPoint, to: CGPoint, obstacles: [String: CGPoint], clearance: CGFloat) -> [CGPoint] {
        let midX = (from.x + to.x) / 2
        
        // Try direct horizontal-then-vertical route
        var testPoint1 = CGPoint(x: midX, y: from.y)
        var testPoint2 = CGPoint(x: midX, y: to.y)
        
        // Check if this route intersects obstacles
        var needsDetour = false
        for (_, obstacleCenter) in obstacles {
            if lineIntersectsNodeBounds(from: from, to: testPoint1, nodeCenter: obstacleCenter) ||
               lineIntersectsNodeBounds(from: testPoint1, to: testPoint2, nodeCenter: obstacleCenter) ||
               lineIntersectsNodeBounds(from: testPoint2, to: to, nodeCenter: obstacleCenter) {
                needsDetour = true
                break
            }
        }
        
        if !needsDetour {
            return [testPoint1, testPoint2]
        }
        
        // Need to route around obstacles - find clear vertical channel
        var clearX = midX
        let step: CGFloat = 30
        var attempts = 0
        let maxAttempts = 20
        
        while needsDetour && attempts < maxAttempts {
            attempts += 1
            // Try offset left/right
            let offset = step * CGFloat((attempts + 1) / 2) * (attempts % 2 == 0 ? 1 : -1)
            clearX = midX + offset
            
            testPoint1 = CGPoint(x: clearX, y: from.y)
            testPoint2 = CGPoint(x: clearX, y: to.y)
            
            needsDetour = false
            for (_, obstacleCenter) in obstacles {
                if lineIntersectsNodeBounds(from: from, to: testPoint1, nodeCenter: obstacleCenter) ||
                   lineIntersectsNodeBounds(from: testPoint1, to: testPoint2, nodeCenter: obstacleCenter) ||
                   lineIntersectsNodeBounds(from: testPoint2, to: to, nodeCenter: obstacleCenter) {
                    needsDetour = true
                    break
                }
            }
        }
        
        return [testPoint1, testPoint2]
    }
    
    /// Check if a path from->to intersects any obstacle
    private func pathIntersectsAnyObstacle(from: CGPoint, to: CGPoint, obstacles: [String: CGPoint]) -> Bool {
        for (_, obstacleCenter) in obstacles {
            if lineIntersectsNodeBounds(from: from, to: to, nodeCenter: obstacleCenter) {
                return true
            }
        }
        return false
    }

    /// Check if a line segment intersects with a node's bounding box using proper geometric test
    private func lineIntersectsNodeBounds(from: CGPoint, to: CGPoint, nodeCenter: CGPoint) -> Bool {
        let halfWidth = nodeWidth / 2
        let halfHeight = nodeHeight / 2

        // Node bounding box with slight padding
        let padding: CGFloat = 5
        let nodeLeft = nodeCenter.x - halfWidth - padding
        let nodeRight = nodeCenter.x + halfWidth + padding
        let nodeTop = nodeCenter.y - halfHeight - padding
        let nodeBottom = nodeCenter.y + halfHeight + padding

        // Quick rejection test: if both endpoints are on same side of box, no intersection
        if (from.x < nodeLeft && to.x < nodeLeft) || (from.x > nodeRight && to.x > nodeRight) {
            return false
        }
        if (from.y < nodeTop && to.y < nodeTop) || (from.y > nodeBottom && to.y > nodeBottom) {
            return false
        }

        // Line segment parameters: P = from + t * (to - from), where 0 ≤ t ≤ 1
        // Check if line segment crosses the rectangle
        
        // Check intersection with each edge of the rectangle
        let lineSegments: [(CGPoint, CGPoint)] = [
            (CGPoint(x: nodeLeft, y: nodeTop), CGPoint(x: nodeRight, y: nodeTop)),      // Top edge
            (CGPoint(x: nodeRight, y: nodeTop), CGPoint(x: nodeRight, y: nodeBottom)),  // Right edge
            (CGPoint(x: nodeLeft, y: nodeBottom), CGPoint(x: nodeRight, y: nodeBottom)), // Bottom edge
            (CGPoint(x: nodeLeft, y: nodeTop), CGPoint(x: nodeLeft, y: nodeBottom))     // Left edge
        ]
        
        for segment in lineSegments {
            if lineSegmentsIntersect(p1: from, q1: to, p2: segment.0, q2: segment.1) {
                return true
            }
        }
        
        // Also check if either endpoint is inside the box
        if from.x >= nodeLeft && from.x <= nodeRight && from.y >= nodeTop && from.y <= nodeBottom {
            return true
        }
        if to.x >= nodeLeft && to.x <= nodeRight && to.y >= nodeTop && to.y <= nodeBottom {
            return true
        }
        
        return false
    }
    
    /// Test if two line segments intersect
    private func lineSegmentsIntersect(p1: CGPoint, q1: CGPoint, p2: CGPoint, q2: CGPoint) -> Bool {
        func orientation(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Int {
            let val = (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
            if val == 0 { return 0 }  // Collinear
            return val > 0 ? 1 : 2    // Clockwise or Counterclockwise
        }
        
        func onSegment(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Bool {
            return q.x <= max(p.x, r.x) && q.x >= min(p.x, r.x) &&
                   q.y <= max(p.y, r.y) && q.y >= min(p.y, r.y)
        }
        
        let o1 = orientation(p1, q1, p2)
        let o2 = orientation(p1, q1, q2)
        let o3 = orientation(p2, q2, p1)
        let o4 = orientation(p2, q2, q1)
        
        // General case
        if o1 != o2 && o3 != o4 { return true }
        
        // Special cases for collinear points
        if o1 == 0 && onSegment(p1, p2, q1) { return true }
        if o2 == 0 && onSegment(p1, q2, q1) { return true }
        if o3 == 0 && onSegment(p2, p1, q2) { return true }
        if o4 == 0 && onSegment(p2, q1, q2) { return true }
        
        return false
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
        let arrowLength: CGFloat = 15  // Increased from 10 for better visibility
        let arrowAngle: CGFloat = .pi / 6

        var path = Path()
        path.move(to: at)
        path.addLine(to: CGPoint(
            x: at.x - arrowLength * cos(angle - arrowAngle),
            y: at.y - arrowLength * sin(angle - arrowAngle)
        ))
        path.addLine(to: CGPoint(
            x: at.x - arrowLength * cos(angle + arrowAngle),
            y: at.y - arrowLength * sin(angle + arrowAngle)
        ))
        path.closeSubpath()  // Close the triangle to make it fillable

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
