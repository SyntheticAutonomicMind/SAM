// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import AppKit
import PDFKit
import ConfigurationSystem
import ConversationEngine
import Logging

/// Service for printing conversations via PDF generation
public class PrintService {
    private static let logger = Logger(label: "com.sam.documents.PrintService")

    /// Print a full conversation by generating PDF first, then printing
    @MainActor
    public static func printConversation(
        conversation: ConversationModel,
        messages: [EnhancedMessage]? = nil
    ) {
        let messagesToPrint = messages ?? conversation.messages
        logger.info("Printing conversation via PDF: \(conversation.title), \(messagesToPrint.count) messages")

        Task {
            do {
                let exporter = ConversationPDFExporter()
                let pdfURL = try await exporter.generatePDF(conversation: conversation, messages: messagesToPrint)

                await MainActor.run {
                    guard let pdfDoc = PDFDocument(url: pdfURL) else {
                        logger.error("Failed to load PDF")
                        showError("Failed to load generated PDF")
                        return
                    }

                    logger.info("Generated PDF for printing: \(pdfURL.path), \(pdfDoc.pageCount) pages")

                    // Create print info - use minimal margins since PDF has its own
                    let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
                    printInfo.horizontalPagination = .automatic
                    printInfo.verticalPagination = .automatic
                    printInfo.orientation = .portrait
                    printInfo.topMargin = 0
                    printInfo.bottomMargin = 0
                    printInfo.leftMargin = 0
                    printInfo.rightMargin = 0
                    printInfo.isHorizontallyCentered = true
                    printInfo.isVerticallyCentered = true

                    // Get print operation from PDFDocument
                    guard let printOp = pdfDoc.printOperation(for: printInfo, scalingMode: .pageScaleNone, autoRotate: false) else {
                        logger.error("Failed to create print operation from PDF")
                        showError("Failed to create print operation")
                        return
                    }

                    // Configure and run the print operation with dialog
                    printOp.showsPrintPanel = true
                    printOp.showsProgressPanel = true

                    // Run the print operation
                    printOp.run()

                    // Clean up temp file after delay (longer delay for print spooling)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60.0) {
                        try? FileManager.default.removeItem(at: pdfURL)
                        logger.debug("Cleaned up temp PDF")
                    }
                }
            } catch {
                logger.error("Conversation print failed: \(error)")
                showError(error.localizedDescription)
            }
        }
    }

    /// Show error alert
    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Print Failed"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
}
