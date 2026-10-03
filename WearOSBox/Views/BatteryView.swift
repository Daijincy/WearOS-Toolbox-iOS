import SwiftUI

/// 电池工具
struct BatteryView: View {
    @StateObject private var session = AdbSessionManager.shared
    @State private var info: [String: String] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if info.isEmpty {
                ContentUnavailableView("无电池数据", systemImage: "battery.0",
                                       description: Text("点击刷新读取电池信息"))
            } else {
                // 概览卡片
                Section {
                    if let level = info["level"], let pct = Int(level) {
                        HStack(spacing: 16) {
                            Gauge(value: Double(pct), in: 0...100) {
                                EmptyView()
                            } currentValueLabel: {
                                Text("\(pct)%")
                                    .font(.headline)
                            }
                            .gaugeStyle(.accessoryCircularCapacity)
                            .tint(pct > 20 ? .green : .red)
                            Text(statusText)
                                .font(.subheadline)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }

                // 详细属性
                Section("电池属性") {
                    ForEach(sortedKeys, id: \.self) { key in
                        HStack {
                            Text(key)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(info[key] ?? "")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }
        }
        .navigationTitle("电池工具")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新", systemImage: "arrow.clockwise") {
                    load()
                }
            }
        }
        .task { load() }
        .alert("提示", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var statusText: String {
        if info["status"] == "2" { return "充电中" }
        if info["status"] == "3" { return "已充满" }
        if info["status"] == "4" { return "未充电" }
        return info["status"] ?? ""
    }

    private var sortedKeys: [String] {
        info.keys.sorted {
            let order = ["AC powered", "USB powered", "Wireless powered", "status", "health", "present",
                         "level", "scale", "voltage", "temperature", "technology"]
            let i1 = order.firstIndex(of: $0) ?? 99
            let i2 = order.firstIndex(of: $1) ?? 99
            return i1 < i2
        }
    }

    private func load() {
        guard let ops = session.ops else { return }
        isLoading = true
        ops.batteryInfo { [weak self] result in
            DispatchQueue.main.async {
                self?.isLoading = false
                switch result {
                case .success(let dict):
                    self?.info = dict
                case .failure(let err):
                    self?.errorMessage = err.localizedDescription
                }
            }
        }
    }
}

#Preview {
    NavigationStack { BatteryView() }
}
