import SwiftUI

/// 远程屏幕：双模式
/// 模式A：静态截图（adb screencap）
/// 模式B：scrcpy 实时镜像（H.264 硬解码 + 触控/按键控制）
struct ScreenView: View {
    @StateObject private var session = AdbSessionManager.shared
    @StateObject private var scrcpy = ScrcpyClient()

    enum MirrorMode: String, CaseIterable {
        case snapshot = "静态截图"
        case mirror = "实时镜像"
    }

    @State private var mode: MirrorMode = .snapshot
    @State private var snapshotImage: UIImage?
    @State private var isCapturing = false
    @State private var statusText = "镜像已停止"
    @State private var fps = 30.0
    @State private var bitRate = 2.0 // Mbps
    @State private var showParams = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            // 模式切换
            Picker("模式", selection: $mode) {
                ForEach(MirrorMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            // 画面区
            contentArea

            Divider()

            // 控制区
            controlBar
        }
        .navigationTitle("远程屏幕")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .onDisappear {
            scrcpy.stop()
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .snapshot {
                scrcpy.stop()
                statusText = "镜像已停止"
            }
        }
    }

    // MARK: - 画面区域

    @ViewBuilder
    private var contentArea: some View {
        Group {
            switch mode {
            case .snapshot:
                snapshotArea
            case .mirror:
                mirrorArea
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }

    private var snapshotArea: some View {
        VStack {
            if let image = snapshotImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding()
                HStack(spacing: 16) {
                    Button("保存到相册") {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        message = "已保存到相册"
                    }
                    .buttonStyle(.bordered)
                    Button("重新截图", systemImage: "arrow.clockwise") {
                        captureSnapshot()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                ContentUnavailableView("暂无截图",
                    systemImage: "camera.viewfinder",
                    description: Text("点击下方「获取截图」抓取手表当前画面"))
            }
        }
    }

    private var mirrorArea: some View {
        ZStack {
            if let frame = scrcpy.frameImage {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .gesture(mirrorGesture)
            } else {
                ProgressView("等待视频流…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
            VStack {
                HStack {
                    Spacer()
                    Text(statusText)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
            }
            .padding(8)
        }
    }

    /// scrcpy 触控手势（归一化坐标）
    private var mirrorGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard scrcpy.isRunning else { return }
                let w = value.size.width > 0 ? value.size.width : 1
                let h = value.size.height > 0 ? value.size.height : 1
                let x = Float(value.location.x / w)
                let y = Float(value.location.y / h)
                scrcpy.injectTouch(action: .move, x: min(max(x, 0), 1), y: min(max(y, 0), 1))
            }
            .onEnded { _ in
                scrcpy.injectTouch(action: .up, x: 0.5, y: 0.5)
            }
    }

    // MARK: - 控制栏

    private var controlBar: some View {
        VStack(spacing: 8) {
            if mode == .snapshot {
                Button {
                    captureSnapshot()
                } label: {
                    Label("获取截图", systemImage: "camera.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCapturing)
            } else {
                HStack(spacing: 12) {
                    Button("主页", systemImage: "house.fill") {
                        scrcpy.injectKeycode(.home)
                    }
                    Button("返回", systemImage: "chevron.left") {
                        scrcpy.injectKeycode(.back)
                    }
                    Button("电源", systemImage: "power") {
                        scrcpy.injectKeycode(.power)
                    }
                    Button("音量-", systemImage: "speaker.fill") {
                        scrcpy.injectKeycode(.volumeDown)
                    }
                    Button("音量+", systemImage: "speaker.wave.2.fill") {
                        scrcpy.injectKeycode(.volumeUp)
                    }
                }
                .buttonStyle(.bordered)
                HStack(spacing: 12) {
                    Button {
                        toggleMirror()
                    } label: {
                        Label(scrcpy.isRunning ? "停止镜像" : "开始镜像",
                              systemImage: scrcpy.isRunning ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(scrcpy.isRunning ? .red : .green)

                    Button("参数", systemImage: "slider.horizontal.3") {
                        withAnimation { showParams.toggle() }
                    }
                    .buttonStyle(.bordered)
                }
                if showParams {
                    VStack(spacing: 10) {
                        HStack {
                            Text("帧率")
                            Spacer()
                            Text("\(Int(fps)) FPS")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $fps, in: 5...60, step: 1)
                        HStack {
                            Text("码率")
                            Spacer()
                            Text(String(format: "%.1f Mbps", bitRate))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $bitRate, in: 0.5...10, step: 0.5)
                    }
                    .font(.caption)
                    .padding(.horizontal)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - 动作

    private func captureSnapshot() {
        guard let ops = session.ops else {
            message = "未连接设备"
            return
        }
        isCapturing = true
        statusText = "截图中…"
        ops.screencap { result in
            DispatchQueue.main.async {
                self.isCapturing = false
                switch result {
                case .success(let data):
                    if let image = UIImage(data: data) {
                        self.snapshotImage = image
                        self.statusText = "截图完成"
                    } else {
                        self.message = "截图数据解析失败"
                        self.statusText = "截图失败"
                    }
                case .failure(let err):
                    self.message = err.localizedDescription
                    self.statusText = "截图失败"
                }
            }
        }
    }

    private func toggleMirror() {
        guard let client = session.client, let host = session.currentTarget?.ip else {
            message = "未连接设备"
            return
        }
        if scrcpy.isRunning {
            scrcpy.stop()
            statusText = "镜像已停止"
        } else {
            scrcpy.onLog = { AppLogger.shared.log($0, level: .adb) }
            statusText = "镜像启动中…"
            scrcpy.start(adb: client, host: host,
                         fps: Int(fps), bitRate: Int(bitRate * 1_000_000)) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self.statusText = "镜像运行中"
                    case .failure(let err):
                        self.statusText = "镜像已停止"
                        self.message = err.localizedDescription
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack { ScreenView() }
}
