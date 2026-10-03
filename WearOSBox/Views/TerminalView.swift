import SwiftUI

/// 交互式终端（shell:v2）
struct TerminalView: View {
    @StateObject private var session = AdbSessionManager.shared
    @State private var outputText = ""
    @State private var inputText = ""
    @State private var history: [String] = []
    @State private var channelID: UInt32?
    @State private var isActive = false
    @State private var showCopied = false

    var body: some View {
        VStack(spacing: 0) {
            // 输出区域
            ScrollViewReader { proxy in
                ScrollView {
                    Text(outputText.isEmpty ? "// 终端已就绪，输入命令开始执行" : outputText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("bottom")
                }
                .background(.background.secondary)
                .onChange(of: outputText) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            Divider()
            // 输入区域
            HStack(spacing: 8) {
                TextField("输入命令…", text: $inputText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .submitLabel(.send)
                    .onSubmit { sendCommand() }
                Button("发送", systemImage: "paperplane.fill") {
                    sendCommand()
                }
                .labelStyle(.iconOnly)
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .background(.bar)
        }
        .navigationTitle("终端")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("清屏", systemImage: "trash") {
                    outputText = ""
                }
                Menu {
                    ForEach(Self.presetCommands, id: \.self) { cmd in
                        Button(cmd) {
                            inputText = cmd
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
            }
        }
        .onAppear {
            startTerminal()
        }
        .onDisappear {
            if let id = channelID {
                session.client?.close(channel: id)
            }
            channelID = nil
        }
    }

    /// 预设常用命令（含此前配置通知监听的命令）
    private static let presetCommands: [String] = [
        "settings get secure enabled_notification_listeners",
        "settings get global adb_enabled",
        "pm list packages | head -20",
        "df -h",
        "top -n 1 | head -15",
        "dumpsys battery | head -20",
        "getprop ro.build.version.release",
        "ls -la /sdcard",
    ]

    private func startTerminal() {
        guard let client = session.client, !isActive else { return }
        isActive = true
        appendOutput("> 打开交互式终端…")
        let id = AdbShell(client: client).openInteractive { [weak self] text in
            self?.appendOutput(text)
        } onExit: { [weak self] code in
            self?.appendOutput("\n[进程退出，退出码 \(code)]")
            self?.isActive = false
        }
        channelID = id
        if id == nil {
            appendOutput("[错误] 无法打开终端通道")
        }
    }

    private func sendCommand() {
        let cmd = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        history.append(cmd)
        guard let client = session.client, let channelID = channelID else {
            appendOutput("[错误] 未连接设备")
            return
        }
        appendOutput("$ \(cmd)")
        let shell = AdbShell(client: client)
        shell.writeToInteractive(channelID: channelID, text: cmd)
        inputText = ""
    }

    private func appendOutput(_ text: String) {
        if outputText.isEmpty {
            outputText = text
        } else {
            outputText += "\n" + text
        }
    }
}

#Preview {
    NavigationStack { TerminalView() }
}
