import Foundation
import PDFKit
import AppKit

public enum OCROptions: Sendable {
    case auto      // trigger only when page has little/no extractable text
    case always    // force OCR every page (best quality for scanned)
    case never     // never OCR, digital PDFs only
}

public final class PdfParser: @unchecked Sendable {
    private let ocrMode: OCROptions
    private let ocrThreshold: Int // chars below which we trigger OCR in auto mode

    public init(ocrMode: OCROptions = .auto, ocrThreshold: Int = 60) {
        self.ocrMode = ocrMode
        self.ocrThreshold = ocrThreshold
    }

    public func parse(at url: URL) throws -> PdfBook {
        guard FileManager.default.fileExists(atPath: url.path) else { throw PdfError.fileNotFound }
        guard let doc = PDFDocument(url: url) else { throw PdfError.invalidPDF }
        return try parse(document: doc, fileURL: url)
    }

    public func parse(data: Data) throws -> PdfBook {
        guard let doc = PDFDocument(data: data) else { throw PdfError.invalidPDF }
        return try parse(document: doc, fileURL: nil)
    }

    private func parse(document: PDFDocument, fileURL: URL?) throws -> PdfBook {
        if document.isEncrypted || document.isLocked { throw PdfError.passwordProtected }

        let pageCount = document.pageCount
        let attrs = document.documentAttributes ?? [:]

        let title = (attrs[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        let authorString = attrs[PDFDocumentAttribute.authorAttribute] as? String
        let authors = authorString?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        let subject = attrs[PDFDocumentAttribute.subjectAttribute] as? String
        let creator = attrs[PDFDocumentAttribute.creatorAttribute] as? String
        let producer = attrs[PDFDocumentAttribute.producerAttribute] as? String
        let creationDate = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date
        let modDate = attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date
        let keywordsRaw = attrs[PDFDocumentAttribute.keywordsAttribute] as? String
        let keywords = keywordsRaw?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []

        let toc = PdfTOCParser.parse(document: document)
        let isScannedOverall = PdfOCREngine.isScanned(document: document)

        let coverData: Data? = {
            guard let first = document.page(at: 0) else { return nil }
            let thumb = first.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox)
            guard let tiff = thumb.tiffRepresentation else { return nil }
            return NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:])
        }()

        // Every source page produces exactly one page model. A missing PDFPage is
        // represented by an empty placeholder so downstream indexes never shift.
        var pages: [PdfPageContent] = []
        pages.reserveCapacity(pageCount)
        for pageIndex in 0..<pageCount {
            pages.append(extractPage(document.page(at: pageIndex), pageIndex: pageIndex))
        }

        let chapters: [PdfChapter]
        if !toc.isEmpty {
            chapters = buildChaptersFromTOC(toc: toc, pages: pages, pageCount: pageCount)
        } else {
            chapters = buildChaptersHeuristic(pages: pages)
        }

        let metadata = PdfMetadata(
            title: title,
            authors: authors,
            subject: subject,
            keywords: keywords,
            creator: creator,
            producer: producer,
            creationDate: creationDate,
            modificationDate: modDate,
            pageCount: pageCount,
            isScanned: isScannedOverall
        )

        return PdfBook(
            metadata: metadata,
            pages: pages,
            chapters: chapters,
            toc: toc,
            cover: coverData,
            fileURL: fileURL
        )
    }

    private func extractPage(_ page: PDFPage?, pageIndex: Int) -> PdfPageContent {
        guard let page else {
            return PdfPageContent(
                pageIndex: pageIndex,
                nativeText: "",
                text: "",
                extractionSource: .empty,
                confidence: 0
            )
        }

        let nativeText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var selectedText = nativeText
        var source: PdfExtractionSource = nativeText.isEmpty ? .empty : .native
        var confidence = nativeText.isEmpty ? 0.0 : 1.0

        if shouldRunOCR(nativeText: nativeText),
           let ocr = PdfOCREngine.recognize(page: page),
           !ocr.text.isEmpty,
           shouldPreferOCR(ocrText: ocr.text, nativeText: nativeText) {
            selectedText = ocr.text
            source = .ocr
            confidence = ocr.confidence
        }

        let cleanedText = PdfTextCleaner.clean(selectedText)
        if cleanedText.isEmpty {
            source = .empty
            confidence = 0
        }

        return PdfPageContent(
            pageIndex: pageIndex,
            nativeText: nativeText,
            text: cleanedText,
            extractionSource: source,
            confidence: confidence
        )
    }

    private func shouldRunOCR(nativeText: String) -> Bool {
        switch ocrMode {
        case .always:
            return true
        case .never:
            return false
        case .auto:
            return nativeText.count < ocrThreshold
        }
    }

    private func shouldPreferOCR(ocrText: String, nativeText: String) -> Bool {
        // Preserve the existing selection policy during Phase 1. Phase 3 will
        // make OCR selection richer and configurable.
        ocrText.count > nativeText.count * 2 || nativeText.count < ocrThreshold
    }

    private func buildChaptersFromTOC(
        toc: [PdfTOCItem],
        pages: [PdfPageContent],
        pageCount: Int
    ) -> [PdfChapter] {
        guard pageCount > 0 else { return [] }

        // Phase 2 will replace this flattening policy. Phase 1 only moves chapter
        // construction onto canonical page models while preserving behavior.
        var flat: [PdfTOCItem] = []
        func flatten(_ items: [PdfTOCItem]) {
            for item in items {
                flat.append(item)
                flatten(item.children)
            }
        }
        flatten(toc)
        let sorted = flat.sorted { $0.pageIndex < $1.pageIndex }

        var chapters: [PdfChapter] = []
        for (index, item) in sorted.enumerated() {
            let start = max(0, min(item.pageIndex, pageCount - 1))
            let end: Int
            if index + 1 < sorted.count {
                end = max(start, min(sorted[index + 1].pageIndex - 1, pageCount - 1))
            } else {
                end = pageCount - 1
            }

            let range = start...end
            let sourcePages = pagesInRange(range, from: pages)
            let combined = sourcePages.map(\.text).joined(separator: "\n\n")
            guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let averageConfidence = averageConfidence(of: sourcePages)
            let isOCR = sourcePages.contains(where: \.isOCRSourced)
            let html = PdfTextCleaner.htmlWrap(combined, title: item.title)

            chapters.append(PdfChapter(
                title: item.title,
                pageRange: range,
                order: index,
                plainText: combined,
                htmlPreview: html,
                confidence: averageConfidence,
                isOCRSourced: isOCR
            ))
        }

        if chapters.isEmpty {
            return buildChaptersHeuristic(pages: pages)
        }
        return chapters
    }

    private func buildChaptersHeuristic(pages: [PdfPageContent]) -> [PdfChapter] {
        guard !pages.isEmpty else { return [] }

        var chapterStarts: [(pageIndex: Int, title: String)] = []
        let chapterRegex = try? NSRegularExpression(
            pattern: "^(Chapter|CHAPTER|Part|PART)\\s+[\\dIVX]+.*$",
            options: [.anchorsMatchLines]
        )

        for page in pages {
            let firstLines = page.text.components(separatedBy: .newlines).prefix(4)
            for line in firstLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.count > 5 && trimmed.count < 120,
                   let regex = chapterRegex,
                   regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                    chapterStarts.append((page.pageIndex, trimmed))
                    break
                }
            }
        }

        if chapterStarts.isEmpty {
            return buildFallbackPageChunks(pages: pages)
        }

        var chapters: [PdfChapter] = []
        for (index, start) in chapterStarts.enumerated() {
            let endPageIndex = index + 1 < chapterStarts.count
                ? chapterStarts[index + 1].pageIndex - 1
                : pages.last!.pageIndex
            guard start.pageIndex <= endPageIndex else { continue }

            let range = start.pageIndex...endPageIndex
            let sourcePages = pagesInRange(range, from: pages)
            let combined = sourcePages.map(\.text).joined(separator: "\n\n")
            let html = PdfTextCleaner.htmlWrap(combined, title: start.title)

            chapters.append(PdfChapter(
                title: start.title,
                pageRange: range,
                order: index,
                plainText: combined,
                htmlPreview: html,
                confidence: averageConfidence(of: sourcePages),
                isOCRSourced: sourcePages.contains(where: \.isOCRSourced)
            ))
        }
        return chapters
    }

    private func buildFallbackPageChunks(pages: [PdfPageContent]) -> [PdfChapter] {
        let chunkSize = 25
        var chapters: [PdfChapter] = []
        var order = 0

        for startOffset in stride(from: 0, to: pages.count, by: chunkSize) {
            let endOffset = min(startOffset + chunkSize, pages.count)
            let sourcePages = Array(pages[startOffset..<endOffset])
            guard let firstPage = sourcePages.first, let lastPage = sourcePages.last else { continue }

            let combined = sourcePages.map(\.text).joined(separator: "\n\n")
            guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let title = order == 0 ? "Beginning" : "Section \(order + 1)"
            let html = PdfTextCleaner.htmlWrap(combined, title: title)
            chapters.append(PdfChapter(
                title: title,
                pageRange: firstPage.pageIndex...lastPage.pageIndex,
                order: order,
                plainText: combined,
                htmlPreview: html,
                confidence: averageConfidence(of: sourcePages),
                isOCRSourced: sourcePages.contains(where: \.isOCRSourced)
            ))
            order += 1
        }

        if chapters.isEmpty, let firstPage = pages.first, let lastPage = pages.last {
            let allText = pages.map(\.text).joined(separator: "\n\n")
            let html = PdfTextCleaner.htmlWrap(allText, title: "Full Text")
            return [PdfChapter(
                title: "Full Text",
                pageRange: firstPage.pageIndex...lastPage.pageIndex,
                order: 0,
                plainText: allText,
                htmlPreview: html,
                confidence: averageConfidence(of: pages),
                isOCRSourced: pages.contains(where: \.isOCRSourced)
            )]
        }

        return chapters
    }

    private func pagesInRange(
        _ range: ClosedRange<Int>,
        from pages: [PdfPageContent]
    ) -> [PdfPageContent] {
        pages.filter { range.contains($0.pageIndex) }
    }

    private func averageConfidence(of pages: [PdfPageContent]) -> Double {
        guard !pages.isEmpty else { return 1 }
        return pages.map(\.confidence).reduce(0, +) / Double(pages.count)
    }
}

private extension String {
    var nonEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
