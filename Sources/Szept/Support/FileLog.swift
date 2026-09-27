import Foundation

/// Append-only file logger. os_log does not persist for this ad-hoc signed
/// build, so key lifecycle events also land in ~/Library/Logs/Szept.log,
/// which can be read over SSH after a failure.
enum FileLog {
    private static let queue = DispatchQueue(label: "dev.zackslash.Szept.filelog")
    private static var handle: FileHandle?

    private static func openHandle() -> FileHandle? {
        guard handle == nil else { return handle }
        guard let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs") else { return nil }
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let url = logsDir.appendingPathComponent("Szept.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        // Cap the log: an oversized file from a previous run is truncated to
        // empty before appending (simplest correct retention).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64, size > 1_000_000 {
            try? handle?.truncate(atOffset: 0)
        }
        try? handle?.seekToEndOfFile()
        return handle
    }

    static func log(_ message: String) {
        let line = "\(Date().ISO8601Format()) \(message)\n"
        queue.async {
            guard let h = openHandle() else { return }
            h.write(line.data(using: .utf8)!)
        }
    }
}
