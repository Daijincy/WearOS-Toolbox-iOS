import SwiftUI

/// 单次命令行（一次性执行命令，返回完整结果）
struct CommandView: View {
    @StateObject private var session = AdbSessionManager.shared
    @State private var commandText = ""
    @State private var resultText = ""
    @State private var isRunning = false
    @State private var history: [String] = []
    @State private var exitCode: Int?

    var body: some View {
        Form {
            Section("命令") {
                TextField("输入单条命令（如 settings get secure …）", text: $commandText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button {
                    execute()
                } label: {
                    HStack {
                        Spacer()
                        if isRunning {
                            ProgressView()
                        } else {
                            Text("执行")
                        }
                        Spacer()
                    }
                }
                .disabled(commandText.trimmingCharacters(in: .whitespaces).isEmpty || isRunning)
            }
            if !history.isEmpty {
                Section("历史命令") {
                    ForEach(history.reversed(), id: \.self) { cmd in
                        Button(cmd) {
                            commandText = cmd
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                }
            }
            if !resultText.isEmpty {
                Section {
                    Text(resultText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    if let code = exitCode {
                        Text("输出（退出码 \(code)）")
                    } else {
                        Text("输出")
                    }
                }
            }
        }
        .navigationTitle("命令行")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func execute() {
        let cmd = commandText.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, let ops = session.ops else { return }
        isRunning = true
        resultText = ""
        exitCode = nil
        history.append(cmd)

        let shell = AdbShell(client: session.client!)
        shell.execute(command: cmd) { result in
            DispatchQueue.main.async {
                self.isRunning = false
                switch result {
                case .success(let out):
                    self.resultText = out.output.isEmpty ? "(无输出)" : out.output
                    self.exitCode = out.exitCode
                case .failure(let err):
                    self.resultText = "[错误] \(err.localizedDescription)"
                    self.exitCode = -1
                }
            }
        }
    }
}

#Preview {
    NavigationStack { CommandView() }
}
