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

        // TOC
        let toc = PdfTOCParser.parse(document: document)

        // Detect scanned
        let isScannedOverall = PdfOCREngine.isScanned(document: document)

        // Cover
        let coverData: Data? = {
            guard let first = document.page(at: 0) else { return nil }
            let thumb = first.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox)
            guard let tiff = thumb.tiffRepresentation else { return nil }
            return NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [:])
        }()

        // Extract pages with auto OCR logic
        var pagesText: [(text: String, confidence: Double, isOCR: Bool)] = []
        pagesText.reserveCapacity(pageCount)

        for i in 0..<pageCount {
            guard let page = document.page(at: i) else { continue }
            let raw = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var finalText = raw
            var confidence = 1.0
            var isOCR = false

            let shouldOCR: Bool = {
                switch ocrMode {
                case .always: return true
                case .never: return false
                case .auto: return raw.count < ocrThreshold
                }
            }()

            if shouldOCR {
                if let ocr = PdfOCREngine.recognize(page: page), !ocr.text.isEmpty {
                    // Prefer OCR if it yields significantly more text
                    if ocr.text.count > raw.count * 2 || raw.count < ocrThreshold {
                        finalText = ocr.text
                        confidence = ocr.confidence
                        isOCR = true
                    }
                } else if raw.isEmpty {
                    // OCR failed but page is empty, keep empty to avoid breaking flow
                    finalText = ""
                    confidence = 0
                    isOCR = true
                }
            }

            let cleaned = PdfTextCleaner.clean(finalText)
            pagesText.append((cleaned, confidence, isOCR))
        }

        // Build chapters
        let chapters: [PdfChapter]
        if !toc.isEmpty {
            chapters = buildChaptersFromTOC(toc: toc, pagesText: pagesText, pageCount: pageCount)
        } else {
            chapters = buildChaptersHeuristic(pagesText: pagesText)
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

        return PdfBook(metadata: metadata, chapters: chapters, toc: toc, cover: coverData, fileURL: fileURL)
    }

    private func buildChaptersFromTOC(toc: [PdfTOCItem], pagesText: [(text:String, confidence:Double, isOCR:Bool)], pageCount: Int) -> [PdfChapter] {
        // Flatten TOC to sorted page indices
        var flat: [PdfTOCItem] = []
        func flatten(_ items: [PdfTOCItem]) { for it in items { flat.append(it); flatten(it.children) } }
        flatten(toc)
        let sorted = flat.sorted { $0.pageIndex < $1.pageIndex }

        var chapters: [PdfChapter] = []
        for (idx, item) in sorted.enumerated() {
            let start = max(0, min(item.pageIndex, pageCount-1))
            let end: Int
            if idx + 1 < sorted.count { end = max(start, min(sorted[idx+1].pageIndex - 1, pageCount-1)) }
            else { end = pageCount - 1 }

            let range = start...end
            let texts = range.compactMap { i in i < pagesText.count ? pagesText[i] : nil }
            let combined = texts.map { $0.text }.joined(separator: "\n\n")
            guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let avgConf = texts.isEmpty ? 1.0 : texts.map { $0.confidence }.reduce(0, +) / Double(texts.count)
            let isOCR = texts.contains { $0.isOCR }
            let html = PdfTextCleaner.htmlWrap(combined, title: item.title)
            chapters.append(PdfChapter(title: item.title, pageRange: range, order: idx, plainText: combined, htmlPreview: html, confidence: avgConf, isOCRSourced: isOCR))
        }
        if chapters.isEmpty { return buildChaptersHeuristic(pagesText: pagesText) }
        return chapters
    }

    private func buildChaptersHeuristic(pagesText: [(text:String, confidence:Double, isOCR:Bool)]) -> [PdfChapter] {
        // Simple heuristic: detect "Chapter" headings or split every 20 pages
        var chapterStarts: [(index:Int, title:String)] = []
        let chapterRegex = try? NSRegularExpression(pattern: "^(Chapter|CHAPTER|Part|PART)\\s+[\\dIVX]+.*$", options: [.anchorsMatchLines])

        for (i, page) in pagesText.enumerated() {
            let firstLines = page.text.components(separatedBy: .newlines).prefix(4)
            for line in firstLines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.count > 5 && trimmed.count < 120 {
                    if let regex = chapterRegex, regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                        chapterStarts.append((i, trimmed))
                        break
                    }
                }
            }
        }

        if chapterStarts.isEmpty {
            // Fallback: chunk every 25 pages as a chapter
            var chapters: [PdfChapter] = []
            let chunkSize = 25
            var order = 0
            for start in stride(from: 0, to: pagesText.count, by: chunkSize) {
                let end = min(start + chunkSize - 1, pagesText.count - 1)
                let slice = pagesText[start...end]
                let combined = slice.map { $0.text }.joined(separator: "\n\n")
                guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let conf = slice.map { $0.confidence }.reduce(0, +) / Double(slice.count)
                let isOCR = slice.contains { $0.isOCR }
                let title = order == 0 ? "Beginning" : "Section \(order+1)"
                let html = PdfTextCleaner.htmlWrap(combined, title: title)
                chapters.append(PdfChapter(title: title, pageRange: start...end, order: order, plainText: combined, htmlPreview: html, confidence: conf, isOCRSourced: isOCR))
                order += 1
            }
            if chapters.isEmpty {
                // Single chapter whole book
                let all = pagesText.map { $0.text }.joined(separator: "\n\n")
                let conf = pagesText.isEmpty ? 1.0 : pagesText.map { $0.confidence }.reduce(0, +) / Double(pagesText.count)
                let isOCR = pagesText.contains { $0.isOCR }
                let html = PdfTextCleaner.htmlWrap(all, title: "Full Text")
                return [PdfChapter(title: "Full Text", pageRange: 0...max(0, pagesText.count-1), order: 0, plainText: all, htmlPreview: html, confidence: conf, isOCRSourced: isOCR)]
            }
            return chapters
        } else {
            var chapters: [PdfChapter] = []
            for (idx, start) in chapterStarts.enumerated() {
                let startIdx = start.index
                let endIdx = idx + 1 < chapterStarts.count ? chapterStarts[idx+1].index - 1 : pagesText.count - 1
                guard startIdx <= endIdx else { continue }
                let slice = pagesText[startIdx...endIdx]
                let combined = slice.map { $0.text }.joined(separator: "\n\n")
                let conf = slice.map { $0.confidence }.reduce(0, +) / Double(slice.count)
                let isOCR = slice.contains { $0.isOCR }
                let html = PdfTextCleaner.htmlWrap(combined, title: start.title)
                chapters.append(PdfChapter(title: start.title, pageRange: startIdx...endIdx, order: idx, plainText: combined, htmlPreview: html, confidence: conf, isOCRSourced: isOCR))
            }
            return chapters
        }
    }
}

private extension String {
    var nonEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
