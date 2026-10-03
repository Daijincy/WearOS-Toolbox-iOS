import SwiftUI

/// 日志查看
struct LogView: View {
    @State private var logs: [AppLogger.LogEntry] = []

    var body: some View {
        List(logs) { entry in
            HStack(alignment: .top, spacing: 8) {
                Text(entry.timestampString)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(entry.level.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(levelColor(entry.level).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(levelColor(entry.level))
                Text(entry.message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空", systemImage: "trash") {
                    AppLogger.shared.clear()
                    refresh()
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    private func levelColor(_ level: AppLogger.LogEntry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        case .adb: return .green
        }
    }

    private func refresh() {
        logs = AppLogger.shared.entries
    }
}

#Preview {
    NavigationStack { LogView() }
}
