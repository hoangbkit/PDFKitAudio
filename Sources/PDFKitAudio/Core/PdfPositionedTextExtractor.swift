import AppKit
import Foundation
import PDFKit

/// Phase 1 extraction utilities. They produce geometry only; parser text selection
/// remains unchanged until the later integration phase.
enum PdfPositionedTextExtractor {
    static func nativeFragments(page: PDFPage) -> [PdfLayoutFragment] {
        let characterCount = page.numberOfCharacters
        guard characterCount > 0,
              let selection = page.selection(for: NSRange(location: 0, length: characterCount)) else {
            return []
        }

        let lineSelections = selection.selectionsByLine()
        let usesPersistentGlyphGutters = shouldUsePersistentGlyphGapSplitting(
            lineSelections: lineSelections,
            page: page
        )

        var fragments: [PdfLayoutFragment] = []
        fragments.reserveCapacity(lineSelections.count)
        var sourceOrder = 0

        for lineSelection in lineSelections {
            let subselections = nativeSubselections(
                for: lineSelection,
                page: page,
                usesPersistentGlyphGutters: usesPersistentGlyphGutters
            )
            for subsection in subselections {
                guard let rawText = subsection.string else { continue }
                let text = rawText.trimmingCharacters(in: .newlines)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                let rawBounds = subsection.bounds(for: page)
                let rect = PdfLayoutGeometry.normalizedPageRect(rawBounds, page: page)
                guard rect.width > 0, rect.height > 0 else { continue }

                fragments.append(PdfLayoutFragment(
                    id: sourceOrder,
                    text: text,
                    rect: rect,
                    source: .native,
                    confidence: 1,
                    sourceOrder: sourceOrder,
                    style: styleHints(from: subsection.attributedString)
                ))
                sourceOrder += 1
            }
        }

        return deduplicated(fragments)
    }

    /// `PDFSelection.selectionsByLine()` can legally return one selection for
    /// text that shares a visual baseline across separate columns. The first
    /// implementation tried to identify those lines from the selection's total
    /// width versus its attributed-string width. Real PDFs can serialize both
    /// columns into one line whose intrinsic text width is also large, which makes
    /// that comparison miss exactly the case we need to repair.
    ///
    /// Phase 1 correctness recovery therefore probes a small, deterministic sample
    /// of wide line selections using PDFPage character bounds. If the same strong
    /// interior X gap recurs across sampled lines, the page has evidence of a real
    /// column gutter and all sufficiently wide lines are allowed to split at glyph
    /// gaps. Ordinary single-column pages pay only for the small probe and stay on
    /// the original line-level fast path when no persistent gutter exists.
    private static func nativeSubselections(
        for lineSelection: PDFSelection,
        page: PDFPage,
        usesPersistentGlyphGutters: Bool
    ) -> [PDFSelection] {
        let ranges = textRanges(in: lineSelection, page: page)
        guard !ranges.isEmpty else { return [lineSelection] }

        // Noncontiguous PDFSelection ranges are already the most faithful cheap
        // subdivision PDFKit exposes; preserve them as separate fragments.
        if ranges.count > 1 {
            let selections = ranges.compactMap { page.selection(for: $0) }
            if selections.count == ranges.count {
                return selections
            }
        }

        guard ranges.count == 1 else { return [lineSelection] }
        let shouldInspect = usesPersistentGlyphGutters
            ? isWideColumnSplitCandidate(lineSelection, page: page)
            : shouldInspectCharacterGeometry(lineSelection, page: page)
        guard shouldInspect else { return [lineSelection] }

        let splitRanges = rangesSplitAtStrongGlyphGaps(ranges[0], page: page)
        guard splitRanges.count > 1 else { return [lineSelection] }
        let selections = splitRanges.compactMap { page.selection(for: $0) }
        return selections.count == splitRanges.count ? selections : [lineSelection]
    }

    private struct GapCluster {
        var center: CGFloat
        var count: Int

        mutating func append(_ x: CGFloat) {
            center = ((center * CGFloat(count)) + x) / CGFloat(count + 1)
            count += 1
        }
    }

    private static func shouldUsePersistentGlyphGapSplitting(
        lineSelections: [PDFSelection],
        page: PDFPage
    ) -> Bool {
        let pageBounds = page.bounds(for: .mediaBox).standardized
        guard pageBounds.width > 0, lineSelections.count >= 2 else { return false }

        let candidateRanges = lineSelections.compactMap { selection -> NSRange? in
            let bounds = selection.bounds(for: page).standardized
            guard bounds.width >= pageBounds.width * 0.46 else { return nil }
            let ranges = textRanges(in: selection, page: page)
            guard ranges.count == 1,
                  ranges[0].length >= 8 else {
                return nil
            }
            return ranges[0]
        }
        guard candidateRanges.count >= 2 else { return false }

        let samples = evenlySampled(candidateRanges, maximumCount: 5)
        var clusters: [GapCluster] = []
        let clusterTolerance: CGFloat = 0.055

        for range in samples {
            for center in strongGlyphGapCenters(in: range, page: page) {
                if let index = clusters.indices.min(by: {
                    abs(clusters[$0].center - center) < abs(clusters[$1].center - center)
                }), abs(clusters[index].center - center) <= clusterTolerance {
                    clusters[index].append(center)
                } else {
                    clusters.append(GapCluster(center: center, count: 1))
                }
            }
        }

        // A single large tab/callout gap is not enough to classify a page as
        // columnar. The same gutter must recur in at least two sampled lines.
        return clusters.contains { $0.count >= 2 }
    }

    private static func evenlySampled<T>(
        _ values: [T],
        maximumCount: Int
    ) -> [T] {
        guard maximumCount > 0, values.count > maximumCount else { return values }
        guard maximumCount > 1 else { return [values[values.count / 2]] }

        let last = values.count - 1
        var indexes: Set<Int> = []
        for slot in 0..<maximumCount {
            let ratio = Double(slot) / Double(maximumCount - 1)
            indexes.insert(Int((Double(last) * ratio).rounded()))
        }
        return indexes.sorted().map { values[$0] }
    }

    private static func textRanges(
        in selection: PDFSelection,
        page: PDFPage
    ) -> [NSRange] {
        let count = selection.numberOfTextRanges(on: page)
        guard count > 0 else { return [] }
        var ranges: [NSRange] = []
        ranges.reserveCapacity(count)
        for index in 0..<count {
            let range = selection.range(at: index, on: page)
            if range.location != NSNotFound, range.length > 0 {
                ranges.append(range)
            }
        }
        return ranges
    }

    private static func isWideColumnSplitCandidate(
        _ selection: PDFSelection,
        page: PDFPage
    ) -> Bool {
        let bounds = selection.bounds(for: page).standardized
        let pageBounds = page.bounds(for: .mediaBox).standardized
        return bounds.width > 0
            && pageBounds.width > 0
            && bounds.width >= pageBounds.width * 0.34
    }

    /// Keep the original isolated-line repair as a fallback for pages that do not
    /// expose a recurring gutter. This remains intentionally conservative.
    private static func shouldInspectCharacterGeometry(
        _ selection: PDFSelection,
        page: PDFPage
    ) -> Bool {
        let bounds = selection.bounds(for: page).standardized
        let pageBounds = page.bounds(for: .mediaBox).standardized
        guard bounds.width > 0,
              pageBounds.width > 0,
              bounds.width >= pageBounds.width * 0.48,
              let attributed = selection.attributedString,
              attributed.length >= 2 else {
            return false
        }

        let naturalBounds = attributed.boundingRect(
            with: CGSize(width: 100_000, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).standardized
        guard naturalBounds.width > 0 else { return false }
        return bounds.width >= naturalBounds.width * 1.18
    }

    private struct NativeGlyph {
        let characterIndex: Int
        let rect: CGRect
    }

    private static func nativeGlyphs(
        in range: NSRange,
        page: PDFPage
    ) -> [NativeGlyph] {
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        let upperBound = range.location + range.length
        guard upperBound <= page.numberOfCharacters else { return [] }

        let pageText = page.string.map { $0 as NSString }
        var glyphs: [NativeGlyph] = []
        glyphs.reserveCapacity(range.length)

        for characterIndex in range.location..<upperBound {
            if let pageText, characterIndex < pageText.length {
                let unit = pageText.substring(
                    with: NSRange(location: characterIndex, length: 1)
                )
                if unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
            }

            let rawBounds = page.characterBounds(at: characterIndex)
            let rect = PdfLayoutGeometry.normalizedPageRect(rawBounds, page: page)
            guard rect.width > 0, rect.height > 0 else { continue }
            glyphs.append(NativeGlyph(characterIndex: characterIndex, rect: rect))
        }
        return glyphs
    }

    private static func strongGlyphGapThreshold(_ glyphs: [NativeGlyph]) -> CGFloat {
        guard !glyphs.isEmpty else { return .greatestFiniteMagnitude }
        let glyphWidths = glyphs.map(\.rect.width).sorted()
        let medianGlyphWidth = glyphWidths[glyphWidths.count / 2]

        // Normal word spacing is well below this threshold. The lower bound still
        // catches practical narrow newspaper gutters while the upper bound avoids
        // letting unusually wide glyphs make real gutters invisible.
        return max(0.024, min(0.060, medianGlyphWidth * 4.0))
    }

    private static func horizontalGap(
        between lhs: CGRect,
        and rhs: CGRect
    ) -> CGFloat {
        if lhs.maxX < rhs.minX { return rhs.minX - lhs.maxX }
        if rhs.maxX < lhs.minX { return lhs.minX - rhs.maxX }
        return 0
    }

    private static func strongGlyphGapCenters(
        in range: NSRange,
        page: PDFPage
    ) -> [CGFloat] {
        let glyphs = nativeGlyphs(in: range, page: page)
        guard glyphs.count >= 2 else { return [] }
        let threshold = strongGlyphGapThreshold(glyphs)
        var centers: [CGFloat] = []

        for index in 1..<glyphs.count {
            let lhs = glyphs[index - 1].rect
            let rhs = glyphs[index].rect
            let gap = horizontalGap(between: lhs, and: rhs)
            guard gap >= threshold else { continue }

            let leftEdge = min(lhs.maxX, rhs.maxX)
            let rightEdge = max(lhs.minX, rhs.minX)
            centers.append((leftEdge + rightEdge) / 2)
        }
        return centers
    }

    private static func rangesSplitAtStrongGlyphGaps(
        _ range: NSRange,
        page: PDFPage
    ) -> [NSRange] {
        guard range.location != NSNotFound, range.length > 1 else { return [range] }
        let glyphs = nativeGlyphs(in: range, page: page)
        guard glyphs.count >= 2 else { return [range] }
        let strongGap = strongGlyphGapThreshold(glyphs)

        var result: [NSRange] = []
        var groupStart = glyphs[0].characterIndex
        var previous = glyphs[0]

        for glyph in glyphs.dropFirst() {
            if horizontalGap(between: previous.rect, and: glyph.rect) >= strongGap {
                let length = previous.characterIndex - groupStart + 1
                if length > 0 {
                    result.append(NSRange(location: groupStart, length: length))
                }
                groupStart = glyph.characterIndex
            }
            previous = glyph
        }

        let finalLength = previous.characterIndex - groupStart + 1
        if finalLength > 0 {
            result.append(NSRange(location: groupStart, length: finalLength))
        }

        guard result.count > 1 else { return [range] }
        return result
    }

    static func ocrFragments(from result: PdfOCREngine.OCRResult) -> [PdfLayoutFragment] {
        let fragments = result.observations.map { observation in
            PdfLayoutFragment(
                id: observation.sourceOrder,
                text: observation.text,
                rect: observation.rect,
                source: .ocr,
                confidence: observation.confidence,
                sourceOrder: observation.sourceOrder,
                style: nil
            )
        }
        return deduplicated(fragments)
    }

    /// Removes duplicate text layers only when both geometry and text strongly
    /// agree. Equal words in different page locations are intentionally preserved.
    static func deduplicated(_ fragments: [PdfLayoutFragment]) -> [PdfLayoutFragment] {
        guard fragments.count > 1 else { return fragments }

        let ordered = fragments.sorted {
            if $0.sourceOrder != $1.sourceOrder { return $0.sourceOrder < $1.sourceOrder }
            return $0.id < $1.id
        }
        var kept: [PdfLayoutFragment] = []
        kept.reserveCapacity(ordered.count)

        for fragment in ordered {
            if let duplicateIndex = kept.firstIndex(where: { isDuplicate(fragment, $0) }) {
                if shouldPrefer(fragment, over: kept[duplicateIndex]) {
                    kept[duplicateIndex] = fragment
                }
                continue
            }
            kept.append(fragment)
        }

        return kept.sorted {
            if $0.sourceOrder != $1.sourceOrder { return $0.sourceOrder < $1.sourceOrder }
            return $0.id < $1.id
        }
    }

    private static func shouldPrefer(
        _ candidate: PdfLayoutFragment,
        over existing: PdfLayoutFragment
    ) -> Bool {
        if candidate.source != existing.source {
            if candidate.source == .native { return true }
            if existing.source == .native { return false }
        }
        if candidate.confidence != existing.confidence {
            return candidate.confidence > existing.confidence
        }
        return candidate.sourceOrder < existing.sourceOrder
    }

    private static func isDuplicate(
        _ lhs: PdfLayoutFragment,
        _ rhs: PdfLayoutFragment
    ) -> Bool {
        guard spatialOverlap(lhs.rect, rhs.rect) >= 0.82 else { return false }
        return textSimilarity(lhs.text, rhs.text) >= 0.90
    }

    /// Intersection over the smaller rectangle is more useful than IoU for OCR,
    /// where the same line can have a slightly larger recognition box.
    private static func spatialOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let a = lhs.standardized
        let b = rhs.standardized
        let aArea = a.width * a.height
        let bArea = b.width * b.height
        guard aArea > 0, bArea > 0 else { return 0 }

        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        return intersectionArea / min(aArea, bArea)
    }

    private static func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = normalizedText(lhs)
        let b = normalizedText(rhs)
        if a == b { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        let aCharacters = Array(a)
        let bCharacters = Array(b)
        let longest = max(aCharacters.count, bCharacters.count)

        // Duplicate detection should stay cheap even on pathological long lines.
        guard longest <= 512 else { return 0 }
        let distance = levenshteinDistance(aCharacters, bCharacters)
        return 1 - (Double(distance) / Double(longest))
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for (leftIndex, leftCharacter) in lhs.enumerated() {
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in rhs.enumerated() {
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                current[rightIndex + 1] = Swift.min(substitution, Swift.min(insertion, deletion))
            }
            swap(&previous, &current)
        }

        return previous[rhs.count]
    }

    private static func styleHints(from attributedString: NSAttributedString?) -> PdfLayoutStyleHints? {
        guard let attributedString, attributedString.length > 0 else { return nil }

        var sizes: [CGFloat] = []
        var sawBold = false
        var sawItalic = false
        var sawFont = false

        attributedString.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: attributedString.length),
            options: []
        ) { value, _, _ in
            guard let font = value as? NSFont else { return }
            sawFont = true
            sizes.append(font.pointSize)
            let traits = font.fontDescriptor.symbolicTraits
            sawBold = sawBold || traits.contains(.bold)
            sawItalic = sawItalic || traits.contains(.italic)
        }

        guard sawFont else { return nil }
        let sortedSizes = sizes.sorted()
        let medianSize = sortedSizes.isEmpty ? nil : sortedSizes[sortedSizes.count / 2]
        return PdfLayoutStyleHints(
            fontSize: medianSize,
            isBold: sawBold,
            isItalic: sawItalic
        )
    }
}

/// Converts PDFKit page-space and Vision image-space rectangles into one visual,
/// normalized, top-left coordinate system.
enum PdfLayoutGeometry {
    static func normalizedPageRect(
        _ rect: CGRect,
        page: PDFPage,
        box: PDFDisplayBox = .mediaBox
    ) -> CGRect {
        let pageBounds = page.bounds(for: box).standardized
        guard isFinite(pageBounds), pageBounds.width > 0, pageBounds.height > 0 else {
            return .zero
        }

        let clipped = rect.standardized.intersection(pageBounds)
        guard !clipped.isNull, !clipped.isEmpty, isFinite(clipped) else { return .zero }

        let corners = [
            CGPoint(x: clipped.minX, y: clipped.minY),
            CGPoint(x: clipped.maxX, y: clipped.minY),
            CGPoint(x: clipped.minX, y: clipped.maxY),
            CGPoint(x: clipped.maxX, y: clipped.maxY)
        ]
        let rotation = normalizedRotation(page.rotation)
        let transformed = corners.map {
            displayedPoint($0, pageBounds: pageBounds, rotation: rotation)
        }
        guard let first = transformed.first else { return .zero }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in transformed.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        let displaySize = displayedSize(for: pageBounds.size, rotation: rotation)
        guard displaySize.width > 0, displaySize.height > 0 else { return .zero }

        return clampedNormalizedRect(CGRect(
            x: minX / displaySize.width,
            y: 1 - (maxY / displaySize.height),
            width: (maxX - minX) / displaySize.width,
            height: (maxY - minY) / displaySize.height
        ))
    }

    /// Vision observations use normalized coordinates with a lower-left origin.
    /// OCR rendering already includes the page's visual orientation, so only the
    /// origin needs conversion here.
    static func normalizedVisionRect(_ rect: CGRect) -> CGRect {
        let standardized = rect.standardized
        guard isFinite(standardized) else { return .zero }
        return clampedNormalizedRect(CGRect(
            x: standardized.minX,
            y: 1 - standardized.maxY,
            width: standardized.width,
            height: standardized.height
        ))
    }

    private static func displayedPoint(
        _ point: CGPoint,
        pageBounds: CGRect,
        rotation: Int
    ) -> CGPoint {
        let x = point.x - pageBounds.minX
        let y = point.y - pageBounds.minY
        let width = pageBounds.width
        let height = pageBounds.height

        switch rotation {
        case 90:
            return CGPoint(x: y, y: width - x)
        case 180:
            return CGPoint(x: width - x, y: height - y)
        case 270:
            return CGPoint(x: height - y, y: x)
        default:
            return CGPoint(x: x, y: y)
        }
    }

    private static func displayedSize(for size: CGSize, rotation: Int) -> CGSize {
        switch rotation {
        case 90, 270:
            return CGSize(width: size.height, height: size.width)
        default:
            return size
        }
    }

    private static func normalizedRotation(_ rotation: Int) -> Int {
        let normalized = rotation % 360
        let positive = normalized >= 0 ? normalized : normalized + 360
        switch positive {
        case 90, 180, 270:
            return positive
        default:
            return 0
        }
    }

    private static func clampedNormalizedRect(_ rect: CGRect) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clipped = rect.standardized.intersection(unit)
        guard !clipped.isNull, !clipped.isEmpty, isFinite(clipped) else { return .zero }
        return clipped
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
    }
}
