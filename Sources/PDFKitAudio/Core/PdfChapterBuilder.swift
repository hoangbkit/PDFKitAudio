import Foundation

enum PdfChapterBuilder {
    static func build(toc: [PdfTOCItem], pages: [PdfPageContent]) -> [PdfChapter] {
        let canonicalPages = pages.sorted { $0.pageIndex < $1.pageIndex }
        guard !canonicalPages.isEmpty else { return [] }

        let tocChapters = buildFromTOC(toc: toc, pages: canonicalPages)
        if !tocChapters.isEmpty {
            return tocChapters
        }
        return buildHeuristic(pages: canonicalPages)
    }

    private struct BoundaryCandidate {
        let title: String
        let pageIndex: Int
        let level: Int
        let sourceOrder: Int
    }

    private static func buildFromTOC(
        toc: [PdfTOCItem],
        pages: [PdfPageContent]
    ) -> [PdfChapter] {
        guard !toc.isEmpty,
              let firstSourcePage = pages.first?.pageIndex,
              let lastSourcePage = pages.last?.pageIndex else {
            return []
        }

        let boundaries = selectAudiobookBoundaries(
            toc: toc,
            validPageRange: firstSourcePage...lastSourcePage
        )
        guard !boundaries.isEmpty else { return [] }

        var chapters: [PdfChapter] = []
        var nextOrder = 0

        if let firstBoundary = boundaries.first,
           firstBoundary.pageIndex > firstSourcePage {
            let frontMatterRange = firstSourcePage...(firstBoundary.pageIndex - 1)
            if let frontMatter = makeChapter(
                title: "Front Matter",
                range: frontMatterRange,
                order: nextOrder,
                pages: pages
            ) {
                chapters.append(frontMatter)
                nextOrder += 1
            }
        }

        for (index, boundary) in boundaries.enumerated() {
            let endPageIndex: Int
            if index + 1 < boundaries.count {
                endPageIndex = boundaries[index + 1].pageIndex - 1
            } else {
                endPageIndex = lastSourcePage
            }

            guard boundary.pageIndex <= endPageIndex else { continue }
            let range = boundary.pageIndex...endPageIndex
            if let chapter = makeChapter(
                title: boundary.title,
                range: range,
                order: nextOrder,
                pages: pages
            ) {
                chapters.append(chapter)
                nextOrder += 1
            }
        }

        return chapters
    }

    /// Picks one hierarchy level for audiobook boundaries instead of flattening
    /// the whole outline. This keeps navigation hierarchy intact while avoiding
    /// parent/child overlap and duplicate speech.
    private static func selectAudiobookBoundaries(
        toc: [PdfTOCItem],
        validPageRange: ClosedRange<Int>
    ) -> [BoundaryCandidate] {
        var flattened: [BoundaryCandidate] = []
        var sourceOrder = 0

        func walk(_ items: [PdfTOCItem]) {
            for item in items {
                if let pageIndex = item.pageIndex,
                   validPageRange.contains(pageIndex) {
                    flattened.append(BoundaryCandidate(
                        title: normalizedBoundaryTitle(item.title),
                        pageIndex: pageIndex,
                        level: item.level,
                        sourceOrder: sourceOrder
                    ))
                }
                sourceOrder += 1
                walk(item.children)
            }
        }
        walk(toc)

        guard !flattened.isEmpty else { return [] }

        let levels = Set(flattened.map(\.level)).sorted()
        let candidatesByLevel: [Int: [BoundaryCandidate]] = Dictionary(grouping: flattened, by: \.level)

        // First prefer a hierarchy level that is already monotonic in source
        // outline order and provides at least two distinct chapter starts.
        for level in levels {
            guard let candidates = candidatesByLevel[level],
                  distinctPageCount(candidates) >= 2,
                  isMonotonicByPage(candidates) else {
                continue
            }
            return normalizedBoundaries(candidates)
        }

        // If the source outline itself is malformed/backward, keep its navigation
        // order untouched but normalize audiobook boundaries into page order.
        for level in levels {
            guard let candidates = candidatesByLevel[level],
                  distinctPageCount(candidates) >= 2 else {
                continue
            }
            return normalizedBoundaries(candidates)
        }

        // A single resolved destination is still useful. Prefer the outermost
        // available level and preserve front matter around it.
        for level in levels {
            guard let candidates = candidatesByLevel[level], !candidates.isEmpty else { continue }
            return normalizedBoundaries(candidates)
        }

        return []
    }

    private static func normalizedBoundaries(
        _ candidates: [BoundaryCandidate]
    ) -> [BoundaryCandidate] {
        let sorted = candidates.sorted {
            if $0.pageIndex != $1.pageIndex {
                return $0.pageIndex < $1.pageIndex
            }
            if $0.level != $1.level {
                return $0.level < $1.level
            }
            return $0.sourceOrder < $1.sourceOrder
        }

        var seenPages = Set<Int>()
        var result: [BoundaryCandidate] = []
        result.reserveCapacity(sorted.count)
        for candidate in sorted where seenPages.insert(candidate.pageIndex).inserted {
            result.append(candidate)
        }
        return result
    }

    private static func distinctPageCount(_ candidates: [BoundaryCandidate]) -> Int {
        Set(candidates.map(\.pageIndex)).count
    }

    private static func isMonotonicByPage(_ candidates: [BoundaryCandidate]) -> Bool {
        let ordered = candidates.sorted { $0.sourceOrder < $1.sourceOrder }
        guard ordered.count > 1 else { return true }
        for pair in zip(ordered, ordered.dropFirst()) where pair.0.pageIndex > pair.1.pageIndex {
            return false
        }
        return true
    }

    private static func normalizedBoundaryTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    private static func buildHeuristic(pages: [PdfPageContent]) -> [PdfChapter] {
        guard let firstPage = pages.first, let lastPage = pages.last else { return [] }

        var chapterStarts: [(pageIndex: Int, title: String)] = []
        let headingRegex = try? NSRegularExpression(
            pattern: "^(?:(?:Chapter|Part|Book)\\s+(?:\\d+|[IVXLCDM]+)\\b.*|Prologue\\b.*|Epilogue\\b.*)$",
            options: [.caseInsensitive]
        )

        for page in pages where !page.text.isEmpty {
            for line in page.text.components(separatedBy: .newlines).prefix(4) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 4, trimmed.count < 120,
                      let headingRegex else {
                    continue
                }
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if headingRegex.firstMatch(in: trimmed, range: range) != nil {
                    chapterStarts.append((page.pageIndex, trimmed))
                    break
                }
            }
        }

        guard !chapterStarts.isEmpty else {
            return buildFallbackPageChunks(pages: pages)
        }

        var chapters: [PdfChapter] = []
        var nextOrder = 0

        if let firstStart = chapterStarts.first,
           firstStart.pageIndex > firstPage.pageIndex,
           let frontMatter = makeChapter(
                title: "Front Matter",
                range: firstPage.pageIndex...(firstStart.pageIndex - 1),
                order: nextOrder,
                pages: pages
           ) {
            chapters.append(frontMatter)
            nextOrder += 1
        }

        for (index, start) in chapterStarts.enumerated() {
            let endPageIndex = index + 1 < chapterStarts.count
                ? chapterStarts[index + 1].pageIndex - 1
                : lastPage.pageIndex
            guard start.pageIndex <= endPageIndex else { continue }

            if let chapter = makeChapter(
                title: start.title,
                range: start.pageIndex...endPageIndex,
                order: nextOrder,
                pages: pages
            ) {
                chapters.append(chapter)
                nextOrder += 1
            }
        }

        return chapters.isEmpty ? buildFallbackPageChunks(pages: pages) : chapters
    }

    private static func buildFallbackPageChunks(pages: [PdfPageContent]) -> [PdfChapter] {
        let chunkSize = 25
        var chapters: [PdfChapter] = []
        var order = 0

        for startOffset in stride(from: 0, to: pages.count, by: chunkSize) {
            let endOffset = min(startOffset + chunkSize, pages.count)
            let sourcePages = Array(pages[startOffset..<endOffset])
            guard let firstPage = sourcePages.first,
                  let lastPage = sourcePages.last else {
                continue
            }

            let title = order == 0 ? "Beginning" : "Section \(order + 1)"
            if let chapter = makeChapter(
                title: title,
                range: firstPage.pageIndex...lastPage.pageIndex,
                order: order,
                pages: sourcePages
            ) {
                chapters.append(chapter)
                order += 1
            }
        }

        if chapters.isEmpty,
           let firstPage = pages.first,
           let lastPage = pages.last {
            let allText = selectedText(from: pages)
            let html = PdfTextCleaner.htmlWrap(allText, title: "Full Text")
            return [PdfChapter(
                title: "Full Text",
                pageRange: firstPage.pageIndex...lastPage.pageIndex,
                order: 0,
                plainText: allText,
                htmlPreview: html,
                confidence: averageConfidence(of: pages),
                isOCRSourced: pages.contains { $0.isOCRSourced }
            )]
        }

        return chapters
    }

    private static func makeChapter(
        title: String,
        range: ClosedRange<Int>,
        order: Int,
        pages: [PdfPageContent]
    ) -> PdfChapter? {
        let sourcePages = pages.filter { range.contains($0.pageIndex) }
        guard !sourcePages.isEmpty else { return nil }

        let text = selectedText(from: sourcePages)
        guard !text.isEmpty else { return nil }

        return PdfChapter(
            title: title,
            pageRange: range,
            order: order,
            plainText: text,
            htmlPreview: PdfTextCleaner.htmlWrap(text, title: title),
            confidence: averageConfidence(of: sourcePages),
            isOCRSourced: sourcePages.contains { $0.isOCRSourced }
        )
    }

    private static func selectedText(from pages: [PdfPageContent]) -> String {
        pages
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private static func averageConfidence(of pages: [PdfPageContent]) -> Double {
        guard !pages.isEmpty else { return 1 }
        return pages.map(\.confidence).reduce(0, +) / Double(pages.count)
    }
}
