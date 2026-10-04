import Foundation

/// A short-lived tool run to the end: what it printed, and how it exited.
enum Subprocess {
    /// Standard input and error go nowhere. Standard output is read to the
    /// end before waiting, or a large output fills the pipe and the tool
    /// never exits.
    static func run(_ executable: URL, _ arguments: [String],
                    environment: [String: String]? = nil) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
