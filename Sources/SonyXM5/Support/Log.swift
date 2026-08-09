import Foundation

/// Minimal append-only log at ~/Library/Logs/Aura.log.
///
/// Bluetooth failures are the hardest thing to diagnose in an app with no
/// window, so connection state and every frame exchanged are recorded.
enum Log {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return dir.appendingPathComponent("Aura.log")
    }()

    private static let queue = DispatchQueue(label: "com.github.argjentsahiti.aura.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ tag: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(tag)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func hex(_ tag: String, _ bytes: [UInt8]) {
        write(tag, bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
    }

    /// Called at launch so each run starts from a readable boundary.
    static func startSession() {
        queue.async {
            let header = "\n===== Aura launched \(Date()) =====\n"
            guard let data = header.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
