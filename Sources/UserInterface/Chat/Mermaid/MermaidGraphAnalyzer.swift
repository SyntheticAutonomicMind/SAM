// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import CoreGraphics
import Logging

/// Analyzes Mermaid flowchart complexity to determine optimal layout parameters
struct MermaidGraphAnalyzer {
    private static let logger = Logger(label: "com.sam.mermaid.analyzer")
    
    /// Metrics describing flowchart complexity
    struct DiagramMetrics {
        let nodeCount: Int
        let edgeCount: Int
        let layerCount: Int
        let maxNodesPerLayer: Int
        let avgNodesPerLayer: Double
        let edgeDensity: Double  // edges per node
        let complexity: ComplexityLevel
        
        /// Complexity classification based on multiple factors
        enum ComplexityLevel: String {
            case simple     // ≤10 nodes, low density
            case moderate   // 11-25 nodes, or higher density
            case complex    // >25 nodes or very high density
            
            var description: String {
                switch self {
                case .simple: return "Simple (≤10 nodes)"
                case .moderate: return "Moderate (11-25 nodes)"
                case .complex: return "Complex (>25 nodes)"
                }
            }
        }
        
        /// Calculate complexity level from metrics
        static func determineComplexity(
            nodeCount: Int,
            edgeCount: Int,
            layerCount: Int,
            maxNodesPerLayer: Int
        ) -> ComplexityLevel {
            let edgeDensity = nodeCount > 0 ? Double(edgeCount) / Double(nodeCount) : 0
            
            // Complex if:
            // - More than 25 nodes
            // - High edge density (>2.0 edges per node)
            // - Wide layers (>8 nodes in a layer)
            if nodeCount > 25 || edgeDensity > 2.0 || maxNodesPerLayer > 8 {
                return .complex
            }
            
            // Moderate if:
            // - 11-25 nodes
            // - Medium edge density (>1.5)
            // - Multiple layers with moderate width
            if nodeCount > 10 || edgeDensity > 1.5 || (layerCount > 3 && maxNodesPerLayer > 4) {
                return .moderate
            }
            
            // Otherwise simple
            return .simple
        }
    }
    
    /// Analyze a flowchart and calculate complexity metrics
    static func analyze(flowchart: Flowchart) -> DiagramMetrics {
        let nodeCount = flowchart.nodes.count
        let edgeCount = flowchart.edges.count
        
        // Calculate layers using same algorithm as FlowchartRenderer
        let layers = calculateLayers(for: flowchart)
        let layerCount = layers.count
        let maxNodesPerLayer = layers.map { $0.count }.max() ?? 1
        let avgNodesPerLayer = layerCount > 0 ? Double(nodeCount) / Double(layerCount) : 0
        let edgeDensity = nodeCount > 0 ? Double(edgeCount) / Double(nodeCount) : 0
        
        let complexity = DiagramMetrics.determineComplexity(
            nodeCount: nodeCount,
            edgeCount: edgeCount,
            layerCount: layerCount,
            maxNodesPerLayer: maxNodesPerLayer
        )
        
        let metrics = DiagramMetrics(
            nodeCount: nodeCount,
            edgeCount: edgeCount,
            layerCount: layerCount,
            maxNodesPerLayer: maxNodesPerLayer,
            avgNodesPerLayer: avgNodesPerLayer,
            edgeDensity: edgeDensity,
            complexity: complexity
        )
        
        logger.info("Flowchart analysis: nodes=\(nodeCount), edges=\(edgeCount), layers=\(layerCount), maxPerLayer=\(maxNodesPerLayer), density=\(String(format: "%.2f", edgeDensity)), complexity=\(complexity.rawValue)")
        
        return metrics
    }
    
    /// Calculate layer structure (simplified version of FlowchartRenderer's logic)
    private static func calculateLayers(for flowchart: Flowchart) -> [[String]] {
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
            layers.append(currentLayer.sorted())
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
        
        return layers
    }
}

/// Configuration for node sizing and spacing based on complexity
struct SpacingConfiguration {
    let nodeWidth: CGFloat
    let nodeHeight: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    
    /// Calculate optimal spacing configuration dynamically based on available width
    static func calculateDynamic(for metrics: MermaidGraphAnalyzer.DiagramMetrics, targetWidth: CGFloat) -> SpacingConfiguration {
        // For vertical (TD/TB) layouts, nodes are arranged horizontally within layers
        // Width needed = (nodeWidth × maxNodesPerLayer) + (spacing × (maxNodesPerLayer - 1))
        // Solve for nodeWidth: nodeWidth = (targetWidth - spacing × (n-1)) / n
        
        let maxNodes = CGFloat(max(1, metrics.maxNodesPerLayer))
        
        // Calculate spacing and node width to fill targetWidth
        var horizontalSpacing: CGFloat
        var nodeWidth: CGFloat
        
        if maxNodes <= 2 {
            // Wide nodes for small layers - use 12% spacing
            horizontalSpacing = targetWidth * 0.12
            nodeWidth = (targetWidth - horizontalSpacing * (maxNodes - 1)) / maxNodes
        } else if maxNodes <= 4 {
            // Medium nodes - use 10% spacing
            horizontalSpacing = targetWidth * 0.10
            nodeWidth = (targetWidth - horizontalSpacing * (maxNodes - 1)) / maxNodes
        } else if maxNodes <= 7 {
            // Narrower nodes for wider layers - use 8% spacing
            horizontalSpacing = targetWidth * 0.08
            nodeWidth = (targetWidth - horizontalSpacing * (maxNodes - 1)) / maxNodes
        } else {
            // Very narrow for extremely wide layers - use 6% spacing
            horizontalSpacing = targetWidth * 0.06
            nodeWidth = (targetWidth - horizontalSpacing * (maxNodes - 1)) / maxNodes
        }
        
        // Ensure minimum readable width (but don't cap maximum)
        nodeWidth = max(nodeWidth, 120)
        
        // Height based on complexity - taller for readability
        let nodeHeight: CGFloat = 70
        
        // Vertical spacing based on layer count
        let verticalSpacing: CGFloat = metrics.layerCount > 5 ? 60 : 70
        
        return SpacingConfiguration(
            nodeWidth: nodeWidth,
            nodeHeight: nodeHeight,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        )
    }
    
    /// Calculate optimal spacing configuration for diagram metrics (legacy - uses fixed 650px)
    static func calculate(for metrics: MermaidGraphAnalyzer.DiagramMetrics) -> SpacingConfiguration {
        return calculateDynamic(for: metrics, targetWidth: 650)
    }
    
    /// Create default configuration (moderate complexity)
    static var `default`: SpacingConfiguration {
        SpacingConfiguration(
            nodeWidth: 180,
            nodeHeight: 60,
            horizontalSpacing: 100,
            verticalSpacing: 80
        )
    }
}
