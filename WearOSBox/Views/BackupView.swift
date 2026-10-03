import SwiftUI

/// 备份和恢复（应用数据）
/// 说明：Android 13+ 已弃用 adb backup，本页提供 pm 备份思路与说明
struct BackupView: View {
    @StateObject private var session = AdbSessionManager.shared
    @State private var packages: [(package: String, version: String)] = []
    @State private var selectedPackages: Set<String> = []
    @State private var isLoading = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Text("备份应用数据需要设备具备 root 权限或使用 adb backup（Android 12 以下）。WearOS 设备通常无法直接备份系统级数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("选择要备份的应用") {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if packages.isEmpty {
                    Text("点击加载应用列表")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(packages, id: \.package) { item in
                        Toggle(isOn: Binding(
                            get: { selectedPackages.contains(item.package) },
                            set: { on in
                                if on {
                                    selectedPackages.insert(item.package)
                                } else {
                                    selectedPackages.remove(item.package)
                                }
                            }
                        )) {
                            Text(item.package)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }

            Section {
                Button("加载应用列表", systemImage: "arrow.clockwise") {
                    loadPackages()
                }
                Button("备份所选应用数据") {
                    backupSelected()
                }
                .disabled(selectedPackages.isEmpty)
            }

            if let msg = message {
                Section("结果") {
                    Text(msg)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("备份和恢复")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadPackages() {
        guard let ops = session.ops else { return }
        isLoading = true
        ops.listPackages { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let list):
                    self.packages = list
                case .failure(let err):
                    self.message = err.localizedDescription
                }
            }
        }
    }

    private func backupSelected() {
        guard let ops = session.ops else { return }
        let list = selectedPackages.sorted().joined(separator: " ")
        let cmd = "pm backup -apk -shared \(list)"
        let shell = AdbShell(client: session.client!)
        shell.execute(command: cmd, timeout: 60) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let out):
                    self.message = "备份命令已执行\n\(out.output)"
                case .failure(let err):
                    self.message = "备份失败：\(err.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    NavigationStack { BackupView() }
}
