import Foundation
import CryptoKit

/// BoringSSL 兼容的 SPAKE2（Ed25519 群），用于 Android 无线调试配对协议。
/// 算法逐行对照 AOSP external/boringssl src/crypto/curve25519/spake25519.c：
///  - 角色：客户端 = Alice("adb pair client\0")，服务端 = Bob("adb pair server\0")
///  - 消息：32 字节 Ed25519 点编码（P* = k*B + h(pwd)*M/N）
///  - 密钥派生：SHA-512(length-prefixed names/messages/DH/password_hash)
/// 群运算基于 BigUInt（无符号），所有可能为负的减法经 modSub 归约。
enum Spake2Ed25519 {
    // ---- Ed25519 常量 ----
    private static let P = (BigUInt(1) << 255) - BigUInt(19)
    private static let D = (BigUInt(121665) * BigUInt(121666).inverse(P)!) % P
    private static let TWO_D = (D << 1) % P
    /// Ed25519 群阶 l
    private static let L = (BigUInt(1) << 252) + BigUInt("27742317777372353535851937790883648493", radix: 10)!
    private static let SQRT_M1 = BigUInt(2).power((P - BigUInt(1)) >> 2, modulus: P)

    // ---- SPAKE2 角色 ----
    static let roleClient = 0 // Alice
    static let roleServer = 1 // Bob

    /// M / N 掩码点（BoringSSL kSpakeMSmallPrecomp / kSpakeNSmallPrecomp 首项，小端）
    private static let MX = leHex("c8a663c597f1ee40ab6242ee256f326c752ca7d3bd323b1e119cbd04a9786f45")
    private static let MY = leHex("5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e")
    private static let NX = leHex("201bc5b343177110441e73b3ae3fbf9ff544c8138fd101c28a1a6dea4d005d6e")
    private static let NY = leHex("10e3df0ae37d8e7a99b5fe74b44672103dbddcbd06af680d71329a11693bc778")

    /// 上下文
    final class Context {
        let role: Int
        let myName: Data
        let theirName: Data
        var privateKey: BigUInt?       // 随机标量（8 的倍数）
        var passwordScalar: BigUInt?   // SHA-512(pwd) reduce 后调整（8 的倍数）
        var passwordHash: Data?        // SHA-512(pwd) 原始 64 字节
        var myMsg: Data?               // 32 字节点编码
        var generated = false

        init(role: Int, myName: Data, theirName: Data) {
            self.role = role
            self.myName = myName
            self.theirName = theirName
        }
    }

    static func newClient() -> Context {
        Context(role: roleClient,
                myName: Data("adb pair client\0".utf8),
                theirName: Data("adb pair server\0".utf8))
    }

    static func newServer() -> Context {
        Context(role: roleServer,
                myName: Data("adb pair server\0".utf8),
                theirName: Data("adb pair client\0".utf8))
    }

    /// 生成我方 SPAKE2 消息（32 字节）
    static func generateMsg(_ ctx: Context, password: Data) -> Data? {
        var rnd = [UInt8](repeating: 0, count: 64)
        for i in 0..<64 { rnd[i] = UInt8.random(in: 0...255) }
        return generateMsgWithRandom(ctx, password: password, random: Data(rnd))
    }

    /// 注入固定随机字节（测试用）
    static func generateMsgWithRandom(_ ctx: Context, password: Data, random rnd64: Data) -> Data? {
        guard !ctx.generated else { return nil }
        // 1) 私钥 = scReduce(rnd) << 3（保证低 3 位为 0）
        let priv = scReduce(rnd64) << 3
        ctx.privateKey = priv
        // 2) 密码标量
        let pwdHash = Data(SHA512.hash(data: password))
        ctx.passwordHash = pwdHash
        var scalar = scReduce(pwdHash)
        // password_scalar hack：加 l/2l/4l 使最低 3 位为 0
        if scalar & BigUInt(1) == BigUInt(1) { scalar += L }
        if scalar & BigUInt(2) == BigUInt(2) { scalar += L << 1 }
        if scalar & BigUInt(4) == BigUInt(4) { scalar += L << 2 }
        guard scalar & BigUInt(7) == BigUInt(0) else { return nil }
        ctx.passwordScalar = scalar
        // 3) P* = priv*B + h(pwd)*maskPoint
        let pStar = scalarmultBase(priv)
        let mask = scalarmult(scalar, point: ctx.role == roleClient ? [MX, MY] : [NX, NY])
        let point = add(pStar, mask)
        ctx.myMsg = encode(point)
        ctx.generated = true
        return ctx.myMsg
    }

    /// 处理对端消息，返回 64 字节密钥材料
    static func processMsg(_ ctx: Context, theirMsg: Data, maxOut: Int) -> Data? {
        guard ctx.generated, theirMsg.count == 32 else { return nil }
        guard let myMsg = ctx.myMsg, let passwordScalar = ctx.passwordScalar,
              let passwordHash = ctx.passwordHash, let privateKey = ctx.privateKey else {
            return nil
        }
        let qStar = decode(theirMsg)
        guard let qStar = qStar else { return nil }
        // 移除对端掩码：Q = Q* - h(pwd)*M/N
        let peersMask = scalarmult(passwordScalar, point: ctx.role == roleClient ? [NX, NY] : [MX, MY])
        let q = sub(fromAffine(qStar), peersMask)
        let dh = scalarmult(privateKey, point: q)
        let dhEnc = encode(dh)

        // SHA-512( LE64(len)||name ... ) —— BoringSSL spake25519 密钥派生
        var md = SHA512()
        if ctx.role == roleClient {
            updateLenPref(&md, ctx.myName)
            updateLenPref(&md, ctx.theirName)
            updateLenPref(&md, myMsg)
            updateLenPref(&md, theirMsg)
        } else {
            updateLenPref(&md, ctx.theirName)
            updateLenPref(&md, ctx.myName)
            updateLenPref(&md, theirMsg)
            updateLenPref(&md, myMsg)
        }
        updateLenPref(&md, dhEnc)
        updateLenPref(&md, passwordHash)
        let key = Data(md.finalize())
        return key.prefix(maxOut)
    }

    // ================= Ed25519 群运算（射影坐标 X:Y:Z:T） =================

    /// (a - b) mod m，a/b 均为无符号
    private static func modSub(_ a: BigUInt, _ b: BigUInt, _ m: BigUInt) -> BigUInt {
        if a >= b {
            return (a - b) % m
        }
        return (m - ((b - a) % m)) % m
    }

    private static func identity() -> [BigUInt] { [BigUInt(0), BigUInt(1), BigUInt(1), BigUInt(0)] }

    private static func fromAffine(_ aff: [BigUInt]) -> [BigUInt] {
        let x = aff[0] % P, y = aff[1] % P
        return [x, y, BigUInt(1), (x * y) % P]
    }

    /// double (dbl-2008-hwcd)
    private static func dbl(_ q: [BigUInt]) -> [BigUInt] {
        let X1 = q[0], Y1 = q[1], Z1 = q[2]
        let A = (X1 * X1) % P
        let B = (Y1 * Y1) % P
        let C = (((Z1 * Z1) % P) << 1) % P
        let D = modSub(P, A, P)          // -A
        let E = modSub(modSub((((X1 + Y1) % P) * ((X1 + Y1) % P)) % P, A, P), B, P)
        let G = (D + B) % P
        let F = modSub(G, C, P)
        let H = modSub(D, B, P)
        return [
            (E * F) % P,
            (G * H) % P,
            (F * G) % P,
            (E * H) % P]
    }

    /// add (add-2008-hwcd-3)
    private static func add(_ p: [BigUInt], _ q: [BigUInt]) -> [BigUInt] {
        let X1 = p[0], Y1 = p[1], Z1 = p[2], T1 = p[3]
        let X2 = q[0], Y2 = q[1], Z2 = q[2], T2 = q[3]
        let A = (modSub(Y1, X1, P) * modSub(Y2, X2, P)) % P
        let B = (((Y1 + X1) % P) * ((Y2 + X2) % P)) % P
        let C = ((T1 * TWO_D % P) * T2) % P
        let D = (((Z1 << 1) % P) * Z2) % P
        let E = modSub(B, A, P)
        let F = modSub(D, C, P)
        let G = (D + C) % P
        let H = (B + A) % P
        return [
            (E * F) % P,
            (G * H) % P,
            (F * G) % P,
            (E * H) % P]
    }

    /// sub: p - q（q 取负：X->-X, T->-T；twisted Edwards a=-1）
    private static func sub(_ p: [BigUInt], _ q: [BigUInt]) -> [BigUInt] {
        let X1 = p[0], Y1 = p[1], Z1 = p[2], T1 = p[3]
        let X2 = modSub(BigUInt(0), q[0], P), Y2 = q[1], Z2 = q[2], T2 = modSub(BigUInt(0), q[3], P)
        let A = (modSub(Y1, X1, P) * modSub(Y2, X2, P)) % P
        let B = (((Y1 + X1) % P) * ((Y2 + X2) % P)) % P
        let C = ((T1 * TWO_D % P) * T2) % P
        let D = (((Z1 << 1) % P) * Z2) % P
        let E = modSub(B, A, P)
        let F = modSub(D, C, P)
        let G = (D + C) % P
        let H = (B + A) % P
        return [
            (E * F) % P,
            (G * H) % P,
            (F * G) % P,
            (E * H) % P]
    }

    /// 标量乘：s * point（double-and-add，MSB-first，与 BoringSSL 一致）
    private static func scalarmult(_ s: BigUInt, point: [BigUInt]) -> [BigUInt] {
        let q = point.count == 4 ? point : fromAffine(point)
        var r = identity()
        guard s > 0 else { return r }
        let highest = s.bitWidth - 1
        for i in stride(from: highest, through: 0, by: -1) {
            r = dbl(r)
            if s & (BigUInt(1) << i) != BigUInt(0) {
                r = add(r, q)
            }
        }
        return r
    }

    /// Ed25519 基点编码（y=4/5）
    private static let basePointEnc = Data([
        0x58, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
        0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
        0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
        0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66
    ])

    private static func scalarmultBase(_ s: BigUInt) -> [BigUInt] {
        scalarmult(s, point: decode(basePointEnc)!)
    }

    /// Ed25519 点编码：y | (x&1)<<255，小端 32 字节
    private static func encode(_ pt: [BigUInt]) -> Data {
        let aff = toAffine(pt)
        var out = Data(repeating: 0, count: 32)
        let yBytes = aff[1].serialize()  // 大端
        for i in 0..<min(yBytes.count, 32) {
            out[i] = yBytes[yBytes.count - 1 - i]
        }
        if aff[0] & BigUInt(1) == BigUInt(1) {
            out[31] |= 0x80
        }
        return out
    }

    private static func toAffine(_ pt: [BigUInt]) -> [BigUInt] {
        let zInv = pt[2].inverse(P) ?? BigUInt(0)
        return [(pt[0] * zInv) % P, (pt[1] * zInv) % P]
    }

    /// Ed25519 点解码（x 恢复 + 奇偶 + on-curve 校验），失败返回 nil
    private static func decode(_ b: Data) -> [BigUInt]? {
        guard b.count == 32 else { return nil }
        let mask = (BigUInt(1) << 255) - BigUInt(1)
        let y = leBytes(b) & mask
        let y2 = (y * y) % P
        let u = modSub(y2, BigUInt(1), P)
        let v = (D * y2 + BigUInt(1)) % P
        let vInv = v.inverse(P) ?? BigUInt(0)
        var x = ((u * vInv) % P).power((P + BigUInt(3)) >> 3, modulus: P)
        // x^2 * v == u ?
        if ((x * x) % P * v) % P != u {
            x = (x * SQRT_M1) % P
            guard ((x * x) % P * v) % P == u else {
                return nil
            }
        }
        let signBit = (b.count > 31 && b[31] & 0x80 != 0)
        if (x & BigUInt(1) == BigUInt(1)) != signBit {
            x = modSub(BigUInt(0), x, P)
        }
        // on-curve：x^2 + y^2 == 1 + d*x^2*y^2
        let x2 = (x * x) % P
        guard (x2 + y2) % P == (BigUInt(1) + (D * x2 % P) * y2 % P) % P else {
            return nil
        }
        return [x, y]
    }

    // ================= 工具 =================

    /// x25519_sc_reduce：64 字节 LE -> mod l
    static func scReduce(_ b64: Data) -> BigUInt {
        leBytes(b64) % L
    }

    private static func leBytes(_ b: Data) -> BigUInt {
        var rev = Data(repeating: 0, count: b.count)
        for i in 0..<b.count { rev[i] = b[b.count - 1 - i] }
        return BigUInt(rev)
    }

    private static func leHex(_ hex: String) -> BigUInt {
        var b = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let e = hex.index(idx, offsetBy: 2)
            b.append(UInt8(hex[idx..<e], radix: 16)!)
            idx = e
        }
        return leBytes(b)
    }

    private static func updateLenPref(_ md: inout SHA512, _ data: Data) {
        var lenBytes = [UInt8](repeating: 0, count: 8)
        var l = UInt64(data.count)
        for i in 0..<8 { lenBytes[i] = UInt8(l & 0xff); l >>= 8 }
        md.update(data: Data(lenBytes))
        md.update(data: data)
    }
}
