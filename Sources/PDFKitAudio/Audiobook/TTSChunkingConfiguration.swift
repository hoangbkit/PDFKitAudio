import Foundation

/// Engine-agnostic limits for PDFKitAudio's convenience audiobook segmentation.
///
/// PDFKitAudio deliberately does not model TTS-engine token limits, prosody, or
/// pause durations. Spokio's TextToSpeech layer owns those concerns.
public struct TTSChunkingConfiguration: Sendable, Equatable {
    public var maxCharacters: Int
    public var preferredMinimumCharacters: Int
    public var preserveParagraphs: Bool

    public init(
        maxCharacters: Int = 2_800,
        preferredMinimumCharacters: Int = 700,
        preserveParagraphs: Bool = true
    ) {
        let safeMaximum = max(1, maxCharacters)
        self.maxCharacters = safeMaximum
        self.preferredMinimumCharacters = min(
            safeMaximum,
            max(0, preferredMinimumCharacters)
        )
        self.preserveParagraphs = preserveParagraphs
    }

    public static let audiobookDefault = TTSChunkingConfiguration()
}
