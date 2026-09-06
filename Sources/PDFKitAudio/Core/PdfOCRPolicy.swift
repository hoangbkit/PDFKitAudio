import Foundation

enum PdfNativeTextQuality: Equatable {
    case empty
    case insufficient
    case suspicious
    case usable
}

enum PdfOCRPolicy {
    static func quality(of text: String, threshold: Int) -> PdfNativeTextQuality {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        var visibleCount = 0
        var informativeCount = 0
        var suspiciousCount = 0

        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            visibleCount += 1
            if CharacterSet.alphanumerics.contains(scalar) {
                informativeCount += 1
            }
            if scalar.value == 0xFFFD || CharacterSet.controlCharacters.contains(scalar) {
                suspiciousCount += 1
            }
        }

        guard visibleCount > 0 else { return .empty }

        let suspiciousRatio = Double(suspiciousCount) / Double(visibleCount)
        let informativeRatio = Double(informativeCount) / Double(visibleCount)
        if suspiciousRatio > 0.02 || (visibleCount >= max(12, threshold / 2) && informativeRatio < 0.45) {
            return .suspicious
        }

        if trimmed.count < max(0, threshold) {
            return .insufficient
        }

        return .usable
    }

    static func shouldRunOCR(nativeText: String, configuration: PdfOCRConfiguration) -> Bool {
        switch configuration.mode {
        case .always:
            return true
        case .never:
            return false
        case .auto:
            return quality(of: nativeText, threshold: configuration.nativeTextThreshold) != .usable
        }
    }

    static func shouldPreferOCR(
        ocrText: String,
        confidence: Double,
        nativeText: String,
        configuration: PdfOCRConfiguration
    ) -> Bool {
        let trimmedOCR = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOCR.isEmpty else { return false }

        let normalizedConfidence = min(1, max(0, confidence))
        let ocrInformation = informationCount(in: trimmedOCR)
        guard ocrInformation > 0 else { return false }

        let nativeQuality = quality(of: nativeText, threshold: configuration.nativeTextThreshold)
        let nativeInformation = informationCount(in: nativeText)

        switch nativeQuality {
        case .empty:
            return normalizedConfidence >= 0.05

        case .insufficient:
            return normalizedConfidence >= 0.20
                && ocrInformation >= max(3, Int(Double(nativeInformation) * 0.8))

        case .suspicious:
            return normalizedConfidence >= 0.20
                && ocrInformation >= max(3, Int(Double(nativeInformation) * 0.6))

        case .usable:
            let minimumGain = max(12, nativeInformation / 4)
            return normalizedConfidence >= 0.65
                && ocrInformation >= nativeInformation + minimumGain
        }
    }

    private static func informationCount(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                count += 1
            }
        }
    }
}
