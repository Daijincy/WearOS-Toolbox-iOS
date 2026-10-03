import Foundation

/// 设备常用操作封装（基于 shell / exec / sync 组合）
final class AdbOps {
    private let client: AdbClient
    private let shell: AdbShell
    /// sync 通道（供文件管理页面使用）
    let sync: AdbSync

    init(client: AdbClient) {
        self.client = client
        self.shell = AdbShell(client: client)
        self.sync = AdbSync(client: client)
    }

    var onLog: ((String) -> Void)? {
        didSet {
            shell.onLog = onLog
            sync.onLog = onLog
        }
    }

    // MARK: - 截图

    /// 获取屏幕截图 PNG（exec:screencap -p）
    func screencap(completion: @escaping (Result<Data, Error>) -> Void) {
        // exec 通道输出原始字节流（无 \r\n 转换）
        var channelID: UInt32?
        var imageData = Data()
        var didFinish = false

        func finish(_ result: Result<Data, Error>) {
            guard !didFinish else { return }
            didFinish = true
            if let id = channelID { client.close(channel: id) }
            completion(result)
        }

        channelID = client.open(service: "exec:screencap -p", onData: { data in
            imageData.append(data)
        }, onClose: {
            finish(.success(imageData))
        })
        guard channelID != nil else {
            finish(.failure(AdbError.notConnected))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            finish(.failure(AdbError.timeout))
        }
    }

    // MARK: - APK 安装

    /// 安装单个 APK
    /// - Parameters:
    ///   - apkURL: 本地 APK 文件
    ///   - progress: 进度回调 0-1
    func installAPK(apkURL: URL,
                    progress: ((Double) -> Void)? = nil,
                    completion: @escaping (Result<String, Error>) -> Void) {
        guard let data = try? Data(contentsOf: apkURL) else {
            completion(.failure(AdbError.connectionFailed("无法读取 APK 文件")))
            return
        }
        let remote = "/data/local/tmp/wearosbox_install.apk"
        sync.onProgress = { sent, _ in
            if let total = data.count > 0 ? Double(data.count) : nil {
                progress?(min(1.0, Double(sent) / total))
            }
        }
        sync.push(data: data, remotePath: remote) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.shell.execute(command: "pm install -r -t \(remote)") { result in
                    switch result {
                    case .success(let out):
                        // 清理临时文件
                        self.shell.execute(command: "rm -f \(remote)") { _ in }
                        if out.output.contains("Success") {
                            completion(.success(out.output))
                        } else {
                            completion(.failure(AdbError.connectionFailed("安装失败：\(out.output)")))
                        }
                    case .failure(let err):
                        completion(.failure(err))
                    }
                }
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    /// 安装 Split APK（base + 多个 split 包）
    func installSplitAPK(apkURLs: [URL], completion: @escaping (Result<String, Error>) -> Void) {
        // 1. 全部推送到设备
        let remoteDir = "/data/local/tmp/wearosbox_split"
        let fileNames = apkURLs.enumerated().map { "\($0.offset).apk" }
        var remotePaths: [String] = []

        func pushNext(index: Int) {
            guard index < apkURLs.count else {
                installSplitSession(remotePaths: remotePaths, completion: completion)
                return
            }
            guard let data = try? Data(contentsOf: apkURLs[index]) else {
                completion(.failure(AdbError.connectionFailed("无法读取 \(apkURLs[index].lastPathComponent)")))
                return
            }
            let remote = "\(remoteDir)/\(fileNames[index])"
            remotePaths.append(remote)
            sync.push(data: data, remotePath: remote) { result in
                switch result {
                case .success:
                    pushNext(index: index + 1)
                case .failure(let err):
                    completion(.failure(err))
                }
            }
        }

        shell.execute(command: "mkdir -p \(remoteDir)") { _ in
            pushNext(index: 0)
        }
    }

    /// 创建安装会话并逐个写入 split 包
    private func installSplitSession(remotePaths: [String], completion: @escaping (Result<String, Error>) -> Void) {
        let totalSize = remotePaths.reduce(0) { size, path in
            size + ((try? Data(contentsOf: URL(fileURLWithPath: path)))?.count ?? 0)
        }
        shell.execute(command: "pm install-create -S \(totalSize)") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let out):
                guard let sessionID = Self.parseSessionID(from: out.output) else {
                    completion(.failure(AdbError.connectionFailed("创建安装会话失败：\(out.output)")))
                    return
                }
                self.writeSplitParts(sessionID: sessionID, remotePaths: remotePaths, index: 0) { writeResult in
                    switch writeResult {
                    case .success:
                        self.shell.execute(command: "pm install-commit \(sessionID)") { commitResult in
                            // 清理
                            self.shell.execute(command: "rm -rf /data/local/tmp/wearosbox_split") { _ in }
                            switch commitResult {
                            case .success(let o):
                                if o.output.contains("Success") {
                                    completion(.success(o.output))
                                } else {
                                    completion(.failure(AdbError.connectionFailed("提交安装失败：\(o.output)")))
                                }
                            case .failure(let err):
                                completion(.failure(err))
                            }
                        }
                    case .failure(let err):
                        completion(.failure(err))
                    }
                }
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    private func writeSplitParts(sessionID: String, remotePaths: [String], index: Int,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        guard index < remotePaths.count else {
            completion(.success(()))
            return
        }
        let path = remotePaths[index]
        let size = (try? Data(contentsOf: URL(fileURLWithPath: path)))?.count ?? 0
        let name = "split\(index).apk"
        shell.execute(command: "pm install-write -S \(size) \(sessionID) \(name) \(path)") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let out):
                if out.output.contains("Success") {
                    self.writeSplitParts(sessionID: sessionID, remotePaths: remotePaths, index: index + 1, completion: completion)
                } else {
                    completion(.failure(AdbError.connectionFailed("写入 split 失败：\(out.output)")))
                }
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    private static func parseSessionID(from output: String) -> String? {
        // "Success: created install session [123456789]"
        guard let range = output.range(of: #"\[(\d+)\]"#, options: .regularExpression) else { return nil }
        let id = output[range].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return id
    }

    // MARK: - 应用管理

    /// 列出已安装应用（包名+版本）
    func listPackages(completion: @escaping (Result<[(package: String, version: String)], Error>) -> Void) {
        shell.execute(command: "pm list packages -f") { result in
            switch result {
            case .success(let out):
                let lines = out.output.split(separator: "\n").map { String($0) }
                var packages: [(String, String)] = []
                for line in lines {
                    // 格式: package:/path/base.apk=com.example.app
                    guard let range = line.range(of: "=") else { continue }
                    let package = String(line[range.upperBound...])
                    packages.append((package, ""))
                }
                completion(.success(packages))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    /// 卸载应用
    func uninstall(package: String, completion: @escaping (Result<String, Error>) -> Void) {
        shell.execute(command: "pm uninstall \(package)") { result in
            switch result {
            case .success(let out):
                completion(.success(out.output))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    /// 清除应用数据
    func clearAppData(package: String, completion: @escaping (Result<String, Error>) -> Void) {
        shell.execute(command: "pm clear \(package)") { result in
            switch result {
            case .success(let out):
                completion(.success(out.output))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    // MARK: - 电池

    /// 读取电池信息（dumpsys battery 解析）
    func batteryInfo(completion: @escaping (Result<[String: String], Error>) -> Void) {
        shell.execute(command: "dumpsys battery") { result in
            switch result {
            case .success(let out):
                var info: [String: String] = [:]
                for line in out.output.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard let colon = trimmed.firstIndex(of: ":") else { continue }
                    let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                    let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    info[key] = value
                }
                completion(.success(info))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    // MARK: - 屏幕工具

    /// 获取当前分辨率与 DPI
    func screenInfo(completion: @escaping (Result<(size: String, density: String), Error>) -> Void) {
        shell.execute(command: "wm size && wm density") { result in
            switch result {
            case .success(let out):
                var size = "Unknown"
                var density = "Unknown"
                for line in out.output.split(separator: "\n") {
                    if line.hasPrefix("Physical size:") {
                        size = String(line).replacingOccurrences(of: "Physical size:", with: "").trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("Override size:") {
                        size = String(line).replacingOccurrences(of: "Override size:", with: "").trimmingCharacters(in: .whitespaces)
                    }
                    if line.hasPrefix("Physical density:") {
                        density = String(line).replacingOccurrences(of: "Physical density:", with: "").trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("Override density:") {
                        density = String(line).replacingOccurrences(of: "Override density:", with: "").trimmingCharacters(in: .whitespaces)
                    }
                }
                completion(.success((size, density)))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    /// 修改分辨率（wm size WxH），空则恢复默认
    func setScreenSize(_ size: String?, completion: @escaping (Result<String, Error>) -> Void) {
        let cmd = size.map { "wm size \($0)" } ?? "wm size reset"
        shell.execute(command: cmd) { result in
            switch result {
            case .success(let out): completion(.success(out.output))
            case .failure(let err): completion(.failure(err))
            }
        }
    }

    /// 修改 DPI（wm density），空则恢复默认
    func setScreenDensity(_ density: String?, completion: @escaping (Result<String, Error>) -> Void) {
        let cmd = density.map { "wm density \($0)" } ?? "wm density reset"
        shell.execute(command: cmd) { result in
            switch result {
            case .success(let out): completion(.success(out.output))
            case .failure(let err): completion(.failure(err))
            }
        }
    }

    // MARK: - 剪贴板

    /// 读取剪贴板文本
    func getClipboard(completion: @escaping (Result<String, Error>) -> Void) {
        shell.execute(command: "service call clipboard 1 i32 1") { result in
            switch result {
            case .success(let out):
                // Parcel 输出解析：查找 "String" 段中的文本
                let text = Self.parseClipboardParcel(out.output)
                completion(.success(text))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    /// 写入剪贴板文本
    func setClipboard(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "'", with: "'\\''")
        shell.execute(command: "service call clipboard 2 i32 1 s16 \"\(escaped)\"") { result in
            switch result {
            case .success(let out): completion(.success(out.output))
            case .failure(let err): completion(.failure(err))
            }
        }
    }

    /// 从 service call 的 Parcel 文本中提取字符串（兼容不同 Android 版本输出）
    private static func parseClipboardParcel(_ output: String) -> String {
        // 输出形如: Result: Parcel(... ... String16 '文本内容' ...)
        var text = ""
        for line in output.split(separator: "\n") {
            if line.contains("'") {
                if let start = line.range(of: "'"), let end = line[start.upperBound...].range(of: "'") {
                    text = String(line[start.upperBound..<end.lowerBound])
                    break
                }
            }
        }
        return text
    }

    // MARK: - 文件操作（远程）

    /// 列出远程目录
    func listRemote(path: String, completion: @escaping (Result<[RemoteFile], Error>) -> Void) {
        let cmd = "ls -la \(path)"
        shell.execute(command: cmd) { result in
            switch result {
            case .success(let out):
                var files: [RemoteFile] = []
                for line in out.output.split(separator: "\n").dropFirst() {
                    let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                    guard fields.count >= 9 else { continue }
                    let name = String(fields[8])
                    if name == "." || name == ".." { continue }
                    let isDir = fields[0].hasPrefix("d")
                    let size = Int64(fields[4]) ?? 0
                    files.append(RemoteFile(name: name, size: size, isDirectory: isDir))
                }
                completion(.success(files))
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    /// 删除远程文件/目录
    func removeRemote(path: String, completion: @escaping (Result<String, Error>) -> Void) {
        shell.execute(command: "rm -rf \(path)") { result in
            switch result {
            case .success(let out): completion(.success(out.output))
            case .failure(let err): completion(.failure(err))
            }
        }
    }

    /// 重命名远程文件
    func renameRemote(from: String, to: String, completion: @escaping (Result<String, Error>) -> Void) {
        shell.execute(command: "mv \(from) \(to)") { result in
            switch result {
            case .success(let out): completion(.success(out.output))
            case .failure(let err): completion(.failure(err))
            }
        }
    }
}

/// 远程文件信息
struct RemoteFile: Identifiable, Hashable {
    let name: String
    let size: Int64
    let isDirectory: Bool

    var id: String { name }
    var sizeText: String {
        if isDirectory { return "目录" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}
