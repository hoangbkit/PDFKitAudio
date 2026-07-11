import Foundation

enum PdfTextCleaner {
    static func clean(_ raw: String) -> String {
        var text = raw

        // Remove null bytes
        text = text.replacingOccurrences(of: "\0", with: "")

        // De-hyphenate line breaks: exam-\nple -> example
        text = text.replacingOccurrences(of: "-\\n", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "­\n", with: "") // soft hyphen

        // Fix common ligatures if OCR missed them
        let ligatures: [String:String] = ["ﬁ":"fi","ﬂ":"fl","ﬀ":"ff","ﬃ":"ffi","ﬄ":"ffl","—":"—","–":"-"]
        for (k,v) in ligatures { text = text.replacingOccurrences(of: k, with: v) }

        // Remove page numbers that are isolated lines of digits
        let lines = text.components(separatedBy: .newlines)
        var filtered: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count <= 4 && Int(trimmed) != nil { continue } // pure page number
            if trimmed.lowercased().hasPrefix("page ") && trimmed.count < 12 { continue }
            filtered.append(line)
        }
        text = filtered.joined(separator: "\n")

        // Collapse 3+ newlines
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        // Collapse multiple spaces but preserve paragraphs
        text = text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func htmlWrap(_ text: String, title: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n\n", with: "</p><p>")
            .replacingOccurrences(of: "\n", with: "<br>")

        return """
        <html><head><meta charset="utf-8"><style>
        body{font-family:-apple-system; line-height:1.7; padding:28px; max-width:800px; margin:auto; color:#1a1a1a;}
        h1{font-size:1.6em; margin-top:0;} p{margin:0 0 1em;}
        </style></head><body><h1>\(title)</h1><p>\(escaped)</p></body></html>
        """
    }
}
