import Foundation

/// ADB sync 文件传输通道（SEND / RECV / DATA / DONE）
/// 协议参考 AOSP system/core/adb/sync.cpp
final class AdbSync {
    enum SyncError: LocalizedError {
        case notConnected
        case transferFailed(String)
        case serverError(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .notConnected: return "未连接设备"
            case .transferFailed(let msg): return "传输失败：\(msg)"
            case .serverError(let msg): return "设备端错误：\(msg)"
            case .timeout: return "传输超时"
            }
        }
    }

    private let client: AdbClient
    private let syncID: String = "sync:"
    var onLog: ((String) -> Void)?
    /// 传输进度回调 (已传输字节, 总字节)
    var onProgress: ((Int64, Int64) -> Void)?

    init(client: AdbClient) {
        self.client = client
    }

    // MARK: - 上传（推送文件到设备）

    /// 上传文件
    /// - Parameters:
    ///   - localPath: 本地文件 URL
    ///   - remotePath: 设备端路径（如 /data/local/tmp/xx.apk）
    ///   - mode: 文件权限（默认 0644）
    func push(fileURL: URL, remotePath: String,
              mode: UInt32 = 0o644,
              completion: @escaping (Result<Void, Error>) -> Void) {
        guard let data = try? Data(contentsOf: fileURL) else {
            completion(.failure(SyncError.transferFailed("本地文件读取失败")))
            return
        }
        push(data: data, remotePath: remotePath, mode: mode, completion: completion)
    }

    /// 上传数据
    func push(data: Data, remotePath: String, mode: UInt32 = 0o644,
              completion: @escaping (Result<Void, Error>) -> Void) {
        var channelID: UInt32?
        var receiveBuffer = Data()
        var didFinish = false

        func finish(_ result: Result<Void, Error>) {
            guard !didFinish else { return }
            didFinish = true
            if let id = channelID { client.close(channel: id) }
            completion(result)
        }

        channelID = client.open(service: syncID, onData: { [weak self] resp in
            guard let self = self else { return }
            receiveBuffer.append(resp)
            self.handleSyncResponse(receiveBuffer: &receiveBuffer,
                                    channelID: channelID,
                                    finish: finish)
        })

        guard let id = channelID else {
            finish(.failure(SyncError.notConnected))
            return
        }

        // 构造 SEND 请求：id("SEND") + mode(4 LE) + path\0
        var request = Data()
        request.append(contentsOf: "SEND".data(using: .ascii)!)
        request.appendUInt32(mode)
        request.append(Data(remotePath.utf8))
        request.append(0)
        client.write(toChannel: id, data: request)

        // 分包发送 DATA（每块 64KB）
        let chunkSize = 64 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            var block = Data()
            block.append(contentsOf: "DATA".data(using: .ascii)!)
            block.appendUInt32(UInt32(chunk.count))
            block.append(chunk)
            client.write(toChannel: id, data: block)
            offset = end
            onProgress?(Int64(offset), Int64(data.count))
        }

        // DONE 结束
        var done = Data()
        done.append(contentsOf: "DONE".data(using: .ascii)!)
        done.appendUInt32(UInt32(Date().timeIntervalSince1970))
        client.write(toChannel: id, data: done)

        // 超时保护
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            finish(.failure(SyncError.timeout))
        }
    }

    // MARK: - 下载（从设备拉取文件）

    /// 下载文件
    /// - Parameters:
    ///   - remotePath: 设备端路径
    ///   - completion: 返回文件数据
    func pull(remotePath: String, completion: @escaping (Result<Data, Error>) -> Void) {
        var channelID: UInt32?
        var receiveBuffer = Data()
        var fileData = Data()
        var didFinish = false

        func finish(_ result: Result<Data, Error>) {
            guard !didFinish else { return }
            didFinish = true
            if let id = channelID { client.close(channel: id) }
            completion(result)
        }

        channelID = client.open(service: syncID, onData: { [weak self] resp in
            guard let self = self else { return }
            receiveBuffer.append(resp)
            self.handlePullData(receiveBuffer: &receiveBuffer, fileData: &fileData, finish: finish)
        })

        guard let id = channelID else {
            finish(.failure(SyncError.notConnected))
            return
        }

        var request = Data()
        request.append(contentsOf: "RECV".data(using: .ascii)!)
        request.append(Data(remotePath.utf8))
        request.append(0)
        client.write(toChannel: id, data: request)

        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            finish(.failure(SyncError.timeout))
        }
    }

    // MARK: - 内部解析

    private func handleSyncResponse(receiveBuffer: inout Data,
                                    channelID: UInt32?,
                                    finish: @escaping (Result<Void, Error>) -> Void) {
        while receiveBuffer.count >= 8 {
            let id = String(data: receiveBuffer.prefix(4), encoding: .ascii) ?? ""
            let length = Int(receiveBuffer.readUInt32(at: 4))
            guard receiveBuffer.count >= 8 + length else { return }
            let message = receiveBuffer.subdata(in: 8..<(8 + length))
            receiveBuffer.removeFirst(8 + length)
            switch id {
            case "OKAY":
                finish(.success(()))
            case "FAIL":
                let text = String(data: message, encoding: .utf8) ?? "unknown"
                finish(.failure(SyncError.serverError(text)))
            default:
                break
            }
        }
    }

    private func handlePullData(receiveBuffer: inout Data,
                                fileData: inout Data,
                                finish: @escaping (Result<Data, Error>) -> Void) {
        while receiveBuffer.count >= 8 {
            let id = String(data: receiveBuffer.prefix(4), encoding: .ascii) ?? ""
            let length = Int(receiveBuffer.readUInt32(at: 4))
            guard receiveBuffer.count >= 8 + length else { return }
            let payload = receiveBuffer.subdata(in: 8..<(8 + length))
            receiveBuffer.removeFirst(8 + length)
            switch id {
            case "DATA":
                fileData.append(payload)
                onProgress?(Int64(fileData.count), 0)
            case "DONE":
                finish(.success(fileData))
            case "FAIL":
                let text = String(data: payload, encoding: .utf8) ?? "unknown"
                finish(.failure(SyncError.serverError(text)))
            default:
                break
            }
        }
    }
}
