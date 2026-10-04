import Testing
@testable import VT


@Test("libghostty-vt reports its version as numbers")
func reportsLibraryVersion() {
    #expect(Terminal.libraryVersion.split(separator: ".").allSatisfy { Int($0) != nil })
}
