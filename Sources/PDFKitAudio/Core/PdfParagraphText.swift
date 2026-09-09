import Foundation

/// Adds only evidenced paragraph separators to otherwise unchanged, ordered text.
/// Uniform line spacing is ambiguous (for example double-spaced prose), so it
/// must not turn every physical PDF line into a paragraph.
enum PdfParagraphText {
    static func restoringBoundaries(in text: String, lines: [String], rects: [CGRect]) -> String {
        guard lines.count >= 2, lines.count == rects.count,
              rects.allSatisfy({ !$0.isNull && $0.minX.isFinite && $0.minY.isFinite
                  && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }) else { return text }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var components = normalized.components(separatedBy: "\n")
        let indices = components.indices.filter {
            !components[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }
        // Never substitute geometry text for selected text: even punctuation,
        // explicit blank lines and intra-line whitespace must survive unchanged.
        guard indices.count == lines.count,
              zip(indices, lines).allSatisfy({ components[$0.0].trimmingCharacters(in: .whitespaces)
                  == $0.1.trimmingCharacters(in: .whitespacesAndNewlines) }) else { return text }
        var steps: [CGFloat] = []
        for index in 1..<rects.count {
            let previous = rects[index - 1], current = rects[index]
            let overlap = min(previous.maxX, current.maxX) - max(previous.minX, current.minX)
            guard current.minY >= previous.maxY - 0.001,
                  overlap >= min(previous.width, current.width) * 0.5 else { return text }
            steps.append(current.minY - previous.minY)
        }
        let heights = rects.map(\.height).sorted()
        let height = heights[(heights.count - 1) / 2]
        let orderedSteps = steps.sorted()
        let typicalStep = orderedSteps[(orderedSteps.count - 1) / 2]
        for index in 1..<rects.count {
            let step = steps[index - 1]
            let isParagraph: Bool
            if rects.count == 2 {
                isParagraph = rects[index].minY - rects[index - 1].maxY > height * 1.5
            } else {
                isParagraph = step > typicalStep * 1.5 && step - typicalStep > height * 0.5
            }
            if isParagraph, indices[index] == indices[index - 1] + 1 {
                components[indices[index - 1]] += "\n"
            }
        }
        return components.joined(separator: "\n")
    }
}
