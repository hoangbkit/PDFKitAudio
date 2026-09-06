# PDFKitAudio

Lightweight PDF extraction and audiobook-oriented text preparation for Apple platforms.

The current implementation uses PDFKit native text extraction first and can selectively fall back to Vision OCR. It intentionally avoids heavyweight document-understanding models.

## Current limitations

PDF text does not carry a universal semantic reading order. PDFKit generally works well for ordinary books and single-column documents, but results can be imperfect for:

- multi-column academic papers and magazines
- pages with floating text boxes, sidebars, or complex positioned layouts
- tables where visual structure is important
- PDFs with malformed or unusual embedded text encodings
- nested or repeated outline destinations (chapter construction is scheduled for hardening)
- scanned documents in languages outside the OCR configuration currently used by the parser

These are documented limitations rather than reasons to introduce a heavyweight layout model into the default parsing path.

## Development

Run the package regression suite with:

```sh
swift test
```

Tests generate small PDF fixtures at runtime so binary fixture files are not required in the repository.

See `PLAN.md` for the phased production-hardening plan aimed at Spokio integration.
