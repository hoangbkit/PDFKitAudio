# PDFKitAudio Demo

A shared SwiftUI demo for PDFKitAudio with separate macOS and iOS application targets, following the same project structure used by `hoangbkit/EpubKit`.

## Targets

- `PDFKitAudioDemo` — macOS 15+, bundle identifier `com.hoangbkit.pdfkit.demo`
- `PDFKitAudioDemo-iOS` — iOS 26+, bundle identifier `com.hoangbkit.pdfkit.demo.ios`

The package supports macOS 15+ and iOS 26+.

## Generate and run

```bash
cd Demo
xcodegen generate --spec project.yml
open PDFKitAudioDemo.xcodeproj
```

Choose `PDFKitAudioDemo` for macOS or `PDFKitAudioDemo-iOS` for iOS. The generated Xcode project is ignored and should not be committed.

## What it demonstrates

- bundled `sample.pdf` with a one-click **Use Sample PDF** action
- **Pick PDF File** for importing a user document
- macOS `NSOpenPanel`
- iOS `fileImporter`
- sandbox-safe security-scoped file access
- async parsing with stage/page progress
- PDF metadata and cover display
- chapter and outline navigation
- native/OCR/empty provenance counts
- plain extracted text
- PDF preview
- audiobook/TTS chunk preview
- cross-platform copy actions

## Demo Release

The manual Demo Release workflow supports:

- platform: `macOS`, `iOS`, or `both`
- configuration: `Debug`, `Release`, or `both`

Selected artifacts are published in one `mycli-build-*` prerelease. macOS uses an unsigned universal `.app.zip`; iOS uses an unsigned `.xcarchive.zip` for local mycli signing/export.
