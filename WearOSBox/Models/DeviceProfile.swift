import Foundation
import SwiftData

/// 设备配对档案（SwiftData 持久化）
@Model
final class DeviceProfile {
    /// 设备备注名（如：小米Watch5）
    var name: String
    /// 配对时的 IP 地址（仅存档，不锁定后续连接）
    var pairIP: String
    /// 配对时的端口（仅存档，不锁定后续连接）
    var pairPort: Int
    /// ADB RSA 私钥（用于后续连接认证）
    var adbPrivateKey: Data?
    /// ADB RSA 公钥
    var adbPublicKey: Data?
    /// 配对时间
    var createdAt: Date
    /// 最后连接时间
    var lastConnectedAt: Date?
    /// 备注信息
    var note: String

    init(name: String, pairIP: String, pairPort: Int, adbPrivateKey: Data? = nil,
         adbPublicKey: Data? = nil, note: String = "") {
        self.name = name
        self.pairIP = pairIP
        self.pairPort = pairPort
        self.adbPrivateKey = adbPrivateKey
        self.adbPublicKey = adbPublicKey
        self.createdAt = Date()
        self.note = note
    }
}
