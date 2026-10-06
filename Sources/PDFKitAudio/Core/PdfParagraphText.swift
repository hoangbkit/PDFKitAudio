import Foundation

/// Inserts evidenced separators into exactly matched source lines. Original
/// CR/CRLF terminators and explicit blank lines survive; cleanup is separate.
enum PdfParagraphText {
    private static let newlinePattern = try! NSRegularExpression(pattern: "\\r\\n|\\r|\\n")

    static func restoringBoundaries(
        in text: String, lines: [String], rects: [CGRect],
        fontSizes: [CGFloat?]? = nil, writingDirection: PdfLayoutWritingDirection? = nil
    ) -> String {
        guard lines.count >= 2, lines.count == rects.count else { return text }
        let source = text as NSString
        let matches = newlinePattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        var components: [String] = []
        var terminators: [String] = []
        var offset = 0
        for match in matches {
            components.append(source.substring(with: NSRange(location: offset, length: match.range.location - offset)))
            terminators.append(source.substring(with: match.range))
            offset = NSMaxRange(match.range)
        }
        components.append(source.substring(from: offset))
        terminators.append("")
        let indices = components.indices.filter {
            !components[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }
        // Never replace selected text with geometry text, even when only one
        // punctuation mark differs. A mismatch abstains for the entire region.
        guard indices.count == lines.count,
              zip(indices, lines).allSatisfy({ components[$0.0].trimmingCharacters(in: .whitespaces)
                  == $0.1.trimmingCharacters(in: .whitespacesAndNewlines) }) else { return text }
        let boundaries = PdfParagraphBoundaryClassifier.boundaries(lines: lines, rects: rects,
            fontSizes: fontSizes, writingDirection: writingDirection ?? PdfLayoutLineBuilder.writingDirection(for: lines))
        guard !boundaries.isEmpty else { return text }
        for index in boundaries where indices[index] == indices[index - 1] + 1 {
            terminators[indices[index - 1]] += "\n"
        }
        return zip(components, terminators).map { $0.0 + $0.1 }.joined()
    }
}
