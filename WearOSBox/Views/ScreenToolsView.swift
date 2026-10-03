import SwiftUI

/// 屏幕工具（分辨率 / DPI 修改）
struct ScreenToolsView: View {
    @StateObject private var session = AdbSessionManager.shared
    @State private var currentSize = ""
    @State private var currentDensity = ""
    @State private var newSize = ""
    @State private var newDensity = ""
    @State private var isLoading = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("当前状态") {
                LabeledContent("分辨率", value: currentSize.isEmpty ? "读取中…" : currentSize)
                LabeledContent("DPI", value: currentDensity.isEmpty ? "读取中…" : currentDensity)
            }

            Section("修改分辨率") {
                TextField("新分辨率（如 466x466），留空恢复默认", text: $newSize)
                    .keyboardType(.numbersAndPunctuation)
                Button("应用分辨率") {
                    applySize()
                }
                .disabled(newSize.isEmpty)
            }

            Section("修改 DPI") {
                TextField("新 DPI（如 320），留空恢复默认", text: $newDensity)
                    .keyboardType(.numberPad)
                Button("应用 DPI") {
                    applyDensity()
                }
                .disabled(newDensity.isEmpty)
            }

            Section("恢复默认") {
                Button("恢复默认分辨率和 DPI", role: .destructive) {
                    restoreDefaults()
                }
            }

            if let msg = message {
                Section {
                    Text(msg)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("结果")
                }
            }
        }
        .navigationTitle("屏幕工具")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .disabled(isLoading)
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
    }

    private func load() {
        guard let ops = session.ops else { return }
        isLoading = true
        ops.screenInfo { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let info):
                    self.currentSize = info.size
                    self.currentDensity = info.density
                case .failure(let err):
                    self.message = err.localizedDescription
                }
            }
        }
    }

    private func applySize() {
        guard let ops = session.ops else { return }
        isLoading = true
        ops.setScreenSize(newSize.trimmingCharacters(in: .whitespaces)) { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let out): self.message = "分辨率设置完成：\(out)"
                case .failure(let err): self.message = err.localizedDescription
                }
            }
        }
    }

    private func applyDensity() {
        guard let ops = session.ops else { return }
        isLoading = true
        ops.setScreenDensity(newDensity.trimmingCharacters(in: .whitespaces)) { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let out): self.message = "DPI 设置完成：\(out)"
                case .failure(let err): self.message = err.localizedDescription
                }
            }
        }
    }

    private func restoreDefaults() {
        guard let ops = session.ops else { return }
        isLoading = true
        ops.setScreenSize(nil) { sizeResult in
            ops.setScreenDensity(nil) { densityResult in
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.message = "已恢复默认设置"
                }
            }
        }
    }
}

#Preview {
    NavigationStack { ScreenToolsView() }
}
