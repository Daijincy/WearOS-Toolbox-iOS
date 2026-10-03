import Foundation
import Network
import CryptoKit

/// 无线调试（Wireless Debugging）配对协议客户端
/// 协议参考 AOSP system/core/adb/pairing/pairing_connection.cpp
/// 流程：明文交换 X25519 公钥 → 派生共享密钥 → AES-256-GCM 加密传输配对码 → 服务端返回状态
final class AdbPairingClient: @unchecked Sendable {
    enum PairingError: LocalizedError {
        case connectionFailed(String)
        case invalidResponse
        case encryptionFailed
        case pairingRejected
        case timeout

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let msg): return "配对连接失败：\(msg)"
            case .invalidResponse: return "配对响应无效"
            case .encryptionFailed: return "配对加密失败"
            case .pairingRejected: return "配对码错误或已被拒绝"
            case .timeout: return "配对超时"
            }
        }
    }

    /// 配对会话上下文（引用类型，供网络回调安全捕获）
    private final class PairingContext {
        enum Phase {
            case awaitingResponse      // 等待明文 PairingResponse
            case awaitingEncrypted     // 等待加密状态包
        }
        var receiveBuffer = Data()
        var phase: Phase = .awaitingResponse
        var clientPrivateKey: Curve25519.KeyAgreement.PrivateKey?
        var symmetricKey: SymmetricKey?
        var nonce = Data()
    }

    var onLog: ((String) -> Void)?

    /// 配对握手头（6 字节）：PSYNC + version(1)
    private static let pairingHeader: [UInt8] = [0x50, 0x53, 0x59, 0x4E, 0x43, 0x01]
    /// 消息类型
    private enum MessageType: UInt32 {
        case pairingRequest = 1
        case pairingResponse = 2
    }

    /// 执行配对
    /// - Parameters:
    ///   - host: 设备 IP
    ///   - port: 配对端口（无线调试-配对码连接端口）
    ///   - code: 6 位配对码
    ///   - completion: 成功回调返回生成的 ADB RSA 密钥对；失败返回错误
    func pair(host: String, port: Int, code: String,
              timeout: TimeInterval = 15,
              completion: @escaping (Result<AdbClient.AdbKeyPair, Error>) -> Void) {
        guard code.count == 6, code.allSatisfy({ $0.isNumber }) else {
            completion(.failure(PairingError.invalidResponse))
            return
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: UInt16(port))!)
        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi
        let conn = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "adb.pairing.queue")
        let context = PairingContext()
        var didComplete = false

        func finish(_ result: Result<AdbClient.AdbKeyPair, Error>) {
            guard !didComplete else { return }
            didComplete = true
            conn.cancel()
            completion(result)
        }

        // 超时
        queue.asyncAfter(deadline: .now() + timeout) {
            finish(.failure(PairingError.timeout))
        }

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.onLog?("配对 TCP 已连接 \(host):\(port)")
                do {
                    let clientKey = Curve25519.KeyAgreement.PrivateKey()
                    context.clientPrivateKey = clientKey
                    // 初始化 nonce：前 4 字节随机，后 8 字节为 0
                    var seed = [UInt8](repeating: 0, count: 4)
                    for i in 0..<4 { seed[i] = UInt8.random(in: 0...255) }
                    context.nonce = Data(seed + [UInt8](repeating: 0, count: 8))

                    // PairingRequest: guid(16) + clientPubKey(32)
                    var request = Data()
                    let guid = (0..<16).map { _ in UInt8.random(in: 0...255) }
                    request.append(contentsOf: guid)
                    request.append(clientKey.publicKey.rawRepresentation)

                    var packet = Data(Self.pairingHeader)
                    packet.appendUInt32(UInt32(request.count))
                    packet.append(request)
                    conn.send(content: packet, completion: .contentProcessed { err in
                        if let err = err {
                            self.onLog?("配对请求发送失败: \(err.localizedDescription)")
                            finish(.failure(PairingError.connectionFailed(err.localizedDescription)))
                        }
                    })
                }
            case .failed(let err):
                finish(.failure(PairingError.connectionFailed(err.localizedDescription)))
            case .cancelled:
                break
            default:
                break
            }
        }

        conn.start(queue: queue)
        receiveLoop(conn: conn, context: context, code: code, finish: finish)
    }

    /// 接收循环
    private func receiveLoop(conn: NWConnection,
                             context: PairingContext,
                             code: String,
                             finish: @escaping (Result<AdbClient.AdbKeyPair, Error>) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                context.receiveBuffer.append(data)
                self.processPairingData(context: context, code: code, conn: conn, finish: finish)
            }
            if isComplete || error != nil {
                finish(.failure(PairingError.invalidResponse))
                return
            }
            self.receiveLoop(conn: conn, context: context, code: code, finish: finish)
        }
    }

    /// 处理配对数据流
    private func processPairingData(context: PairingContext,
                                    code: String,
                                    conn: NWConnection,
                                    finish: @escaping (Result<AdbClient.AdbKeyPair, Error>) -> Void) {
        switch context.phase {
        case .awaitingResponse:
            // 需要至少 6(header) + 4(size) + 64(PairingResponse)
            guard context.receiveBuffer.count >= 6 + 4 + 64 else { return }
            let header = [UInt8](context.receiveBuffer.prefix(6))
            guard header == Array(Self.pairingHeader) else {
                finish(.failure(PairingError.invalidResponse))
                return
            }
            let payloadSize = Int(context.receiveBuffer.readUInt32(at: 6))
            guard context.receiveBuffer.count >= 6 + 4 + payloadSize else { return }
            let payload = context.receiveBuffer.subdata(in: (6 + 4)..<(6 + 4 + payloadSize))
            context.receiveBuffer.removeFirst(6 + 4 + payloadSize)

            // PairingResponse: serverPubKey(32) + salt(32)
            guard payload.count >= 64 else {
                finish(.failure(PairingError.invalidResponse))
                return
            }
            let serverPubKeyData = payload.subdata(in: 0..<32)

            guard let clientKey = context.clientPrivateKey else {
                finish(.failure(PairingError.invalidResponse))
                return
            }
            guard let serverPubKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPubKeyData),
                  let shared = try? clientKey.sharedSecretFromKeyAgreement(with: serverPubKey) else {
                finish(.failure(PairingError.encryptionFailed))
                return
            }
            // SharedSecret → SymmetricKey（AES-GCM 密钥）
            context.symmetricKey = SymmetricKey(data: shared)

            // 发送加密配对码包
            do {
                guard let symmetricKey = context.symmetricKey else {
                    finish(.failure(PairingError.encryptionFailed))
                    return
                }
                var body = Data()
                body.append(contentsOf: code.data(using: .ascii)!)
                var plaintext = Data()
                plaintext.appendUInt32(UInt32(4 + 4 + body.count))
                plaintext.appendUInt32(MessageType.pairingRequest.rawValue)
                plaintext.append(body)

                incrementNonce(&context.nonce)
                let gcmNonce = try AES.GCM.Nonce(data: context.nonce)
                let sealed = try AES.GCM.seal(plaintext,
                                              using: symmetricKey,
                                              nonce: gcmNonce,
                                              authenticating: Data(Self.pairingHeader))
                var packet = Data(Self.pairingHeader)
                packet.append(context.nonce)
                packet.append(sealed.combined ?? Data())
                conn.send(content: packet, completion: .contentProcessed { err in
                    if let err = err {
                        finish(.failure(PairingError.connectionFailed(err.localizedDescription)))
                    }
                })
                self.onLog?("配对码已加密发送")
                context.phase = .awaitingEncrypted
            } catch {
                finish(.failure(PairingError.encryptionFailed))
            }

        case .awaitingEncrypted:
            // 加密包: header(6) + nonce(12) + ciphertext+tag(>=16)
            guard context.receiveBuffer.count >= 6 + 12 + 16 else { return }
            let header = [UInt8](context.receiveBuffer.prefix(6))
            guard header == Array(Self.pairingHeader) else {
                finish(.failure(PairingError.invalidResponse))
                return
            }
            let packetNonce = context.receiveBuffer.subdata(in: 6..<(6 + 12))
            let combined = context.receiveBuffer.subdata(in: (6 + 12)..<context.receiveBuffer.count)
            context.receiveBuffer.removeAll()

            guard let key = context.symmetricKey else {
                finish(.failure(PairingError.encryptionFailed))
                return
            }
            do {
                let sealed = try AES.GCM.SealedBox(combined: combined)
                let gcmNonce = try AES.GCM.Nonce(data: packetNonce)
                let plaintext = try AES.GCM.open(sealed,
                                                 using: key,
                                                 nonce: gcmNonce,
                                                 authenticating: Data(Self.pairingHeader))
                guard plaintext.count >= 8 else {
                    finish(.failure(PairingError.invalidResponse))
                    return
                }
                let typeRaw = plaintext.readUInt32(at: 4)
                guard typeRaw == MessageType.pairingResponse.rawValue else {
                    finish(.failure(PairingError.invalidResponse))
                    return
                }
                let status = plaintext.subdata(in: 8..<plaintext.count).first ?? 0
                onLog?("配对状态码: \(status)")
                guard status == 0x01 else {
                    finish(.failure(PairingError.pairingRejected))
                    return
                }
                // 配对成功：生成 ADB RSA 密钥对返回，供后续 connect 认证使用
                if let keyPair = AdbClient.generateKeyPair() {
                    finish(.success(keyPair))
                } else {
                    finish(.failure(PairingError.encryptionFailed))
                }
            } catch {
                finish(.failure(PairingError.invalidResponse))
            }
        }
    }

    /// 递增 nonce 后 8 字节（大端计数器）
    private func incrementNonce(_ nonce: inout Data) {
        guard nonce.count == 12 else { return }
        var bytes = [UInt8](nonce)
        for i in stride(from: 11, through: 4, by: -1) {
            bytes[i] &+= 1
            if bytes[i] != 0 { break }
        }
        nonce = Data(bytes)
    }
}
