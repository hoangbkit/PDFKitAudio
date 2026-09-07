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
        var fragments: [PdfLayoutFragment] = []
        fragments.reserveCapacity(lineSelections.count)

        for (sourceOrder, lineSelection) in lineSelections.enumerated() {
            guard let rawText = lineSelection.string else { continue }
            let text = rawText.trimmingCharacters(in: .newlines)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let rawBounds = lineSelection.bounds(for: page)
            let rect = PdfLayoutGeometry.normalizedPageRect(rawBounds, page: page)
            guard rect.width > 0, rect.height > 0 else { continue }

            fragments.append(PdfLayoutFragment(
                id: sourceOrder,
                text: text,
                rect: rect,
                source: .native,
                confidence: 1,
                sourceOrder: sourceOrder,
                style: styleHints(from: lineSelection.attributedString)
            ))
        }

        return deduplicated(fragments)
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
                current[rightIndex + 1] = min(substitution, insertion, deletion)
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
