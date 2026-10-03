import Foundation

/// shell:v2 输出帧解析
/// 帧格式：4 字节 Id + 4 字节 Length + payload
/// Id: 0=窗口变化 1=Stdout 2=Stderr 3=Exit(退出码) 4=关闭stdin
final class ShellV2Parser {
    enum Id: UInt32 {
        case windowSize = 0
        case stdout = 1
        case stderr = 2
        case exit = 3
        case closeStdin = 4
    }

    private var buffer = Data()
    var onStdout: ((Data) -> Void)?
    var onStderr: ((Data) -> Void)?
    var onExit: ((Int) -> Void)?

    func append(_ data: Data) {
        buffer.append(data)
        parse()
    }

    private func parse() {
        while buffer.count >= 8 {
            let idRaw = buffer.readUInt32(at: 0)
            let length = Int(buffer.readUInt32(at: 4))
            guard length <= 1 << 22 else { buffer.removeAll(); return } // 异常长度保护
            guard buffer.count >= 8 + length else { break }
            let payload = buffer.subdata(in: 8..<(8 + length))
            buffer.removeFirst(8 + length)
            switch idRaw {
            case Id.stdout.rawValue:
                onStdout?(payload)
            case Id.stderr.rawValue:
                onStderr?(payload)
            case Id.exit.rawValue:
                let code = payload.count >= 4 ? Int(payload.readUInt32(at: 0)) : -1
                onExit?(code)
            default:
                break
            }
        }
    }
}

/// Shell 通道封装：交互式终端 + 单次命令执行
final class AdbShell {
    private let client: AdbClient
    var onLog: ((String) -> Void)?

    init(client: AdbClient) {
        self.client = client
    }

    /// 一次性执行命令（shell,v2,raw），返回 stdout 字符串与退出码
    func execute(command: String,
                 timeout: TimeInterval = 30,
                 completion: @escaping (Result<(output: String, exitCode: Int), Error>) -> Void) {
        let service = "shell,v2,raw:\(command)"
        var stdoutData = Data()
        var stderrData = Data()
        var channelID: UInt32?

        let parser = ShellV2Parser()
        parser.onStdout = { stdoutData.append($0) }
        parser.onStderr = { stderrData.append($0) }
        var didFinish = false

        func finish(_ result: Result<(String, Int), Error>) {
            guard !didFinish else { return }
            didFinish = true
            if let id = channelID { client.close(channel: id) }
            completion(result)
        }

        channelID = client.open(service: service, onData: { data in
            parser.append(data)
        }, onClose: {
            // 通道被远端关闭
            finish(.success((String(data: stdoutData, encoding: .utf8) ?? "",
                             stderrData.isEmpty ? 0 : -1)))
        })
        parser.onExit = { code in
            onLog?("命令退出码: \(code)")
            finish(.success((String(data: stdoutData, encoding: .utf8) ?? "", code)))
        }

        // 超时保护
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            finish(.failure(AdbError.timeout))
        }
    }

    /// 打开交互式 shell 通道
    /// - Returns: 通道 ID
    @discardableResult
    func openInteractive(onStdout: @escaping (String) -> Void,
                         onExit: @escaping (Int) -> Void) -> UInt32? {
        let service = "shell:v2"
        let parser = ShellV2Parser()
        parser.onStdout = { data in
            if let text = String(data: data, encoding: .utf8) {
                onStdout(text)
            }
        }
        parser.onExit = onExit
        return client.open(service: service, onData: { data in
            parser.append(data)
        })
    }

    /// 向交互式终端写入命令
    func writeToInteractive(channelID: UInt32, text: String) {
        client.write(toChannel: channelID, data: Data((text + "\n").utf8))
    }
}
