// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import Logging
import UniformTypeIdentifiers

/// Full-window overlay for viewing Mermaid diagrams at full size with zoom and pan.
/// Opened by clicking a diagram in the chat. Re-renders at higher resolution for crisp detail.
@MainActor
struct DiagramZoomOverlay: View {
    let mermaidCode: String
    let initialImage: NSImage
    @Binding var isPresented: Bool

    @Environment(\.colorScheme) private var colorScheme

    private let logger = Logger(label: "com.sam.mermaid.zoom")

    @State private var hiResImage: NSImage?
    @State private var isRenderingHiRes = false
    @State private var zoomScale: CGFloat = 2.0
    @State private var lastZoomScale: CGFloat = 2.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minZoom: CGFloat = 0.5
    private let maxZoom: CGFloat = 5.0

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture {
                    close()
                }

            // Diagram content
            GeometryReader { geometry in
                let displayImage = hiResImage ?? initialImage
                let fittedSize = fittedImageSize(image: displayImage, in: geometry.size)

                ZStack {
                    Image(nsImage: displayImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: fittedSize.width, height: fittedSize.height)
                        .scaleEffect(zoomScale)
                        .offset(offset)
                        .gesture(dragGesture)
                        .gesture(magnifyGesture)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            .padding(40)

            // Controls overlay
            VStack {
                HStack {
                    Spacer()
                    controlBar
                }
                .padding(.top, 16)
                .padding(.trailing, 16)
                Spacer()
                zoomIndicator
                    .padding(.bottom, 16)
            }
        }
        .onAppear {
            renderHighResolution()
        }
        .onChange(of: colorScheme) { _, _ in
            renderHighResolution()
        }
        .onExitCommand {
            close()
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 8) {
            // Zoom controls
            Button(action: { zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(OverlayButtonStyle())
            .help("Zoom out")

            Button(action: { resetZoom() }) {
                Text(zoomPercentText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(minWidth: 48)
            }
            .buttonStyle(OverlayButtonStyle())
            .help("Reset zoom")

            Button(action: { zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(OverlayButtonStyle())
            .help("Zoom in")

            Divider()
                .frame(height: 20)
                .background(Color.white.opacity(0.3))

            // Export menu
            Menu {
                Button("Save as PNG") { saveDiagramAsPNG() }
                Button("Save as SVG") { saveDiagramAsSVG() }
                Divider()
                Button("Copy Mermaid Source") { copyMermaidSource() }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(OverlayButtonStyle())
            .help("Export diagram")

            Divider()
                .frame(height: 20)
                .background(Color.white.opacity(0.3))

            // Close
            Button(action: { close() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(OverlayButtonStyle())
            .help("Close (Esc)")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
    }

    private var zoomIndicator: some View {
        Group {
            if isRenderingHiRes {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Rendering high resolution...")
                        .font(.caption2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .cornerRadius(8)
            }
        }
    }

    private var zoomPercentText: String {
        let pct = Int(zoomScale * 100)
        return "\(pct)%"
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = lastZoomScale * value.magnification
                zoomScale = min(max(newScale, minZoom), maxZoom)
            }
            .onEnded { _ in
                lastZoomScale = zoomScale
            }
    }

    // MARK: - Zoom Actions

    private func zoomIn() {
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomScale = min(zoomScale * 1.25, maxZoom)
            lastZoomScale = zoomScale
        }
    }

    private func zoomOut() {
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomScale = max(zoomScale / 1.25, minZoom)
            lastZoomScale = zoomScale
        }
    }

    private let defaultZoom: CGFloat = 2.0

    private func resetZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomScale = defaultZoom
            lastZoomScale = defaultZoom
            offset = .zero
            lastOffset = .zero
        }
    }

    private func close() {
        isPresented = false
    }

    // MARK: - High-Resolution Rendering

    private func renderHighResolution() {
        guard !isRenderingHiRes else { return }
        isRenderingHiRes = true

        Task { @MainActor in
            let isDark = colorScheme == .dark
            let image = await MermaidWebRenderer.renderToImage(
                code: mermaidCode,
                width: 1400,
                isDarkMode: isDark
            )
            if let image = image {
                hiResImage = image
                logger.debug("Hi-res diagram rendered: \(image.size.width)x\(image.size.height)")
            }
            isRenderingHiRes = false
        }
    }

    // MARK: - Export

    private func saveDiagramAsPNG() {
        let imageToSave = hiResImage ?? initialImage
        guard let tiffData = imageToSave.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            logger.error("Failed to convert diagram to PNG data")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "diagram.png"
        savePanel.message = "Save diagram as PNG"

        let result = savePanel.runModal()
        if result == .OK, let url = savePanel.url {
            do {
                try pngData.write(to: url)
                logger.info("Saved PNG to \(url.path)")
                NSWorkspace.shared.open(url)
            } catch {
                logger.error("Failed to save PNG: \(error)")
            }
        }
    }

    private func saveDiagramAsSVG() {
        Task { @MainActor in
            let isDark = colorScheme == .dark
            guard let svgString = await MermaidWebRenderer.renderToSVG(
                code: mermaidCode,
                width: 1400,
                isDarkMode: isDark
            ) else {
                logger.error("Failed to render SVG")
                return
            }

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.svg]
            savePanel.nameFieldStringValue = "diagram.svg"
            savePanel.message = "Save diagram as SVG"

            let result = savePanel.runModal()
            if result == .OK, let url = savePanel.url {
                do {
                    try svgString.write(to: url, atomically: true, encoding: .utf8)
                    logger.info("Saved SVG to \(url.path)")
                    NSWorkspace.shared.open(url)
                } catch {
                    logger.error("Failed to save SVG: \(error)")
                }
            }
        }
    }

    private func copyMermaidSource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mermaidCode, forType: .string)
        logger.info("Copied Mermaid source to clipboard")
    }

    // MARK: - Layout Helpers

    private func fittedImageSize(image: NSImage, in containerSize: CGSize) -> CGSize {
        let imgW = image.size.width
        let imgH = image.size.height
        guard imgW > 0, imgH > 0 else { return CGSize(width: 300, height: 300) }

        let scaleX = containerSize.width / imgW
        let scaleY = containerSize.height / imgH
        let scale = min(scaleX, scaleY, 1.0)

        return CGSize(width: imgW * scale, height: imgH * scale)
    }
}

// MARK: - Overlay Button Style

private struct OverlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Color.white.opacity(0.3) : Color.white.opacity(0.15))
            )
            .contentShape(Rectangle())
    }
}
