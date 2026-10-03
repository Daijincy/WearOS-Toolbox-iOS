import SwiftUI

/// 功能主页：连接成功后的功能网格
struct MainGridView: View {
    @StateObject private var session = AdbSessionManager.shared
    @State private var path = NavigationPath()

    private let columns = [GridItem(.adaptive(minimum: 90, maximum: 120), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                // 当前设备横幅
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("已连接：\(session.currentDevice?.name ?? "设备")")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(session.currentTarget?.ip ?? ""):\(session.currentTarget?.port ?? 0)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Divider()
                }
                .padding(.horizontal)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(FeatureModule.allCases) { module in
                        NavigationLink(value: module) {
                            featureCard(module)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("功能")
            .navigationDestination(for: FeatureModule.self) { module in
                destination(for: module)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("断开") {
                        session.disconnect()
                    }
                }
            }
        }
    }

    private func featureCard(_ module: FeatureModule) -> some View {
        VStack(spacing: 10) {
            Image(systemName: module.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            Text(module.rawValue)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func destination(for module: FeatureModule) -> some View {
        switch module {
        case .installApk: InstallView()
        case .installSplit: SplitInstallView()
        case .terminal: TerminalView()
        case .command: CommandView()
        case .screen: ScreenView()
        case .screenTools: ScreenToolsView()
        case .battery: BatteryView()
        case .files: FileManagerView()
        case .apps: AppManagerView()
        case .clipboard: ClipboardView()
        case .backup: BackupView()
        case .log: LogView()
        case .settings: SettingsView()
        }
    }
}

#Preview {
    MainGridView()
}
