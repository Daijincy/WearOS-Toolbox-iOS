import Foundation
import Network
import CryptoKit

/// 无线调试（Wireless Debugging）配对协议客户端（Android 11+ 官方 adb pair）。
/// 协议对照 AOSP adb/pairing_connection.cpp + pairing_auth.cpp：
///  TLS 1.3（客户端携带自签名 RSA 证书，不校验服务器证书）
///  → 导出密钥 "adb-label\0" (64B)
///  → SPAKE2 Ed25519（密码 = 6 位配对码 + 导出密钥）
///  → HKDF-SHA256 → AES-128-GCM（nonce = 8B LE 计数器 + 4B 零，双向独立从 0 开始）
///  → 帧协议 version(1)+type(1)+len(4BE)，type 0=SPAKE2_MSG / 1=PEER_INFO
///  → PeerInfo(8192B)：byte0 = 0(TYPE_ADB_RSA_PUB_KEY) + 公钥行
final class AdbPairingClient: @unchecked Sendable {
    enum PairingError: LocalizedError {
        case connectionFailed(String)
        case invalidResponse
        case encryptionFailed
        case pairingRejected
        case timeout
        case keyUnavailable

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let msg): return "配对连接失败：\(msg)"
            case .invalidResponse: return "配对响应无效"
            case .encryptionFailed: return "配对加密失败"
            case .pairingRejected: return "配对码错误或已被拒绝"
            case .timeout: return "配对超时"
            case .keyUnavailable: return "未找到 ADB 密钥，请先初始化"
            }
        }
    }

    var onLog: ((String) -> Void)?

    // 帧类型（AOSP PairingPacketHeader）
    private static let typeSpake2Msg: UInt8 = 0
    private static let typePeerInfo: UInt8 = 1
    private static let peerInfoSize = 8192
    private static let typeAdbRsaPubKey: UInt8 = 0
    private static let typeAdbDeviceGuid: UInt8 = 1
    private static let exportedKeySize = 64
    /// AOSP tls_connection.cpp: kExportedKeyLabel = "adb-label\0"（10 字节含 NUL）
    private static let exportedKeyLabel = "adb-label\u{0}"

    /// 配对状态（引用类型，供 TLS 回调安全捕获）
    private final class PairState {
        var frameBuffer = Data()
        var spakeCtx: Spake2Ed25519.Context?
        var encBox: AESGCM128.Box?
        var decBox: AESGCM128.Box?
    }

    /// 执行配对
    /// - Parameters:
    ///   - host: 设备 IP
    ///   - port: 配对端口（无线调试-使用配对码配对设备页面显示的端口）
    ///   - code: 6 位配对码
    ///   - keyPair: 已有 ADB RSA 密钥（证书与 PeerInfo 公钥同源，配对/连接共用）
    ///   - completion: 成功回调返回 RSA 密钥对；失败返回错误
    func pair(host: String, port: Int, code: String,
              keyPair: AdbClient.AdbKeyPair?,
              timeout: TimeInterval = 20,
              completion: @escaping (Result<AdbClient.AdbKeyPair, Error>) -> Void) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy({ $0.isNumber }) else {
            completion(.failure(PairingError.invalidResponse))
            return
        }
        guard let key = keyPair ?? AdbClient.generateKeyPair() else {
            completion(.failure(PairingError.keyUnavailable))
            return
        }
        // 自签名客户端证书（公钥 = ADB key 的公钥）
        guard let certDER = X509SelfSigned.generateSelfSignedCertificate(privateKey: key.privateKey) else {
            completion(.failure(PairingError.encryptionFailed))
            return
        }

        onLog?("配对开始 \(host):\(port)，生成 TLS 1.3 客户端证书")
        let tls = TLS13Client(clientCertDER: certDER, clientPrivateKey: key.privateKey)
        tls.onLog = { [weak self] msg in self?.onLog?("[TLS] \(msg)") }

        var didComplete = false
        func finish(_ result: Result<AdbClient.AdbKeyPair, Error>) {
            guard !didComplete else { return }
            didComplete = true
            tls.close()
            completion(result)
        }

        let state = PairState()

        tls.onHandshakeDone = { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                finish(.failure(err))
            case .success(let exported):
                self.onLog?("TLS 握手完成，导出密钥 \(exported.count) 字节")
                // SPAKE2 密码 = 配对码 + 导出密钥
                var pswd = Data(trimmed.utf8)
                pswd.append(exported)
                let ctx = Spake2Ed25519.newClient()
                guard let myMsg = Spake2Ed25519.generateMsg(ctx, password: pswd) else {
                    finish(.failure(PairingError.encryptionFailed))
                    return
                }
                state.spakeCtx = ctx
                self.sendFrame(tls, type: Self.typeSpake2Msg, payload: myMsg)
                self.onLog?("SPAKE2 消息已发送（32 字节）")
            }
        }

        tls.onData = { [weak self] data in
            guard let self = self else { return }
            self.consumeFrameData(data, tls: tls, state: state,
                                  key: key, trimmedCode: trimmed, finish: finish)
        }

        tls.onClosed = { [weak self] err in
            self?.onLog?("TLS 连接关闭")
            finish(.failure(PairingError.connectionFailed(err?.localizedDescription ?? "连接关闭")))
        }

        // 超时
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            finish(.failure(PairingError.timeout))
        }

        tls.connect(host: host, port: port, timeout: timeout)
    }

    // MARK: - 帧协议

    /// 消费 TLS 应用数据（累积缓冲，解析完整帧）
    private func consumeFrameData(_ data: Data,
                                  tls: TLS13Client,
                                  state: PairState,
                                  key: AdbClient.AdbKeyPair,
                                  trimmedCode: String,
                                  finish: @escaping (Result<AdbClient.AdbKeyPair, Error>) -> Void) {
        state.frameBuffer.append(data)
        while state.frameBuffer.count >= 6 {
            let version = state.frameBuffer[0]
            let type = state.frameBuffer[1]
            let len = Int(state.frameBuffer[2]) << 24 | Int(state.frameBuffer[3]) << 16
                | Int(state.frameBuffer[4]) << 8 | Int(state.frameBuffer[5])
            guard version == 1, len >= 0, len <= 1 << 16 else {
                finish(.failure(PairingError.invalidResponse))
                return
            }
            guard state.frameBuffer.count >= 6 + len else { return }  // 等待更多数据
            let body = state.frameBuffer.subdata(in: 6..<(6 + len))
            state.frameBuffer.removeFirst(6 + len)
            handleFrame(type: type, body: body, tls: tls, state: state,
                        key: key, trimmedCode: trimmedCode, finish: finish)
        }
    }

    private func handleFrame(type: UInt8,
                             body: Data,
                             tls: TLS13Client,
                             state: PairState,
                             key: AdbClient.AdbKeyPair,
                             trimmedCode: String,
                             finish: @escaping (Result<AdbClient.AdbKeyPair, Error>) -> Void) {
        switch type {
        case Self.typeSpake2Msg:
            guard body.count == 32, let ctx = state.spakeCtx else {
                finish(.failure(PairingError.invalidResponse))
                return
            }
            guard let keyMaterial = Spake2Ed25519.processMsg(ctx, theirMsg: body, maxOut: 64) else {
                finish(.failure(PairingError.pairingRejected))
                return
            }
            onLog?("SPAKE2 完成，密钥材料 64 字节")
            // AES-128-GCM 密钥 = HKDF-SHA256(keyMaterial, "adb pairing_auth aes-128-gcm key", 16)
            guard let aesKey = hkdfSha256(ikm: keyMaterial,
                                          info: Data("adb pairing_auth aes-128-gcm key".utf8),
                                          outLen: 16) else {
                finish(.failure(PairingError.encryptionFailed))
                return
            }
            let box = AESGCM128.Box(key: aesKey)
            state.encBox = box
            state.decBox = box
            // 加密 PeerInfo 并发送
            guard let peerInfo = buildPeerInfo(key: key) else {
                finish(.failure(PairingError.encryptionFailed))
                return
            }
            do {
                var b = box
                let nonce = b.counterNonce(seq: 0)
                let encrypted = try b.encrypt(peerInfo, nonce: nonce)
                sendFrame(tls, type: Self.typePeerInfo, payload: encrypted)
                onLog?("PeerInfo 已加密发送（\(peerInfo.count) 字节）")
            } catch {
                finish(.failure(PairingError.encryptionFailed))
            }

        case Self.typePeerInfo:
            guard var box = state.decBox else {
                finish(.failure(PairingError.invalidResponse))
                return
            }
            do {
                let nonce = box.counterNonce(seq: 0)
                let plain = try box.decrypt(body, nonce: nonce)
                state.decBox = box
                guard let first = plain.first else {
                    finish(.failure(PairingError.invalidResponse))
                    return
                }
                onLog?("设备响应解密成功，类型 \(first)")
                guard first == Self.typeAdbDeviceGuid else {
                    finish(.failure(PairingError.pairingRejected))
                    return
                }
                onLog?("配对成功！设备已信任此 ADB 公钥")
                finish(.success(key))
            } catch {
                onLog?("设备响应解密失败：\(error.localizedDescription)")
                finish(.failure(PairingError.pairingRejected))
            }

        default:
            finish(.failure(PairingError.invalidResponse))
        }
    }

    /// 构建 PeerInfo：8192 字节，[0]=0(TYPE_ADB_RSA_PUB_KEY) + 公钥行
    private func buildPeerInfo(key: AdbClient.AdbKeyPair) -> Data? {
        guard let pubLine = AndroidPubKey.publicKeyLine(privateKey: key.privateKey) else {
            return nil
        }
        var peerInfo = Data(repeating: 0, count: Self.peerInfoSize)
        peerInfo[0] = Self.typeAdbRsaPubKey
        let n = min(pubLine.count, Self.peerInfoSize - 2)
        peerInfo.replaceSubrange(1..<(1 + n), with: pubLine[0..<n])
        return peerInfo
    }

    /// 发送帧：version(1) + type(1) + len(4BE) + payload
    private func sendFrame(_ tls: TLS13Client, type: UInt8, payload: Data) {
        var header = Data([0x01, type])
        header.appendUInt32BE(UInt32(payload.count))
        tls.send(header + payload)
    }

    /// HKDF-SHA256（RFC 5869，HMAC 实现）：extract(salt=zeros(32), ikm) + expand(info, 0x01)
    private func hkdfSha256(ikm: Data, info: Data, outLen: Int) -> Data? {
        // PRK = HMAC-SHA256(salt=zeros(32), ikm)
        let mac = HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: Data(repeating: 0, count: 32)))
        let prk = mac.withUnsafeBytes { Data($0) }
        // OKM = T(1) || T(2) ...
        var out = Data()
        var t = Data()
        var counter: UInt8 = 1
        while out.count < outLen {
            var input = t
            input.append(info)
            input.append(counter)
            let m = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: prk))
            t = m.withUnsafeBytes { Data($0) }
            out.append(t)
            counter += 1
        }
        return Data(out.prefix(outLen))
    }
}

extension Data {
    mutating func appendUInt32BE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }
}
