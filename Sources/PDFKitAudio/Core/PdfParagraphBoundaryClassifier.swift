import Foundation

/// Region-local decisions. Callers retain source text, blocks and reading order.
enum PdfParagraphBoundaryClassifier {
    static func boundaries(
        lines: [String], rects: [CGRect], fontSizes: [CGFloat?]? = nil,
        writingDirection: PdfLayoutWritingDirection = .leftToRight
    ) -> Set<Int> {
        guard lines.count >= 2, lines.count == rects.count,
              fontSizes == nil || fontSizes?.count == lines.count else { return [] }

        // Source order stays fixed. An unsafe line or a jump to a different
        // region stops the local run instead of vetoing every paragraph on a
        // page. Never infer a boundary across such a discontinuity.
        var result: Set<Int> = []
        var start = 0
        func classifyRun(endingAt end: Int) {
            guard end - start >= 2 else { return }
            let range = start..<end
            let sizes = fontSizes.map { Array($0[range]) }
            let local = boundariesInRegion(lines: Array(lines[range]),
                rects: Array(rects[range]), fontSizes: sizes,
                writingDirection: writingDirection)
            result.formUnion(local.map { $0 + start })
        }
        for index in rects.indices {
            if !isValidRect(rects[index]) {
                classifyRun(endingAt: index)
                start = index + 1
            } else if index > start,
                      !hasCoherentGeometry([rects[index - 1], rects[index]]) {
                classifyRun(endingAt: index)
                let previous = rects[index - 1], current = rects[index]
                let overlap = min(previous.maxX, current.maxX) - max(previous.minX, current.minX)
                let jitter = max(0.001, min(previous.height, current.height) * 0.12)
                let overlapsSameLane = overlap >= min(previous.width, current.width) * 0.5
                    && current.minY < previous.maxY - jitter
                    && current.maxY > previous.minY + jitter
                // Do not turn an overlapping duplicate/bad line into the start
                // of a run with an artificial large gap to its next line.
                start = overlapsSameLane ? index + 1 : index
            }
        }
        classifyRun(endingAt: lines.count)
        return result
    }

    private static func boundariesInRegion(
        lines: [String], rects: [CGRect], fontSizes: [CGFloat?]?,
        writingDirection: PdfLayoutWritingDirection
    ) -> Set<Int> {
        let height = lowerMedian(rects.map(\.height))
        let steps = (1..<rects.count).map { rects[$0].minY - rects[$0 - 1].minY }
        let typicalStep = lowerMedian(steps)
        let leading = rects.map { writingDirection == .rightToLeft ? -$0.maxX : $0.minX }
        let trailing = rects.map { writingDirection == .rightToLeft ? -$0.minX : $0.maxX }
        let edgeTolerance = max(0.001, height * 0.18)
        let margin = dominantEdge(leading, tolerance: edgeTolerance)
        let right = trailing.sorted()[max(0, (trailing.count * 4 / 5) - 1)]
        let bodyWidth = max(0, right - margin)
        let minimumIndent = max(height * 0.5, bodyWidth * 0.018)
        let maximumIndent = max(height * 2.5, bodyWidth * 0.12)
        let atMargin = leading.map { abs($0 - margin) <= edgeTolerance }
        let nearFull = rects.map { $0.width >= bodyWidth * 0.85 }
        let prose = lines.map { !isNonProse($0) }
        let isProseRegion = prose.allSatisfy({ $0 })

        // Repeated first-line indents must immediately return to the same body
        // margin. Hanging lists/code and arbitrary edge changes are not evidence.
        var indents: [Int] = []
        if lines.count >= 5, bodyWidth > 0,
           atMargin.filter({ $0 }).count * 5 >= lines.count * 3,
           isProseRegion {
            for index in 0..<(lines.count - 1) {
                let indent = leading[index] - margin
                if indent >= minimumIndent, indent <= maximumIndent,
                   atMargin[index + 1], index == 0 || atMargin[index - 1] {
                    indents.append(index)
                }
            }
        }
        let hasWrappedProse = (1..<lines.count).contains { index in
            nearFull[index - 1] && nearFull[index]
                && !endsSentence(lines[index - 1]) && prose[index - 1] && prose[index]
        }
        let repeatedIndent = lowerMedian(indents.map { leading[$0] - margin })
        let matchingIndents = indents.filter {
            abs(leading[$0] - margin - repeatedIndent) <= edgeTolerance * 2
        }
        let supportedIndents: Set<Int> = matchingIndents.count >= 2 && hasWrappedProse
            ? Set(matchingIndents) : []

        var result: Set<Int> = []
        for index in 1..<lines.count {
            let step = steps[index - 1]
            let strongGap: Bool
            if lines.count == 2 {
                strongGap = rects[index].minY - rects[index - 1].maxY > height * 1.5
            } else {
                strongGap = step > typicalStep * 1.5 && step - typicalStep > height * 0.5
            }
            // Preserve the existing strong gap rule independently of prose cues.
            if strongGap {
                result.insert(index)
                continue
            }
            guard !endsWithContinuationHyphen(lines[index - 1]), prose[index - 1], prose[index] else {
                continue
            }
            if supportedIndents.contains(index), endsSentence(lines[index - 1]) {
                result.insert(index)
                continue
            }
            // Short final lines need an independent spacing increase, not just
            // punctuation or a return to the margin.
            if isProseRegion, hasWrappedProse, bodyWidth > 0, atMargin[index],
               rects[index - 1].width < bodyWidth * 0.80,
               endsSentence(lines[index - 1]),
               step > typicalStep * 1.18, step - typicalStep > height * 0.20 {
                result.insert(index)
                continue
            }
            // Never infer headings from any-bold-run hints, which can mean one
            // emphasized word. Font-size transitions are optional visual evidence.
            if let sizes = fontSizes, let previous = sizes[index - 1], let current = sizes[index],
               previous.isFinite, current.isFinite, previous > 0, current > 0, bodyWidth > 0 {
                let precedingHeading = previous >= current * 1.28
                    && rects[index - 1].height >= rects[index].height * 1.20
                    && rects[index - 1].width < bodyWidth * 0.65
                    && lines[index - 1].count <= 80 && !endsSentence(lines[index - 1])
                    && atMargin[index] && nearFull[index]
                let followingHeading = current >= previous * 1.28
                    && rects[index].height >= rects[index - 1].height * 1.20
                    && rects[index].width < bodyWidth * 0.65
                    && lines[index].count <= 80 && !endsSentence(lines[index])
                    && atMargin[index - 1] && nearFull[index - 1]
                if precedingHeading || followingHeading { result.insert(index) }
            }
        }
        return result
    }

    private static func isValidRect(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    /// Checks a consecutive source-order run, never an entire mixed page.
    static func hasCoherentGeometry(_ rects: [CGRect]) -> Bool {
        guard rects.count >= 2, rects.allSatisfy(isValidRect) else { return false }
        for index in 1..<rects.count {
            let previous = rects[index - 1], current = rects[index]
            let overlap = min(previous.maxX, current.maxX) - max(previous.minX, current.minX)
            let jitter = max(0.001, min(previous.height, current.height) * 0.12)
            guard current.minY >= previous.maxY - jitter,
                  current.minY - previous.minY > min(previous.height, current.height) * 0.5,
                  overlap >= min(previous.width, current.width) * 0.5 else { return false }
        }
        return true
    }

    private static func dominantEdge(_ values: [CGFloat], tolerance: CGFloat) -> CGFloat {
        let sorted = values.sorted()
        var start = 0, bestStart = 0, bestEnd = 0
        for end in sorted.indices {
            while sorted[end] - sorted[start] > tolerance * 2 { start += 1 }
            if end - start > bestEnd - bestStart { bestStart = start; bestEnd = end }
        }
        return sorted[(bestStart + bestEnd) / 2]
    }

    private static func lowerMedian(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    private static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'’”»)]}"))
        guard let last = trimmed.last else { return false }
        return ".!?…。！？".contains(last)
    }

    private static func endsWithContinuationHyphen(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return "-‐‑\u{00AD}".contains(last)
    }

    private static func isNonProse(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.contains("{") || trimmed.contains("}") || trimmed.hasSuffix(";")
            || trimmed.hasPrefix("//") || trimmed.hasPrefix("```") || trimmed.hasPrefix("#") {
            return true
        }
        if let first = trimmed.first, "•◦▪▫‣⁃".contains(first) { return true }
        let token = trimmed.prefix { !$0.isWhitespace }
        if ["-", "*", "–", "—"].contains(String(token)) { return true }
        guard let last = token.last, ".)]:".contains(last) else { return false }
        let marker = token.dropLast()
        return !marker.isEmpty && (marker.allSatisfy(\.isNumber)
            || (marker.count == 1 && marker.first?.isLetter == true))
    }
}
