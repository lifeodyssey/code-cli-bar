import Foundation

/// Bounds temporary Foundation objects to one read or parsed record. Cost
/// scans run on worker threads whose autorelease pools may otherwise retain
/// an entire multi-gigabyte history until the task yields.
enum CostUsageLineReader {
    private static let chunkSize = 64 * 1024

    @discardableResult
    static func forEachLine(in file: URL, _ body: (Data) -> Void) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return forEachLine(from: handle, body)
    }

    @discardableResult
    static func forEachLine(from handle: FileHandle, _ body: (Data) -> Void) -> Bool {
        var buffer: [UInt8] = []
        var lineStart = 0
        var cursor = 0
        do {
            while true {
                let chunk = try autoreleasepool {
                    try handle.read(upToCount: chunkSize)
                }
                guard let chunk, !chunk.isEmpty else { break }
                buffer.append(contentsOf: chunk)
                while cursor < buffer.count {
                    if buffer[cursor] == 0x0A {
                        if cursor > lineStart {
                            autoreleasepool { body(Data(buffer[lineStart..<cursor])) }
                        }
                        lineStart = cursor + 1
                    }
                    cursor += 1
                }
                if lineStart >= chunkSize {
                    buffer.removeFirst(lineStart)
                    cursor -= lineStart
                    lineStart = 0
                }
            }
            if lineStart < buffer.count {
                autoreleasepool { body(Data(buffer[lineStart...])) }
            }
            return true
        } catch {
            return false
        }
    }
}
