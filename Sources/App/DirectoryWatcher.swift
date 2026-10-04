import Foundation

/// A directory on disk, watched for writes.
enum DirectoryWatcher {
    /// One element per change to the directory, `settling` seconds after the
    /// last of a burst; nil when the directory cannot be opened. The
    /// directory rather than a file in it: an editor saves a new file and
    /// renames it into place, which the old file never sees.
    static func changes(in directory: URL, settling: TimeInterval = 0.3) -> AsyncStream<Void>? {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        return AsyncStream { continuation in
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: .write, queue: .main)
            var pending: DispatchWorkItem?
            source.setEventHandler {
                pending?.cancel()
                let item = DispatchWorkItem { continuation.yield() }
                pending = item
                DispatchQueue.main.asyncAfter(deadline: .now() + settling, execute: item)
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            continuation.onTermination = { _ in source.cancel() }
        }
    }
}
