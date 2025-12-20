// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import AppKit

/// Comprehensive formatting metadata for document roundtrip preservation Stores original formatting information when importing documents Enables faithful recreation of documents when exporting.
public struct FormattingMetadata: Codable, @unchecked Sendable {
    /// Document-level styling.
    public var defaultFont: FontMetadata?
    public var defaultFontSize: Double?
    public var defaultTextColor: ColorMetadata?
    public var backgroundColor: ColorMetadata?
    public var pageSize: PageSizeMetadata?
    public var margins: MarginsMetadata?

    /// Paragraph and content styling.
    public var headingStyles: [Int: HeadingStyleMetadata]
    public var paragraphStyles: [String: ParagraphStyleMetadata]
    public var characterStyles: [String: CharacterStyleMetadata]

    /// Document structure metadata.
    public var hasTableOfContents: Bool
    public var hasTables: Bool
    public var hasImages: Bool
    public var hasCodeBlocks: Bool

    /// Mermaid diagram metadata.
    /// Maps Mermaid diagram code to exported image paths for embedding in documents
    public var mermaidDiagramPaths: [String: String]

    /// Original format information.
    public var sourceFormat: DocumentFormat
    public var preservedRawMetadata: [String: String]

    public init(
        defaultFont: FontMetadata? = nil,
        defaultFontSize: Double? = nil,
        defaultTextColor: ColorMetadata? = nil,
        backgroundColor: ColorMetadata? = nil,
        pageSize: PageSizeMetadata? = nil,
        margins: MarginsMetadata? = nil,
        headingStyles: [Int: HeadingStyleMetadata] = [:],
        paragraphStyles: [String: ParagraphStyleMetadata] = [:],
        characterStyles: [String: CharacterStyleMetadata] = [:],
        hasTableOfContents: Bool = false,
        hasTables: Bool = false,
        hasImages: Bool = false,
        hasCodeBlocks: Bool = false,
        mermaidDiagramPaths: [String: String] = [:],
        sourceFormat: DocumentFormat,
        preservedRawMetadata: [String: String] = [:]
    ) {
        self.defaultFont = defaultFont
        self.defaultFontSize = defaultFontSize
        self.defaultTextColor = defaultTextColor
        self.backgroundColor = backgroundColor
        self.pageSize = pageSize
        self.margins = margins
        self.headingStyles = headingStyles
        self.paragraphStyles = paragraphStyles
        self.characterStyles = characterStyles
        self.hasTableOfContents = hasTableOfContents
        self.hasTables = hasTables
        self.hasImages = hasImages
        self.hasCodeBlocks = hasCodeBlocks
        self.mermaidDiagramPaths = mermaidDiagramPaths
        self.sourceFormat = sourceFormat
        self.preservedRawMetadata = preservedRawMetadata
    }
}

// MARK: - Font Metadata

public struct FontMetadata: Codable {
    public var familyName: String
    public var weight: String?
    public var isItalic: Bool
    public var isMonospaced: Bool

    public init(familyName: String, weight: String? = nil, isItalic: Bool = false, isMonospaced: Bool = false) {
        self.familyName = familyName
        self.weight = weight
        self.isItalic = isItalic
        self.isMonospaced = isMonospaced
    }

    /// Create FontMetadata from NSFont.
    public static func from(_ font: NSFont) -> FontMetadata {
        return FontMetadata(
            familyName: font.familyName ?? "Helvetica",
            weight: font.fontDescriptor.object(forKey: .face) as? String,
            isItalic: font.fontDescriptor.symbolicTraits.contains(.italic),
            isMonospaced: font.isFixedPitch
        )
    }
}

// MARK: - Color Metadata

public struct ColorMetadata: Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Create ColorMetadata from NSColor.
    public static func from(_ color: NSColor) -> ColorMetadata {
        let rgbColor = color.usingColorSpace(.deviceRGB) ?? color
        return ColorMetadata(
            red: Double(rgbColor.redComponent),
            green: Double(rgbColor.greenComponent),
            blue: Double(rgbColor.blueComponent),
            alpha: Double(rgbColor.alphaComponent)
        )
    }

    /// Convert to NSColor.
    public func toNSColor() -> NSColor {
        return NSColor(
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }

    /// Convert to hex string for Word XML (e.g., "FF0000" for red) - Returns: 6-character hex string without # prefix.
    public func toHex() -> String {
        let r = Int(red * 255.0)
        let g = Int(green * 255.0)
        let b = Int(blue * 255.0)
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

// MARK: - Page Size Metadata

public struct PageSizeMetadata: Codable {
    public var width: Double
    public var height: Double
    public var unit: String

    public init(width: Double, height: Double, unit: String = "points") {
        self.width = width
        self.height = height
        self.unit = unit
    }

    /// Standard US Letter size.
    public static var letter: PageSizeMetadata {
        return PageSizeMetadata(width: 612, height: 792, unit: "points")
    }

    /// Standard A4 size.
    public static var a4: PageSizeMetadata {
        return PageSizeMetadata(width: 595, height: 842, unit: "points")
    }
}

// MARK: - Margins Metadata

public struct MarginsMetadata: Codable {
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double
    public var unit: String

    public init(top: Double, bottom: Double, left: Double, right: Double, unit: String = "points") {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
        self.unit = unit
    }

    /// Standard 1-inch margins.
    public static var standard: MarginsMetadata {
        return MarginsMetadata(top: 72, bottom: 72, left: 72, right: 72, unit: "points")
    }
}

// MARK: - Heading Style Metadata

public struct HeadingStyleMetadata: Codable {
    public var level: Int
    public var font: FontMetadata
    public var fontSize: Double
    public var textColor: ColorMetadata
    public var spacingBefore: Double
    public var spacingAfter: Double
    public var alignment: String

    public init(
        level: Int,
        font: FontMetadata,
        fontSize: Double,
        textColor: ColorMetadata,
        spacingBefore: Double = 0,
        spacingAfter: Double = 0,
        alignment: String = "left"
    ) {
        self.level = level
        self.font = font
        self.fontSize = fontSize
        self.textColor = textColor
        self.spacingBefore = spacingBefore
        self.spacingAfter = spacingAfter
        self.alignment = alignment
    }
}

// MARK: - Paragraph Style Metadata

public struct ParagraphStyleMetadata: Codable {
    public var name: String
    public var font: FontMetadata?
    public var fontSize: Double?
    public var textColor: ColorMetadata?
    public var alignment: String
    public var lineSpacing: Double?
    public var spacingBefore: Double
    public var spacingAfter: Double
    public var firstLineIndent: Double
    public var leftIndent: Double
    public var rightIndent: Double

    public init(
        name: String,
        font: FontMetadata? = nil,
        fontSize: Double? = nil,
        textColor: ColorMetadata? = nil,
        alignment: String = "left",
        lineSpacing: Double? = nil,
        spacingBefore: Double = 0,
        spacingAfter: Double = 0,
        firstLineIndent: Double = 0,
        leftIndent: Double = 0,
        rightIndent: Double = 0
    ) {
        self.name = name
        self.font = font
        self.fontSize = fontSize
        self.textColor = textColor
        self.alignment = alignment
        self.lineSpacing = lineSpacing
        self.spacingBefore = spacingBefore
        self.spacingAfter = spacingAfter
        self.firstLineIndent = firstLineIndent
        self.leftIndent = leftIndent
        self.rightIndent = rightIndent
    }
}

// MARK: - Character Style Metadata

public struct CharacterStyleMetadata: Codable {
    public var name: String
    public var font: FontMetadata?
    public var fontSize: Double?
    public var textColor: ColorMetadata?
    public var backgroundColor: ColorMetadata?
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderlined: Bool
    public var isStrikethrough: Bool

    public init(
        name: String,
        font: FontMetadata? = nil,
        fontSize: Double? = nil,
        textColor: ColorMetadata? = nil,
        backgroundColor: ColorMetadata? = nil,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        isStrikethrough: Bool = false
    ) {
        self.name = name
        self.font = font
        self.fontSize = fontSize
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.isStrikethrough = isStrikethrough
    }
}

// MARK: - Document Format Enum

public enum DocumentFormat: String, Codable, CaseIterable, Sendable {
    case pdf = "pdf"
    case docx = "docx"
    case pptx = "pptx"
    case markdown = "markdown"
    case rtf = "rtf"
    case txt = "txt"
    case html = "html"
    case xlsx = "xlsx"
    case unknown = "unknown"

    public var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .pptx: return "pptx"
        case .markdown: return "md"
        case .rtf: return "rtf"
        case .txt: return "txt"
        case .html: return "html"
        case .xlsx: return "xlsx"
        case .unknown: return "bin"
        }
    }
}

// MARK: - Helper Methods

extension FormattingMetadata {
    /// Create default metadata for a given document format.
    public static func defaultMetadata(for format: DocumentFormat) -> FormattingMetadata {
        let defaultFont = FontMetadata(familyName: "Helvetica", weight: "regular", isItalic: false, isMonospaced: false)
        let defaultColor = ColorMetadata(red: 0, green: 0, blue: 0, alpha: 1.0)

        /// Default heading styles.
        var headingStyles: [Int: HeadingStyleMetadata] = [:]
        headingStyles[1] = HeadingStyleMetadata(
            level: 1,
            font: FontMetadata(familyName: "Helvetica", weight: "bold"),
            fontSize: 24,
            textColor: defaultColor,
            spacingBefore: 12,
            spacingAfter: 6
        )
        headingStyles[2] = HeadingStyleMetadata(
            level: 2,
            font: FontMetadata(familyName: "Helvetica", weight: "bold"),
            fontSize: 18,
            textColor: defaultColor,
            spacingBefore: 10,
            spacingAfter: 5
        )
        headingStyles[3] = HeadingStyleMetadata(
            level: 3,
            font: FontMetadata(familyName: "Helvetica", weight: "bold"),
            fontSize: 14,
            textColor: defaultColor,
            spacingBefore: 8,
            spacingAfter: 4
        )

        return FormattingMetadata(
            defaultFont: defaultFont,
            defaultFontSize: 12,
            defaultTextColor: defaultColor,
            backgroundColor: ColorMetadata(red: 1, green: 1, blue: 1, alpha: 1.0),
            pageSize: .letter,
            margins: .standard,
            headingStyles: headingStyles,
            sourceFormat: format
        )
    }
}
