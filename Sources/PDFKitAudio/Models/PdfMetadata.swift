import Foundation

public struct PdfMetadata: Sendable {
    public var title: String
    public var authors: [String]
    public var subject: String?
    public var keywords: [String]
    public var creator: String?
    public var producer: String?
    public var creationDate: Date?
    public var modificationDate: Date?
    public var pageCount: Int
    public var isScanned: Bool

    /// Detected document language when the parser actually has a reliable signal.
    /// `nil` means unknown; the package no longer pretends every PDF is English.
    public var detectedLanguage: String?

    public init(
        title: String = "Untitled",
        authors: [String] = [],
        subject: String? = nil,
        keywords: [String] = [],
        creator: String? = nil,
        producer: String? = nil,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        pageCount: Int = 0,
        isScanned: Bool = false,
        detectedLanguage: String? = nil
    ) {
        self.title = title
        self.authors = authors
        self.subject = subject
        self.keywords = keywords
        self.creator = creator
        self.producer = producer
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pageCount = pageCount
        self.isScanned = isScanned
        self.detectedLanguage = detectedLanguage
    }

    public var authorString: String {
        authors.isEmpty ? (creator ?? "Unknown") : authors.joined(separator: ", ")
    }
}

/// One navigation entry from the PDF outline.
///
/// Outline destinations are navigation metadata, not audiobook chapter boundaries.
/// `pageIndex` is optional because real PDFs can contain unresolved, malformed, or
/// non-page outline actions. Parsed items use deterministic outline-path IDs so
/// identity remains stable across repeated parses of the same document.
public struct PdfTOCItem: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var pageIndex: Int?
    public var level: Int
    public var children: [PdfTOCItem]

    public init(
        id: String? = nil,
        title: String,
        pageIndex: Int?,
        level: Int = 0,
        children: [PdfTOCItem] = []
    ) {
        self.title = title
        self.pageIndex = pageIndex
        self.level = level
        self.children = children

        if let id {
            self.id = id
        } else {
            // Manual construction remains deterministic. Parsed outline items use
            // stronger path-based IDs supplied by `PdfTOCParser`.
            let destination = pageIndex.map(String.init) ?? "unresolved"
            self.id = "manual:\(level):\(destination):\(title)"
        }
    }

    public var hasResolvedDestination: Bool { pageIndex != nil }
}
