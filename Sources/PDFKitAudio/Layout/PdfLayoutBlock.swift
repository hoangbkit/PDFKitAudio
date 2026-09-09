import Foundation

/// Paragraph-like logical block assembled from compatible reconstructed lines.
/// Text intentionally preserves line boundaries for downstream cleanup and
/// dehyphenation rather than flattening them at this stage.
struct PdfLayoutBlock {
    let id: Int
    let lines: [PdfLayoutLine]
    let text: String
    let rect: CGRect
    let sourceOrder: Int
}
