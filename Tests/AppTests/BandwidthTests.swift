import Foundation
import Testing
@testable import App

/// An SSH tab's bandwidth fits at the end of a sidebar row.
@Test("bandwidth reads in a few characters", arguments: [
    (0.0, "0B"), (812.0, "812B"), (4300.0, "4.2K"), (1_000_000.0, "976K"),
    (32_000_000.0, "30M"), (3_000_000_000.0, "2.8G"),
])
func compactBandwidth(perSecond: Double, reads: String) {
    #expect(ToolsSidebar.compact(perSecond) == reads)
}

/// Nothing carried yet reads as a number, like everything after it.
@Test("zero bytes is a figure, not a word")
@MainActor func zeroBytesIsAFigure() {
    #expect(ByteCountFormatter.numeric(UInt64(0)).first?.isNumber == true)
}
