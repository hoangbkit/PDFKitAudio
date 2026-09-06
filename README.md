# PDFKitAudio

Lightweight PDF extraction and audiobook-oriented text preparation for Apple platforms.

The parser uses PDFKit native text first and selectively falls back to Vision OCR. It intentionally avoids heavyweight document-understanding models.

## OCR

Default parsing keeps healthy digital PDFs on the native fast path. Pages with missing, short, or suspicious native text become OCR candidates.

Vision automatic language detection is enabled by default; PDFKitAudio no longer hard-codes English. Callers that need tighter control can provide explicit recognition languages and recognition behavior:

```swift
let parser = PdfParser(ocrConfiguration: PdfOCRConfiguration(
    mode: .auto,
    recognitionLanguages: ["vi-VN", "en-US"],
    automaticallyDetectsLanguage: false,
    recognitionLevel: .accurate
))

let book = try parser.parse(at: url)
```

`PdfParser()` and `PdfParser(ocrMode:)` remain available for simple and existing callers.

Running OCR does not automatically replace native PDF text. PDFKitAudio keeps the native result when OCR is empty, low-confidence, or does not provide enough information gain.

## Chapters and navigation

PDF outline entries are retained as navigation metadata independently from audiobook chapter boundaries. Nested and repeated outline destinations are normalized into monotonic, non-overlapping spoken chapter ranges, and meaningful content before the first chapter is preserved as front matter.

## Current limitations

PDF text does not carry a universal semantic reading order. PDFKit generally works well for ordinary books and single-column documents, but results can still be imperfect for:

- multi-column academic papers and magazines
- pages with floating text boxes, sidebars, or complex positioned layouts
- tables where visual structure is important
- PDFs with malformed or unusual embedded text encodings
- scanned languages or scripts not supported by the Vision version on the target OS

These are documented limitations rather than reasons to introduce a heavyweight layout model into the default parsing path.

## Development

Run the package regression suite with:

```sh
swift test
```

Tests generate small PDF fixtures at runtime so binary fixture files are not required in the repository.

Current hardening status: Phases 0-3 are complete. See `PLAN.md` for the remaining audiobook cleanup, segmentation, concurrency, platform, and Spokio integration phases.
