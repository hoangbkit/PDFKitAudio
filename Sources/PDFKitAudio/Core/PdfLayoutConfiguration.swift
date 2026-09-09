import Foundation

/// Controls whether PDFKitAudio reconstructs page reading order from positioned
/// text geometry before document cleanup.
public enum PdfLayoutMode: Hashable, Sendable {
    /// Analyze only pages that the conservative complexity detector identifies as
    /// likely to benefit from layout reconstruction. This is the default.
    case auto

    /// Preserve the legacy selected-text path and skip positioned layout work.
    case never

    /// Attempt layout reconstruction for every page with usable positioned text.
    /// Unsafe or low-confidence reconstruction still falls back to selected text.
    case always
}

/// Public layout configuration for `PdfParser`.
///
/// Heuristic thresholds intentionally remain internal. The package exposes only
/// the policy decision callers actually need while retaining freedom to improve
/// the geometry implementation without growing the public API surface.
public struct PdfLayoutConfiguration: Hashable, Sendable {
    public var mode: PdfLayoutMode

    public init(mode: PdfLayoutMode = .auto) {
        self.mode = mode
    }
}
