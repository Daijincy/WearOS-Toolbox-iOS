import Foundation

/// 连接状态
enum ConnectionState: Equatable {
    case idle           // 未连接
    case pairing        // 配对中
    case connecting     // 连接中
    case connected      // 已连接
    case failed(String) // 失败（带错误信息）
}

/// ADB 连接配置（当前会话）
struct AdbTarget: Equatable {
    var ip: String
    var port: Int
}

/// 功能模块枚举（主页面网格）
enum FeatureModule: String, CaseIterable, Identifiable {
    case installApk = "安装APK"
    case installSplit = "安装Split APK"
    case terminal = "终端"
    case command = "命令行"
    case screen = "远程屏幕"
    case screenTools = "屏幕工具"
    case battery = "电池工具"
    case files = "文件管理"
    case apps = "应用管理"
    case clipboard = "剪切板"
    case backup = "备份恢复"
    case log = "日志"
    case settings = "设置"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .installApk: return "square.and.arrow.down.fill"
        case .installSplit: return "square.stack.3d.up.fill"
        case .terminal: return "terminal.fill"
        case .command: return "chevron.left.forwardslash.chevron.right"
        case .screen: return "rectangle.inset.filled.and.person.filled"
        case .screenTools: return "rectangle.dashed"
        case .battery: return "battery.100.bolt"
        case .files: return "folder.fill"
        case .apps: return "square.grid.2x2.fill"
        case .clipboard: return "doc.on.doc.fill"
        case .backup: return "externaldrive.fill.badge.timemachine"
        case .log: return "doc.text.magnifyingglass"
        case .settings: return "gearshape.fill"
        }
    }
}

/// 通用工具结果
struct ToolResult {
    var success: Bool
    var message: String
}
