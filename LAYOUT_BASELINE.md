# Layout analyzer baseline

Measured before layout-analyzer production integration so later phases have a stable comparison point.

## Environment

- GitHub Actions `macos-14-arm64`
- macOS 14.8.9
- Swift 5.10
- PDFKitAudio layout fixture corpus: 75 deterministic fixtures total
- Native reading-order baseline: 72 native fixtures

## Native reading-order baseline

| Category | Fixtures | Marker coverage | Pairwise order |
| --- | ---: | ---: | ---: |
| overall | 72 | 100.00% | 87.13% |
| columns | 11 | 100.00% | 96.35% |
| difficult positioning | 9 | 100.00% | 90.48% |
| footnotes / captions | 6 | 100.00% | 100.00% |
| mixed regions | 8 | 100.00% | 94.00% |
| running matter | 7 | 100.00% | 96.92% |
| scripts / languages | 5 | 100.00% | 100.00% |
| side content | 6 | 100.00% | 81.08% |
| simple | 11 | 100.00% | 91.67% |
| tables | 9 | 100.00% | 76.03% |

Duplicate semantic markers observed in the corrected baseline: **0**.

These numbers intentionally describe current PDFKit ordering rather than an analyzer result. They show that text conservation is already strong while tables and side content are the clearest reading-order weaknesses.

## Performance baseline

One-time opt-in stress run using `PDFKITAUDIO_RUN_LAYOUT_BENCHMARKS=1`:

| Fixture | Pages | Wall clock | Peak RSS | OCR-selected pages | Output characters |
| --- | ---: | ---: | ---: | ---: | ---: |
| simple-100 | 100 | 0.1258 s | 207,601,664 B | 0 | 12,300 |
| two-column-100 | 100 | 0.1383 s | 258,834,432 B | 0 | 18,500 |
| mixed-native-scanned-20 | 20 | 4.0482 s | 480,706,560 B | 0 | 390 |
| simple-stress-500 | 500 | 0.9172 s | 934,150,144 B | 0 | 61,500 |

The mixed benchmark records OCR selection as an observed metric rather than asserting that OCR must win. OCR selection policy is covered by dedicated OCR tests; the benchmark exists to measure time, memory, page count, and output size across mixed content.

## Phase 0 conclusion

Phase 0 exit criteria are satisfied:

- deterministic fixture matrix exists and exceeds the 50-layout minimum
- current native reading order is measurable by semantic marker relationships
- performance and memory baselines are recorded
- diagnostic JSON support exists for fixture inspection
- no production parser text-selection behavior was changed
