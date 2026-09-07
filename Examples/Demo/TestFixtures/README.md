# Demo PDF test fixtures

These intentionally tiny PDFs are checked in for quick manual testing of the macOS example app:

- `digital-text.pdf` - two native-text pages for extraction order and page provenance.
- `outline-chapters.pdf` - three pages with front matter plus two top-level PDF outline entries.
- `blank-page.pdf` - one valid blank page for empty-content behavior.

The package unit tests still generate richer runtime fixtures, including OCR cases. Keeping the checked-in example corpus tiny makes the repository lightweight while providing a few files that can be opened immediately from Finder or Xcode.
