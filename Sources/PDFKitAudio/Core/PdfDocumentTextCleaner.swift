import Foundation

enum PdfDocumentTextCleaner {
    private enum EdgeSide: Hashable {
        case top
        case bottom
    }

    private struct EdgeCandidate: Hashable {
        let pageOffset: Int
        let pageIndex: Int
        let lineIndex: Int
        let side: EdgeSide
        let text: String
        let normalized: String
    }

    private struct RepetitionKey: Hashable {
        let side: EdgeSide
        let normalized: String
    }

    private struct SequenceKey: Hashable {
        let side: EdgeSide
        let template: String
        let offset: Int
    }

    private struct NumberPattern {
        let number: Int
        let template: String
        let isPurePagination: Bool
    }

    static func clean(
        _ pages: [PdfPageContent],
        configuration: PdfCleanupConfiguration
    ) -> [PdfPageContent] {
        guard !pages.isEmpty,
              configuration.removesRepeatedHeadersAndFooters
                || configuration.removesSequentialPageNumbers else {
            return pages
        }

        let candidates = edgeCandidates(from: pages)
        var removals: [Int: Set<Int>] = [:]

        if configuration.removesRepeatedHeadersAndFooters {
            collectRepeatedRunningMatter(
                candidates: candidates,
                pageCount: pages.count,
                removals: &removals
            )
        }

        if configuration.removesSequentialPageNumbers {
            collectSequentialPagination(
                candidates: candidates,
                pageCount: pages.count,
                removals: &removals
            )
        }

        guard !removals.isEmpty else { return pages }

        return pages.enumerated().map { pageOffset, page in
            guard let lineIndexes = removals[pageOffset], !lineIndexes.isEmpty else {
                return page
            }

            let lines = page.text.components(separatedBy: "\n")
            let remaining = lines.enumerated().compactMap { index, line in
                lineIndexes.contains(index) ? nil : line
            }
            let cleaned = PdfTextCleaner.finalizeWhitespace(remaining.joined(separator: "\n"))

            return PdfPageContent(
                pageIndex: page.pageIndex,
                nativeText: page.nativeText,
                text: cleaned,
                extractionSource: cleaned.isEmpty ? .empty : page.extractionSource,
                confidence: cleaned.isEmpty ? 0 : page.confidence
            )
        }
    }

    private static func edgeCandidates(from pages: [PdfPageContent]) -> [EdgeCandidate] {
        var result: [EdgeCandidate] = []

        for (pageOffset, page) in pages.enumerated() {
            let lines = page.text.components(separatedBy: "\n")
            let nonEmptyIndexes = lines.indices.filter {
                !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !nonEmptyIndexes.isEmpty else { continue }

            for lineIndex in nonEmptyIndexes.prefix(2) {
                if let candidate = makeCandidate(
                    pageOffset: pageOffset,
                    pageIndex: page.pageIndex,
                    lineIndex: lineIndex,
                    side: .top,
                    line: lines[lineIndex]
                ) {
                    result.append(candidate)
                }
            }

            for lineIndex in nonEmptyIndexes.suffix(2) {
                if let candidate = makeCandidate(
                    pageOffset: pageOffset,
                    pageIndex: page.pageIndex,
                    lineIndex: lineIndex,
                    side: .bottom,
                    line: lines[lineIndex]
                ) {
                    result.append(candidate)
                }
            }
        }

        return result
    }

    private static func makeCandidate(
        pageOffset: Int,
        pageIndex: Int,
        lineIndex: Int,
        side: EdgeSide,
        line: String
    ) -> EdgeCandidate? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 100,
              trimmed.split(whereSeparator: \.isWhitespace).count <= 14 else {
            return nil
        }

        return EdgeCandidate(
            pageOffset: pageOffset,
            pageIndex: pageIndex,
            lineIndex: lineIndex,
            side: side,
            text: trimmed,
            normalized: normalizeForComparison(trimmed)
        )
    }

    private static func collectRepeatedRunningMatter(
        candidates: [EdgeCandidate],
        pageCount: Int,
        removals: inout [Int: Set<Int>]
    ) {
        // Three-page documents are too small for repeated-edge statistics to be
        // trustworthy. Sequential pagination has its own stronger detector.
        guard pageCount >= 4 else { return }
        let required = requiredOccurrences(pageCount: pageCount)

        let eligible = candidates.filter { candidate in
            candidate.text.contains(where: \.isLetter)
                && pageNumberPattern(for: candidate.text) == nil
        }
        let grouped = Dictionary(grouping: eligible) {
            RepetitionKey(side: $0.side, normalized: $0.normalized)
        }

        for group in grouped.values {
            let uniquePages = Set(group.map(\.pageOffset))
            guard uniquePages.count >= required else { continue }

            // Keep the first occurrence as a conservative semantic anchor. This
            // prevents a genuine chapter heading from disappearing everywhere
            // merely because later pages repeat it as running matter.
            let sorted = group.sorted {
                if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
                return $0.lineIndex < $1.lineIndex
            }
            for candidate in sorted.dropFirst() {
                removals[candidate.pageOffset, default: []].insert(candidate.lineIndex)
            }
        }
    }

    private static func collectSequentialPagination(
        candidates: [EdgeCandidate],
        pageCount: Int,
        removals: inout [Int: Set<Int>]
    ) {
        let patterned = candidates.compactMap { candidate -> (EdgeCandidate, NumberPattern)? in
            guard let pattern = pageNumberPattern(for: candidate.text) else { return nil }
            return (candidate, pattern)
        }
        let grouped = Dictionary(grouping: patterned) { pair in
            SequenceKey(
                side: pair.0.side,
                template: pair.1.template,
                offset: pair.1.number - pair.0.pageIndex
            )
        }

        for group in grouped.values {
            guard let firstPattern = group.first?.1 else { continue }
            let uniquePages = Set(group.map { $0.0.pageOffset })
            let required = firstPattern.isPurePagination
                ? min(3, max(2, pageCount))
                : requiredOccurrences(pageCount: pageCount)
            guard uniquePages.count >= required else { continue }

            let sorted = group.sorted {
                if $0.0.pageIndex != $1.0.pageIndex { return $0.0.pageIndex < $1.0.pageIndex }
                return $0.0.lineIndex < $1.0.lineIndex
            }

            if firstPattern.isPurePagination {
                // A proven numeric pagination sequence is not semantic content.
                for pair in sorted {
                    removals[pair.0.pageOffset, default: []].insert(pair.0.lineIndex)
                }
            } else {
                // Decorated running matter such as `Some Book • 42` retains one
                // occurrence for the same conservative reason as exact headers.
                for pair in sorted.dropFirst() {
                    removals[pair.0.pageOffset, default: []].insert(pair.0.lineIndex)
                }
            }
        }
    }

    private static func pageNumberPattern(for text: String) -> NumberPattern? {
        let normalized = collapseSpaces(text).lowercased()

        if let match = firstMatch(of: purePageNumberRegex, in: normalized),
           let numberRange = Range(match.range(at: 1), in: normalized),
           let number = Int(normalized[numberRange]) {
            return NumberPattern(
                number: number,
                template: "page-number",
                isPurePagination: true
            )
        }

        if let match = firstMatch(of: decoratedTrailingNumberRegex, in: normalized),
           let prefixRange = Range(match.range(at: 1), in: normalized),
           let numberRange = Range(match.range(at: 2), in: normalized),
           let number = Int(normalized[numberRange]) {
            let prefix = normalizeForComparison(String(normalized[prefixRange]))
            guard prefix.contains(where: \.isLetter) else { return nil }
            return NumberPattern(
                number: number,
                template: prefix + "#",
                isPurePagination: false
            )
        }

        return nil
    }

    private static func firstMatch(
        of regex: NSRegularExpression,
        in text: String
    ) -> NSTextCheckingResult? {
        regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )
    }

    private static func requiredOccurrences(pageCount: Int) -> Int {
        max(3, Int(ceil(Double(pageCount) * 0.4)))
    }

    private static func normalizeForComparison(_ text: String) -> String {
        collapseSpaces(text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
    }

    private static func collapseSpaces(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    }

    private static let purePageNumberRegex = try! NSRegularExpression(
        pattern: #"^(?:page\s+)?([0-9]{1,5})(?:\s*(?:of|/)\s*[0-9]{1,5})?$"#,
        options: [.caseInsensitive]
    )

    private static let decoratedTrailingNumberRegex = try! NSRegularExpression(
        pattern: #"^(.+?[•·|—–-]\s*)([0-9]{1,5})$"#
    )
}
