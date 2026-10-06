# Paragraph inference fixture

The generated fixture in `PdfParagraphInferenceTests.nativeFixture()` uses original prose rather than redistributing book content. It reproduces repeated first-line indentation with uniform spacing, including a sentence transition inside a physical line that must remain in the same paragraph.

The publisher's [Eloquent JavaScript, 4th edition PDF](https://eloquentjavascript.net/Eloquent_JavaScript.pdf), downloaded on 2026-10-06, exposes this convention on PDF page 13 (zero-based index 12, printed page 1):

- page size: approximately 595.28 × 841.89 points
- body left edge: approximately 89.29 points
- paragraph first-line edge: approximately 102.24 points
- indent: approximately 12.95 points
- regular vertical line step: approximately 15.54 points
- body glyph-box height: approximately 12.95 points

These are source measurements from PyMuPDF, not evidence that Apple PDFKit reports exactly the same rectangles. The user-uploaded edition has not been identified. Apple-platform regression execution remains pending.

The original issue incorrectly expected a paragraph break before the sentence beginning “But for unique”. The publisher's PDF and [HTML introduction](https://eloquentjavascript.net/00_intro.html) place it within the preceding paragraph. The fixture therefore includes an equivalent sentence transition as a negative case.

Coverage is split between exact text/geometry unit inputs, a generated native PDF through parser modes, analyzed column materialization, and injected OCR observations. Existing paragraph tests retain the strong-gap, explicit-boundary, uniform-spacing and invalid-geometry baseline.
