import Foundation
import Network
import CoreMedia
import VideoToolbox
import UIKit

/// scrcpy 实时镜像客户端
/// 通过 ADB shell 在设备端启动 scrcpy server（TCP 模式），iOS 直连视频端口
/// 协议参考 scrcpy v2.x（https://github.com/Genymobile/scrcpy）
/// 视频流：H.264（MediaCodec 输出 AVCC 格式）+ 控制消息复用同一 socket
final class ScrcpyClient: ObservableObject, @unchecked Sendable {
    enum ScrcpyError: LocalizedError {
        case serverNotRunning(String)
        case connectionFailed(String)
        case decodeFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .serverNotRunning(let msg): return "设备端 scrcpy 服务异常：\(msg)"
            case .connectionFailed(let msg): return "镜像连接失败：\(msg)"
            case .decodeFailed(let msg): return "视频解码失败：\(msg)"
            case .timeout: return "镜像连接超时"
            }
        }
    }

    // 状态
    @Published private(set) var isRunning = false
    @Published private(set) var frameImage: UIImage?
    @Published private(set) var deviceSize = CGSize.zero

    var onLog: ((String) -> Void)?

    private var videoConnection: NWConnection?
    private var receiveBuffer = Data()
    private var decodeSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sessionQueue = DispatchQueue(label: "scrcpy.decode.queue")

    // 会话参数
    private let videoPort: UInt16 = 27183
    private var adbClient: AdbClient?
    private var serverVersion = "2.7"

    // MARK: - 启动

    /// 启动 scrcpy 镜像
    /// - Parameters:
    ///   - adb: 当前 ADB 客户端（用于 shell 启动 server）
    ///   - host: 设备 IP
    ///   - fps: 帧率
    ///   - bitRate: 码率（bps）
    ///   - maxSize: 最大尺寸（宽或高，0 表示不限制）
    func start(adb: AdbClient, host: String, fps: Int = 30,
               bitRate: Int = 2_000_000, maxSize: Int = 0,
               completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isRunning else { return }
        adbClient = adb
        let shell = AdbShell(client: adb)
        shell.onLog = onLog

        // 1. 检查 scrcpy server jar 是否存在
        shell.execute(command: "ls -la /data/local/tmp/scrcpy-server.jar 2>/dev/null; echo EXITCODE:$?") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let check):
                guard check.output.contains("scrcpy-server.jar") else {
                    completion(.failure(ScrcpyError.serverNotRunning("设备上未找到 scrcpy-server.jar，请先通过文件管理推送 scrcpy-server.jar 到 /data/local/tmp/")))
                    return
                }
                self.launchServer(shell: shell, fps: fps, bitRate: bitRate, maxSize: maxSize, host: host, completion: completion)
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    private func launchServer(shell: AdbShell, fps: Int, bitRate: Int, maxSize: Int,
                              host: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // 2. 通过 app_process 启动 scrcpy server（TCP 视频端口模式）
        var args = "--video-codec=h264 --video-source=display --audio=false --video-port=\(videoPort)"
        args += " --max-fps=\(fps) --video-bit-rate=\(bitRate)"
        if maxSize > 0 {
            args += " --max-size=\(maxSize)"
        }
        let cmd = "app_process / com.genymobile.scrcpy.Server \(serverVersion) \(args) >/dev/null 2>&1 &"
        onLog?("启动 scrcpy server: \(cmd)")
        shell.execute(command: cmd, timeout: 5) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                // 3. 稍等 server 启动，然后连接视频端口
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                    self.connectVideoStream(host: host, completion: completion)
                }
            case .failure(let err):
                completion(.failure(err))
            }
        }
    }

    // MARK: - 视频连接

    private func connectVideoStream(host: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: videoPort)!)
        let params = NWParameters.tcp
        let conn = NWConnection(to: endpoint, using: params)
        videoConnection = conn
        receiveBuffer.removeAll()

        var didFinish = false
        func finish(_ result: Result<Void, Error>) {
            guard !didFinish else { return }
            didFinish = true
            completion(result)
        }

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.onLog?("视频端口已连接 \(host):\(videoPort)")
                // 发送 dummy 字节（scrcpy 握手）
                conn.send(content: Data([0x00]), completion: .contentProcessed { _ in })
                self.isRunning = true
                self.receiveVideo()
                finish(.success(()))
            case .failed(let err):
                self.isRunning = false
                finish(.failure(ScrcpyError.connectionFailed(err.localizedDescription)))
            case .cancelled:
                self.isRunning = false
            default:
                break
            }
        }

        conn.start(queue: sessionQueue)
        sessionQueue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self else { return }
            if !self.isRunning {
                finish(.failure(ScrcpyError.timeout))
            }
        }
    }

    private func receiveVideo() {
        videoConnection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processVideoBuffer()
            }
            if isComplete || error != nil {
                self.stop()
                return
            }
            self.receiveVideo()
        }
    }

    /// 解析 scrcpy v2 消息：4字节长度 + 4字节类型 + payload
    private func processVideoBuffer() {
        while true {
            guard receiveBuffer.count >= 8 else { return }
            let length = Int(receiveBuffer.readUInt32(at: 0))
            guard length <= 1 << 26 else { receiveBuffer.removeAll(); return } // 异常保护
            guard receiveBuffer.count >= 8 + length else { return }
            let type = receiveBuffer.readUInt32(at: 4)
            let payload = receiveBuffer.subdata(in: 8..<(8 + length))
            receiveBuffer.removeFirst(8 + length)

            if type == 1 {
                // DeviceInfo JSON
                let json = String(data: payload, encoding: .utf8) ?? ""
                onLog?("scrcpy 设备信息: \(json)")
                parseDeviceInfo(json)
            } else if type == 2 {
                // 视频包：4字节flags(1=config, 2=frame) + H.264数据
                guard payload.count >= 4 else { continue }
                let flags = payload.readUInt32(at: 0)
                let videoData = payload.subdata(in: 4..<payload.count)
                if flags == 1 {
                    // codec 配置（含 SPS/PPS）
                    setupCodecConfig(videoData)
                } else if flags == 2 {
                    decodeFrame(videoData)
                }
            }
            // type 0: 无操作
        }
    }

    private func parseDeviceInfo(_ json: String) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let w = (dict["width"] as? Int) ?? 0
        let h = (dict["height"] as? Int) ?? 0
        if w > 0, h > 0 {
            deviceSize = CGSize(width: w, height: h)
        }
    }

    // MARK: - H.264 解码

    /// 从 AVCDecoderConfigurationRecord 提取 SPS/PPS 并创建 FormatDescription
    private func setupCodecConfig(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count > 7, bytes[0] == 0x01 else {
            onLog?("非 AVCC 配置格式")
            return
        }
        // 解析 AVCDecoderConfigurationRecord
        var spsList: [Data] = []
        var ppsList: [Data] = []
        let numSPS = Int(bytes[5] & 0x1F)
        var offset = 6
        for _ in 0..<numSPS {
            guard offset + 2 <= bytes.count else { return }
            let len = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
            guard offset + len <= bytes.count else { return }
            spsList.append(Data(bytes[offset..<(offset + len)]))
            offset += len
        }
        guard offset + 1 <= bytes.count else { return }
        let numPPS = Int(bytes[offset])
        offset += 1
        for _ in 0..<numPPS {
            guard offset + 2 <= bytes.count else { return }
            let len = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
            guard offset + len <= bytes.count else { return }
            ppsList.append(Data(bytes[offset..<(offset + len)]))
            offset += len
        }
        guard let sps = spsList.first, let pps = ppsList.first else {
            onLog?("SPS/PPS 缺失")
            return
        }

        var fd: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                var pointers = [spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &fd)
            }
        }
        guard status == noErr, let fd = fd else {
            onLog?("FormatDescription 创建失败: \(status)")
            return
        }
        formatDescription = fd
        createDecodeSession()
    }

    private func createDecodeSession() {
        guard let fd = formatDescription else { return }
        var session: VTDecompressionSession?
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                guard let refCon = refCon, status == noErr, let imageBuffer = imageBuffer else { return }
                let client = Unmanaged<ScrcpyClient>.fromOpaque(refCon).takeUnretainedValue()
                client.renderFrame(imageBuffer)
            },
            decompressionOutputRefCon: refCon)
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fd,
            decoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferOpenGLCompatibilityKey: true
            ] as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session)
        guard status == noErr, let session = session else {
            onLog?("解码会话创建失败: \(status)")
            return
        }
        decodeSession = session
    }

    /// 解码一帧（AVCC 长度前缀格式）
    private func decodeFrame(_ data: Data) {
        guard let fd = formatDescription, let session = decodeSession else {
            return
        }
        // 构造 CMBlockBuffer + CMSampleBuffer
        var blockBuffer: CMBlockBuffer?
        let status = data.withUnsafeBytes { ptr in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: ptr.baseAddress!),
                blockLength: data.count,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: data.count,
                flags: 0,
                blockBufferOut: &blockBuffer)
        }
        guard status == kCMBlockBufferNoErr, let blockBuffer = blockBuffer else { return }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: 0, timescale: 30),
            decodeTimeStamp: .invalid)
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: fd,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [data.count],
            sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else { return }

        let decodeStatus = VTDecompressionSessionDecodeFrame(session,
                                                             sampleBuffer: sampleBuffer,
                                                             flags: [],
                                                             infoFlagsOut: nil) { [weak self] _, _, imageBuffer, _, _ in
            guard let self = self, let imageBuffer = imageBuffer else { return }
            self.renderFrame(imageBuffer)
        }
        if decodeStatus != noErr {
            onLog?("解码失败: \(decodeStatus)")
        }
    }

    /// 渲染解码帧为 UIImage（主线程发布）
    private func renderFrame(_ imageBuffer: CVImageBuffer) {
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        DispatchQueue.main.async { [weak self] in
            self?.frameImage = image
        }
    }

    // MARK: - 控制指令

    /// 注入触摸事件（坐标 0-1 归一化，与屏幕比例对应）
    enum TouchAction: UInt8 {
        case down = 0
        case up = 1
        case move = 2
        case cancel = 3
    }

    func injectTouch(action: TouchAction, x: Float, y: Float, pointerId: UInt64 = 0) {
        guard isRunning, let conn = videoConnection else { return }
        var msg = Data()
        msg.append(0x03) // inject_touch
        msg.append(action.rawValue)
        msg.appendUInt64(pointerId)
        msg.appendUInt32(x.bitPattern)
        msg.appendUInt32(y.bitPattern)
        msg.appendUInt16(0xFFFF) // pressure max
        msg.appendUInt32(0)      // actionButton
        msg.appendUInt32(0)      // buttons
        conn.send(content: msg, completion: .contentProcessed { _ in })
    }

    /// 注入按键
    enum AndroidKeycode: Int32 {
        case home = 3
        case back = 4
        case power = 26
        case volumeUp = 24
        case volumeDown = 25
    }

    func injectKeycode(_ keycode: AndroidKeycode, action: UInt8 = 0) {
        guard isRunning, let conn = videoConnection else { return }
        var msg = Data()
        msg.append(0x01) // inject_keycode
        msg.append(action)
        msg.appendUInt32(UInt32(bitPattern: keycode.rawValue))
        msg.appendUInt32(0) // repeat
        msg.appendUInt32(0) // metaState
        conn.send(content: msg, completion: .contentProcessed { _ in })
    }

    /// 返回或点亮屏幕
    func backOrScreenOn() {
        guard isRunning, let conn = videoConnection else { return }
        conn.send(content: Data([0x05]), completion: .contentProcessed { _ in })
    }

    // MARK: - 停止

    func stop() {
        isRunning = false
        videoConnection?.cancel()
        videoConnection = nil
        receiveBuffer.removeAll()
        decodeSession = nil
        formatDescription = nil
        // 通知设备端停止 server
        if let adb = adbClient {
            let shell = AdbShell(client: adb)
            shell.execute(command: "killall scrcpy 2>/dev/null; pkill -f genymobile.scrcpy 2>/dev/null", timeout: 3) { _ in }
        }
    }
}

extension Data {
    mutating func appendUInt64(_ value: UInt64) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
