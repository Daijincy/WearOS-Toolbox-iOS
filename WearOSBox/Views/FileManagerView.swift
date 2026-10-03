import SwiftUI
import UniformTypeIdentifiers

/// 文件管理（双向传输）
struct FileManagerView: View {
    @StateObject private var session = AdbSessionManager.shared
    @State private var currentPath = "/sdcard"
    @State private var files: [RemoteFile] = []
    @State private var isLoading = false
    @State private var showUploadPicker = false
    @State private var errorMessage: String?
    @State private var pathHistory: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // 路径栏
            HStack(spacing: 8) {
                Button {
                    goUp()
                } label: {
                    Image(systemName: "arrow.up.doc")
                }
                .disabled(currentPath == "/")
                Text(currentPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    showUploadPicker = true
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
            }
            .padding(10)
            .background(.bar)

            List {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if files.isEmpty {
                    ContentUnavailableView("目录为空", systemImage: "folder")
                } else {
                    ForEach(files, id: \.self) { file in
                        row(file)
                    }
                }
            }
        }
        .navigationTitle("文件管理")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            load(path: currentPath)
        }
        .fileImporter(isPresented: $showUploadPicker,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                upload(urls: urls)
            case .failure(let err):
                errorMessage = err.localizedDescription
            }
        }
        .alert("提示", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ file: RemoteFile) -> some View {
        HStack {
            Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(file.isDirectory ? .yellow : .secondary)
            VStack(alignment: .leading) {
                Text(file.name)
                Text(file.sizeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !file.isDirectory {
                Button {
                    download(file)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if file.isDirectory {
                openDirectory(file.name)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive) {
                delete(file)
            }
        }
    }

    private func load(path: String) {
        guard let ops = session.ops else { return }
        isLoading = true
        currentPath = path
        ops.listRemote(path: path) { result in
            DispatchQueue.main.async {
                self.isLoading = false
                switch result {
                case .success(let list):
                    self.files = list
                case .failure(let err):
                    self.errorMessage = err.localizedDescription
                }
            }
        }
    }

    private func openDirectory(_ name: String) {
        let newPath = currentPath == "/" ? "/\(name)" : "\(currentPath)/\(name)"
        pathHistory.append(currentPath)
        load(path: newPath)
    }

    private func goUp() {
        guard let last = pathHistory.popLast() else {
            load(path: "/sdcard")
            return
        }
        load(path: last)
    }

    private func delete(_ file: RemoteFile) {
        guard let ops = session.ops else { return }
        let path = currentPath == "/" ? "/\(file.name)" : "\(currentPath)/\(file.name)"
        ops.removeRemote(path: path) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.load(path: self.currentPath ?? "/sdcard")
                case .failure(let err):
                    self.errorMessage = err.localizedDescription
                }
            }
        }
    }

    private func download(_ file: RemoteFile) {
        guard let ops = session.ops else { return }
        let remote = currentPath == "/" ? "/\(file.name)" : "\(currentPath)/\(file.name)"
        ops.sync.pull(remotePath: remote) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    self.saveToFiles(data, name: file.name)
                case .failure(let err):
                    self.errorMessage = "下载失败：\(err.localizedDescription)"
                }
            }
        }
    }

    private func saveToFiles(_ data: Data, name: String) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: temp)
        let controller = UIDocumentPickerViewController(forExporting: [temp], asCopy: true)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(controller, animated: true)
        }
    }

    private func upload(urls: [URL]) {
        guard let ops = session.ops else { return }
        var remaining = urls
        func next() {
            guard !remaining.isEmpty else { return }
            let url = remaining.removeFirst()
            let accessing = url.startAccessingSecurityScopedResource()
            let remote = currentPath == "/" ? "/\(url.lastPathComponent)" : "\(currentPath)/\(url.lastPathComponent)"
            ops.sync.push(fileURL: url, remotePath: remote) { result in
                if accessing { url.stopAccessingSecurityScopedResource() }
                switch result {
                case .success:
                    self.load(path: self.currentPath ?? "/sdcard")
                    next()
                case .failure(let err):
                    self.errorMessage = "上传失败：\(err.localizedDescription)"
                }
            }
        }
        next()
    }
}

#Preview {
    NavigationStack { FileManagerView() }
}
