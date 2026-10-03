import SwiftUI

/// 剪切板同步
struct ClipboardView: View {
    @StateObject private var session = AdbSessionManager.shared
    @State private var watchText = ""
    @State private var inputText = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section("手表剪贴板") {
                Button {
                    readWatch()
                } label: {
                    Label("读取手表剪贴板", systemImage: "arrow.down.doc")
                }
                if !watchText.isEmpty {
                    Text(watchText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Button("复制到 iPhone") {
                        UIPasteboard.general.string = watchText
                        message = "已复制到 iPhone 剪贴板"
                    }
                    .font(.caption)
                }
            }

            Section("写入手表") {
                TextField("输入要推送到手表的文字…", text: $inputText, axis: .vertical)
                    .lineLimit(3...6)
                Button {
                    writeWatch()
                } label: {
                    Label("推送到手表", systemImage: "arrow.up.doc")
                }
                .disabled(inputText.isEmpty)
            }

            if let msg = message {
                Section {
                    Text(msg).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("剪切板")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func readWatch() {
        guard let ops = session.ops else { return }
        ops.getClipboard { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    self?.watchText = text
                    self?.message = text.isEmpty ? "手表剪贴板为空" : "读取成功"
                case .failure(let err):
                    self?.message = "读取失败：\(err.localizedDescription)"
                }
            }
        }
    }

    private func writeWatch() {
        guard let ops = session.ops, !inputText.isEmpty else { return }
        ops.setClipboard(inputText) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.message = "已推送到手表"
                case .failure(let err):
                    self?.message = "写入失败：\(err.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    NavigationStack { ClipboardView() }
}
