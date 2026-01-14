//
//  FilesView.swift
//  HexBSD
//
//  Split-view file browser for local and remote filesystem
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
        fileIcon(for: name, isDirectory: isDirectory)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        formatFileSizeHelper(bytes)
    }
}

struct LocalFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date?

    var displaySize: String {
        if isDirectory {
            return "-"
        }
        return formatFileSize(size)
    }

    var icon: String {
        fileIcon(for: name, isDirectory: isDirectory)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        formatFileSizeHelper(bytes)
    }
}

// MARK: - Shared Helpers

private func fileIcon(for name: String, isDirectory: Bool) -> String {
    if isDirectory {
        return "folder.fill"
    }
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

private func formatFileSizeHelper(_ bytes: Int64) -> String {
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

// MARK: - Main Split View

struct FilesContentView: View {
    @StateObject private var localVM = LocalFilesViewModel()
    @StateObject private var remoteVM = RemoteFilesViewModel()
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isTransferring = false

    // Transfer progress state
    @State private var transferProgress: Double = 0.0
    @State private var transferFileName: String = ""
    @State private var transferRate: String = ""
    @State private var transferredBytes: Int64 = 0
    @State private var totalTransferBytes: Int64 = 0
    @State private var transferCancelled = false
    @State private var transferTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Transfer status bar
            if isTransferring {
                VStack(spacing: 6) {
                    HStack {
                        Text(transferFileName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        if !transferRate.isEmpty {
                            Text(transferRate)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button(action: {
                            transferCancelled = true
                            transferTask?.cancel()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Cancel transfer")
                    }

                    ProgressView(value: transferProgress, total: 1.0)
                        .progressViewStyle(.linear)

                    HStack {
                        Text(formatBytes(transferredBytes))
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Spacer()

                        Text(formatBytes(totalTransferBytes))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.1))
            }

            HSplitView {
                // Local pane (left)
                LocalFilePaneView(
                    currentPath: $localVM.currentPath,
                    files: localVM.files,
                    selectedFiles: $localVM.selectedFiles,
                    isLoading: localVM.isLoading,
                    error: localVM.error,
                    onNavigateUp: { await localVM.navigateUp() },
                    onNavigateHome: { await localVM.navigateHome() },
                    onRefresh: { await localVM.refresh() },
                    onNavigateTo: { file in await localVM.navigateTo(file) },
                    onDelete: { file in await localVM.deleteFile(file) },
                    onTransfer: { await transferToRemote() },
                    canTransfer: !localVM.selectedFiles.isEmpty && !isTransferring,
                    onDropReceived: { path in
                        Task { await handleDropToLocal(remotePath: path) }
                    }
                )
                .frame(minWidth: 300)

                // Remote pane (right)
                RemoteFilePaneView(
                    currentPath: $remoteVM.currentPath,
                    files: remoteVM.files,
                    selectedFiles: $remoteVM.selectedFiles,
                    isLoading: remoteVM.isLoading,
                    onNavigateUp: { await remoteVM.navigateUp() },
                    onNavigateHome: { await remoteVM.navigateHome() },
                    onNavigateRoot: { await remoteVM.navigateRoot() },
                    onRefresh: { await remoteVM.refresh() },
                    onNavigateTo: { file in await remoteVM.navigateTo(file) },
                    onDelete: { file in await remoteVM.deleteFile(file) },
                    onTransfer: { await transferToLocal() },
                    canTransfer: !remoteVM.selectedFiles.isEmpty && !isTransferring,
                    onDropReceived: { path in
                        Task { await handleDropToRemote(localPath: path) }
                    }
                )
                .frame(minWidth: 300)
            }
        }
        .alert("File Transfer Error", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            Task {
                await localVM.loadInitialDirectory()
                await remoteVM.loadInitialDirectory()
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024

        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        } else if mb >= 1 {
            return String(format: "%.2f MB", mb)
        } else if kb >= 1 {
            return String(format: "%.1f KB", kb)
        } else {
            return "\(bytes) B"
        }
    }

    private func resetTransferState() async {
        await MainActor.run {
            isTransferring = false
            transferProgress = 0.0
            transferFileName = ""
            transferRate = ""
            transferredBytes = 0
            totalTransferBytes = 0
            transferCancelled = false
            transferTask = nil
        }
    }

    private func transferToRemote() async {
        guard !localVM.selectedFiles.isEmpty else { return }

        await MainActor.run {
            isTransferring = true
            transferCancelled = false
            transferProgress = 0.0
        }

        let sshManager = SSHConnectionManager.shared

        for fileId in localVM.selectedFiles {
            // Check for cancellation before each file
            if transferCancelled { break }

            guard let file = localVM.files.first(where: { $0.id == fileId }) else { continue }
            guard !file.isDirectory else { continue } // Skip directories for now

            await MainActor.run {
                transferFileName = "Uploading: \(file.name)"
                transferredBytes = 0
                totalTransferBytes = file.size
            }

            let remotePath: String
            if remoteVM.currentPath.hasSuffix("/") {
                remotePath = remoteVM.currentPath + file.name
            } else {
                remotePath = remoteVM.currentPath + "/" + file.name
            }

            do {
                let localURL = URL(fileURLWithPath: file.path)
                try await sshManager.uploadFile(
                    localURL: localURL,
                    remotePath: remotePath,
                    detailedProgressCallback: { transferred, total, rate in
                        Task { @MainActor in
                            self.transferredBytes = transferred
                            self.totalTransferBytes = total
                            self.transferProgress = total > 0 ? Double(transferred) / Double(total) : 0
                            self.transferRate = rate
                        }
                    },
                    cancelCheck: { self.transferCancelled }
                )
            } catch {
                if !transferCancelled {
                    await MainActor.run {
                        errorMessage = "Failed to upload \(file.name): \(error.localizedDescription)"
                        showError = true
                    }
                }
            }
        }

        await MainActor.run { localVM.selectedFiles.removeAll() }
        await remoteVM.refresh()
        await resetTransferState()
    }

    private func transferToLocal() async {
        guard !remoteVM.selectedFiles.isEmpty else { return }

        await MainActor.run {
            isTransferring = true
            transferCancelled = false
            transferProgress = 0.0
        }

        let sshManager = SSHConnectionManager.shared

        for fileId in remoteVM.selectedFiles {
            // Check for cancellation before each file
            if transferCancelled { break }

            guard let file = remoteVM.files.first(where: { $0.id == fileId }) else { continue }
            guard !file.isDirectory else { continue } // Skip directories for now

            await MainActor.run {
                transferFileName = "Downloading: \(file.name)"
                transferredBytes = 0
                totalTransferBytes = file.size
            }

            let localPath: String
            if localVM.currentPath.hasSuffix("/") {
                localPath = localVM.currentPath + file.name
            } else {
                localPath = localVM.currentPath + "/" + file.name
            }

            do {
                let localURL = URL(fileURLWithPath: localPath)
                try await sshManager.downloadFile(
                    remotePath: file.path,
                    localURL: localURL,
                    progressCallback: { transferred, total, rate in
                        Task { @MainActor in
                            self.transferredBytes = transferred
                            self.totalTransferBytes = total
                            self.transferProgress = total > 0 ? Double(transferred) / Double(total) : 0
                            self.transferRate = rate
                        }
                    },
                    cancelCheck: { self.transferCancelled }
                )
            } catch {
                if !transferCancelled {
                    await MainActor.run {
                        errorMessage = "Failed to download \(file.name): \(error.localizedDescription)"
                        showError = true
                    }
                }
            }
        }

        await MainActor.run { remoteVM.selectedFiles.removeAll() }
        await localVM.refresh()
        await resetTransferState()
    }

    private func handleDropToRemote(localPath: String) async {
        // Check if this is actually a local file (not from remote pane)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: localPath) else { return }

        let fileName = (localPath as NSString).lastPathComponent
        let localURL = URL(fileURLWithPath: localPath)

        // Get file size
        let fileSize: Int64
        if let attrs = try? fileManager.attributesOfItem(atPath: localPath),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        } else {
            fileSize = 0
        }

        await MainActor.run {
            isTransferring = true
            transferCancelled = false
            transferFileName = "Uploading: \(fileName)"
            transferredBytes = 0
            totalTransferBytes = fileSize
            transferProgress = 0.0
        }

        let sshManager = SSHConnectionManager.shared

        let remotePath: String
        if remoteVM.currentPath.hasSuffix("/") {
            remotePath = remoteVM.currentPath + fileName
        } else {
            remotePath = remoteVM.currentPath + "/" + fileName
        }

        do {
            try await sshManager.uploadFile(
                localURL: localURL,
                remotePath: remotePath,
                detailedProgressCallback: { transferred, total, rate in
                    Task { @MainActor in
                        self.transferredBytes = transferred
                        self.totalTransferBytes = total
                        self.transferProgress = total > 0 ? Double(transferred) / Double(total) : 0
                        self.transferRate = rate
                    }
                },
                cancelCheck: { self.transferCancelled }
            )
            await remoteVM.refresh()
        } catch {
            if !transferCancelled {
                await MainActor.run {
                    errorMessage = "Failed to upload \(fileName): \(error.localizedDescription)"
                    showError = true
                }
            }
        }

        await resetTransferState()
    }

    private func handleDropToLocal(remotePath: String) async {
        // Check if this is actually a remote file (not from local pane)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: remotePath) { return }

        let fileName = (remotePath as NSString).lastPathComponent

        await MainActor.run {
            isTransferring = true
            transferCancelled = false
            transferFileName = "Downloading: \(fileName)"
            transferredBytes = 0
            totalTransferBytes = 0  // Will be updated by progress callback
            transferProgress = 0.0
        }

        let sshManager = SSHConnectionManager.shared

        let localPath: String
        if localVM.currentPath.hasSuffix("/") {
            localPath = localVM.currentPath + fileName
        } else {
            localPath = localVM.currentPath + "/" + fileName
        }

        do {
            let localURL = URL(fileURLWithPath: localPath)
            try await sshManager.downloadFile(
                remotePath: remotePath,
                localURL: localURL,
                progressCallback: { transferred, total, rate in
                    Task { @MainActor in
                        self.transferredBytes = transferred
                        self.totalTransferBytes = total
                        self.transferProgress = total > 0 ? Double(transferred) / Double(total) : 0
                        self.transferRate = rate
                    }
                },
                cancelCheck: { self.transferCancelled }
            )
            await localVM.refresh()
        } catch {
            if !transferCancelled {
                await MainActor.run {
                    errorMessage = "Failed to download \(fileName): \(error.localizedDescription)"
                    showError = true
                }
            }
        }

        await resetTransferState()
    }
}

// MARK: - Local File Pane View

struct LocalFilePaneView: View {
    @Binding var currentPath: String
    let files: [LocalFile]
    @Binding var selectedFiles: Set<UUID>
    let isLoading: Bool
    let error: String?
    let onNavigateUp: () async -> Void
    let onNavigateHome: () async -> Void
    let onRefresh: () async -> Void
    let onNavigateTo: (LocalFile) async -> Void
    let onDelete: (LocalFile) async -> Void
    let onTransfer: () async -> Void
    let canTransfer: Bool
    var onDropReceived: ((String) -> Void)? = nil

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "laptopcomputer")
                    .foregroundColor(.accentColor)
                Text("Local")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            // Navigation bar
            HStack(spacing: 8) {
                Button(action: { Task { await onNavigateUp() } }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(currentPath == "/")

                Button(action: { Task { await onNavigateHome() } }) {
                    Image(systemName: "house")
                }
                .buttonStyle(.borderless)

                Text(currentPath)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: { Task { await onRefresh() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                Button(action: { Task { await onTransfer() } }) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canTransfer)
                .help("Transfer to remote")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            // File list - Local pane
            ZStack {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMsg = error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        Text("Access Denied")
                            .font(.headline)
                        Text(errorMsg)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if files.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Empty")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedFiles) {
                        ForEach(files) { file in
                            HStack(spacing: 8) {
                                Image(systemName: file.icon)
                                    .foregroundColor(file.isDirectory ? .blue : .secondary)
                                    .frame(width: 20)
                                Text(file.name)
                                    .lineLimit(1)
                                Spacer()
                                Text(file.displaySize)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .tag(file.id)
                            .contentShape(Rectangle())
                            .gesture(
                                TapGesture(count: 2).onEnded {
                                    if file.isDirectory {
                                        Task { await onNavigateTo(file) }
                                    }
                                }
                            )
                            .simultaneousGesture(
                                TapGesture(count: 1).onEnded {
                                    selectedFiles = [file.id]
                                }
                            )
                            .draggable(file.path) {
                                HStack(spacing: 6) {
                                    Image(systemName: file.icon)
                                        .foregroundColor(file.isDirectory ? .blue : .secondary)
                                    Text(file.name)
                                }
                                .padding(6)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(4)
                            }
                            .contextMenu {
                                if file.isDirectory {
                                    Button("Open") {
                                        Task { await onNavigateTo(file) }
                                    }
                                    Divider()
                                }
                                Button("Delete", role: .destructive) {
                                    Task { await onDelete(file) }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }

                // Drop highlight overlay
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.1))
                        .padding(4)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .dropDestination(for: String.self) { items, _ in
            for path in items {
                onDropReceived?(path)
            }
            return !items.isEmpty
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }
}

// MARK: - Remote File Pane View

struct RemoteFilePaneView: View {
    @Binding var currentPath: String
    let files: [RemoteFile]
    @Binding var selectedFiles: Set<UUID>
    let isLoading: Bool
    let onNavigateUp: () async -> Void
    let onNavigateHome: () async -> Void
    let onNavigateRoot: () async -> Void
    let onRefresh: () async -> Void
    let onNavigateTo: (RemoteFile) async -> Void
    let onDelete: (RemoteFile) async -> Void
    let onTransfer: () async -> Void
    let canTransfer: Bool
    var onDropReceived: ((String) -> Void)? = nil

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "server.rack")
                    .foregroundColor(.accentColor)
                Text("Remote")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            // Navigation bar
            HStack(spacing: 8) {
                Button(action: { Task { await onNavigateUp() } }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(currentPath == "/")

                Button(action: { Task { await onNavigateHome() } }) {
                    Image(systemName: "house")
                }
                .buttonStyle(.borderless)
                .help("Go to home directory")

                Text(currentPath)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: { Task { await onRefresh() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                Button(action: { Task { await onTransfer() } }) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canTransfer)
                .help("Transfer to local")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            // File list
            ZStack {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if files.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Empty")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedFiles) {
                        ForEach(files) { file in
                            HStack(spacing: 8) {
                                Image(systemName: file.icon)
                                    .foregroundColor(file.isDirectory ? .blue : .secondary)
                                    .frame(width: 20)
                                Text(file.name)
                                    .lineLimit(1)
                                Spacer()
                                Text(file.displaySize)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .tag(file.id)
                            .contentShape(Rectangle())
                            .gesture(
                                TapGesture(count: 2).onEnded {
                                    if file.isDirectory {
                                        Task { await onNavigateTo(file) }
                                    }
                                }
                            )
                            .simultaneousGesture(
                                TapGesture(count: 1).onEnded {
                                    selectedFiles = [file.id]
                                }
                            )
                            .draggable(file.path) {
                                HStack(spacing: 6) {
                                    Image(systemName: file.icon)
                                        .foregroundColor(file.isDirectory ? .blue : .secondary)
                                    Text(file.name)
                                }
                                .padding(6)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(4)
                            }
                            .contextMenu {
                                if file.isDirectory {
                                    Button("Open") {
                                        Task { await onNavigateTo(file) }
                                    }
                                    Divider()
                                }
                                Button("Delete", role: .destructive) {
                                    Task { await onDelete(file) }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }

                // Drop highlight overlay
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.1))
                        .padding(4)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .dropDestination(for: String.self) { items, _ in
            for path in items {
                onDropReceived?(path)
            }
            return !items.isEmpty
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }
}

// MARK: - Local Files View Model

@MainActor
class LocalFilesViewModel: ObservableObject {
    @Published var files: [LocalFile] = []
    @Published var currentPath: String = ""
    @Published var isLoading = false
    @Published var selectedFiles: Set<UUID> = []
    @Published var error: String?

    private let fileManager = FileManager.default

    // Get real home directory from passwd database
    private var realHomeDirectory: String {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return String(cString: home)
        }
        return "/Users/\(NSUserName())"
    }

    func loadInitialDirectory() async {
        // Start with real home directory
        currentPath = realHomeDirectory
        await loadDirectory(currentPath)
    }

    func navigateHome() async {
        currentPath = realHomeDirectory
        await loadDirectory(currentPath)
    }

    func navigateUp() async {
        let url = URL(fileURLWithPath: currentPath)
        let parent = url.deletingLastPathComponent()
        if parent.path != currentPath {
            currentPath = parent.path
            await loadDirectory(currentPath)
        }
    }

    func navigateTo(_ file: LocalFile) async {
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
        selectedFiles.removeAll()

        do {
            let url = URL(fileURLWithPath: path)
            let contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            var loadedFiles: [LocalFile] = []

            for itemURL in contents {
                let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])

                let file = LocalFile(
                    name: itemURL.lastPathComponent,
                    path: itemURL.path,
                    isDirectory: resourceValues.isDirectory ?? false,
                    size: Int64(resourceValues.fileSize ?? 0),
                    modifiedDate: resourceValues.contentModificationDate
                )
                loadedFiles.append(file)
            }

            // Sort: directories first, then alphabetically
            files = loadedFiles.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } catch {
            self.error = "Failed to load directory: \(error.localizedDescription)"
            files = []
        }

        isLoading = false
    }

    func deleteFile(_ file: LocalFile) async {
        let alert = NSAlert()
        alert.messageText = "Delete \(file.name)?"
        alert.informativeText = file.isDirectory
            ? "This will permanently delete the directory and all its contents."
            : "This will permanently delete the file."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try fileManager.removeItem(atPath: file.path)
            await refresh()
        } catch {
            self.error = "Failed to delete: \(error.localizedDescription)"
        }
    }
}

// MARK: - Remote Files View Model

@MainActor
class RemoteFilesViewModel: ObservableObject {
    @Published var files: [RemoteFile] = []
    @Published var currentPath: String = "~"
    @Published var isLoading = false
    @Published var selectedFiles: Set<UUID> = []
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadInitialDirectory() async {
        // Resolve ~ to actual home directory path
        do {
            let homePath = try await sshManager.executeCommand("echo $HOME")
            currentPath = homePath.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            currentPath = "/root"
        }
        await loadDirectory(currentPath)
    }

    func navigateHome() async {
        // Resolve ~ to actual home directory path
        do {
            let homePath = try await sshManager.executeCommand("echo $HOME")
            currentPath = homePath.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            currentPath = "/root"
        }
        await loadDirectory(currentPath)
    }

    func navigateRoot() async {
        currentPath = "/"
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
        selectedFiles.removeAll()

        do {
            files = try await sshManager.listDirectory(path: path)
        } catch {
            self.error = "Failed to load directory: \(error.localizedDescription)"
            files = []
        }

        isLoading = false
    }

    func deleteFile(_ file: RemoteFile) async {
        let alert = NSAlert()
        alert.messageText = "Delete \(file.name)?"
        alert.informativeText = file.isDirectory
            ? "This will permanently delete the directory and all its contents."
            : "This will permanently delete the file."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try await sshManager.deleteFile(path: file.path, isDirectory: file.isDirectory)
            await refresh()
        } catch {
            self.error = "Failed to delete: \(error.localizedDescription)"
        }
    }
}
