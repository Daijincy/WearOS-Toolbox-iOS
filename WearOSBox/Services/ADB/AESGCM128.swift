import Foundation
import CommonCrypto

/// 自实现 AES-128-GCM（NIST SP 800-38D）。
/// 用于 ADB 配对 TLS 1.3 记录保护与 SPAKE2 配对消息加密：
/// TLS 记录 nonce = iv(12B) XOR (0^4 || seq8)，必须由调用方指定 nonce 加解密，
/// CryptoKit 无法满足该场景，故基于 CommonCrypto 的 AES-ECB 块加密自实现。
enum AESGCM128 {
    struct Box {
        let key: Data  // 16 字节
        private(set) var encSeq: UInt64 = 0
        private(set) var decSeq: UInt64 = 0

        init(key: Data) {
            precondition(key.count == 16)
            self.key = key
        }

        /// 加密（nonce 由调用方提供，12 字节）
        mutating func encrypt(_ plaintext: Data, nonce: Data, aad: Data = Data()) throws -> Data {
            defer { encSeq += 1 }
            let cipher = try AESGCM128.encrypt(plaintext, key: key, nonce: nonce, aad: aad)
            return cipher  // ciphertext + tag(16)
        }

        /// 解密
        mutating func decrypt(_ ciphertext: Data, nonce: Data, aad: Data = Data()) throws -> Data {
            defer { decSeq += 1 }
            return try AESGCM128.decrypt(ciphertext, key: key, nonce: nonce, aad: aad)
        }

        /// 计数器 nonce：前 8 字节 LE 计数器 + 后 4 字节 0（AOSP aes_128_gcm.cpp 格式）
        func counterNonce(seq: UInt64) -> Data {
            var n = Data(repeating: 0, count: 12)
            for i in 0..<8 {
                n[i] = UInt8((seq >> (8 * i)) & 0xff)
            }
            return n
        }
    }

    // MARK: - GCM 核心

    static func encrypt(_ plaintext: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
        let blocks = splitBlocks(plaintext)
        let counter = j0(nonce: nonce)
        var ciphertext = Data(capacity: blocks.count * 16)
        var inc = counter
        for block in blocks {
            inc = inc32(inc)
            let mask = aesEncrypt(inc, key: key)
            var out = Data(repeating: 0, count: 16)
            for i in 0..<block.count {
                out[i] = block[i] ^ mask[i]
            }
            ciphertext.append(out[0..<block.count])
        }
        // tag = E(K, J0) XOR GHASH(AAD || pad || C || pad || len(AAD)||len(C))
        let tag = ghashTag(ciphertext: ciphertext, aad: aad, j0: counter, key: key)
        return ciphertext + tag
    }

    static func decrypt(_ input: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
        guard input.count >= 16 else {
            throw AESGCMError.badInput
        }
        let ciphertext = input[0..<(input.count - 16)]
        let tag = input[(input.count - 16)..<input.count]
        let blocks = splitBlocks(Data(ciphertext))
        let counter = j0(nonce: nonce)
        var plain = Data(capacity: blocks.count * 16)
        var inc = counter
        for block in blocks {
            inc = inc32(inc)
            let mask = aesEncrypt(inc, key: key)
            var out = Data(repeating: 0, count: 16)
            for i in 0..<block.count {
                out[i] = block[i] ^ mask[i]
            }
            plain.append(out[0..<block.count])
        }
        let expect = ghashTag(ciphertext: Data(ciphertext), aad: aad, j0: counter, key: key)
        guard tag.count == 16, constantTimeEqual(expect, Data(tag)) else {
            throw AESGCMError.tagMismatch
        }
        return plain
    }

    enum AESGCMError: Error {
        case badInput
        case tagMismatch
    }

    // MARK: - 内部

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    /// J0 = IV || 0^31 || 1（12 字节 IV）
    private static func j0(nonce: Data) -> [UInt8] {
        var j = [UInt8](repeating: 0, count: 16)
        for i in 0..<min(nonce.count, 12) {
            j[i] = nonce[i]
        }
        j[15] = 1
        return j
    }

    /// inc32：最后 4 字节大端 +1
    private static func inc32(_ ctr: [UInt8]) -> [UInt8] {
        var c = ctr
        for i in stride(from: 15, through: 12, by: -1) {
            c[i] &+= 1
            if c[i] != 0 { break }
        }
        return c
    }

    private static func splitBlocks(_ data: Data) -> [Data] {
        var blocks = [Data]()
        var idx = 0
        while idx < data.count {
            let end = min(idx + 16, data.count)
            blocks.append(data[idx..<end])
            idx = end
        }
        return blocks
    }

    /// AES-128 单块加密（CommonCrypto ECB）
    private static func aesEncrypt(_ block: [UInt8], key: Data) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var inData = block
        var dataOutMoved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt),
                             CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionECBMode),
                             [UInt8](key), key.count,
                             nil,
                             &inData, 16,
                             &out, 16,
                             &dataOutMoved)
        precondition(status == kCCSuccess, "AES 块加密失败 status=\(status)")
        return out
    }

    /// GHASH（GF(2^128)）
    private static func ghashTag(ciphertext: Data, aad: Data, j0: [UInt8], key: Data) -> Data {
        let h = aesEncrypt([UInt8](repeating: 0, count: 16), key: key)

        // 乘法输入补零到 16 字节倍数
        func pad16(_ d: Data) -> Data {
            var out = d
            let rem = out.count % 16
            if rem != 0 {
                out.append(Data(repeating: 0, count: 16 - rem))
            }
            return out
        }

        var y = [UInt8](repeating: 0, count: 16)
        func update(_ block: Data) {
            for i in 0..<16 {
                y[i] ^= block[i]
            }
            y = gfMul(y, h)
        }

        let paddedAAD = pad16(aad)
        for i in stride(from: 0, to: paddedAAD.count, by: 16) {
            update(paddedAAD[i..<(i + 16)])
        }
        let paddedC = pad16(ciphertext)
        for i in stride(from: 0, to: paddedC.count, by: 16) {
            update(paddedC[i..<(i + 16)])
        }
        // len(AAD) || len(C) 各 64 位大端（前 8 字节 = len(A)，后 8 字节 = len(C)）
        var lenBlock = Data(repeating: 0, count: 16)
        var aLen = UInt64(aad.count) * 8
        var cLen = UInt64(ciphertext.count) * 8
        for i in 0..<8 {
            lenBlock[i] = UInt8((aLen >> (56 - 8 * i)) & 0xff)
            lenBlock[8 + i] = UInt8((cLen >> (56 - 8 * i)) & 0xff)
        }
        update(lenBlock)

        // tag = E(K, J0) XOR y
        let eJ0 = aesEncrypt(j0, key: key)
        var tag = Data(repeating: 0, count: 16)
        for i in 0..<16 {
            tag[i] = y[i] ^ eJ0[i]
        }
        return tag
    }

    /// GF(2^128) 乘法（多项式 0x87 约简）
    private static func gfMul(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 16)
        var x = a
        var v = b
        for _ in 0..<128 {
            if (v[15] & 0x01) != 0 {
                for i in 0..<16 { result[i] ^= x[i] }
            }
            // x = x * 2（GF 左移）
            let xmsb = x[0] & 0x80
            var newX = [UInt8](repeating: 0, count: 16)
            for i in 0..<15 {
                newX[i] = (x[i] << 1) | (x[i + 1] >> 7)
            }
            newX[15] = x[15] << 1
            if xmsb != 0 {
                newX[15] ^= 0x87
            }
            x = newX
            // v = v >> 1
            let vlsb = v[15] & 0x01
            var newV = [UInt8](repeating: 0, count: 16)
            for i in stride(from: 15, through: 1, by: -1) {
                newV[i] = (v[i] >> 1) | (v[i - 1] << 7)
            }
            newV[0] = v[0] >> 1
            if vlsb != 0 {
                newV[0] |= 0x80
            }
            v = newV
        }
        return result
    }
}
