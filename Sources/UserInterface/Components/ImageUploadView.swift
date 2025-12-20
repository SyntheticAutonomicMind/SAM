// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import SwiftUI
import UniformTypeIdentifiers
import Logging

private let logger = Logger(label: "com.sam.imageupload")

/// Image upload component with drag-drop and file picker support for img2img
struct ImageUploadView: View {
    @Binding var imagePath: String?
    @State private var isHovering = false
    @State private var showingFilePicker = false

    var body: some View {
        VStack(spacing: 8) {
            if let path = imagePath, let image = NSImage(contentsOfFile: path) {
                /// Preview mode: Show image with remove button
                VStack(spacing: 4) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 200, maxHeight: 120)
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )

                    HStack(spacing: 4) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Button(action: {
                            imagePath = nil
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove image")
                    }
                }
            } else {
                /// Upload mode: Show drop zone
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [5])
                    )
                    .foregroundColor(isHovering ? .blue : .gray.opacity(0.5))
                    .frame(height: 80)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.title2)
                                .foregroundColor(isHovering ? .blue : .gray)
                            Text("Drop image or click to upload")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    )
                    .onTapGesture {
                        showingFilePicker = true
                    }
                    .onDrop(of: [.fileURL], isTargeted: $isHovering) { providers in
                        handleDrop(providers: providers)
                        return true
                    }
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.png, .jpeg, .heic, .bmp, .gif, .tiff],
            allowsMultipleSelection: false
        ) { result in
            handleFilePickerResult(result)
        }
    }

    /// Handle drag-and-drop
    private func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard error == nil,
                  let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  isValidImageFile(url) else {
                return
            }

            DispatchQueue.main.async {
                self.imagePath = url.path
            }
        }
    }

    /// Handle file picker result
    private func handleFilePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first,
                  isValidImageFile(url) else {
                return
            }
            imagePath = url.path

        case .failure(let error):
            logger.warning("File picker error: \(error.localizedDescription)")
        }
    }

    /// Validate image file
    private func isValidImageFile(_ url: URL) -> Bool {
        let validExtensions = ["png", "jpg", "jpeg", "heic", "bmp", "gif", "tiff", "tif"]
        let ext = url.pathExtension.lowercased()
        return validExtensions.contains(ext) && FileManager.default.fileExists(atPath: url.path)
    }
}
