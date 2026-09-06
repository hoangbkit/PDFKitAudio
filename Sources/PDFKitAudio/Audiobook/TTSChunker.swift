import Foundation

enum TTSChunker {
    static func chunk(text: String, maxLength: Int) -> [String] {
        chunk(
            text: text,
            configuration: TTSChunkingConfiguration(maxCharacters: maxLength)
        )
    }

    static func chunk(
        text: String,
        configuration: TTSChunkingConfiguration
    ) -> [String] {
        let normalized = normalizeLineEndings(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let maximum = configuration.maxCharacters
        let paragraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if configuration.preserveParagraphs {
            // Paragraph preservation is semantic, not merely a fallback for long
            // inputs. Even two short paragraphs remain distinct convenience chunks.
            return paragraphs
                .flatMap { paragraph in
                    chunkParagraph(paragraph, configuration: configuration)
                }
                .filter { !$0.isEmpty }
        }

        let compact = paragraphs.joined(separator: " ")
        guard compact.count > maximum else { return [compact] }
        return chunkParagraph(compact, configuration: configuration)
    }

    private static func chunkParagraph(
        _ paragraph: String,
        configuration: TTSChunkingConfiguration
    ) -> [String] {
        guard !paragraph.isEmpty else { return [] }
        guard paragraph.count > configuration.maxCharacters else { return [paragraph] }

        let sentences = splitIntoSentences(paragraph)
        var chunks: [String] = []
        var current = ""

        for sentence in sentences {
            if sentence.count > configuration.maxCharacters {
                appendCurrent(&current, to: &chunks)
                chunks.append(contentsOf: splitOversizedUnit(
                    sentence,
                    configuration: configuration
                ))
                continue
            }

            let separator = current.isEmpty ? "" : separatorBetween(current, sentence)
            let candidate = current + separator + sentence
            if candidate.count <= configuration.maxCharacters {
                current = candidate
            } else {
                appendCurrent(&current, to: &chunks)
                current = sentence
            }
        }

        appendCurrent(&current, to: &chunks)
        return chunks.filter { !$0.isEmpty }
    }

    private static func appendCurrent(
        _ current: inout String,
        to chunks: inout [String]
    ) {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            chunks.append(trimmed)
        }
        current = ""
    }

    private static func splitIntoSentences(_ text: String) -> [String] {
        var results: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: .bySentences
        ) { substring, _, _, _ in
            guard let sentence = substring?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !sentence.isEmpty else {
                return
            }
            results.append(sentence)
        }
        return results.isEmpty ? [text] : results
    }

    private static func separatorBetween(_ left: String, _ right: String) -> String {
        guard let last = left.last, let first = right.first else { return "" }
        if last.isWhitespace || first.isWhitespace { return "" }

        // East Asian sentence punctuation is conventionally followed directly by
        // the next sentence without an inserted ASCII space. Foundation sentence
        // enumeration trims its substrings, so preserve that writing convention.
        if cjkSentenceTerminators.contains(last) || isCJK(first) {
            return ""
        }
        return " "
    }

    private static func splitOversizedUnit(
        _ text: String,
        configuration: TTSChunkingConfiguration
    ) -> [String] {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var chunks: [String] = []
        let maximum = configuration.maxCharacters

        while remainder.count > maximum {
            let limitIndex = remainder.index(
                remainder.startIndex,
                offsetBy: maximum
            )
            let prefix = remainder[remainder.startIndex..<limitIndex]

            let preferredOffset = min(
                max(1, configuration.preferredMinimumCharacters),
                max(1, maximum - 1)
            )
            let preferredIndex = remainder.index(
                remainder.startIndex,
                offsetBy: preferredOffset,
                limitedBy: limitIndex
            ) ?? remainder.startIndex

            let clauseIndex = prefix.indices.reversed().first { index in
                index >= preferredIndex && clauseTerminators.contains(remainder[index])
            }
            let whitespaceIndex = prefix.indices.reversed().first { index in
                remainder[index].isWhitespace
            }

            let splitIndex: String.Index
            if let clauseIndex {
                splitIndex = remainder.index(after: clauseIndex)
            } else if let whitespaceIndex, whitespaceIndex > remainder.startIndex {
                splitIndex = whitespaceIndex
            } else {
                // Only an unbroken token is hard-split. Swift String indexing is
                // grapheme-cluster based, so this cannot split a Unicode scalar
                // sequence in the middle of a user-perceived character.
                splitIndex = limitIndex
            }

            let head = String(remainder[..<splitIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty {
                chunks.append(head)
            }

            remainder = String(remainder[splitIndex...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if !remainder.isEmpty {
            chunks.append(remainder)
        }
        return chunks
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x9FFF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }

    private static let clauseTerminators: Set<Character> = [
        ",", ";", ":", "—", "–", "，", "；", "："
    ]

    private static let cjkSentenceTerminators: Set<Character> = ["。", "！", "？"]
}
