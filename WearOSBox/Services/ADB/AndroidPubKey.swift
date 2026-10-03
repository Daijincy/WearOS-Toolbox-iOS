import Foundation
import Security

/// AOSP libcrypto_utils android_pubkey_encode 的 ANDROID_PUBKEY 格式
/// 用于配对 PeerInfo 中的 RSA 公钥（ADB 白名单写入格式）：
/// "base64(ANDROID_PUBKEY 二进制) user@host"，无 "ssh-rsa " 前缀
enum AndroidPubKey {
    /// 从 RSA SecKey 公钥生成 ADB 公钥行
    static func publicKeyLine(privateKey: SecKey, user: String = "wearosbox@ios") -> Data? {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { return nil }
        var err: Unmanaged<CFError>?
        // iOS 返回 PKCS#1 RSAPublicKey：SEQUENCE { INTEGER n, INTEGER e }
        guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &err) as Data? else {
            return nil
        }
        guard let (n, e) = parsePKCS1(pkcs1) else { return nil }
        let androidKey = androidPubkeyBytes(n: n, e: e)
        let line = androidKey.base64EncodedString() + " " + user
        return Data(line.utf8)
    }

    /// AOSP android_pubkey_encode：modulus_size_words(LE) + n0inv(LE)
    /// + modulus(256B LE) + rr(256B LE) + exponent(LE)
    static func androidPubkeyBytes(n: BigUInt, e: BigUInt) -> Data {
        let mod = 256
        var out = Data()

        // 1) modulus_size_words = 64（2048 bit / 32）
        out.append(leU32(64))
        // 2) n0inv = (2^32 - (N mod 2^32)^-1 mod 2^32) mod 2^32
        let two32 = BigUInt(1) << 32
        let n0 = n % two32
        let inv = n0.inverse(two32) ?? BigUInt(0)
        out.append(leU32((two32 - inv % two32) % two32))
        // 3) modulus：256 字节小端
        out.append(lePadded(n, size: mod))
        // 4) rr = 2^4096 mod N：256 字节小端
        let rr = (BigUInt(1) << 4096) % n
        out.append(lePadded(rr, size: mod))
        // 5) exponent
        out.append(leU32(e))
        return out
    }

    // MARK: - PKCS#1 解析

    /// 解析 PKCS#1 RSAPublicKey DER：SEQUENCE { INTEGER n, INTEGER e }
    private static func parsePKCS1(_ der: Data) -> (BigUInt, BigUInt)? {
        var offset = 0
        guard offset + 4 <= der.count else { return nil }
        // SEQUENCE 头
        guard der[0] == 0x30 else { return nil }
        let (seqLen, afterLen) = derLength(der, at: 1)
        guard let seqLen = seqLen, afterLen + seqLen <= der.count else { return nil }
        offset = afterLen
        // INTEGER n
        guard der[offset] == 0x02 else { return nil }
        let (nLen, nStart) = derLength(der, at: offset + 1)
        guard let nLen = nLen, nStart + nLen <= der.count else { return nil }
        let nBig = BigUInt(Data(der[nStart..<(nStart + nLen)]))  // 大端
        offset = nStart + nLen
        // INTEGER e
        guard offset + 1 < der.count, der[offset] == 0x02 else { return nil }
        let (eLen, eStart) = derLength(der, at: offset + 1)
        guard let eLen = eLen, eStart + eLen <= der.count else { return nil }
        let eBig = BigUInt(Data(der[eStart..<(eStart + eLen)]))
        return (nBig, eBig)
    }

    /// 读取 DER 长度（返回 (length, 内容起始偏移)）
    private static func derLength(_ data: Data, at pos: Int) -> (Int?, Int) {
        guard pos < data.count else { return (nil, pos) }
        let first = Int(data[pos])
        if first < 0x80 {
            return (first, pos + 1)
        }
        let numBytes = first & 0x7f
        guard numBytes > 0, numBytes <= 4, pos + 1 + numBytes <= data.count else {
            return (nil, pos + 1)
        }
        var len = 0
        for i in 0..<numBytes {
            len = len << 8 | Int(data[pos + 1 + i])
        }
        return (len, pos + 1 + numBytes)
    }

    // MARK: - 编码工具

    /// 小端 32 位
    private static func leU32(_ v: BigUInt) -> Data {
        let mask = BigUInt(0xff)
        var out = Data()
        var x = v
        for _ in 0..<4 {
            out.append(UInt8((x & mask).words.first ?? 0))
            x >>= 8
        }
        return out
    }

    /// 以 size 字节小端写入
    private static func lePadded(_ v: BigUInt, size: Int) -> Data {
        var bytes = v.serialize()  // 大端
        // 反转成小端
        var out = Data(repeating: 0, count: size)
        let n = min(bytes.count, size)
        for i in 0..<n {
            out[i] = bytes[bytes.count - 1 - i]
        }
        return out
    }
}
