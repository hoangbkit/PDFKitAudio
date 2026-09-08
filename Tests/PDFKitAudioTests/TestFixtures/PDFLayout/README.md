# PDF Layout Test Fixtures

Deterministic PDFs for manual and automated layout-analyzer testing.

- `01-single-column.pdf` — simple linear article
- `02-two-columns.pdf` — two independent reading columns
- `03-three-columns.pdf` — three-column newspaper layout
- `04-spanning-headline-two-columns.pdf` — full-width heading followed by two columns
- `05-right-sidebar.pdf` — main narrative plus boxed sidebar
- `06-pull-quote.pdf` — body text interrupted visually by a pull quote
- `07-table-with-prose.pdf` — prose, ruled table, then prose
- `08-footnotes.pdf` — main body plus separated footnotes
- `09-repeated-header-footer.pdf` — three pages with repeated running matter
- `10-mixed-column-transitions.pdf` — full-width intro, two-column middle, full-width conclusion
- `11-landscape-dashboard.pdf` — landscape page with multiple boxed regions and wide data area
- `12-dense-academic.pdf` — compact two-column academic layout with references

These PDFs contain selectable native text and fixed geometry. They are intentionally small so they can be committed directly and used in CI or opened manually in Preview/PDFKit-based test apps.
