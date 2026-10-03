import Foundation
import zlib

/// ADB 协议报文（system/core/adb/protocol.txt 定义的 wire format）
/// 报文结构（全部小端序）：
///   command(4) arg0(4) arg1(4) length(4) payload(length) crc32(4) magic(4)
///   magic = command ^ 0xFFFFFFFF
struct AdbPacket {
    enum Command: UInt32 {
        case auth = 0x48545541 // AUTH
        case cnxn = 0x4e584e43 // CNXN
        case open = 0x4e45504f // OPEN
        case wrte = 0x45545257 // WRTE
        case clse = 0x45534c43 // CLSE
        case okay = 0x59414b4f // OKAY

        var name: String {
            switch self {
            case .auth: return "AUTH"
            case .cnxn: return "CNXN"
            case .open: return "OPEN"
            case .wrte: return "WRTE"
            case .clse: return "CLSE"
            case .okay: return "OKAY"
            }
        }
    }

    /// AUTH 子类型
    enum AuthType: UInt32 {
        case token = 1          // 设备发送 token
        case signature = 2      // 客户端用私钥签名 token
        case rsaPublicKey = 3   // 客户端发送 RSA 公钥
    }

    let command: Command
    let arg0: UInt32
    let arg1: UInt32
    let payload: Data

    init(command: Command, arg0: UInt32 = 0, arg1: UInt32 = 0, payload: Data = Data()) {
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.payload = payload
    }

    /// 序列化为字节流
    func serialize() -> Data {
        var data = Data()
        data.appendUInt32(command.rawValue)
        data.appendUInt32(arg0)
        data.appendUInt32(arg1)
        data.appendUInt32(UInt32(payload.count))
        data.append(payload)
        let crc = UInt32(zlib.crc32(0, [UInt8](payload), uInt(payload.count)))
        data.appendUInt32(crc)
        data.appendUInt32(command.rawValue ^ 0xFFFF_FFFF)
        return data
    }

    /// 从数据流解析第一个完整报文；返回报文与消耗的字节数
    static func parse(from data: Data, offset: Int = 0) -> (packet: AdbPacket?, consumed: Int)? {
        let available = data.count - offset
        guard available >= 24 else { return nil }
        let command = data.readUInt32(at: offset)
        let arg0 = data.readUInt32(at: offset + 4)
        let arg1 = data.readUInt32(at: offset + 8)
        let length = Int(data.readUInt32(at: offset + 12))
        guard available >= 24 + length else { return nil }
        let payload = data.subdata(in: (offset + 16)..<(offset + 16 + length))
        let crc = data.readUInt32(at: offset + 16 + length)
        let magic = data.readUInt32(at: offset + 20 + length)

        // 校验 CRC 与 magic
        let crcCalc = UInt32(zlib.crc32(0, [UInt8](payload), uInt(payload.count)))
        guard crc == crcCalc else {
            return (nil, 0)
        }
        guard magic == (command ^ 0xFFFF_FFFF) else {
            return (nil, 0)
        }
        guard let cmd = Command(rawValue: command) else {
            return (nil, 0)
        }
        let packet = AdbPacket(command: cmd, arg0: arg0, arg1: arg1, payload: payload)
        return (packet, 24 + length)
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let raw = subdata(in: offset..<(offset + 4))
        return raw.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }

    mutating func appendUInt16(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let raw = subdata(in: offset..<(offset + 2))
        return raw.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    }
}
