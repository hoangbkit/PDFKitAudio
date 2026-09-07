import AppKit
import Foundation

/// Expected level of support once the layout analyzer is complete.
enum TestLayoutSupport: String, CaseIterable, Codable {
    case supported
    case degradedButReadable
    case unsupported
}

enum TestLayoutRendering: String, Codable {
    case native
    case scanned
}

/// A positioned text box in normalized top-left page coordinates.
struct TestLayoutTextBox: Codable, Equatable {
    let marker: String
    let text: String
    let rect: CGRect
    let fontSize: CGFloat
    let alignment: NSTextAlignment
    let fontWeight: NSFont.Weight

    init(
        _ marker: String,
        text: String? = nil,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        fontSize: CGFloat = 12,
        alignment: NSTextAlignment = .left,
        fontWeight: NSFont.Weight = .regular
    ) {
        self.marker = marker
        self.text = text ?? "\(marker) deterministic fixture text."
        self.rect = CGRect(x: x, y: y, width: width, height: height)
        self.fontSize = fontSize
        self.alignment = alignment
        self.fontWeight = fontWeight
    }

    private enum CodingKeys: String, CodingKey {
        case marker, text, rect, fontSize, alignment, fontWeight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        marker = try container.decode(String.self, forKey: .marker)
        text = try container.decode(String.self, forKey: .text)
        rect = try container.decode(CGRect.self, forKey: .rect)
        fontSize = try container.decode(CGFloat.self, forKey: .fontSize)
        alignment = NSTextAlignment(rawValue: try container.decode(Int.self, forKey: .alignment)) ?? .left
        fontWeight = NSFont.Weight(rawValue: try container.decode(CGFloat.self, forKey: .fontWeight))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(marker, forKey: .marker)
        try container.encode(text, forKey: .text)
        try container.encode(rect, forKey: .rect)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(alignment.rawValue, forKey: .alignment)
        try container.encode(fontWeight.rawValue, forKey: .fontWeight)
    }
}

struct TestLayoutPage: Codable, Equatable {
    let size: CGSize
    let cropInsets: NSEdgeInsets
    let rotation: Int
    let rendering: TestLayoutRendering
    let boxes: [TestLayoutTextBox]

    init(
        size: CGSize = CGSize(width: 612, height: 792),
        cropInsets: NSEdgeInsets = .zero,
        rotation: Int = 0,
        rendering: TestLayoutRendering = .native,
        boxes: [TestLayoutTextBox]
    ) {
        self.size = size
        self.cropInsets = cropInsets
        self.rotation = rotation
        self.rendering = rendering
        self.boxes = boxes
    }

    private enum CodingKeys: String, CodingKey {
        case size, cropTop, cropLeft, cropBottom, cropRight, rotation, rendering, boxes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = try container.decode(CGSize.self, forKey: .size)
        cropInsets = NSEdgeInsets(
            top: try container.decode(CGFloat.self, forKey: .cropTop),
            left: try container.decode(CGFloat.self, forKey: .cropLeft),
            bottom: try container.decode(CGFloat.self, forKey: .cropBottom),
            right: try container.decode(CGFloat.self, forKey: .cropRight)
        )
        rotation = try container.decode(Int.self, forKey: .rotation)
        rendering = try container.decode(TestLayoutRendering.self, forKey: .rendering)
        boxes = try container.decode([TestLayoutTextBox].self, forKey: .boxes)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(size, forKey: .size)
        try container.encode(cropInsets.top, forKey: .cropTop)
        try container.encode(cropInsets.left, forKey: .cropLeft)
        try container.encode(cropInsets.bottom, forKey: .cropBottom)
        try container.encode(cropInsets.right, forKey: .cropRight)
        try container.encode(rotation, forKey: .rotation)
        try container.encode(rendering, forKey: .rendering)
        try container.encode(boxes, forKey: .boxes)
    }
}

struct TestLayoutFixture: Codable, Equatable {
    let name: String
    let category: String
    let support: TestLayoutSupport
    let pages: [TestLayoutPage]
    let expectedMarkerOrder: [String]
    let notes: String

    func repeatedPages(_ count: Int, name: String? = nil) -> TestLayoutFixture {
        precondition(count > 0)
        let source = pages.isEmpty ? [] : Array(repeating: pages[0], count: count)
        return TestLayoutFixture(
            name: name ?? "\(self.name)-x\(count)",
            category: category,
            support: support,
            pages: source,
            expectedMarkerOrder: expectedMarkerOrder,
            notes: notes
        )
    }
}

/// Deterministic matrix used by all layout-analyzer phases.
///
/// Complex fixtures deliberately use a content-stream order that can differ from
/// the desired spoken order. This prevents tests from accidentally succeeding only
/// because the source PDF already serialized text in semantic order.
enum TestLayoutFixtureCatalog {
    static let all: [TestLayoutFixture] = {
        var result: [TestLayoutFixture] = []

        // MARK: Simple layouts
        result += [
            singleColumn("single-column-narrow-margins", x: 0.05, width: 0.90),
            singleColumn("single-column-wide-margins", x: 0.20, width: 0.60),
            singleColumn("centered-paragraphs", x: 0.18, width: 0.64, alignment: .center),
            singleColumn("justified-looking-paragraphs", x: 0.10, width: 0.80, alignment: .justified),
            singleColumn("first-line-indentation", x: 0.14, width: 0.76),
            singleColumn("hanging-indentation", x: 0.08, width: 0.76),
            headingAndBody("short-chapter-heading-body", headingWidth: 0.55),
            headingAndBody("full-width-title-body", headingWidth: 0.84),
            singleColumn("large-whitespace-between-paragraphs", x: 0.12, width: 0.76, yGap: 0.15),
            fixture(
                "blank-page",
                category: "simple",
                support: .supported,
                boxes: [],
                expected: []
            ),
            fixture(
                "page-number-only",
                category: "simple",
                support: .supported,
                boxes: [box("PAGE_7", x: 0.45, y: 0.92, w: 0.10, h: 0.03)],
                expected: ["PAGE_7"]
            )
        ]

        // MARK: Columns
        result += [
            twoColumn("two-column-symmetric", leftWidth: 0.38, gutter: 0.08),
            twoColumn("two-column-60-40", leftWidth: 0.48, gutter: 0.06),
            twoColumn("two-column-40-60", leftWidth: 0.31, gutter: 0.06),
            twoColumn("two-column-narrow-gutter", leftWidth: 0.40, gutter: 0.025),
            twoColumn("two-column-wide-gutter", leftWidth: 0.34, gutter: 0.15),
            threeColumn("three-column"),
            twoColumn("columns-unequal-final-heights", leftWidth: 0.38, gutter: 0.08, leftCount: 4, rightCount: 2),
            twoColumn("left-column-ending-early", leftWidth: 0.38, gutter: 0.08, leftCount: 2, rightCount: 4),
            twoColumn("right-column-begins-lower", leftWidth: 0.38, gutter: 0.08, rightYOffset: 0.13),
            twoColumn("short-column-beside-long-column", leftWidth: 0.28, gutter: 0.08, leftCount: 2, rightCount: 5),
            twoColumn("columns-with-indented-paragraphs", leftWidth: 0.38, gutter: 0.08, indentation: 0.035)
        ]

        // MARK: Mixed vertical regions
        result += [
            mixedRegions("full-width-title-two-columns", prefix: "TITLE", suffix: nil),
            mixedRegions("full-width-abstract-two-columns", prefix: "ABSTRACT", suffix: nil),
            mixedRegions("two-columns-full-width-conclusion", prefix: nil, suffix: "CONCLUSION"),
            mixedRegions("title-columns-footer-note", prefix: "TITLE", suffix: "FOOTER_NOTE"),
            singleTwoSingle("single-two-single"),
            interruptedColumns("columns-interrupted-by-caption", middle: "FIGURE_CAPTION"),
            interruptedColumns("multiple-spanning-headings", middle: "SECTION_HEADING", includeSecond: true),
            mixedRegions("abstract-columns-summary", prefix: "ABSTRACT", suffix: "SUMMARY")
        ]

        // MARK: Side content
        result += [
            sidebar("right-sidebar", onRight: true),
            sidebar("left-sidebar", onRight: false),
            sidebar("pull-quote-inside-body", onRight: true, sidebarMarker: "PULL_QUOTE", sidebarY: 0.34),
            sideCallout("narrow-callout-between-body-regions"),
            sidebar("marginal-note", onRight: true, sidebarMarker: "MARGINAL_NOTE", sidebarWidth: 0.14),
            multipleSidebars("multiple-small-sidebars")
        ]

        // MARK: Tables
        result += [
            table("table-2x3-bordered", columns: 3, rows: 2),
            table("table-borderless", columns: 3, rows: 3),
            table("table-header-row", columns: 3, rows: 3, header: true),
            table("table-numeric", columns: 4, rows: 3, numeric: true),
            table("table-uneven-column-widths", columns: 3, rows: 3, uneven: true),
            table("table-full-page-width", columns: 4, rows: 4, width: 0.88),
            table("table-inside-single-column", columns: 2, rows: 3, width: 0.42),
            tableBetweenText("table-between-text-regions"),
            table("table-multiline-cells", columns: 3, rows: 3, multiline: true)
        ]

        // MARK: Footnotes and captions
        result += [
            bodyWithFootnotes("one-footnote", footnoteCount: 1),
            bodyWithFootnotes("multiple-footnotes", footnoteCount: 3),
            bodyWithFootnotes("footnote-rule", footnoteCount: 2, withRuleMarker: true),
            bodyWithCaption("image-caption-below-body", captionY: 0.70),
            bodyWithCaption("caption-between-columns", captionY: 0.48, twoColumns: true),
            bodyWithFootnotes("small-font-citation-block", footnoteCount: 2, markerPrefix: "CITATION")
        ]

        // MARK: Running matter
        result += [
            runningMatter("identical-header-every-page", headers: ["BOOK_HEADER", "BOOK_HEADER", "BOOK_HEADER", "BOOK_HEADER"]),
            runningMatter("alternating-even-odd-headers", headers: ["EVEN_HEADER", "ODD_HEADER", "EVEN_HEADER", "ODD_HEADER"]),
            runningMatter("chapter-title-running-header", headers: ["CHAPTER_HEADER", "CHAPTER_HEADER", "CHAPTER_HEADER", "CHAPTER_HEADER"]),
            runningMatter("pure-page-number-footer", headers: nil, footers: ["1", "2", "3", "4"]),
            runningMatter("decorated-page-number-footer", headers: nil, footers: ["BOOK • 1", "BOOK • 2", "BOOK • 3", "BOOK • 4"]),
            runningMatter("legitimate-year-near-bottom", headers: nil, footers: ["2023", "2024", "2025", "2026"]),
            runningMatter("semantic-sentence-near-top", headers: ["SEMANTIC_TOP_A", "SEMANTIC_TOP_B", "SEMANTIC_TOP_C", "SEMANTIC_TOP_D"])
        ]

        // MARK: Difficult positioning
        result += [
            floatingBox("floating-text-box-over-body", x: 0.58, y: 0.35),
            floatingBox("text-box-near-center-gutter", x: 0.44, y: 0.30),
            transformed("landscape-page", size: CGSize(width: 792, height: 612), rotation: 0),
            transformed("rotated-page-90", size: CGSize(width: 612, height: 792), rotation: 90),
            mixedOrientation("mixed-portrait-landscape"),
            transformed("crop-box-differs-media-box", crop: NSEdgeInsets(top: 24, left: 30, bottom: 36, right: 28)),
            superscriptFixture("tiny-superscript-near-line"),
            duplicateLayer("duplicate-overlapping-text-layer"),
            duplicateLayer("near-duplicate-overlapping-text-layer", nearDuplicate: true)
        ]

        // MARK: Scripts / languages
        result += [
            languageFixture("latin-diacritics", text: "LATIN_DIACRITICS Café naïve façade résumé"),
            languageFixture("vietnamese", text: "VIETNAMESE Tiếng Việt có dấu, đọc đúng thứ tự."),
            languageFixture("horizontal-cjk", text: "CJK 横書きテキスト。中文段落。"),
            languageFixture("rtl-horizontal", text: "RTL שלום עולם", support: .degradedButReadable),
            languageFixture("mixed-latin-cjk-punctuation", text: "MIXED Hello，世界。Next sentence！")
        ]

        // OCR / mixed equivalents required by the fixture infrastructure.
        result += [
            scannedEquivalent(of: singleColumn("scanned-single-column", x: 0.12, width: 0.76)),
            scannedEquivalent(of: twoColumn("scanned-two-column", leftWidth: 0.38, gutter: 0.08)),
            mixedNativeScannedDocument("mixed-native-scanned-pages")
        ]

        return result
    }()

    static var byName: [String: TestLayoutFixture] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    }

    // MARK: - Fixture templates

    private static func box(
        _ marker: String,
        text: String? = nil,
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        h: CGFloat,
        font: CGFloat = 12,
        alignment: NSTextAlignment = .left,
        weight: NSFont.Weight = .regular
    ) -> TestLayoutTextBox {
        TestLayoutTextBox(marker, text: text, x: x, y: y, width: w, height: h, fontSize: font, alignment: alignment, fontWeight: weight)
    }

    private static func fixture(
        _ name: String,
        category: String,
        support: TestLayoutSupport,
        boxes: [TestLayoutTextBox],
        expected: [String],
        notes: String = "",
        pageSize: CGSize = CGSize(width: 612, height: 792),
        crop: NSEdgeInsets = .zero,
        rotation: Int = 0,
        rendering: TestLayoutRendering = .native
    ) -> TestLayoutFixture {
        TestLayoutFixture(
            name: name,
            category: category,
            support: support,
            pages: [TestLayoutPage(size: pageSize, cropInsets: crop, rotation: rotation, rendering: rendering, boxes: boxes)],
            expectedMarkerOrder: expected,
            notes: notes
        )
    }

    private static func singleColumn(
        _ name: String,
        x: CGFloat,
        width: CGFloat,
        alignment: NSTextAlignment = .left,
        yGap: CGFloat = 0.09
    ) -> TestLayoutFixture {
        let markers = ["P1", "P2", "P3", "P4"]
        let boxes = markers.enumerated().map { index, marker in
            box(marker, x: x, y: 0.12 + CGFloat(index) * yGap, w: width, h: 0.055, alignment: alignment)
        }
        return fixture(name, category: "simple", support: .supported, boxes: boxes, expected: markers)
    }

    private static func headingAndBody(_ name: String, headingWidth: CGFloat) -> TestLayoutFixture {
        let boxes = [
            box("TITLE", x: (1 - headingWidth) / 2, y: 0.07, w: headingWidth, h: 0.055, font: 20, alignment: .center, weight: .bold),
            box("P1", x: 0.12, y: 0.17, w: 0.76, h: 0.06),
            box("P2", x: 0.12, y: 0.27, w: 0.76, h: 0.06)
        ]
        return fixture(name, category: "simple", support: .supported, boxes: boxes, expected: ["TITLE", "P1", "P2"])
    }

    private static func twoColumn(
        _ name: String,
        leftWidth: CGFloat,
        gutter: CGFloat,
        leftCount: Int = 3,
        rightCount: Int = 3,
        rightYOffset: CGFloat = 0,
        indentation: CGFloat = 0
    ) -> TestLayoutFixture {
        let leftX: CGFloat = 0.08
        let rightX = leftX + leftWidth + gutter
        let rightWidth = max(0.12, 0.92 - rightX)
        var expected: [String] = []
        var left: [TestLayoutTextBox] = []
        var right: [TestLayoutTextBox] = []
        for index in 0..<leftCount {
            let marker = "L\(index + 1)"
            expected.append(marker)
            left.append(box(marker, x: leftX + (index == 0 ? indentation : 0), y: 0.14 + CGFloat(index) * 0.11, w: leftWidth - (index == 0 ? indentation : 0), h: 0.065))
        }
        for index in 0..<rightCount {
            let marker = "R\(index + 1)"
            expected.append(marker)
            right.append(box(marker, x: rightX, y: 0.14 + rightYOffset + CGFloat(index) * 0.11, w: rightWidth, h: 0.065))
        }

        // Interleave source drawing order intentionally; desired spoken order is column-major.
        var drawOrder: [TestLayoutTextBox] = []
        for index in 0..<max(left.count, right.count) {
            if index < left.count { drawOrder.append(left[index]) }
            if index < right.count { drawOrder.append(right[index]) }
        }
        return fixture(name, category: "columns", support: .supported, boxes: drawOrder, expected: expected)
    }

    private static func threeColumn(_ name: String) -> TestLayoutFixture {
        let x: [CGFloat] = [0.06, 0.37, 0.68]
        let markers = [["A1", "A2", "A3"], ["B1", "B2", "B3"], ["C1", "C2", "C3"]]
        var columns: [[TestLayoutTextBox]] = []
        for column in 0..<3 {
            columns.append(markers[column].enumerated().map { index, marker in
                box(marker, x: x[column], y: 0.14 + CGFloat(index) * 0.11, w: 0.25, h: 0.065)
            })
        }
        var drawOrder: [TestLayoutTextBox] = []
        for row in 0..<3 {
            for column in 0..<3 { drawOrder.append(columns[column][row]) }
        }
        return fixture(name, category: "columns", support: .supported, boxes: drawOrder, expected: markers.flatMap { $0 })
    }

    private static func mixedRegions(_ name: String, prefix: String?, suffix: String?) -> TestLayoutFixture {
        var boxes: [TestLayoutTextBox] = []
        var expected: [String] = []
        if let prefix {
            boxes.append(box(prefix, x: 0.08, y: 0.06, w: 0.84, h: 0.055, font: 18, alignment: .center, weight: .bold))
            expected.append(prefix)
        }
        let left = [box("L1", x: 0.08, y: 0.19, w: 0.38, h: 0.06), box("L2", x: 0.08, y: 0.31, w: 0.38, h: 0.06)]
        let right = [box("R1", x: 0.54, y: 0.19, w: 0.38, h: 0.06), box("R2", x: 0.54, y: 0.31, w: 0.38, h: 0.06)]
        boxes += [left[0], right[0], left[1], right[1]]
        expected += ["L1", "L2", "R1", "R2"]
        if let suffix {
            boxes.append(box(suffix, x: 0.10, y: 0.52, w: 0.80, h: 0.06, font: 13))
            expected.append(suffix)
        }
        return fixture(name, category: "mixed-regions", support: .supported, boxes: boxes, expected: expected)
    }

    private static func singleTwoSingle(_ name: String) -> TestLayoutFixture {
        let boxes = [
            box("TOP", x: 0.10, y: 0.07, w: 0.80, h: 0.06),
            box("L1", x: 0.08, y: 0.20, w: 0.38, h: 0.06),
            box("R1", x: 0.54, y: 0.20, w: 0.38, h: 0.06),
            box("L2", x: 0.08, y: 0.32, w: 0.38, h: 0.06),
            box("R2", x: 0.54, y: 0.32, w: 0.38, h: 0.06),
            box("BOTTOM", x: 0.10, y: 0.52, w: 0.80, h: 0.06)
        ]
        return fixture(name, category: "mixed-regions", support: .supported, boxes: boxes, expected: ["TOP", "L1", "L2", "R1", "R2", "BOTTOM"])
    }

    private static func interruptedColumns(_ name: String, middle: String, includeSecond: Bool = false) -> TestLayoutFixture {
        var boxes = [
            box("L1", x: 0.08, y: 0.10, w: 0.38, h: 0.055),
            box("R1", x: 0.54, y: 0.10, w: 0.38, h: 0.055),
            box(middle, x: 0.14, y: 0.30, w: 0.72, h: 0.05, font: 13, alignment: .center),
            box("L2", x: 0.08, y: 0.42, w: 0.38, h: 0.055),
            box("R2", x: 0.54, y: 0.42, w: 0.38, h: 0.055)
        ]
        var expected = ["L1", "R1", middle, "L2", "R2"]
        if includeSecond {
            boxes.append(box("SECOND_HEADING", x: 0.12, y: 0.58, w: 0.76, h: 0.05, font: 15, alignment: .center, weight: .bold))
            expected.append("SECOND_HEADING")
        }
        return fixture(name, category: "mixed-regions", support: .degradedButReadable, boxes: boxes, expected: expected)
    }

    private static func sidebar(
        _ name: String,
        onRight: Bool,
        sidebarMarker: String = "SIDEBAR",
        sidebarY: CGFloat = 0.24,
        sidebarWidth: CGFloat = 0.22
    ) -> TestLayoutFixture {
        let bodyX: CGFloat = onRight ? 0.08 : 0.32
        let bodyWidth: CGFloat = 0.60
        let sideX: CGFloat = onRight ? 0.74 : 0.06
        let boxes = [
            box("BODY1", x: bodyX, y: 0.12, w: bodyWidth, h: 0.07),
            box(sidebarMarker, x: sideX, y: sidebarY, w: sidebarWidth, h: 0.12, font: 10),
            box("BODY2", x: bodyX, y: 0.26, w: bodyWidth, h: 0.07),
            box("BODY3", x: bodyX, y: 0.40, w: bodyWidth, h: 0.07)
        ]
        return fixture(name, category: "side-content", support: .degradedButReadable, boxes: boxes, expected: ["BODY1", "BODY2", "BODY3", sidebarMarker])
    }

    private static func sideCallout(_ name: String) -> TestLayoutFixture {
        let boxes = [
            box("BODY_TOP", x: 0.12, y: 0.10, w: 0.76, h: 0.08),
            box("CALLOUT", x: 0.39, y: 0.29, w: 0.22, h: 0.10, font: 10, alignment: .center),
            box("BODY_BOTTOM", x: 0.12, y: 0.50, w: 0.76, h: 0.08)
        ]
        return fixture(name, category: "side-content", support: .degradedButReadable, boxes: boxes, expected: ["BODY_TOP", "CALLOUT", "BODY_BOTTOM"])
    }

    private static func multipleSidebars(_ name: String) -> TestLayoutFixture {
        let boxes = [
            box("BODY1", x: 0.22, y: 0.10, w: 0.56, h: 0.07),
            box("LEFT_NOTE", x: 0.04, y: 0.18, w: 0.14, h: 0.10, font: 9),
            box("BODY2", x: 0.22, y: 0.26, w: 0.56, h: 0.07),
            box("RIGHT_NOTE", x: 0.82, y: 0.33, w: 0.14, h: 0.10, font: 9),
            box("BODY3", x: 0.22, y: 0.44, w: 0.56, h: 0.07)
        ]
        return fixture(name, category: "side-content", support: .degradedButReadable, boxes: boxes, expected: ["BODY1", "BODY2", "BODY3", "LEFT_NOTE", "RIGHT_NOTE"])
    }

    private static func table(
        _ name: String,
        columns: Int,
        rows: Int,
        header: Bool = false,
        numeric: Bool = false,
        uneven: Bool = false,
        width: CGFloat = 0.72,
        multiline: Bool = false
    ) -> TestLayoutFixture {
        let startX = (1 - width) / 2
        let baseWidth = width / CGFloat(columns)
        var boxes: [TestLayoutTextBox] = []
        var expected: [String] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let marker = header && row == 0 ? "H\(column + 1)" : "T\(row + 1)_\(column + 1)"
                let xAdjustment = uneven ? CGFloat(column) * 0.008 : 0
                let cellWidth = max(0.08, baseWidth - xAdjustment)
                let text: String
                if numeric {
                    text = "\(marker) \((row + 1) * (column + 2) * 10)"
                } else if multiline {
                    text = "\(marker) first line\nsecond line"
                } else {
                    text = "\(marker) cell"
                }
                boxes.append(box(marker, text: text, x: startX + CGFloat(column) * baseWidth, y: 0.18 + CGFloat(row) * 0.10, w: cellWidth, h: 0.07, font: header && row == 0 ? 11 : 10, weight: header && row == 0 ? .bold : .regular))
                expected.append(marker)
            }
        }
        return fixture(name, category: "tables", support: .degradedButReadable, boxes: boxes, expected: expected)
    }

    private static func tableBetweenText(_ name: String) -> TestLayoutFixture {
        let tableFixture = table("embedded", columns: 3, rows: 2, width: 0.64)
        let tableBoxes = tableFixture.pages[0].boxes.map { item in
            TestLayoutTextBox(item.marker, text: item.text, x: item.rect.minX, y: item.rect.minY + 0.18, width: item.rect.width, height: item.rect.height, fontSize: item.fontSize, alignment: item.alignment, fontWeight: item.fontWeight)
        }
        let boxes = [box("BEFORE", x: 0.12, y: 0.08, w: 0.76, h: 0.06)] + tableBoxes + [box("AFTER", x: 0.12, y: 0.62, w: 0.76, h: 0.06)]
        return fixture(name, category: "tables", support: .degradedButReadable, boxes: boxes, expected: ["BEFORE"] + tableFixture.expectedMarkerOrder + ["AFTER"])
    }

    private static func bodyWithFootnotes(
        _ name: String,
        footnoteCount: Int,
        withRuleMarker: Bool = false,
        markerPrefix: String = "FOOTNOTE"
    ) -> TestLayoutFixture {
        var boxes = [
            box("BODY1", x: 0.12, y: 0.12, w: 0.76, h: 0.07),
            box("BODY2", x: 0.12, y: 0.26, w: 0.76, h: 0.07)
        ]
        var expected = ["BODY1", "BODY2"]
        if withRuleMarker {
            boxes.append(box("FOOTNOTE_RULE", text: "FOOTNOTE_RULE —————", x: 0.12, y: 0.72, w: 0.30, h: 0.03, font: 8))
            expected.append("FOOTNOTE_RULE")
        }
        for index in 0..<footnoteCount {
            let marker = "\(markerPrefix)_\(index + 1)"
            boxes.append(box(marker, x: 0.12, y: 0.78 + CGFloat(index) * 0.045, w: 0.76, h: 0.035, font: 8))
            expected.append(marker)
        }
        return fixture(name, category: "footnotes-captions", support: .supported, boxes: boxes, expected: expected)
    }

    private static func bodyWithCaption(_ name: String, captionY: CGFloat, twoColumns: Bool = false) -> TestLayoutFixture {
        if twoColumns {
            let boxes = [
                box("L1", x: 0.08, y: 0.12, w: 0.38, h: 0.06),
                box("R1", x: 0.54, y: 0.12, w: 0.38, h: 0.06),
                box("CAPTION", x: 0.20, y: captionY, w: 0.60, h: 0.05, font: 9, alignment: .center),
                box("L2", x: 0.08, y: 0.62, w: 0.38, h: 0.06),
                box("R2", x: 0.54, y: 0.62, w: 0.38, h: 0.06)
            ]
            return fixture(name, category: "footnotes-captions", support: .degradedButReadable, boxes: boxes, expected: ["L1", "R1", "CAPTION", "L2", "R2"])
        }
        let boxes = [
            box("BODY", x: 0.12, y: 0.12, w: 0.76, h: 0.12),
            box("CAPTION", x: 0.22, y: captionY, w: 0.56, h: 0.05, font: 9, alignment: .center)
        ]
        return fixture(name, category: "footnotes-captions", support: .supported, boxes: boxes, expected: ["BODY", "CAPTION"])
    }

    private static func runningMatter(
        _ name: String,
        headers: [String]? = nil,
        footers: [String]? = nil
    ) -> TestLayoutFixture {
        let count = max(headers?.count ?? 0, footers?.count ?? 0, 4)
        var pages: [TestLayoutPage] = []
        var expected: [String] = []
        for index in 0..<count {
            var boxes: [TestLayoutTextBox] = []
            if let headers, index < headers.count {
                boxes.append(box(headers[index], x: 0.18, y: 0.035, w: 0.64, h: 0.035, font: 9, alignment: .center))
                expected.append(headers[index])
            }
            let body = "BODY_PAGE_\(index + 1)"
            boxes.append(box(body, x: 0.12, y: 0.16, w: 0.76, h: 0.10))
            expected.append(body)
            if let footers, index < footers.count {
                let marker = "FOOTER_\(index + 1)"
                boxes.append(box(marker, text: "\(marker) \(footers[index])", x: 0.30, y: 0.93, w: 0.40, h: 0.025, font: 8, alignment: .center))
                expected.append(marker)
            }
            pages.append(TestLayoutPage(boxes: boxes))
        }
        return TestLayoutFixture(name: name, category: "running-matter", support: .supported, pages: pages, expectedMarkerOrder: expected, notes: "Document-level running matter fixture")
    }

    private static func floatingBox(_ name: String, x: CGFloat, y: CGFloat) -> TestLayoutFixture {
        let boxes = [
            box("BODY1", x: 0.08, y: 0.12, w: 0.84, h: 0.07),
            box("FLOAT", x: x, y: y, w: 0.30, h: 0.11, font: 10),
            box("BODY2", x: 0.08, y: 0.30, w: 0.84, h: 0.07),
            box("BODY3", x: 0.08, y: 0.50, w: 0.84, h: 0.07)
        ]
        return fixture(name, category: "difficult-positioning", support: .degradedButReadable, boxes: boxes, expected: ["BODY1", "BODY2", "BODY3", "FLOAT"])
    }

    private static func transformed(
        _ name: String,
        size: CGSize = CGSize(width: 612, height: 792),
        rotation: Int = 0,
        crop: NSEdgeInsets = .zero
    ) -> TestLayoutFixture {
        fixture(
            name,
            category: "difficult-positioning",
            support: .supported,
            boxes: [
                box("TOP_LEFT", x: 0.08, y: 0.10, w: 0.34, h: 0.06),
                box("BOTTOM_RIGHT", x: 0.58, y: 0.78, w: 0.34, h: 0.06)
            ],
            expected: ["TOP_LEFT", "BOTTOM_RIGHT"],
            pageSize: size,
            crop: crop,
            rotation: rotation
        )
    }

    private static func mixedOrientation(_ name: String) -> TestLayoutFixture {
        let portrait = TestLayoutPage(boxes: [box("PORTRAIT", x: 0.12, y: 0.15, w: 0.76, h: 0.08)])
        let landscape = TestLayoutPage(size: CGSize(width: 792, height: 612), boxes: [box("LANDSCAPE", x: 0.12, y: 0.15, w: 0.76, h: 0.08)])
        return TestLayoutFixture(name: name, category: "difficult-positioning", support: .supported, pages: [portrait, landscape], expectedMarkerOrder: ["PORTRAIT", "LANDSCAPE"], notes: "Variable page-size document")
    }

    private static func superscriptFixture(_ name: String) -> TestLayoutFixture {
        let boxes = [
            box("BASE_TEXT", x: 0.12, y: 0.18, w: 0.62, h: 0.06),
            box("SUPER_1", x: 0.73, y: 0.16, w: 0.08, h: 0.025, font: 7),
            box("NEXT_LINE", x: 0.12, y: 0.31, w: 0.76, h: 0.06)
        ]
        return fixture(name, category: "difficult-positioning", support: .degradedButReadable, boxes: boxes, expected: ["BASE_TEXT", "SUPER_1", "NEXT_LINE"])
    }

    private static func duplicateLayer(_ name: String, nearDuplicate: Bool = false) -> TestLayoutFixture {
        let first = box("DUPLICATE", text: "DUPLICATE same semantic text", x: 0.12, y: 0.16, w: 0.76, h: 0.06)
        let second = box("DUPLICATE_LAYER", text: nearDuplicate ? "DUPLICATE same semantic text." : "DUPLICATE same semantic text", x: 0.1205, y: 0.1605, w: 0.76, h: 0.06)
        let boxes = [first, second, box("AFTER", x: 0.12, y: 0.30, w: 0.76, h: 0.06)]
        return fixture(name, category: "difficult-positioning", support: .degradedButReadable, boxes: boxes, expected: ["DUPLICATE", "AFTER"], notes: "Overlapping duplicate layer should eventually deduplicate spatially")
    }

    private static func languageFixture(_ name: String, text: String, support: TestLayoutSupport = .supported) -> TestLayoutFixture {
        fixture(name, category: "scripts-languages", support: support, boxes: [box("LANG", text: text, x: 0.10, y: 0.16, w: 0.80, h: 0.12, font: 14)], expected: ["LANG"])
    }

    private static func scannedEquivalent(of fixture: TestLayoutFixture) -> TestLayoutFixture {
        let pages = fixture.pages.map { page in
            TestLayoutPage(size: page.size, cropInsets: page.cropInsets, rotation: page.rotation, rendering: .scanned, boxes: page.boxes)
        }
        return TestLayoutFixture(name: fixture.name, category: "ocr-equivalents", support: fixture.support, pages: pages, expectedMarkerOrder: fixture.expectedMarkerOrder, notes: "Image-only equivalent of positioned native fixture")
    }

    private static func mixedNativeScannedDocument(_ name: String) -> TestLayoutFixture {
        let native = TestLayoutPage(rendering: .native, boxes: [box("NATIVE_PAGE", x: 0.10, y: 0.18, w: 0.80, h: 0.09)])
        let scanned = TestLayoutPage(rendering: .scanned, boxes: [box("SCANNED_PAGE", x: 0.10, y: 0.18, w: 0.80, h: 0.09, font: 16)])
        return TestLayoutFixture(name: name, category: "ocr-equivalents", support: .supported, pages: [native, scanned], expectedMarkerOrder: ["NATIVE_PAGE", "SCANNED_PAGE"], notes: "Mixed native and image-only pages")
    }
}
