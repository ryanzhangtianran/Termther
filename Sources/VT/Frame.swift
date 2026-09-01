import Foundation

/// One cell of the grid, resolved down to what a renderer actually draws.
///
/// Colours are already flattened here: libghostty-vt resolves palette indices
/// and the three places a background can come from, so `nil` genuinely means
/// "use the terminal default" rather than "look somewhere else".
public struct Cell: Equatable, Sendable {
    /// The full grapheme cluster, so combining marks and emoji stay together.
    /// Empty for a blank cell and for the trailing half of a wide character.
    public var text: String
    public var foreground: Color?
    public var background: Color?
    public var attributes: Attributes
    public var isSelected: Bool

    public struct Attributes: OptionSet, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let bold          = Attributes(rawValue: 1 << 0)
        public static let italic        = Attributes(rawValue: 1 << 1)
        public static let faint         = Attributes(rawValue: 1 << 2)
        public static let blink         = Attributes(rawValue: 1 << 3)
        public static let inverse       = Attributes(rawValue: 1 << 4)
        public static let invisible     = Attributes(rawValue: 1 << 5)
        public static let strikethrough = Attributes(rawValue: 1 << 6)
        public static let overline      = Attributes(rawValue: 1 << 7)
        public static let underline     = Attributes(rawValue: 1 << 8)
    }
}

public struct Color: Equatable, Sendable, Codable {
    public var red: UInt8, green: UInt8, blue: UInt8
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red; self.green = green; self.blue = blue
    }
}

public struct Row: Equatable, Sendable {
    public var y: UInt16
    public var cells: [Cell]
}

public struct Cursor: Equatable, Sendable {
    public enum Shape: Sendable { case block, bar, underline, hollowBlock }
    public var x: UInt16
    public var y: UInt16
    public var shape: Shape
    public var isVisible: Bool
    public var isBlinking: Bool
    /// True while the terminal believes a password is being typed, which is a
    /// reason to stop blinking and never screenshot.
    public var isPasswordInput: Bool
}

/// What changed since the last frame.
///
/// `rows` carries only the rows that need redrawing. `isFullRedraw` says the
/// renderer should discard whatever it cached -- a resize, a scroll, a palette
/// change -- rather than trusting per-row diffs.
public struct Frame: Sendable {
    public var cols: UInt16
    public var rows: UInt16
    public var isFullRedraw: Bool
    public var dirtyRows: [Row]
    public var cursor: Cursor?
    public var defaultForeground: Color
    public var defaultBackground: Color

    public var isEmpty: Bool { dirtyRows.isEmpty && !isFullRedraw }
}
