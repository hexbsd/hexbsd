//
//  FilesView.swift
//  HexBSD
//
//  SFTP file browser for remote filesystem
//

import SwiftUI
import AppKit

// MARK: - File Models

struct RemoteFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let permissions: String
    let modifiedDate: Date?

    var displaySize: String {
        if isDirectory {
            return "-"
        }
        return formatFileSize(size)
    }

    var icon: String {
        if isDirectory {
            return "folder.fill"
        }
        // Determine icon by extension
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "log":
            return "doc.text"
        case "jpg", "jpeg", "png", "gif", "bmp":
            return "photo"
        case "mp4", "mov", "avi", "mkv":
            return "video"
        case "mp3", "wav", "m4a", "flac":
            return "music.note"
        case "zip", "tar", "gz", "bz2", "xz":
            return "doc.zipper"
        case "pdf":
            return "doc.richtext"
        case "sh", "py", "js", "swift", "c", "cpp", "h":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc"
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024

        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        } else if mb >= 1 {
            return String(format: "%.2f MB", mb)
        } else if kb >= 1 {
            return String(format: "%.2f KB", kb)
        } else {
            return "\(bytes) B"
        }
    }
}

// MARK: - Files View

struct FilesContentView: View {
    @StateObject private var viewModel = FilesViewModel()
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            // Navigation bar
            HStack {
                Button(action: {
                    Task {
                        await viewModel.navigateUp()
                    }
                }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(viewModel.currentPath == "/")
                .buttonStyle(.borderless)

                Button(action: {
                    Task {
                        await viewModel.navigateToHome()
                    }
                }) {
                    Image(systemName: "house")
                }
                .buttonStyle(.borderless)

                Text(viewModel.currentPath)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 8)

                Spacer()

                Button(action: {
                    Task {
                        await viewModel.refresh()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                Button(action: {
                    Task {
                        await viewModel.uploadFile()
                    }
                }) {
                    Label("Upload", systemImage: "arrow.up.doc")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            // File list
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading files...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.files.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "folder")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("Empty Directory")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(viewModel.files) {
                    TableColumn("Name") { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.icon)
                                .foregroundColor(file.isDirectory ? .blue : .secondary)
                            Text(file.name)
                        }
                    }

                    TableColumn("Size", value: \.displaySize)
                        .width(min: 80, ideal: 100, max: 120)

                    TableColumn("Permissions", value: \.permissions)
                        .width(min: 80, ideal: 100, max: 120)

                    TableColumn("Modified") { file in
                        if let date = file.modifiedDate {
                            Text(date, style: .date)
                        } else {
                            Text("-")
                        }
                    }
                    .width(min: 100, ideal: 120, max: 150)
                }
                .onTapGesture { }
                .contextMenu(forSelectionType: RemoteFile.ID.self) { items in
                    // Context menu for selected files
                    if items.count == 1, let id = items.first,
                       let file = viewModel.files.first(where: { $0.id == id }) {
                        if file.isDirectory {
                            Button("Open") {
                                Task {
                                    await viewModel.navigateTo(file)
                                }
                            }
                        } else {
                            Button("Download...") {
                                Task {
                                    await viewModel.downloadFile(file)
                                }
                            }
                        }

                        Divider()

                        Button("Delete") {
                            Task {
                                await viewModel.deleteFile(file)
                            }
                        }
                    }

                    Divider()

                    Button("Upload File...") {
                        Task {
                            await viewModel.uploadFile()
                        }
                    }

                    Button("Refresh") {
                        Task {
                            await viewModel.refresh()
                        }
                    }
                } primaryAction: { items in
                    // Double-click action
                    if let id = items.first,
                       let file = viewModel.files.first(where: { $0.id == id }) {
                        Task {
                            if file.isDirectory {
                                await viewModel.navigateTo(file)
                            } else {
                                await viewModel.downloadFile(file)
                            }
                        }
                    }
                }
            }
        }
        .alert("Files Error", isPresented: $showError) {
            Button("OK") {
                showError = false
            }
        } message: {
            Text(viewModel.error ?? "Unknown error")
        }
        .onChange(of: viewModel.error) { oldValue, newValue in
            if newValue != nil {
                showError = true
            }
        }
        .onAppear {
            Task {
                await viewModel.loadInitialDirectory()
            }
        }
    }
}

// MARK: - View Model

@MainActor
class FilesViewModel: ObservableObject {
    @Published var files: [RemoteFile] = []
    @Published var currentPath: String = "~"
    @Published var isLoading = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadInitialDirectory() async {
        currentPath = "~"
        await loadDirectory(currentPath)
    }

    func navigateToHome() async {
        currentPath = "~"
        await loadDirectory(currentPath)
    }

    func navigateUp() async {
        let components = currentPath.split(separator: "/")
        if components.count > 1 {
            currentPath = "/" + components.dropLast().joined(separator: "/")
        } else {
            currentPath = "/"
        }
        await loadDirectory(currentPath)
    }

    func navigateTo(_ file: RemoteFile) async {
        guard file.isDirectory else { return }
        currentPath = file.path
        await loadDirectory(currentPath)
    }

    func refresh() async {
        await loadDirectory(currentPath)
    }

    func loadDirectory(_ path: String) async {
        isLoading = true
        error = nil

        do {
            files = try await sshManager.listDirectory(path: path)
        } catch {
            self.error = "Failed to load directory: \(error.localizedDescription)"
            files = []
        }

        isLoading = false
    }

    func downloadFile(_ file: RemoteFile) async {
        // Show save panel
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.message = "Choose where to save the file"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        isLoading = true
        error = nil

        do {
            try await sshManager.downloadFile(remotePath: file.path, localURL: url)
        } catch {
            self.error = "Failed to download file: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func uploadFile() async {
        // Show open panel to select file to upload
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file to upload"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let fileName = url.lastPathComponent

        // Build remote path
        let remotePath: String
        if currentPath.hasSuffix("/") {
            remotePath = currentPath + fileName
        } else {
            remotePath = currentPath + "/" + fileName
        }

        isLoading = true
        error = nil

        do {
            try await sshManager.uploadFile(localURL: url, remotePath: remotePath)
            // Refresh directory to show the uploaded file
            await refresh()
        } catch {
            self.error = "Failed to upload file: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func deleteFile(_ file: RemoteFile) async {
        // Confirm deletion
        let alert = NSAlert()
        alert.messageText = "Delete \(file.name)?"
        alert.informativeText = file.isDirectory
            ? "This will permanently delete the directory and all its contents."
            : "This will permanently delete the file."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        isLoading = true
        error = nil

        do {
            try await sshManager.deleteFile(path: file.path, isDirectory: file.isDirectory)
            // Refresh directory to remove the deleted file
            await refresh()
        } catch {
            self.error = "Failed to delete file: \(error.localizedDescription)"
        }

        isLoading = false
    }
}
