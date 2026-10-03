import SwiftUI

/// 局域网扫描结果页
struct ScannerSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var scanner: DeviceScanner
    /// 选择设备回调：IP、端口
    var onSelect: (String, Int) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if scanner.isScanning && scanner.devices.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("正在扫描局域网内的无线调试设备…")
                            .foregroundStyle(.secondary)
                    }
                } else if scanner.devices.isEmpty {
                    ContentUnavailableView("未发现设备",
                        systemImage: "wifi.slash",
                        description: Text("请确认手表已开启无线调试，且与 iPhone 连接同一 WiFi"))
                } else {
                    List(scanner.devices) { device in
                        Button {
                            onSelect(device.host, device.port)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: device.isPairingService ? "lock.open" : "link")
                                    .foregroundStyle(device.isPairingService ? .orange : .green)
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text("\(device.host):\(device.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(device.isPairingService ? "配对服务" : "连接服务")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("扫描设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        scanner.startScanning()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                scanner.startScanning()
            }
            .onDisappear {
                scanner.stopScanning()
            }
        }
    }
}

#Preview {
    ScannerSheetView(scanner: DeviceScanner(), onSelect: { _, _ in })
}
