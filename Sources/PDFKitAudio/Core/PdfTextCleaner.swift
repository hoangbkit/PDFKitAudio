import Foundation

enum PdfTextCleaner {
    /// Backward-compatible page-local cleanup entry point.
    static func clean(_ raw: String) -> String {
        cleanPage(raw, configuration: .audiobookDefault)
    }

    /// Safe cleanup that requires no cross-page context.
    static func cleanPage(
        _ raw: String,
        configuration: PdfCleanupConfiguration
    ) -> String {
        var text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        text = removingUnsafeControlCharacters(from: text)
        text = normalizeLigatures(in: text)

        if configuration.dehyphenatesLineWraps {
            text = dehyphenateLineWraps(in: text)
        }

        return finalizeWhitespace(text)
    }

    /// Normalizes spacing without discarding line or paragraph boundaries.
    static func finalizeWhitespace(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(
            of: "[ \\t]+\\n",
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "[ \\t]{2,}",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func htmlWrap(_ text: String, title: String) -> String {
        let escapedBody = escapeHTML(text)
            .replacingOccurrences(of: "\n\n", with: "</p><p>")
            .replacingOccurrences(of: "\n", with: "<br>")
        let escapedTitle = escapeHTML(title)

        return """
        <html><head><meta charset="utf-8"><style>
        body{font-family:-apple-system; line-height:1.7; padding:28px; max-width:800px; margin:auto; color:#1a1a1a;}
        h1{font-size:1.6em; margin-top:0;} p{margin:0 0 1em;}
        </style></head><body><h1>\(escapedTitle)</h1><p>\(escapedBody)</p></body></html>
        """
    }

    private static func removingUnsafeControlCharacters(from text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)

        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isAllowedWhitespaceControl = value == 9 || value == 10
            let isControl = CharacterSet.controlCharacters.contains(scalar)
            if !isControl || isAllowedWhitespaceControl {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    private static func normalizeLigatures(in text: String) -> String {
        let replacements: [(String, String)] = [
            ("ﬁ", "fi"),
            ("ﬂ", "fl"),
            ("ﬀ", "ff"),
            ("ﬃ", "ffi"),
            ("ﬄ", "ffl")
        ]

        return replacements.reduce(text) { result, replacement in
            result.replacingOccurrences(of: replacement.0, with: replacement.1)
        }
    }

    private static func dehyphenateLineWraps(in text: String) -> String {
        // A soft hyphen is explicitly discretionary, so removing it at a line
        // boundary is safe and language-independent.
        var text = text.replacingOccurrences(of: "­\n", with: "")
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var index = 0

        while index < lines.count {
            var current = lines[index]

            while index + 1 < lines.count,
                  shouldJoinHyphenatedLine(current, with: lines[index + 1]) {
                let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
                let trimmedCurrent = current.trimmingCharacters(in: .whitespaces)
                let trailingWord = wordBeforeTrailingHyphen(in: trimmedCurrent).lowercased()
                let nextWord = leadingWord(in: next).lowercased()

                let preserveHyphen = nextWord.contains("-")
                    || commonHyphenatedStems.contains(trailingWord)
                    || commonStandaloneContinuations.contains(nextWord)

                if preserveHyphen {
                    current = trimmedCurrent + next
                } else {
                    current = String(trimmedCurrent.dropLast()) + next
                }
                index += 1
            }

            result.append(current)
            index += 1
        }

        text = result.joined(separator: "\n")
        return text
    }

    private static func shouldJoinHyphenatedLine(_ current: String, with next: String) -> Bool {
        let left = current.trimmingCharacters(in: .whitespaces)
        let right = next.trimmingCharacters(in: .whitespaces)

        guard left.hasSuffix("-"),
              !right.isEmpty,
              !looksLikeListItem(left),
              !looksLikeListItem(right),
              !looksLikeHeading(left),
              let first = right.first,
              first.isLetter,
              first.isLowercase else {
            return false
        }

        let stem = wordBeforeTrailingHyphen(in: left)
        return stem.count >= 2 && stem.allSatisfy(\.isLetter)
    }

    private static func wordBeforeTrailingHyphen(in line: String) -> String {
        guard line.hasSuffix("-") else { return "" }
        return String(
            line.dropLast().reversed().prefix(while: \.isLetter).reversed()
        )
    }

    private static func leadingWord(in line: String) -> String {
        String(line.prefix { $0.isLetter || $0 == "-" })
    }

    private static func looksLikeListItem(_ line: String) -> Bool {
        line.range(
            of: #"^\s*(?:[-*•]|\d+[.)]|[A-Za-z][.)])\s+"#,
            options: .regularExpression
        ) != nil
    }

    private static func looksLikeHeading(_ line: String) -> Bool {
        let letters = line.filter(\.isLetter)
        return letters.count >= 4 && !letters.contains(where: \.isLowercase)
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let commonHyphenatedStems: Set<String> = [
        "self", "well", "state", "high", "low", "long", "short",
        "full", "part", "cross", "half"
    ]

    private static let commonStandaloneContinuations: Set<String> = [
        "a", "an", "and", "as", "at", "be", "been", "being", "by",
        "for", "from", "in", "is", "of", "on", "or", "the", "to",
        "was", "were", "with"
    ]
}
