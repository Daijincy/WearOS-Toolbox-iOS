import SwiftUI
import UniformTypeIdentifiers

/// 安装 APK
struct InstallView: View {
    @StateObject private var session = AdbSessionManager.shared
    @State private var showFilePicker = false
    @State private var isInstalling = false
    @State private var progress: Double = 0
    @State private var resultText: String?
    @State private var showResult = false

    var body: some View {
        Form {
            Section {
                Button {
                    showFilePicker = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.down.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text("选择 APK 文件")
                            Text("支持普通单包 APK")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            } footer: {
                Text("将 APK 推送到设备并执行 pm install 安装")
            }

            if isInstalling {
                Section("安装进度") {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let result = resultText {
                Section {
                    Text(result)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("安装结果")
                }
            }
        }
        .navigationTitle("安装 APK")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first, let ops = session.ops else { return }
                install(url: url, ops: ops)
            case .failure(let err):
                resultText = "选择文件失败：\(err.localizedDescription)"
            }
        }
    }

    private func install(url: URL, ops: AdbOps) {
        isInstalling = true
        progress = 0
        resultText = nil
        let accessing = url.startAccessingSecurityScopedResource()
        ops.installAPK(apkURL: url, progress: { p in
            DispatchQueue.main.async { self.progress = p }
        }) { result in
            if accessing { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                self.isInstalling = false
                switch result {
                case .success(let out):
                    self.resultText = "安装成功\n\n\(out)"
                case .failure(let err):
                    self.resultText = "安装失败：\(err.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    NavigationStack { InstallView() }
}
