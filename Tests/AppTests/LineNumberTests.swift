import Foundation
import Testing
@testable import App

struct LineNumberTests {
    @Test("the line number counts the newlines before the place, as Characters did, a CRLF not among them")
    func countsAsCharactersDid() {
        for text in ["", "a", "a\nb\n\nc", "\n\n", "x\r\ny\nz", "e\u{301}\n\u{1F600}\nq"] {
            let string = text as NSString
            for location in 0...string.length {
                let expected = string.substring(to: location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                #expect(lineNumber(at: location, in: string) == expected, "\(text.debugDescription) at \(location)")
            }
        }
    }
}
