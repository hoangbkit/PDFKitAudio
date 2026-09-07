import Foundation

enum PdfLayoutWritingDirection: String, Equatable {
    case leftToRight
    case rightToLeft
}

/// Logical horizontal text line reconstructed from one or more positioned
/// fragments. Line text preserves source wording while normalizing only the
/// spacing required to join split PDF/OCR fragments.
struct PdfLayoutLine {
    let id: Int
    let fragments: [PdfLayoutFragment]
    let text: String
    let rect: CGRect
    let writingDirection: PdfLayoutWritingDirection
    let sourceOrder: Int

    var medianFontSize: CGFloat? {
        let values = fragments.compactMap { $0.style?.fontSize }.sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }

    var isPredominantlyBold: Bool? {
        let values = fragments.compactMap { $0.style?.isBold }
        guard !values.isEmpty else { return nil }
        let boldCount = values.filter { $0 }.count
        return boldCount * 2 >= values.count
    }
}
