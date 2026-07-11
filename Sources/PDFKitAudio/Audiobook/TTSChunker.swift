import Foundation

enum TTSChunker {
    static func chunk(text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength else { return [text] }
        var chunks: [String] = []
        var current = ""
        let sentences = splitIntoSentences(text)
        for sentence in sentences {
            if current.count + sentence.count + 1 <= maxLength {
                current = current.isEmpty ? sentence : current + " " + sentence
            } else {
                if !current.isEmpty { chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if sentence.count > maxLength {
                    let parts = stride(from: 0, to: sentence.count, by: maxLength).map { i -> String in
                        let s = sentence.index(sentence.startIndex, offsetBy: i)
                        let e = sentence.index(s, offsetBy: min(maxLength, sentence.count - i))
                        return String(sentence[s..<e])
                    }
                    chunks.append(contentsOf: parts.dropLast())
                    current = parts.last ?? ""
                } else {
                    current = sentence
                }
            }
        }
        if !current.isEmpty { chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return chunks.filter { !$0.isEmpty }
    }

    private static func splitIntoSentences(_ text: String) -> [String] {
        var results: [String] = []
        var buffer = ""
        let terminators: Set<Character> = [".","!","?"]
        for ch in text {
            buffer.append(ch)
            if terminators.contains(ch) && buffer.count > 20 {
                results.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                buffer = ""
            } else if ch == "\n" && buffer.trimmingCharacters(in: .whitespaces).count > 100 {
                results.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                buffer = ""
            }
        }
        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return results.isEmpty ? [text] : results
    }
}
