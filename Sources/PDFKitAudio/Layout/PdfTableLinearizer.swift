import Foundation

enum PdfTableLinearizer {
    static func linearize(
        rows: [[PdfTableCell]],
        headerRowIndex: Int?
    ) -> String {
        guard !rows.isEmpty else { return "" }

        let normalizedRows = rows.map { row in
            row.sorted {
                if abs($0.rect.minX - $1.rect.minX) > 0.000_001 {
                    return $0.rect.minX < $1.rect.minX
                }
                if $0.blockID != $1.blockID { return $0.blockID < $1.blockID }
                return $0.lineID < $1.lineID
            }
        }

        if let headerRowIndex,
           normalizedRows.indices.contains(headerRowIndex) {
            let headers = normalizedRows[headerRowIndex].map { clean($0.text) }
            guard !headers.isEmpty else {
                return rowMajor(normalizedRows)
            }

            var spokenRows: [String] = []
            for (index, row) in normalizedRows.enumerated() where index != headerRowIndex {
                let pairs = row.enumerated().compactMap { column, cell -> String? in
                    let value = clean(cell.text)
                    guard !value.isEmpty else { return nil }
                    guard headers.indices.contains(column), !headers[column].isEmpty else {
                        return value
                    }
                    return "\(headers[column]): \(value)"
                }
                if !pairs.isEmpty {
                    spokenRows.append(pairs.joined(separator: ". ") + ".")
                }
            }
            if !spokenRows.isEmpty {
                return spokenRows.joined(separator: "\n")
            }
        }

        return rowMajor(normalizedRows)
    }

    private static func rowMajor(_ rows: [[PdfTableCell]]) -> String {
        rows.compactMap { row -> String? in
            let cells = row.map { clean($0.text) }.filter { !$0.isEmpty }
            guard !cells.isEmpty else { return nil }
            return cells.joined(separator: ". ") + "."
        }.joined(separator: "\n")
    }

    private static func clean(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
