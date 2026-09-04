import Foundation

/// Local-only logger. Never leaves the machine.
/// File: ~/Library/Logs/ZephyrFlow/zephyrflow.log (rotated at ~2 MB).
enum ZFLog {
    private static let queue = DispatchQueue(label: "dev.zephyrflow.log")
    private static let maxBytes: UInt64 = 2 * 1024 * 1024

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/ZephyrFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("zephyrflow.log")
    }()

    /// Set from SettingsStore; debug lines are skipped when false.
    nonisolated(unsafe) static var debugEnabled = false

    static func info(_ message: String, file: String = #fileID, line: Int = #line) {
        write("INFO", message, file: file, line: line)
    }

    static func error(_ message: String, file: String = #fileID, line: Int = #line) {
        write("ERROR", message, file: file, line: line)
    }

    static func debug(_ message: String, file: String = #fileID, line: Int = #line) {
        guard debugEnabled else { return }
        write("DEBUG", message, file: file, line: line)
    }

    private static func write(_ level: String, _ message: String, file: String, line: Int) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let lineOut = "\(ts) [\(level)] \(file):\(line) \(message)\n"
        queue.async {
            rotateIfNeeded()
            guard let data = lineOut.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path),
                let handle = try? FileHandle(forWritingTo: url)
            {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
        #if DEBUG
            print(lineOut, terminator: "")
        #endif
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? UInt64,
            size >= maxBytes
        else { return }
        let backup = url.deletingLastPathComponent().appendingPathComponent("zephyrflow.log.1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
