import Foundation

enum PdfDocumentTextCleaner {
    private enum EdgeSide: Hashable {
        case top
        case bottom
    }

    private struct EdgeCandidate {
        let pageOffset: Int
        let pageIndex: Int
        let lineIndex: Int
        let side: EdgeSide
        let text: String
        let normalized: String
        let rect: CGRect?
        let role: PdfLayoutRole?
        let roleConfidence: Double
        let styleBucket: PdfDocumentLayoutStyleBucket?

        var hasGeometry: Bool { rect != nil }
    }

    private struct CandidateKey: Hashable {
        let pageOffset: Int
        let lineIndex: Int
        let side: EdgeSide
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
        configuration: PdfCleanupConfiguration,
        layoutFingerprints: [PdfDocumentLayoutFingerprint] = []
    ) -> [PdfPageContent] {
        guard !pages.isEmpty,
              configuration.removesRepeatedHeadersAndFooters
                || configuration.removesSequentialPageNumbers else {
            return pages
        }

        let candidates = edgeCandidates(
            from: pages,
            layoutFingerprints: layoutFingerprints
        )
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

        protectSemanticOccurrences(
            candidates: candidates,
            removals: &removals
        )

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

    private static func edgeCandidates(
        from pages: [PdfPageContent],
        layoutFingerprints: [PdfDocumentLayoutFingerprint]
    ) -> [EdgeCandidate] {
        var candidates: [EdgeCandidate] = []

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
                    candidates.append(candidate)
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
                    candidates.append(candidate)
                }
            }
        }

        if !layoutFingerprints.isEmpty {
            candidates.append(contentsOf: geometryCandidates(
                from: pages,
                fingerprints: layoutFingerprints
            ))
        }

        return deduplicated(candidates)
    }

    private static func geometryCandidates(
        from pages: [PdfPageContent],
        fingerprints: [PdfDocumentLayoutFingerprint]
    ) -> [EdgeCandidate] {
        let pageOffsets = Dictionary(uniqueKeysWithValues: pages.enumerated().map { ($0.element.pageIndex, $0.offset) })
        var result: [EdgeCandidate] = []

        for fingerprint in fingerprints.sorted(by: fingerprintOrder) {
            guard let pageOffset = pageOffsets[fingerprint.pageIndex],
                  let side = edgeSide(for: fingerprint.rect) else {
                continue
            }

            let page = pages[pageOffset]
            let lines = page.text.components(separatedBy: "\n")
            let fingerprintLines = fingerprint.text
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for fingerprintLine in fingerprintLines {
                guard isShortEdgeText(fingerprintLine),
                      let lineIndex = matchingLineIndex(
                        for: fingerprintLine,
                        in: lines,
                        side: side
                      ) else {
                    continue
                }

                result.append(EdgeCandidate(
                    pageOffset: pageOffset,
                    pageIndex: page.pageIndex,
                    lineIndex: lineIndex,
                    side: side,
                    text: fingerprintLine,
                    normalized: PdfDocumentTextSignature.normalize(fingerprintLine),
                    rect: fingerprint.rect,
                    role: fingerprint.role,
                    roleConfidence: fingerprint.roleConfidence,
                    styleBucket: fingerprint.styleBucket
                ))
            }
        }

        return result
    }

    private static func matchingLineIndex(
        for fingerprintLine: String,
        in pageLines: [String],
        side: EdgeSide
    ) -> Int? {
        let signature = PdfDocumentTextSignature.normalize(fingerprintLine)
        let matches = pageLines.indices.filter {
            PdfDocumentTextSignature.normalize(pageLines[$0]) == signature
        }
        switch side {
        case .top:
            return matches.first
        case .bottom:
            return matches.last
        }
    }

    private static func makeCandidate(
        pageOffset: Int,
        pageIndex: Int,
        lineIndex: Int,
        side: EdgeSide,
        line: String
    ) -> EdgeCandidate? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isShortEdgeText(trimmed) else { return nil }

        return EdgeCandidate(
            pageOffset: pageOffset,
            pageIndex: pageIndex,
            lineIndex: lineIndex,
            side: side,
            text: trimmed,
            normalized: PdfDocumentTextSignature.normalize(trimmed),
            rect: nil,
            role: nil,
            roleConfidence: 0,
            styleBucket: nil
        )
    }

    private static func deduplicated(_ candidates: [EdgeCandidate]) -> [EdgeCandidate] {
        var byKey: [CandidateKey: EdgeCandidate] = [:]
        for candidate in candidates {
            let key = CandidateKey(
                pageOffset: candidate.pageOffset,
                lineIndex: candidate.lineIndex,
                side: candidate.side,
                normalized: candidate.normalized
            )
            guard let existing = byKey[key] else {
                byKey[key] = candidate
                continue
            }

            if shouldPrefer(candidate, over: existing) {
                byKey[key] = candidate
            }
        }

        return byKey.values.sorted(by: stableCandidateOrder)
    }

    private static func shouldPrefer(_ lhs: EdgeCandidate, over rhs: EdgeCandidate) -> Bool {
        if lhs.hasGeometry != rhs.hasGeometry { return lhs.hasGeometry }
        if lhs.roleConfidence != rhs.roleConfidence { return lhs.roleConfidence > rhs.roleConfidence }
        return lhs.text < rhs.text
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

            let runningCandidates: [EdgeCandidate]
            let geometryPages = Set(group.filter(\.hasGeometry).map(\.pageOffset))
            if geometryPages.count >= required {
                guard let cluster = dominantGeometryCluster(
                    candidates: group,
                    requiredOccurrences: required
                ) else {
                    // Enough layout metadata exists to judge geometry, so a lack
                    // of a stable edge cluster is evidence against removal.
                    continue
                }
                runningCandidates = cluster
            } else {
                // Mixed analyzed/fast-path documents deliberately keep the
                // existing text-only behavior until enough geometry exists.
                runningCandidates = group
            }

            guard Set(runningCandidates.map(\.pageOffset)).count >= required else { continue }
            let sortedRunning = runningCandidates.sorted(by: stableCandidateOrder)

            if let semanticAnchor = semanticAnchor(in: group) {
                // A chapter heading or other confidently classified semantic
                // occurrence wins over geometrically repetitive running matter.
                for candidate in sortedRunning where !sameOccurrence(candidate, semanticAnchor) {
                    removals[candidate.pageOffset, default: []].insert(candidate.lineIndex)
                }
            } else {
                // Preserve the existing conservative principle: repeated text is
                // spoken once unless it is proven non-semantic pagination.
                for candidate in sortedRunning.dropFirst() {
                    removals[candidate.pageOffset, default: []].insert(candidate.lineIndex)
                }
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
            let required = firstPattern.isPurePagination
                ? 3
                : requiredOccurrences(pageCount: pageCount)
            let uniquePages = Set(group.map { $0.0.pageOffset })
            guard uniquePages.count >= required else { continue }

            let candidatesOnly = group.map(\.0)
            let effectiveCandidates: [EdgeCandidate]
            let geometryPages = Set(candidatesOnly.filter(\.hasGeometry).map(\.pageOffset))
            if geometryPages.count >= required {
                guard let cluster = dominantGeometryCluster(
                    candidates: candidatesOnly,
                    requiredOccurrences: required
                ) else {
                    continue
                }
                effectiveCandidates = cluster
            } else {
                effectiveCandidates = candidatesOnly
            }

            guard Set(effectiveCandidates.map(\.pageOffset)).count >= required else { continue }
            let sorted = effectiveCandidates.sorted(by: stableCandidateOrder)

            if firstPattern.isPurePagination {
                // A proven numeric pagination sequence is not semantic content.
                for candidate in sorted {
                    removals[candidate.pageOffset, default: []].insert(candidate.lineIndex)
                }
            } else if let anchor = semanticAnchor(in: candidatesOnly) {
                for candidate in sorted where !sameOccurrence(candidate, anchor) {
                    removals[candidate.pageOffset, default: []].insert(candidate.lineIndex)
                }
            } else {
                // Decorated running matter retains one occurrence for the same
                // conservative reason as exact repeated headers.
                for candidate in sorted.dropFirst() {
                    removals[candidate.pageOffset, default: []].insert(candidate.lineIndex)
                }
            }
        }
    }

    private static func protectSemanticOccurrences(
        candidates: [EdgeCandidate],
        removals: inout [Int: Set<Int>]
    ) {
        // Legacy first/last-line windows can classify the same line as both top
        // and bottom on very short pages. A confident semantic layout role must
        // protect that exact occurrence across edge-side ambiguity. Proven page
        // number patterns remain removable regardless of role hints.
        let protected = candidates.filter { candidate in
            candidate.role == .heading
                && candidate.roleConfidence >= 0.70
                && pageNumberPattern(for: candidate.text) == nil
        }

        for candidate in protected {
            removals[candidate.pageOffset]?.remove(candidate.lineIndex)
            if removals[candidate.pageOffset]?.isEmpty == true {
                removals.removeValue(forKey: candidate.pageOffset)
            }
        }
    }

    private static func dominantGeometryCluster(
        candidates: [EdgeCandidate],
        requiredOccurrences: Int
    ) -> [EdgeCandidate]? {
        let geometric = candidates.filter(\.hasGeometry)
        guard !geometric.isEmpty else { return nil }

        let heights = geometric.compactMap { $0.rect?.height }.filter { $0.isFinite && $0 > 0 }
        let medianHeight = median(heights) ?? 0.015
        let tolerance = max(0.022, min(0.060, medianHeight * 1.8))

        var best: [EdgeCandidate] = []
        for seed in geometric.sorted(by: stableCandidateOrder) {
            guard let seedY = seed.rect?.midY else { continue }
            let cluster = geometric.filter { candidate in
                guard let y = candidate.rect?.midY else { return false }
                return abs(y - seedY) <= tolerance
            }
            let uniquePages = Set(cluster.map(\.pageOffset)).count
            let bestPages = Set(best.map(\.pageOffset)).count
            if uniquePages > bestPages
                || (uniquePages == bestPages && stableClusterKey(cluster) < stableClusterKey(best)) {
                best = cluster
            }
        }

        guard Set(best.map(\.pageOffset)).count >= requiredOccurrences else { return nil }
        return best.sorted(by: stableCandidateOrder)
    }

    private static func semanticAnchor(in candidates: [EdgeCandidate]) -> EdgeCandidate? {
        candidates
            .filter { candidate in
                guard candidate.roleConfidence >= 0.70, let role = candidate.role else { return false }
                switch role {
                case .heading:
                    return true
                case .body, .listItem, .sidebar, .pullQuote, .caption, .footnote, .tableCell, .runningMatter, .unknown:
                    return false
                }
            }
            .sorted(by: stableCandidateOrder)
            .first
    }

    private static func edgeSide(for rect: CGRect) -> EdgeSide? {
        guard rect.minY.isFinite, rect.maxY.isFinite else { return nil }
        if rect.maxY <= 0.30 { return .top }
        if rect.minY >= 0.70 { return .bottom }
        return nil
    }

    private static func pageNumberPattern(for text: String) -> NumberPattern? {
        let normalized = PdfDocumentTextSignature.collapseSpaces(text).lowercased()

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
            let prefix = PdfDocumentTextSignature.normalize(String(normalized[prefixRange]))
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

    private static func isShortEdgeText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= 100
            && trimmed.split(whereSeparator: \.isWhitespace).count <= 14
    }

    private static func sameOccurrence(_ lhs: EdgeCandidate, _ rhs: EdgeCandidate) -> Bool {
        lhs.pageOffset == rhs.pageOffset
            && lhs.lineIndex == rhs.lineIndex
            && lhs.side == rhs.side
            && lhs.normalized == rhs.normalized
    }

    private static func stableCandidateOrder(_ lhs: EdgeCandidate, _ rhs: EdgeCandidate) -> Bool {
        if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
        if lhs.lineIndex != rhs.lineIndex { return lhs.lineIndex < rhs.lineIndex }
        if lhs.side != rhs.side { return sideRank(lhs.side) < sideRank(rhs.side) }
        return lhs.normalized < rhs.normalized
    }

    private static func fingerprintOrder(
        _ lhs: PdfDocumentLayoutFingerprint,
        _ rhs: PdfDocumentLayoutFingerprint
    ) -> Bool {
        if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
        if lhs.rect.minY != rhs.rect.minY { return lhs.rect.minY < rhs.rect.minY }
        if lhs.rect.minX != rhs.rect.minX { return lhs.rect.minX < rhs.rect.minX }
        return lhs.blockID < rhs.blockID
    }

    private static func stableClusterKey(_ candidates: [EdgeCandidate]) -> String {
        candidates.sorted(by: stableCandidateOrder).map {
            "\($0.pageIndex):\($0.lineIndex):\($0.normalized)"
        }.joined(separator: "|")
    }

    private static func sideRank(_ side: EdgeSide) -> Int {
        switch side {
        case .top: return 0
        case .bottom: return 1
        }
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static let purePageNumberRegex = try! NSRegularExpression(
        pattern: #"^(?:page\s+)?([0-9]{1,5})(?:\s*(?:of|/)\s*[0-9]{1,5})?$"#,
        options: [.caseInsensitive]
    )

    private static let decoratedTrailingNumberRegex = try! NSRegularExpression(
        pattern: #"^(.+?[•·|—–-]\s*)([0-9]{1,5})$"#
    )
}
