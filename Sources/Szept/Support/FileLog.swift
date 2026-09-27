import Foundation

/// Append-only file logger. os_log does not persist for this ad-hoc signed
/// build, so key lifecycle events also land in ~/Library/Logs/Szept.log,
/// which can be read over SSH after a failure.
enum FileLog {
    private static let queue = DispatchQueue(label: "dev.kocheck.Szept.filelog")
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
