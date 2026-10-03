import SwiftUI
import SwiftData

/// 首页：设备配对档案管理 + ADB 连接
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DeviceProfile.createdAt, order: .reverse) private var profiles: [DeviceProfile]

    @StateObject private var session = AdbSessionManager.shared
    @StateObject private var scanner = DeviceScanner()

    @State private var selectedProfile: DeviceProfile?
    @State private var ipText = ""
    @State private var portText = ""
    @State private var showPairSheet = false
    @State private var showScannerSheet = false
    @State private var errorMessage: String?
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            List {
                // 已配对设备
                Section {
                    if profiles.isEmpty {
                        Text("暂无配对设备，点击右上角「添加」开始配对")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(profiles) { profile in
                            deviceRow(profile)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    select(profile)
                                }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let profile = profiles[index]
                                if selectedProfile?.persistentModelID == profile.persistentModelID {
                                    selectedProfile = nil
                                    ipText = ""
                                    portText = ""
                                }
                                modelContext.delete(profile)
                            }
                            try? modelContext.save()
                        }
                    }
                } header: {
                    Text("已配对设备")
                } footer: {
                    Text("选中档案后自动回填 IP/端口，可直接修改后连接（无需再次输入配对码）")
                }

                // 连接区域
                Section("连接设备") {
                    HStack {
                        Text("IP 地址")
                        TextField("请输入手表 IP 地址", text: $ipText)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("端口号")
                        TextField("请输入无线调试端口", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    connectButton

                    if session.state != .idle {
                        HStack(spacing: 12) {
                            if case .pairing = session.state {
                                ProgressView().controlSize(.small)
                                Text("配对中…")
                            } else if case .connecting = session.state {
                                ProgressView().controlSize(.small)
                                Text("连接中…")
                            } else if case .connected = session.state {
                                Label("已连接", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if case .failed(let msg) = session.state {
                                Label(msg, systemImage: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .lineLimit(3)
                            }
                        }
                        .font(.footnote)
                    }
                }
            }
            .navigationTitle("WearOS 工具箱")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showScannerSheet = true
                    } label: {
                        Label("扫描", systemImage: "wifi")
                    }
                    Button {
                        showPairSheet = true
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showPairSheet) {
                PairSheetView(initialIP: ipText, initialPort: portText) { name, ip, port, code in
                    addProfile(name: name, ip: ip, port: port, code: code)
                }
            }
            .sheet(isPresented: $showScannerSheet) {
                ScannerSheetView(scanner: scanner) { ip, port in
                    showPairSheet = true
                    ipText = ip
                    portText = String(port)
                }
            }
            .alert("提示", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .navigationDestination(isPresented: Binding(
                get: { session.isConnected && navPath.isEmpty },
                set: { if $0 { navPath.append("main") } }
            )) {
                if session.isConnected {
                    MainGridView()
                }
            }
            .onAppear {
                scanner.onLog = { AppLogger.shared.log($0, level: .adb) }
            }
        }
    }

    // MARK: - 子视图

    private func deviceRow(_ profile: DeviceProfile) -> some View {
        HStack {
            Image(systemName: "applewatch")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.body)
                Text("\(profile.pairIP):\(profile.pairPort)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = profile.lastConnectedAt {
                    Text("最近连接：\(last.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if selectedProfile?.persistentModelID == profile.persistentModelID {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
    }

    private var connectButton: some View {
        Button {
            connect()
        } label: {
            HStack {
                Spacer()
                Text("连接")
                Spacer()
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isInputValid || session.state == .pairing || session.state == .connecting)
    }

    // MARK: - 逻辑

    private var isInputValid: Bool {
        !ipText.trimmingCharacters(in: .whitespaces).isEmpty &&
        !portText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func select(_ profile: DeviceProfile) {
        selectedProfile = profile
        ipText = profile.pairIP
        portText = String(profile.pairPort)
    }

    private func connect() {
        guard let profile = selectedProfile else {
            errorMessage = "请先选择或添加一个配对设备"
            return
        }
        guard Validators.isValidIPv4(ipText) else {
            errorMessage = "IP 地址格式不正确"
            return
        }
        guard Validators.isValidPort(portText) else {
            errorMessage = "端口号必须在 1~65535 之间"
            return
        }
        let ip = ipText.trimmingCharacters(in: .whitespaces)
        let port = Int(portText.trimmingCharacters(in: .whitespaces)) ?? 0
        session.connect(profile: profile, ip: ip, port: port) { result in
            switch result {
            case .success:
                break // 已连接，触发导航
            case .failure(let err):
                self.errorMessage = err.localizedDescription
            }
        }
    }

    private func addProfile(name: String, ip: String, port: Int, code: String) {
        let profile = DeviceProfile(name: name, pairIP: ip, pairPort: port)
        modelContext.insert(profile)
        try? modelContext.save()

        session.pair(profile: profile, code: code) { result in
            switch result {
            case .success:
                self.selectedProfile = profile
                self.ipText = ip
                self.portText = String(port)
            case .failure(let err):
                self.errorMessage = "配对失败：\(err.localizedDescription)"
                // 配对失败则移除档案
                self.modelContext.delete(profile)
                try? self.modelContext.save()
            }
        }
    }
}

#Preview {
    RootView()
}
