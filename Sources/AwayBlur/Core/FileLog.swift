import Foundation

/// A plain text log next to the other app logs, because a menu bar app that
/// only misbehaves when you are not at the keyboard is hard to watch live.
enum FileLog {
    static let url: URL = {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        return directory.appendingPathComponent("AwayBlur.log")
    }()

    private static let queue = DispatchQueue(label: "com.dora.away-blur.log")
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
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
}
