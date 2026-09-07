import Foundation

/// Small document-level metadata retained after page-local layout analysis.
///
/// Phase 7 intentionally does not retain full fragment/line/block graphs across
/// the whole document. These fingerprints are sufficient for recurring-matter
/// cleanup while keeping memory bounded and parser integration decoupled until
/// Phase 8.
struct PdfDocumentLayoutFingerprint: Equatable {
    let pageIndex: Int
    let blockID: Int
    let text: String
    let textSignature: String
    let rect: CGRect
    let role: PdfLayoutRole
    let roleConfidence: Double
    let styleBucket: PdfDocumentLayoutStyleBucket?

    init(
        pageIndex: Int,
        blockID: Int,
        text: String,
        rect: CGRect,
        role: PdfLayoutRole = .unknown,
        roleConfidence: Double = 0,
        styleBucket: PdfDocumentLayoutStyleBucket? = nil
    ) {
        self.pageIndex = pageIndex
        self.blockID = blockID
        self.text = text
        self.textSignature = PdfDocumentTextSignature.normalize(text)
        self.rect = rect
        self.role = role
        self.roleConfidence = min(1, max(0, roleConfidence))
        self.styleBucket = styleBucket
    }
}

/// Coarse style information is diagnostic/supporting evidence only. Cleanup
/// never removes content based on font size or emphasis alone.
struct PdfDocumentLayoutStyleBucket: Equatable {
    let fontSizeBand: Int?
    let isPredominantlyBold: Bool?
}

enum PdfDocumentLayoutFingerprintBuilder {
    static func make(
        pageIndex: Int,
        blocks: [PdfLayoutBlock],
        analysis: PdfSpecialStructureAnalysis
    ) -> [PdfDocumentLayoutFingerprint] {
        let assignments = Dictionary(uniqueKeysWithValues: analysis.assignments.map { ($0.blockID, $0) })

        return blocks
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.sourceOrder != rhs.sourceOrder { return lhs.sourceOrder < rhs.sourceOrder }
                return lhs.id < rhs.id
            }
            .map { block in
                let assignment = assignments[block.id]
                return PdfDocumentLayoutFingerprint(
                    pageIndex: pageIndex,
                    blockID: block.id,
                    text: block.text,
                    rect: block.rect,
                    role: assignment?.role ?? .unknown,
                    roleConfidence: assignment?.confidence ?? 0,
                    styleBucket: styleBucket(for: block)
                )
            }
    }

    private static func styleBucket(for block: PdfLayoutBlock) -> PdfDocumentLayoutStyleBucket? {
        let fontSizes = block.lines.compactMap(\.medianFontSize).sorted()
        let fontSize: CGFloat?
        if fontSizes.isEmpty {
            fontSize = nil
        } else {
            let middle = fontSizes.count / 2
            fontSize = fontSizes.count.isMultiple(of: 2)
                ? (fontSizes[middle - 1] + fontSizes[middle]) / 2
                : fontSizes[middle]
        }

        let boldValues = block.lines.compactMap(\.isPredominantlyBold)
        let bold: Bool? = boldValues.isEmpty
            ? nil
            : boldValues.filter { $0 }.count * 2 >= boldValues.count

        guard fontSize != nil || bold != nil else { return nil }
        let fontBand = fontSize.map { Int(($0 / 2).rounded()) }
        return PdfDocumentLayoutStyleBucket(
            fontSizeBand: fontBand,
            isPredominantlyBold: bold
        )
    }
}

enum PdfDocumentTextSignature {
    static func normalize(_ text: String) -> String {
        collapseSpaces(text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
    }

    static func collapseSpaces(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    }
}
