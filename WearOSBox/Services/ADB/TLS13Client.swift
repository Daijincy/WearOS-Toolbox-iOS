import Foundation
import Network
import CryptoKit
import Security

/// 手写 TLS 1.3 客户端（RFC 8446 子集）。
/// 仅支持 Android 无线调试配对所需的：
///  - TLS_AES_128_GCM_SHA256 (0x1301)
///  - X25519 key_share、无 PSK
///  - 客户端 RSA 证书（rsa_pss_rsae_sha256 / rsa_pkcs1_sha256）
///  - 不校验服务器证书（配对认证由 SPAKE2 完成，与 AOSP adb client 一致）
///  - 支持自定义 label 的 TLS exporter（Network.framework 固定空 label，故自实现）
final class TLS13Client: @unchecked Sendable {
    enum TLS13Error: LocalizedError {
        case connectionFailed(String)
        case handshakeFailed(String)
        case serverHelloBad
        case unsupportedCipher
        case badRecord
        case recordTooLong
        case notReady
        case closed

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let m): return "TLS 连接失败：\(m)"
            case .handshakeFailed(let m): return "TLS 握手失败：\(m)"
            case .serverHelloBad: return "TLS 服务器响应异常"
            case .unsupportedCipher: return "TLS 密码套件不受支持"
            case .badRecord: return "TLS 记录解析失败"
            case .recordTooLong: return "TLS 记录过长"
            case .notReady: return "TLS 尚未就绪"
            case .closed: return "TLS 连接已关闭"
            }
        }
    }

    var onLog: ((String) -> Void)?

    /// 握手完成后回调（导出密钥可用于 SPAKE2）
    var onHandshakeDone: ((Result<Data, Error>) -> Void)?
    /// 应用数据回调
    var onData: ((Data) -> Void)?
    /// 连接关闭
    var onClosed: ((Error?) -> Void)?

    private let queue = DispatchQueue(label: "adb.tls13.queue")
    private var connection: NWConnection?
    private var recvBuffer = Data()
    private var didClose = false

    // TLS 状态
    private enum Phase {
        case connecting
        case awaitingServerHello
        case awaitingServerFlight
        case ready
        case failed
    }
    private var phase: Phase = .connecting

    // 密钥材料
    private let suiteID: UInt16 = 0x1301
    private let hashLen = 32  // SHA-256
    private var ecdhePrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var clientRandom = Data()
    private var serverRandom = Data()
    private var clientHandshakeKey = Data()
    private var clientHandshakeIV = Data()
    private var serverHandshakeKey = Data()
    private var serverHandshakeIV = Data()
    private var clientAppKey = Data()
    private var clientAppIV = Data()
    private var serverAppKey = Data()
    private var serverAppIV = Data()
    private var serverFinishedKey = Data()
    private var clientFinishedKey = Data()
    private var seqRead: UInt64 = 0
    private var seqWrite: UInt64 = 0

    // 转录哈希（CryptoKit SHA256 增量）
    private var transcriptHash = SHA256()

    // 客户端证书
    private var clientCertDER: Data
    private var clientPrivateKey: SecKey

    init(clientCertDER: Data, clientPrivateKey: SecKey) {
        self.clientCertDER = clientCertDER
        self.clientPrivateKey = clientPrivateKey
    }

    // MARK: - 连接与生命周期

    func connect(host: String, port: Int, timeout: TimeInterval = 15) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: UInt16(port))!)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .wifi
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.onLog?("TLS TCP 已连接 \(host):\(port)")
                do {
                    let hello = try self.buildClientHello()
                    self.sendRecord(type: 22, payload: hello, encrypted: false)
                    self.phase = .awaitingServerHello
                    self.receiveLoop()
                } catch {
                    self.fail(error)
                }
            case .failed(let err):
                self.fail(TLS13Error.connectionFailed(err.localizedDescription))
            case .cancelled:
                self.phase = .failed
                if !self.didClose {
                    self.didClose = true
                    self.onClosed?(nil)
                }
            default:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) {
            if self.phase != .ready && self.phase != .failed {
                self.fail(TLS13Error.handshakeFailed("握手超时"))
            }
        }
        conn.start(queue: queue)
    }

    func close() {
        connection?.cancel()
    }

    /// 发送应用数据（type 23）
    func send(_ data: Data) {
        guard phase == .ready else {
            onLog?("TLS 未就绪，丢弃应用数据")
            return
        }
        do {
            try sendRecord(type: 23, payload: data, encrypted: true)
        } catch {
            fail(error)
        }
    }

    // MARK: - 接收循环

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.recvBuffer.append(data)
                do {
                    if !self.processRecords() {
                        return
                    }
                } catch {
                    self.fail(error)
                    return
                }
            }
            if isComplete || error != nil {
                if self.phase != .ready {
                    self.fail(TLS13Error.closed)
                } else {
                    self.didClose = true
                    self.onClosed?(error)
                }
                return
            }
            self.receiveLoop()
        }
    }

    /// 处理缓冲区中的 TLS 记录，返回是否继续接收
    private func processRecords() throws -> Bool {
        while recvBuffer.count >= 5 {
            let type = recvBuffer[0]
            let length = Int(recvBuffer[3]) << 8 | Int(recvBuffer[4])
            guard length <= 1 << 18 else { throw TLS13Error.recordTooLong }
            guard recvBuffer.count >= 5 + length else { break }
            let payload = recvBuffer.subdata(in: 5..<(5 + length))
            recvBuffer.removeFirst(5 + length)

            switch type {
            case 22:  // handshake
                if phase == .awaitingServerHello {
                    try handleServerHelloRecord(payload)
                } else if phase == .awaitingServerFlight {
                    try handleEncryptedFlightRecord(payload)
                } else {
                    throw TLS13Error.badRecord
                }
            case 23:  // application data
                guard phase == .ready else { throw TLS13Error.badRecord }
                let plain = try decryptRecord(payload, recordType: type, key: serverAppKey, iv: serverAppIV)
                // TLS 1.3 内层最后 1 字节是 content type：
                //  23 = 应用数据（透传）；22 = 握手消息（如 NewSessionTicket，忽略）
                guard let innerType = plain.last else { throw TLS13Error.badRecord }
                if innerType == 23 {
                    onData?(plain.dropLast())
                }
                // 其他内层类型（22 NST 等）忽略
            case 21:  // alert
                onLog?("TLS alert: \(payload.hexString)")
                throw TLS13Error.handshakeFailed("服务器返回 TLS alert")
            default:
                // 忽略心跳等
                break
            }
        }
        return true
    }

    private func stripInnerContentType(_ inner: Data) -> Data {
        guard !inner.isEmpty else { return inner }
        return inner.dropLast()  // 最后一个字节是 content type
    }

    // MARK: - ClientHello

    private func buildClientHello() throws -> Data {
        let key = Curve25519.KeyAgreement.PrivateKey()
        ecdhePrivateKey = key
        let pub = key.publicKey.rawRepresentation
        clientRandom = (0..<32).map { _ in UInt8.random(in: 0...255) }.reduce(Data()) { $0 + [$1] }

        var body = Data()
        body.append(0x03)  // legacy_version 0x0303
        body.append(0x03)
        body.append(clientRandom)
        body.append(0x00)  // legacy_session_id 空
        // cipher_suites: [0x1301]
        body.append(0x00)
        body.append(0x02)
        body.appendUInt16(0x1301)
        body.append(0x01)  // compression_methods: [null]
        body.append(0x00)

        // extensions
        var exts = Data()
        // supported_versions (43): [TLS 1.3]
        var v43 = Data([0x00, 0x02, 0x03, 0x04])
        exts.appendUInt16(43)
        exts.appendUInt16(UInt16(v43.count))
        exts.append(v43)
        // key_share (51): [X25519(0x001D), pub(32)]
        var ks = Data([0x00, 0x1d])
        ks.appendUInt16(UInt16(pub.count))
        ks.append(pub)
        exts.appendUInt16(51)
        exts.appendUInt16(UInt16(ks.count))
        exts.append(ks)
        // signature_algorithms (13): rsa_pss_rsae_sha256(0x0804), rsa_pkcs1_sha256(0x0401)
        var sa = Data([0x00, 0x04, 0x08, 0x04, 0x04, 0x01])
        exts.appendUInt16(13)
        exts.appendUInt16(UInt16(sa.count))
        exts.append(sa)

        body.appendUInt16(UInt16(exts.count))
        body.append(exts)

        var hello = Data([0x01])  // handshake type ClientHello
        hello.appendUInt24(UInt32(body.count))
        hello.append(body)

        // 转录：ClientHello（完整握手消息）
        updateTranscript(hello)
        return hello
    }

    // MARK: - ServerHello 处理（明文）

    private func handleServerHelloRecord(_ payload: Data) throws {
        // 一个 record 可能包含多个握手消息；ServerHello 单独
        let messages = try parseHandshakeMessages(payload)
        guard let first = messages.first else { throw TLS13Error.serverHelloBad }
        guard first.type == 2 else { throw TLS13Error.serverHelloBad }
        // 转录：SH 先入哈希，再计算密钥
        updateTranscript(encodeHandshake(type: 2, body: first.body))
        try handleServerHello(first.body)

        // TLS 1.3 中 ServerHello 之后的消息在加密记录中
        phase = .awaitingServerFlight
    }

    private func handleServerHello(_ body: Data) throws {
        var r = ByteReader(body)
        let legacyVersion = r.readUInt16()
        guard legacyVersion == 0x0303 else { throw TLS13Error.serverHelloBad }
        serverRandom = r.readData(32)
        let sessionIDLen = Int(r.readUInt8())
        _ = r.readData(sessionIDLen)
        let suite = r.readUInt16()
        guard suite == suiteID else { throw TLS13Error.unsupportedCipher }
        _ = r.readUInt8()  // compression
        // extensions
        var serverKeyShare: Data?
        let extTotal = Int(r.readUInt16())
        let extEnd = r.offset + extTotal
        while r.offset + 4 <= extEnd {
            let type = r.readUInt16()
            let len = Int(r.readUInt16())
            let ext = r.readData(len)
            if type == 51 {  // key_share
                var kr = ByteReader(ext)
                let group = kr.readUInt16()
                guard group == 0x001D else { throw TLS13Error.unsupportedCipher }
                let ksLen = Int(kr.readUInt16())
                serverKeyShare = kr.readData(ksLen)
            }
        }
        guard let serverKeyShare = serverKeyShare else {
            throw TLS13Error.serverHelloBad
        }
        guard let priv = ecdhePrivateKey,
              let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverKeyShare) else {
            throw TLS13Error.serverHelloBad
        }
        let shared = try priv.sharedSecretFromKeyAgreement(with: pub)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        ecdheSharedSecret = sharedBytes

        // 密钥调度
        let early = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: Data(repeating: 0, count: hashLen)),
                                         salt: Data(repeating: 0, count: hashLen))
        let derived1 = deriveSecret(secret: SymmetricKey(data: symKeyData(early)), label: "derived", transcript: Data())
        let hs = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: sharedBytes),
                                      salt: symKeyData(derived1))
        let hsKey = SymmetricKey(data: symKeyData(hs))

        // transcript = CH || SH
        let chSH = transcriptHashCopy()

        let cHs = deriveSecret(secret: hsKey, label: "c hs traffic", transcript: chSH)
        let sHs = deriveSecret(secret: hsKey, label: "s hs traffic", transcript: chSH)
        clientHandshakeKey = Data(expandLabel(key: cHs, label: "key", context: Data(), length: 16))
        clientHandshakeIV = Data(expandLabel(key: cHs, label: "iv", context: Data(), length: 12))
        serverHandshakeKey = Data(expandLabel(key: sHs, label: "key", context: Data(), length: 16))
        serverHandshakeIV = Data(expandLabel(key: sHs, label: "iv", context: Data(), length: 12))
        serverFinishedKey = Data(expandLabel(key: sHs, label: "finished", context: Data(), length: hashLen))
        clientFinishedKey = Data(expandLabel(key: cHs, label: "finished", context: Data(), length: hashLen))
    }

    // MARK: - 加密 flight 处理

    private func handleEncryptedFlightRecord(_ payload: Data) throws {
        // 注意：一个 record 可能承载多条握手消息
        let plain = try decryptRecord(payload, recordType: 22, key: serverHandshakeKey, iv: serverHandshakeIV)
        let inner = stripInnerContentType(plain)
        let messages = try parseHandshakeMessages(inner)
        for msg in messages {
            try handleHandshakeMessage(msg)
        }
    }

    private func handleHandshakeMessage(_ msg: HandshakeMessage) throws {
        switch msg.type {
        case 8:  // EncryptedExtensions
            updateTranscript(encodeHandshake(type: 8, body: msg.body))
        case 13:  // CertificateRequest（可选）
            updateTranscript(encodeHandshake(type: 13, body: msg.body))
        case 11:  // Certificate
            updateTranscript(encodeHandshake(type: 11, body: msg.body))
        case 15:  // CertificateVerify（跳过验证，与 AOSP adb client 一致）
            updateTranscript(encodeHandshake(type: 15, body: msg.body))
        case 20:  // Finished
            let transcriptBefore = transcriptHashCopy()
            updateTranscript(encodeHandshake(type: 20, body: msg.body))
            // 验证服务器 Finished
            let verifyData = computeVerifyData(key: serverFinishedKey, transcript: transcriptBefore)
            guard msg.body.count >= verifyData.count,
                  msg.body.prefix(verifyData.count) == verifyData else {
                throw TLS13Error.handshakeFailed("服务器 Finished 校验失败")
            }
            // 派生应用流量密钥（transcript 到 server Finished 为止）
            let hs = masterSecretFromHandshake()
            let masterKey = SymmetricKey(data: symKeyData(hs))
            let fullTranscript = transcriptHashCopy()
            let cAp = deriveSecret(secret: masterKey, label: "c ap traffic", transcript: fullTranscript)
            let sAp = deriveSecret(secret: masterKey, label: "s ap traffic", transcript: fullTranscript)
            clientAppKey = Data(expandLabel(key: cAp, label: "key", context: Data(), length: 16))
            clientAppIV = Data(expandLabel(key: cAp, label: "iv", context: Data(), length: 12))
            serverAppKey = Data(expandLabel(key: sAp, label: "key", context: Data(), length: 16))
            serverAppIV = Data(expandLabel(key: sAp, label: "iv", context: Data(), length: 12))
            let expMaster = deriveSecret(secret: masterKey, label: "exp master", transcript: fullTranscript)
            exporterSecret = symKeyData(expMaster)

            // 发送客户端证书链 + 签名 + Finished
            try sendClientFlight()
            phase = .ready
            onLog?("TLS 1.3 握手完成")
            do {
                let exported = try exportKeyingMaterial(label: "adb-label\0", context: nil, length: 64)
                onHandshakeDone?(.success(exported))
            } catch {
                fail(error)
            }
        default:
            throw TLS13Error.handshakeFailed("未知握手消息 type=\(msg.type)")
        }
    }

    private var exporterSecret = Data()

    /// TLS exporter（RFC 8446 7.5 / BoringSSL tls13_export_keying_material）
    /// 输出 = HKDF-Expand-Label(exporter_secret, "exporter", SHA-256(label||context), L)
    func exportKeyingMaterial(label: String, context: Data?, length: Int) throws -> Data {
        guard phase == .ready, !exporterSecret.isEmpty else {
            throw TLS13Error.notReady
        }
        var ctx = Data(label.utf8)
        if let context = context {
            ctx.append(context)
        }
        let hash = Data(SHA256.hash(data: ctx))
        return Data(expandLabel(key: SymmetricKey(data: exporterSecret),
                                label: "exporter",
                                context: hash,
                                length: length))
    }

    /// master_secret = HKDF-Extract(Derive-Secret(handshake_secret, "derived", ""), 0)
    private func masterSecretFromHandshake() -> [UInt8] {
        // 从 CH..SF 重新推导 handshake_secret
        let early = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: Data(repeating: 0, count: hashLen)),
                                         salt: Data(repeating: 0, count: hashLen))
        let derived1 = deriveSecret(secret: SymmetricKey(data: symKeyData(early)), label: "derived", transcript: Data())
        let hs = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ecdheSharedSecret),
                                      salt: symKeyData(derived1))
        let derived2 = deriveSecret(secret: SymmetricKey(data: symKeyData(hs)), label: "derived", transcript: Data())
        let master = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: Data(repeating: 0, count: hashLen)),
                                          salt: symKeyData(derived2))
        return Array(master)
    }

    private func symKeyData(_ k: SymmetricKey) -> Data {
        k.withUnsafeBytes { Data($0) }
    }

    private var ecdheSharedSecret = Data()

    // MARK: - 客户端 flight

    private func sendClientFlight() throws {
        // Certificate 消息
        var certList = Data()
        certList.appendUInt24(UInt32(clientCertDER.count))
        certList.append(clientCertDER)
        certList.appendUInt16(0)  // 无 extensions
        var certMsg = Data()
        certMsg.append(0)  // certificate_request_context 空
        certMsg.appendUInt24(UInt32(certList.count))
        certMsg.append(certList)
        let certWire = encodeHandshake(type: 11, body: certMsg)
        updateTranscript(certWire)
        sendRecord(type: 22, payload: certWire, encrypted: true)

        // CertificateVerify（签名内容 = 64空格 + "TLS 1.3, client CertificateVerify" + 0x00 + transcript_hash）
        let transcript = transcriptHashCopy()
        var toSign = Data(repeating: 0x20, count: 64)
        toSign.append(Data("TLS 1.3, client CertificateVerify".utf8))
        toSign.append(0x00)
        toSign.append(transcript)
        var err: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(clientPrivateKey,
                                                    .rsaSignatureMessagePSSSHA256,
                                                    toSign as CFData,
                                                    &err) as Data? else {
            throw TLS13Error.handshakeFailed("RSA 签名失败")
        }
        var cvBody = Data()
        cvBody.appendUInt16(0x0804)  // rsa_pss_rsae_sha256
        cvBody.appendUInt16(UInt16(signature.count))
        cvBody.append(signature)
        let cvWire = encodeHandshake(type: 15, body: cvBody)
        updateTranscript(cvWire)
        sendRecord(type: 22, payload: cvWire, encrypted: true)

        // Finished
        let verify = computeVerifyData(key: clientFinishedKey, transcript: transcriptHashCopy())
        let finWire = encodeHandshake(type: 20, body: verify)
        updateTranscript(finWire)
        sendRecord(type: 22, payload: finWire, encrypted: true)
    }

    // MARK: - 密钥工具

    private func deriveSecret(secret: SymmetricKey, label: String, transcript: Data) -> SymmetricKey {
        SymmetricKey(data: expandLabel(key: secret, label: label, context: transcript, length: hashLen))
    }

    private func expandLabel(key: SymmetricKey, label: String, context: Data, length: Int) -> Data {
        var info = Data()
        info.appendUInt16(UInt16(length))
        let fullLabel = "tls13 " + label
        info.append(UInt8(fullLabel.utf8.count))
        info.append(Data(fullLabel.utf8))
        info.append(UInt8(context.count))
        info.append(context)
        return Data(HKDF<SHA256>.expand(pseudoRandomKey: key, info: info, outputByteCount: length))
    }

    private func computeVerifyData(key: Data, transcript: Data) -> Data {
        let fk = expandLabel(key: SymmetricKey(data: key), label: "finished", context: Data(), length: hashLen)
        return Data(HMAC<SHA256>.authenticationCode(for: transcript, using: SymmetricKey(data: fk)))
    }

    // MARK: - 转录哈希

    private func updateTranscript(_ handshakeMsg: Data) {
        transcriptHash.update(data: handshakeMsg)
    }

    private func transcriptHashCopy() -> Data {
        var copy = transcriptHash
        return Data(copy.finalize())
    }

    // MARK: - 记录层

    private func sendRecord(type: UInt8, payload: Data, encrypted: Bool) throws {
        var body = payload
        var recordType = type
        if encrypted {
            let key: Data
            let iv: Data
            if phase == .ready {
                key = clientAppKey
                iv = clientAppIV
            } else {
                key = clientHandshakeKey
                iv = clientHandshakeIV
            }
            // TLS 1.3 内层：payload || content_type
            var inner = payload
            inner.append(type)
            // nonce = iv XOR (0^4 || seq8)
            let nonce = xorNonce(iv: iv, seq: seqWrite)
            let aad = Data([type, 0x03, 0x03]) + UInt16(inner.count).bigEndianBytes
            var box = AESGCM128.Box(key: key)
            let cipher = try box.encrypt(inner, nonce: nonce, aad: aad)
            body = cipher
            recordType = type  // 外层 record type 保持 22/23
            seqWrite += 1
        }
        var header = Data([recordType, 0x03, 0x03])
        header.appendUInt16(UInt16(body.count))
        connection?.send(content: header + body, completion: .contentProcessed { [weak self] err in
            if let err = err {
                self?.onLog?("TLS 发送失败: \(err.localizedDescription)")
            }
        })
    }

    private func decryptRecord(_ payload: Data, recordType: UInt8, key: Data, iv: Data) throws -> Data {
        let nonce = xorNonce(iv: iv, seq: seqRead)
        let aad = Data([recordType, 0x03, 0x03]) + UInt16(payload.count).bigEndianBytes
        var box = AESGCM128.Box(key: key)
        let plain = try box.decrypt(payload, nonce: nonce, aad: aad)
        seqRead += 1
        return plain
    }

    private func xorNonce(iv: Data, seq: UInt64) -> Data {
        var n = Data(repeating: 0, count: 12)
        for i in 0..<12 { n[i] = iv[i] }
        var s = seq.bigEndian
        for i in 0..<8 {
            n[4 + i] ^= UInt8((s >> (56 - 8 * i)) & 0xff)
        }
        return n
    }

    // MARK: - 消息解析

    private struct HandshakeMessage {
        let type: UInt8
        let body: Data
    }

    private func parseHandshakeMessages(_ data: Data) throws -> [HandshakeMessage] {
        var messages = [HandshakeMessage]()
        var offset = 0
        while offset + 4 <= data.count {
            let type = data[offset]
            let len = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            guard offset + 4 + len <= data.count else {
                throw TLS13Error.badRecord
            }
            messages.append(HandshakeMessage(type: type, body: data.subdata(in: (offset + 4)..<(offset + 4 + len))))
            offset += 4 + len
        }
        return messages
    }

    private func encodeHandshake(type: UInt8, body: Data) -> Data {
        var msg = Data([type])
        msg.appendUInt24(UInt32(body.count))
        msg.append(body)
        return msg
    }

    // MARK: - 错误处理

    private func fail(_ error: Error) {
        guard phase != .failed else { return }
        phase = .failed
        onLog?("TLS 失败: \(error.localizedDescription)")
        connection?.cancel()
        if !didClose {
            didClose = true
            onHandshakeDone?(.failure(error))
        }
    }
}

// MARK: - 工具扩展

extension Data {
    mutating func appendUInt16(_ v: UInt16) {
        append(UInt8(v >> 8))
        append(UInt8(v & 0xff))
    }

    mutating func appendUInt24(_ v: UInt32) {
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension UInt16 {
    var bigEndianBytes: Data {
        Data([UInt8(self >> 8), UInt8(self & 0xff)])
    }
}

private struct ByteReader {
    let data: Data
    var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func readUInt8() -> UInt8 {
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() -> UInt16 {
        defer { offset += 2 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    mutating func readData(_ count: Int) -> Data {
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}
