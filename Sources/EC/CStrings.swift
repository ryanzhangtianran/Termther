import Foundation

/// cgo declares its exported parameters as non-const `char *`, which Swift will
/// not bridge a String literal to, so every call needs a mutable copy.
func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>]) -> R) -> R {
    let copies = strings.map { strdup($0)! }
    defer { copies.forEach { free($0) } }
    return body(copies)
}
