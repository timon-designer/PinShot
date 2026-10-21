import Foundation

/// 轻量诊断日志：写到 /tmp/snipshot.log，方便排查"没反应"类问题。
/// （App 非沙盒化，可直接写 /tmp）
enum SnipLog {
    static let fileURL = URL(fileURLWithPath: "/tmp/snipshot.log")

    private static let queue = DispatchQueue(label: "com.taoliu.snipshot.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// 清空日志（每次启动时调用，避免无限增长）
    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
