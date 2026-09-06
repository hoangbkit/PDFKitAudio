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
        guard normalized.count > maximum else { return [normalized] }

        if configuration.preserveParagraphs {
            return normalized
                .components(separatedBy: "\n\n")
                .flatMap { paragraph in
                    chunkParagraph(
                        paragraph.trimmingCharacters(in: .whitespacesAndNewlines),
                        configuration: configuration
                    )
                }
                .filter { !$0.isEmpty }
        }

        return chunkParagraph(
            normalized.replacingOccurrences(of: "\n\n", with: " "),
            configuration: configuration
        )
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

            let candidate = current.isEmpty ? sentence : current + " " + sentence
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

    private static let clauseTerminators: Set<Character> = [
        ",", ";", ":", "—", "–", "，", "；", "："
    ]
}
