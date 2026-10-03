import Foundation
import Network
import Security

/// ADB 连接错误
enum AdbError: LocalizedError {
    case invalidState
    case connectionFailed(String)
    case authFailed
    case timeout
    case channelClosed
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidState: return "状态异常"
        case .connectionFailed(let msg): return "连接失败：\(msg)"
        case .authFailed: return "ADB 认证失败，请确认设备已授权调试"
        case .timeout: return "连接超时"
        case .channelClosed: return "通道已关闭"
        case .notConnected: return "未连接设备"
        }
    }
}

/// 单个 ADB 数据通道（OPEN / WRTE / OKAY / CLSE）
final class AdbChannel {
    enum State {
        case opening
        case open
        case closed
    }

    let localID: UInt32
    private(set) var remoteID: UInt32 = 0
    private(set) var state: State = .opening
    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?

    init(localID: UInt32) {
        self.localID = localID
    }

    func markOpen(remoteID: UInt32) {
        self.remoteID = remoteID
        self.state = .open
    }

    func close() {
        guard state != .closed else { return }
        state = .closed
        onClose?()
    }
}

/// ADB TCP 客户端：连接 → RSA 认证 → CNXN → 通道复用
/// 协议参考 AOSP system/core/adb（protocol.txt / auth.cpp / transport.cpp）
final class AdbClient: @unchecked Sendable {
    /// RSA 密钥对（ADB 使用 RSA-2048，签名算法 RSA-SHA1 PKCS1v1.5）
    struct AdbKeyPair {
        let privateKey: SecKey
        let publicKeyPEM: Data   // PKCS#8 SPKI PEM，含 '\0' + user@host 后缀

        var privateKeyData: Data? {
            var err: Unmanaged<CFError>?
            guard let data = SecKeyCopyExternalRepresentation(privateKey, &err) as Data? else {
                return nil
            }
            return data
        }
    }

    /// 通道回调
    var onLog: ((String) -> Void)?

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private let queue = DispatchQueue(label: "adb.client.queue")
    private let lock = NSLock()
    private var channels: [UInt32: AdbChannel] = [:]
    private var nextLocalID: UInt32 = 1
    private(set) var isConnected = false
    private var maxDataLength: UInt32 = 0
    /// 保存的密钥（来自配对档案）
    var savedKeyPair: AdbKeyPair?

    // MARK: - 连接

    /// 建立 TCP 连接并完成 ADB 认证
    /// - Parameters:
    ///   - keyProvider: 提供已保存的密钥（可为 nil 表示无密钥，将发送公钥请求授权）
    ///   - completion: 连接结果；成功回调参数为认证完成后的 CNXN 系统类型字符串
    func connect(host: String, port: Int,
                 keyProvider: (() -> AdbKeyPair?)? = nil,
                 timeout: TimeInterval = 10,
                 completion: @escaping (Result<String, Error>) -> Void) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .wifi

        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        var didComplete = false
        func finish(_ result: Result<String, Error>) {
            guard !didComplete else { return }
            didComplete = true
            self.connectCompletion = nil
            completion(result)
        }
        self.connectCompletion = completion

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.onLog?("TCP 已连接 \(host):\(port)")
                self.isConnected = true
                // 等待设备 CNXN / AUTH
                self.startReceiving()
            case .failed(let err):
                self.isConnected = false
                finish(.failure(AdbError.connectionFailed(err.localizedDescription)))
            case .cancelled:
                self.isConnected = false
            default:
                break
            }
        }

        conn.start(queue: queue)

        // 超时
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self, !didComplete else { return }
            if self.connectCompletion != nil {
                self.disconnect()
                finish(.failure(AdbError.timeout))
            }
        }

        // 若提供了密钥，等待设备 AUTH token 后由 handleAuth 使用
        self.savedKeyPair = keyProvider?()
    }

    // MARK: - 接收数据

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processBuffer()
            }
            if isComplete || error != nil {
                self.handleDisconnect(error)
                return
            }
            self.startReceiving()
        }
    }

    private func processBuffer() {
        while true {
            guard let result = AdbPacket.parse(from: receiveBuffer) else { break }
            if result.consumed == 0 {
                break
            }
            receiveBuffer.removeFirst(result.consumed)
            if let packet = result.packet {
                handlePacket(packet)
            } else {
                // CRC 校验失败：丢弃 4 字节重试
                if receiveBuffer.count > 0 {
                    receiveBuffer.removeFirst(1)
                }
            }
        }
    }

    private func handlePacket(_ packet: AdbPacket) {
        switch packet.command {
        case .cnxn:
            // 连接建立
            let system = String(data: packet.payload.split(separator: 0).first ?? Data(), encoding: .utf8) ?? ""
            maxDataLength = packet.arg1 > 0 ? packet.arg1 : 0x100000
            onLog?("CNXN 收到 system=\(system)")
            // 认证完成
            isConnected = true
            let completion = connectCompletion
            connectCompletion = nil
            completion?(.success(system))
        case .auth:
            handleAuth(packet)
        case .open:
            // 服务端发来 OPEN（一般为 server 主动连接，客户端不支持）
            break
        case .wrte:
            if let channel = channels[packet.arg0] {
                channel.onData?(packet.payload)
            }
        case .okay:
            if let channel = channels[packet.arg0] {
                channel.markOpen(remoteID: packet.arg1)
            }
        case .clse:
            if let channel = channels.removeValue(forKey: packet.arg0) {
                channel.close()
            }
        }
    }

    /// 连接完成回调（CNXN 收到后调用成功，失败/超时调用失败）
    private var connectCompletion: ((Result<String, Error>) -> Void)?

    private func handleAuth(_ packet: AdbPacket) {
        let authType = AdbPacket.AuthType(rawValue: packet.arg0) ?? .token
        switch authType {
        case .token:
            // 设备发送 token，要求签名
            let token = packet.payload
            onLog?("AUTH token 收到 (\(token.count) 字节)")
            if let key = savedKeyPair {
                sendSignature(token, key: key)
            } else {
                // 无已保存密钥：生成新密钥并发送公钥，触发设备授权弹窗
                if let key = AdbClient.generateKeyPair() {
                    onLog?("无已保存密钥，生成新密钥")
                    sendAuthPublicKey(key)
                }
            }
        case .signature, .rsaPublicKey:
            break
        }
    }

    /// RSA-SHA1 PKCS1v1.5 签名 token 并发送 AUTH(2)
    private func sendSignature(_ token: Data, key: AdbKeyPair) {
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key.privateKey,
                                              .rsaSignatureMessagePKCS1v15SHA1,
                                              token as CFData,
                                              &err) as Data? else {
            onLog?("RSA 签名失败: \(err?.takeRetainedValue().localizedDescription ?? "unknown")")
            // 签名失败回退：发送公钥重新授权
            if let newKey = AdbClient.generateKeyPair() {
                sendAuthPublicKey(newKey)
            }
            return
        }
        onLog?("AUTH(2) 发送签名")
        sendPacket(AdbPacket(command: .auth, arg0: AdbPacket.AuthType.signature.rawValue, payload: sig))
    }

    /// 发送 RSA 公钥请求设备授权（AUTH(3)）
    private func sendAuthPublicKey(_ key: AdbKeyPair) {
        onLog?("AUTH(3) 发送 RSA 公钥（等待设备授权）")
        sendPacket(AdbPacket(command: .auth, arg0: AdbPacket.AuthType.rsaPublicKey.rawValue, payload: key.publicKeyPEM))
    }

    // MARK: - 发送

    private func sendPacket(_ packet: AdbPacket) {
        let data = packet.serialize()
        connection?.send(content: data, completion: .contentProcessed { [weak self] err in
            if let err = err {
                self?.onLog?("发送失败: \(err.localizedDescription)")
            }
        })
    }

    /// 打开数据通道
    @discardableResult
    func open(service: String, onData: @escaping (Data) -> Void, onClose: (() -> Void)? = nil) -> UInt32? {
        guard isConnected else { return nil }
        lock.lock()
        let localID = nextLocalID
        nextLocalID += 1
        lock.unlock()
        let channel = AdbChannel(localID: localID)
        channel.onData = onData
        channel.onClose = onClose
        lock.lock()
        channels[localID] = channel
        lock.unlock()
        var serviceData = Data(service.utf8)
        serviceData.append(0)
        sendPacket(AdbPacket(command: .open, arg0: localID, payload: serviceData))
        return localID
    }

    /// 向通道写入数据
    func write(toChannel localID: UInt32, data: Data) {
        guard let channel = channels[localID], channel.state == .open else { return }
        sendPacket(AdbPacket(command: .wrte, arg0: channel.remoteID, arg1: localID, payload: data))
    }

    /// 关闭通道
    func close(channel localID: UInt32) {
        guard let channel = channels.removeValue(forKey: localID) else { return }
        if channel.state == .open {
            sendPacket(AdbPacket(command: .clse, arg0: channel.remoteID, arg1: localID))
        }
        channel.close()
    }

    /// 断开连接
    func disconnect() {
        isConnected = false
        connection?.cancel()
        connection = nil
        channels.removeAll()
    }

    private func handleDisconnect(_ error: Error?) {
        onLog?("连接断开: \(error?.localizedDescription ?? "unknown")")
        let chans = channels.values
        channels.removeAll()
        chans.forEach { $0.close() }
        isConnected = false
        if let completion = connectCompletion {
            connectCompletion = nil
            completion(.failure(AdbError.connectionFailed(error?.localizedDescription ?? "连接已断开")))
        }
    }

    // MARK: - RSA 密钥

    /// 生成 ADB RSA-2048 密钥对
    static func generateKeyPair() -> AdbKeyPair? {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ]
        var err: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &err) else {
            return nil
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { return nil }
        // 获取 PKCS#1 公钥原始数据
        guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &err) as Data? else {
            return nil
        }
        // 包装为 PKCS#8 SPKI 并转 PEM
        let spki = wrapSPKI(pkcs1: pkcs1)
        let pem = pemEncode(spki, type: "PUBLIC KEY")
        // ADB 公钥格式：PEM + '\0' + "user@host" + '\0'
        var pubKeyData = Data(pem.utf8)
        pubKeyData.append(0)
        pubKeyData.append(Data("wearosbox@ios".utf8))
        pubKeyData.append(0)
        return AdbKeyPair(privateKey: privateKey, publicKeyPEM: pubKeyData)
    }

    /// 从保存的私钥数据恢复密钥对（Keychain 导出）
    static func restoreKeyPair(privateKeyData: Data) -> AdbKeyPair? {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2048
        ]
        var err: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(privateKeyData as CFData, attributes as CFDictionary, &err) else {
            return nil
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { return nil }
        guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &err) as Data? else {
            return nil
        }
        let spki = wrapSPKI(pkcs1: pkcs1)
        let pem = pemEncode(spki, type: "PUBLIC KEY")
        var pubKeyData = Data(pem.utf8)
        pubKeyData.append(0)
        pubKeyData.append(Data("wearosbox@ios".utf8))
        pubKeyData.append(0)
        return AdbKeyPair(privateKey: privateKey, publicKeyPEM: pubKeyData)
    }

    /// 将 PKCS#1 RSAPublicKey 包装为 PKCS#8 SubjectPublicKeyInfo DER
    private static func wrapSPKI(pkcs1: Data) -> Data {
        let oid: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
        var bitString = Data([0x03])
        bitString.append(lengthBytes(pkcs1.count + 1))
        bitString.append(0x00)
        bitString.append(pkcs1)
        var sequence = Data(oid)
        sequence.append(bitString)
        var spki = Data([0x30])
        spki.append(lengthBytes(sequence.count))
        spki.append(sequence)
        return spki
    }

    private static func lengthBytes(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }

    private static func pemEncode(_ der: Data, type: String) -> String {
        let base64 = der.base64EncodedString()
        var lines = ""
        var index = 0
        while index < base64.count {
            let end = min(index + 64, base64.count)
            lines += String(base64[base64.index(base64.startIndex, offsetBy: index)..<base64.index(base64.startIndex, offsetBy: end)]) + "\n"
            index = end
        }
        return "-----BEGIN \(type)-----\n\(lines)-----END \(type)-----\n"
    }
}
