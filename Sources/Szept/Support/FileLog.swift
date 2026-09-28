import Foundation

/// Append-only file logger. os_log does not persist for this ad-hoc signed
/// build, so key lifecycle events also land in ~/Library/Logs/Szept.log,
/// which can be read over SSH after a failure.
enum FileLog {
    private static let queue = DispatchQueue(label: "dev.zackslash.Szept.filelog")
    private static var handle: FileHandle?
    private static var didNoteFallback = false

    private static func openHandle() -> FileHandle? {
        guard handle == nil else { return handle }
        guard let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs") else {
            return openFallbackHandle()
        }
        // The Logs directory can be missing (fresh account, cleaned temp
        // profile); create it before touching the log file.
        do {
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            return openFallbackHandle()
        }
        let url = logsDir.appendingPathComponent("Szept.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        guard handle != nil else {
            // ~/Library/Logs/Szept.log unusable; fall back to ~/.szept.log.
            return openFallbackHandle()
        }
        // Cap the log: an oversized file from a previous run is truncated to
        // empty before appending (simplest correct retention).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64, size > 1_000_000 {
            try? handle?.truncate(atOffset: 0)
        }
        try? handle?.seekToEndOfFile()
        return handle
    }

    /// Last-resort sink when ~/Library/Logs/Szept.log cannot be created or
    /// opened. Noted once on stderr; never retried per call beyond this.
    private static func openFallbackHandle() -> FileHandle? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".szept.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let fallback = try? FileHandle(forWritingTo: url)
        try? fallback?.seekToEndOfFile()
        if !didNoteFallback {
            didNoteFallback = true
            let note = "Szept: cannot log to ~/Library/Logs/Szept.log; falling back to \(url.path)\n"
            FileHandle.standardError.write(note.data(using: .utf8)!)
        }
        handle = fallback
        return fallback
    }

    static func log(_ message: String) {
        let line = "\(Date().ISO8601Format()) \(message)\n"
        queue.async {
            guard let h = openHandle() else { return }
            h.write(line.data(using: .utf8)!)
        }
    }
}
