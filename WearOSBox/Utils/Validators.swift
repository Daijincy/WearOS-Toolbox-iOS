import Foundation

/// IP / 端口输入校验
enum Validators {
    /// 校验 IPv4 地址格式（0.0.0.0 ~ 255.255.255.255）
    static func isValidIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let value = Int(part), (0...255).contains(value) else { return false }
            // 禁止前导零（如 01.2.3.4 视为非法，与多数实现一致）
            if part.count > 1 && part.hasPrefix("0") { return false }
        }
        return true
    }

    /// 校验端口号（1 ~ 65535）
    static func isValidPort(_ text: String) -> Bool {
        guard let value = Int(text), (1...65535).contains(value) else { return false }
        return true
    }

    /// 校验配对码（6 位数字）
    static func isValidPairingCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy({ $0.isNumber }) else { return false }
        return true
    }
}

/// 日志工具（写入内存环形缓冲 + 可选文件）
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()
    private(set) var entries: [LogEntry] = []
    private let lock = NSLock()
    private let maxEntries = 2000

    struct LogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String

        enum Level: String {
            case info = "INFO"
            case warn = "WARN"
            case error = "ERROR"
            case adb = "ADB"
        }

        var timestampString: String {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f.string(from: date)
        }
    }

    func log(_ message: String, level: LogEntry.Level = .info) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(LogEntry(date: Date(), level: level, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        #if DEBUG
        print("[\(level.rawValue)] \(message)")
        #endif
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
