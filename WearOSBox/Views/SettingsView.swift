import SwiftUI

/// 设置 / 关于
struct SettingsView: View {
    @AppStorage("scrcpyServerVersion") private var serverVersion = "2.7"

    var body: some View {
        Form {
            Section("scrcpy") {
                LabeledContent("服务端版本", value: serverVersion)
                Text("实时镜像需要设备端已推送 scrcpy-server.jar 到 /data/local/tmp/")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                LabeledContent("版本", value: "1.0.0")
                LabeledContent("最低系统", value: "iOS 26")
                LabeledContent("通信方式", value: "WiFi ADB (TCP)")
            }

            Section("使用说明") {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("首次使用：添加配对设备（IP + 配对端口 + 配对码）完成配对")
                    bullet("再次连接：选中档案，IP/端口可修改，直接连接（无需配对码）")
                    bullet("手表需开启「开发者选项 → 无线调试」")
                    bullet("iPhone 与手表需连接同一 WiFi")
                }
                .font(.footnote)
            }

            Section("限制说明") {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("仅支持 WiFi 局域网 TCP 连接，不支持蓝牙 ADB")
                    bullet("首次配对需在手表屏幕确认授权")
                    bullet("App 退入后台会断开 ADB 连接（iOS 系统限制）")
                    bullet("部分系统命令受 WearOS 权限管控会返回 Permission denied")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
        }
    }
}

#Preview {
    NavigationStack { SettingsView() }
}
