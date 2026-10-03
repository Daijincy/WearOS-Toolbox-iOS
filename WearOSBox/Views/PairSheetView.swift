import SwiftUI

/// 添加配对设备表单（IP + 端口 + 配对码）
struct PairSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var initialIP: String = ""
    var initialPort: String = ""
    /// 提交回调：名称、IP、端口、配对码
    var onSubmit: (String, String, Int, String) -> Void

    @State private var name = "小米Watch5"
    @State private var ip = ""
    @State private var port = ""
    @State private var code = ""
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("设备信息") {
                    TextField("设备备注（如：小米Watch5）", text: $name)
                    TextField("IP 地址", text: $ip)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("无线调试配对端口", text: $port)
                        .keyboardType(.numberPad)
                }
                Section("配对码") {
                    TextField("6 位配对码", text: $code)
                        .keyboardType(.numberPad)
                    Text("在手表「无线调试」页面点击「使用配对码配对设备」可查看配对码")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("开始配对") {
                        submit()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                } footer: {
                    Text("配对成功后设备档案将保存，后续连接仅需 IP 与端口")
                }
            }
            .navigationTitle("添加配对设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("输入有误", isPresented: $showError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                if ip.isEmpty { ip = initialIP }
                if port.isEmpty { port = initialPort }
            }
        }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !ip.trimmingCharacters(in: .whitespaces).isEmpty &&
        !port.trimmingCharacters(in: .whitespaces).isEmpty &&
        !code.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        guard Validators.isValidIPv4(ip.trimmingCharacters(in: .whitespaces)) else {
            errorMessage = "IP 地址格式不正确"
            showError = true
            return
        }
        guard Validators.isValidPort(port.trimmingCharacters(in: .whitespaces)) else {
            errorMessage = "端口号必须在 1~65535 之间"
            showError = true
            return
        }
        guard Validators.isValidPairingCode(code) else {
            errorMessage = "配对码必须是 6 位数字"
            showError = true
            return
        }
        let ipText = ip.trimmingCharacters(in: .whitespaces)
        let portValue = Int(port.trimmingCharacters(in: .whitespaces)) ?? 0
        let codeValue = code.trimmingCharacters(in: .whitespaces)
        onSubmit(name.trimmingCharacters(in: .whitespaces), ipText, portValue, codeValue)
        dismiss()
    }
}

#Preview {
    PairSheetView(onSubmit: { _, _, _, _ in })
}
