import AppKit

/// AppKit's NSEdgeInsets lacks conveniences that the deterministic test model
/// benefits from on the Swift 5.10/macOS 14 CI toolchain. Keep these additions
/// test-only rather than leaking compatibility surface into the package.
extension NSEdgeInsets {
    static var zero: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

extension NSEdgeInsets: Equatable {
    public static func == (lhs: NSEdgeInsets, rhs: NSEdgeInsets) -> Bool {
        lhs.top == rhs.top
            && lhs.left == rhs.left
            && lhs.bottom == rhs.bottom
            && lhs.right == rhs.right
    }
}
