import SwiftUI

/// 应用管理
struct AppManagerView: View {
    @StateObject private var session = AdbSessionManager.shared
    @State private var packages: [(package: String, version: String)] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var errorMessage: String?

    var filtered: [(package: String, version: String)] {
        guard !searchText.isEmpty else { return packages }
        return packages.filter { $0.package.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if packages.isEmpty {
                ContentUnavailableView("无应用列表", systemImage: "square.grid.2x2",
                                       description: Text("点击右上角刷新"))
            } else {
                ForEach(filtered, id: \.package) { item in
                    HStack {
                        Image(systemName: "app.badge")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(item.package)
                                .font(.system(.body, design: .monospaced))
                            if !item.version.isEmpty {
                                Text("版本 \(item.version)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Menu {
                            Button("卸载", role: .destructive) {
                                uninstall(item.package)
                            }
                            Button("清除数据") {
                                clearData(item.package)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .navigationTitle("应用管理")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索包名")
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

    private func load() {
        guard let ops = session.ops else { return }
        isLoading = true
        ops.listPackages { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let list):
                    self.packages = list
                case .failure(let err):
                    self.errorMessage = err.localizedDescription
                }
            }
        }
    }

    private func uninstall(_ package: String) {
        guard let ops = session.ops else { return }
        ops.uninstall(package: package) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.load()
                case .failure(let err):
                    self.errorMessage = err.localizedDescription
                }
            }
        }
    }

    private func clearData(_ package: String) {
        guard let ops = session.ops else { return }
        ops.clearAppData(package: package) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.errorMessage = "已清除 \(package) 的数据"
                case .failure(let err):
                    self.errorMessage = err.localizedDescription
                }
            }
        }
    }
}

#Preview {
    NavigationStack { AppManagerView() }
}
