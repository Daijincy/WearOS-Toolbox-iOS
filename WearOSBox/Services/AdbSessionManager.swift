import Foundation

/// ADB 会话管理器：持有连接状态、设备档案、协议客户端
/// 单例，供所有页面共享当前会话
final class AdbSessionManager: ObservableObject, @unchecked Sendable {
    static let shared = AdbSessionManager()

    @Published var state: ConnectionState = .idle
    @Published var currentDevice: DeviceProfile?
    @Published var currentTarget: AdbTarget?

    private(set) var client: AdbClient?
    private(set) var ops: AdbOps?
    private(set) var shell: AdbShell?
    private(set) var sync: AdbSync?

    private let pairingClient = AdbPairingClient()

    private init() {
        pairingClient.onLog = { AppLogger.shared.log($0, level: .adb) }
    }

    // MARK: - 配对

    /// 执行无线调试配对
    /// - Parameters:
    ///   - profile: 配对档案（含 IP、端口、配对码）
    ///   - completion: 配对结果
    func pair(profile: DeviceProfile, code: String,
              completion: @escaping (Result<Void, Error>) -> Void) {
        state = .pairing
        // 复用档案已保存密钥（若存在），保证配对与后续连接使用同一公钥
        var savedKey: AdbClient.AdbKeyPair?
        if let keyData = profile.adbPrivateKey {
            savedKey = AdbClient.restoreKeyPair(privateKeyData: keyData)
        }
        pairingClient.pair(host: profile.pairIP, port: profile.pairPort, code: code, keyPair: savedKey) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let keyPair):
                    // 保存密钥到档案
                    profile.adbPrivateKey = keyPair.privateKeyData
                    profile.adbPublicKey = keyPair.publicKeyPEM
                    self.state = .idle
                    completion(.success(()))
                case .failure(let err):
                    self.state = .idle
                    completion(.failure(err))
                }
            }
        }
    }

    // MARK: - 连接

    /// 连接设备（使用档案保存的密钥；若密钥无效可回退为发送公钥触发授权）
    func connect(profile: DeviceProfile, ip: String, port: Int,
                 completion: @escaping (Result<Void, Error>) -> Void) {
        disconnect()
        state = .connecting
        currentDevice = profile
        currentTarget = AdbTarget(ip: ip, port: port)

        let client = AdbClient()
        client.onLog = { AppLogger.shared.log($0, level: .adb) }
        self.client = client

        // 从档案恢复密钥
        var savedKey: AdbClient.AdbKeyPair?
        if let keyData = profile.adbPrivateKey {
            savedKey = AdbClient.restoreKeyPair(privateKeyData: keyData)
        }

        client.connect(host: ip, port: port, keyProvider: { savedKey }) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let system):
                    self.state = .connected
                    self.ops = AdbOps(client: client)
                    self.shell = AdbShell(client: client)
                    self.sync = AdbSync(client: client)
                    self.ops?.onLog = { AppLogger.shared.log($0, level: .adb) }
                    profile.lastConnectedAt = Date()
                    completion(.success(()))
                case .failure(let err):
                    self.disconnect()
                    completion(.failure(err))
                }
            }
        }
    }

    /// 断开当前连接
    func disconnect() {
        client?.disconnect()
        client = nil
        ops = nil
        shell = nil
        sync = nil
        if state == .connected || state == .connecting {
            state = .idle
        }
        currentDevice = nil
        currentTarget = nil
    }

    var isConnected: Bool {
        state == .connected
    }
}
