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
    public var detectedLanguage: String = "en"

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
        isScanned: Bool = false
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
    }

    public var authorString: String {
        authors.isEmpty ? (creator ?? "Unknown") : authors.joined(separator: ", ")
    }
}

public struct PdfTOCItem: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var pageIndex: Int
    public var level: Int
    public var children: [PdfTOCItem]

    public init(id: String = UUID().uuidString, title: String, pageIndex: Int, level: Int = 0, children: [PdfTOCItem] = []) {
        self.id = id
        self.title = title
        self.pageIndex = pageIndex
        self.level = level
        self.children = children
    }
}
