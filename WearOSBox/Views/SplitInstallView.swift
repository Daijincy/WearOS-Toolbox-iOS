import SwiftUI
import UniformTypeIdentifiers

/// 安装 Split APK（base + 拆分包）
struct SplitInstallView: View {
    @StateObject private var session = AdbSessionManager.shared
    @State private var showFilePicker = false
    @State private var selectedURLs: [URL] = []
    @State private var isInstalling = false
    @State private var resultText: String?
    @State private var progressText = ""

    var body: some View {
        Form {
            Section {
                Button {
                    showFilePicker = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text("选择 Split APK 文件")
                            Text("可多选 base + 多个拆分包")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }

            if !selectedURLs.isEmpty {
                Section("已选择 \(selectedURLs.count) 个文件") {
                    ForEach(selectedURLs, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "doc")
                            .font(.caption)
                    }
                    Button("开始安装") {
                        install()
                    }
                    .disabled(isInstalling || session.ops == nil)
                }
            }

            if isInstalling {
                Section {
                    Text(progressText)
                } header: {
                    Text("安装进度")
                }
            }

            if let result = resultText {
                Section("安装结果") {
                    Text(result)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("安装 Split APK")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                selectedURLs = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
            case .failure(let err):
                resultText = "选择文件失败：\(err.localizedDescription)"
            }
        }
    }

    private func install() {
        guard let ops = session.ops else { return }
        isInstalling = true
        resultText = nil
        progressText = "正在推送 \(selectedURLs.count) 个文件到设备…"
        // 保持安全作用域访问
        let accessed = selectedURLs.map { $0.startAccessingSecurityScopedResource() }
        ops.installSplitAPK(apkURLs: selectedURLs) { [weak self] result in
            selectedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                self?.isInstalling = false
                switch result {
                case .success(let out):
                    self?.resultText = "安装成功\n\n\(out)"
                case .failure(let err):
                    self?.resultText = "安装失败：\(err.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    NavigationStack { SplitInstallView() }
}
