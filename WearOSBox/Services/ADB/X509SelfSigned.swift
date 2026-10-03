import Foundation
import Security

/// 最小 X.509 DER 编码器 + RSA 自签名证书生成。
/// 用于 ADB 配对 TLS 1.3 客户端证书（设备端不校验 CA，仅要求结构合法的自签证书）。
enum X509SelfSigned {
    // MARK: - DER 基础编码

    private static func derLength(_ n: Int) -> Data {
        if n < 0x80 {
            return Data([UInt8(n)])
        }
        var bytes = [UInt8]()
        var v = n
        while v > 0 {
            bytes.insert(UInt8(v & 0xff), at: 0)
            v >>= 8
        }
        return Data([UInt8(0x80 | bytes.count)]) + Data(bytes)
    }

    private static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + derLength(content.count) + content
    }

    private static func sequence(_ parts: [Data]) -> Data {
        tlv(0x30, parts.reduce(Data(), +))
    }

    private static func setOf(_ parts: [Data]) -> Data {
        tlv(0x31, parts.reduce(Data(), +))
    }

    /// 无符号 INTEGER（正数，前导 0 处理）
    private static func integer(_ bytes: Data) -> Data {
        var b = bytes
        while b.count > 1 && b.first == 0 { b.removeFirst() }
        if b.first! & 0x80 != 0 {
            b.insert(0, at: 0)
        }
        return tlv(0x02, b)
    }

    private static func oid(_ oid: [UInt8]) -> Data {
        tlv(0x06, Data(oid))
    }

    private static func utf8(_ s: String) -> Data {
        tlv(0x0c, Data(s.utf8))
    }

    private static func bitString(_ content: Data) -> Data {
        tlv(0x03, Data([0x00]) + content)  // unused bits = 0
    }

    private static func nullValue() -> Data {
        tlv(0x05, Data())
    }

    private static func utcTime(_ date: Date) -> Data {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(fmt.string(from: date).utf8))
    }

    // MARK: - 证书生成

    /// 生成 RSA-2048 自签名证书 DER
    static func generateSelfSignedCertificate(privateKey: SecKey) -> Data? {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { return nil }
        var err: Unmanaged<CFError>?
        // iOS 返回 PKCS#1 RSAPublicKey
        guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &err) as Data? else {
            return nil
        }

        // AlgorithmIdentifier: rsaEncryption
        let rsaEncOID = oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01])  // 1.2.840.113549.1.1.1
        let algId = sequence([rsaEncOID, nullValue()])
        // SPKI
        let spki = sequence([algId, bitString(pkcs1)])

        // Name: CN=wearosbox
        let namePart = sequence([oid([0x55, 0x04, 0x03]), utf8("wearosbox")])  // 2.5.4.3
        let name = sequence([setOf([namePart])])

        // TBSCertificate
        let now = Date()
        let notBefore = utcTime(now.addingTimeInterval(-86400))
        let notAfter = utcTime(now.addingTimeInterval(86400 * 3650))
        let validity = sequence([notBefore, notAfter])

        // serialNumber = 1
        let serial = integer(Data([0x01]))

        // version v3 = 2
        let version = tlv(0xa0, integer(Data([0x02])))
        // sha256WithRSAEncryption 1.2.840.113549.1.1.11
        let sha256RSA = sequence([oid([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]), nullValue()])

        let tbs = sequence([version, serial, sha256RSA, name, validity, name, spki])

        // 签名
        let sigAlgorithm = sha256RSA
        guard let signature = SecKeyCreateSignature(privateKey,
                                                    .rsaSignatureMessagePKCS1v15SHA256,
                                                    tbs as CFData,
                                                    &err) as Data? else {
            return nil
        }
        let cert = sequence([tbs, sigAlgorithm, bitString(signature)])
        return cert
    }

    /// PEM 编码（调试显示用）
    static func pemEncode(_ der: Data) -> String {
        let base64 = der.base64EncodedString()
        var lines = [String]()
        var idx = base64.startIndex
        while idx < base64.endIndex {
            let e = base64.index(idx, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[idx..<e]))
            idx = e
        }
        return "-----BEGIN CERTIFICATE-----\n" + lines.joined(separator: "\n") + "\n-----END CERTIFICATE-----"
    }
}
