/// Bytes waiting to go one way. Taken from the front by moving an index, not
/// by shifting what is left: `removeFirst` copies the rest every time, which
/// over a large transfer is quadratic.
struct ByteQueue {
    private var storage: [UInt8] = []
    private var head = 0

    var count: Int { storage.count - head }

    mutating func append<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        storage.append(contentsOf: bytes)
    }

    func peek(_ max: Int) -> ArraySlice<UInt8> {
        storage[head..<min(storage.count, head + max)]
    }

    mutating func consume(_ n: Int) {
        head += min(n, count)
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 64 * 1024 && head * 2 > storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }
}
