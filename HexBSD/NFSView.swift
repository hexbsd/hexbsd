//
//  NFSView.swift
//  HexBSD
//
//  Network File System (NFS) management - both client and server
//

import SwiftUI
import AppKit

// MARK: - Data Models

struct NFSStatus: Identifiable {
    let id = UUID()
    let isClientEnabled: Bool
    let isServerEnabled: Bool
    let nfsdThreads: Int
    let rpcbindRunning: Bool
}

struct NFSMount: Identifiable, Hashable {
    let id = UUID()
    let server: String
    let remotePath: String
    let mountPoint: String
    let type: String  // nfs, nfs4
    let options: String
    let status: MountStatus

    enum MountStatus: String {
        case mounted = "Mounted"
        case error = "Error"
        case unknown = "Unknown"
    }

    var statusColor: Color {
        switch status {
        case .mounted: return .green
        case .error: return .red
        case .unknown: return .secondary
        }
    }

    var displayServer: String {
        "\(server):\(remotePath)"
    }
}

struct NFSExport: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let clients: String  // Host/network restrictions
    let options: String  // ro, rw, maproot, etc.
    let isActive: Bool

    var displayClients: String {
        clients.isEmpty ? "All hosts" : clients
    }
}

struct NFSClient: Identifiable, Hashable {
    let id = UUID()
    let hostname: String
    let mountedPath: String
}

struct NFSStats: Identifiable {
    let id = UUID()
    let getattr: String
    let lookup: String
    let read: String
    let write: String
    let total: String
}

// MARK: - Main View

struct NFSContentView: View {
    @StateObject private var viewModel = NFSViewModel()
    @State private var selectedView: NFSViewType = .client
    @State private var showError = false

    enum NFSViewType: String, CaseIterable {
        case client = "Client"
        case server = "Server"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segmented control for view selection
            Picker("View", selection: $selectedView) {
                ForEach(NFSViewType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // Content based on selected view
            Group {
                switch selectedView {
                case .client:
                    NFSClientView(viewModel: viewModel)
                case .server:
                    NFSServerView(viewModel: viewModel)
                }
            }
        }
        .alert("NFS Error", isPresented: $showError) {
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
                await viewModel.loadStatus()
            }
        }
    }
}

// MARK: - Client View

struct NFSClientView: View {
    @ObservedObject var viewModel: NFSViewModel
    @State private var showMountSheet = false
    @State private var selectedMount: NFSMount?

    var body: some View {
        VStack(spacing: 0) {
            // Status section
            VStack(spacing: 16) {
                HStack {
                    Text("Client Status")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    Circle()
                        .fill(viewModel.status?.isClientEnabled == true ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(viewModel.status?.isClientEnabled == true ? "Active" : "Inactive")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Info card
                if let status = viewModel.status {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("RPC Bind:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(status.rpcbindRunning ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(status.rpcbindRunning ? "Running" : "Stopped")
                                    .font(.body)
                                    .fontWeight(.medium)
                            }
                        }

                        HStack {
                            Text("Mounted Shares:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(viewModel.mounts.count)")
                                .font(.body)
                                .fontWeight(.medium)
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }

                // Actions
                HStack(spacing: 12) {
                    Button(action: {
                        showMountSheet = true
                    }) {
                        Label("Mount Share", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderedProminent)

                    if let mount = selectedMount {
                        Button(action: {
                            Task {
                                await viewModel.unmount(mount: mount)
                            }
                        }) {
                            Label("Unmount", systemImage: "eject")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(action: {
                        Task {
                            await viewModel.refreshMounts()
                        }
                    }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    if viewModel.status?.isClientEnabled == true {
                        Button(action: {
                            Task {
                                await viewModel.viewClientStats()
                            }
                        }) {
                            Label("Statistics", systemImage: "chart.bar")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()

            Divider()

            // Mounts list
            HStack {
                Text("Mounted NFS Shares")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding()

            Divider()

            if viewModel.isLoadingMounts {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading mounts...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.mounts.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No NFS Shares Mounted")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Click 'Mount Share' to mount an NFS share")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.mounts, selection: $selectedMount) { mount in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "externaldrive.connected")
                                .foregroundColor(.blue)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(mount.displayServer)
                                    .font(.headline)

                                HStack(spacing: 12) {
                                    Label(mount.mountPoint, systemImage: "folder")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    Label(mount.type.uppercased(), systemImage: "")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    if !mount.options.isEmpty {
                                        Label(mount.options, systemImage: "gearshape")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }

                            Spacer()

                            HStack(spacing: 4) {
                                Circle()
                                    .fill(mount.statusColor)
                                    .frame(width: 8, height: 8)
                                Text(mount.status.rawValue)
                                    .font(.caption)
                                    .foregroundColor(mount.statusColor)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .sheet(isPresented: $showMountSheet) {
            MountShareSheet(
                onMount: { server, path, mountPoint, options, addToFstab in
                    Task {
                        await viewModel.mountShare(
                            server: server,
                            remotePath: path,
                            mountPoint: mountPoint,
                            options: options,
                            addToFstab: addToFstab
                        )
                        showMountSheet = false
                    }
                },
                onCancel: {
                    showMountSheet = false
                }
            )
        }
    }
}

// MARK: - Server View

struct NFSServerView: View {
    @ObservedObject var viewModel: NFSViewModel
    @State private var showAddExport = false
    @State private var selectedExport: NFSExport?

    var body: some View {
        VStack(spacing: 0) {
            // Status section
            VStack(spacing: 16) {
                HStack {
                    Text("Server Status")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    Circle()
                        .fill(viewModel.status?.isServerEnabled == true ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(viewModel.status?.isServerEnabled == true ? "Running" : "Stopped")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Server info
                if let status = viewModel.status, status.isServerEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("NFS Threads:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(status.nfsdThreads)")
                                .font(.body)
                                .fontWeight(.medium)
                        }

                        HStack {
                            Text("Active Exports:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(viewModel.exports.count)")
                                .font(.body)
                                .fontWeight(.medium)
                        }

                        HStack {
                            Text("Connected Clients:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(viewModel.clients.count)")
                                .font(.body)
                                .fontWeight(.medium)
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }

                // Actions
                HStack(spacing: 12) {
                    if viewModel.status?.isServerEnabled != true {
                        Button(action: {
                            Task {
                                await viewModel.startServer()
                            }
                        }) {
                            Label("Start Server", systemImage: "play.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(action: {
                            showAddExport = true
                        }) {
                            Label("Add Export", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderedProminent)

                        if selectedExport != nil {
                            Button(action: {
                                Task {
                                    if let export = selectedExport {
                                        await viewModel.removeExport(export: export)
                                    }
                                }
                            }) {
                                Label("Remove Export", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                        }

                        Button(action: {
                            Task {
                                await viewModel.reloadExports()
                            }
                        }) {
                            Label("Reload Exports", systemImage: "arrow.clockwise.circle")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            Task {
                                await viewModel.stopServer()
                            }
                        }) {
                            Label("Stop Server", systemImage: "stop.circle")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            Task {
                                await viewModel.viewServerStats()
                            }
                        }) {
                            Label("Statistics", systemImage: "chart.bar")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()

            Divider()

            // Tabs for exports and clients
            if viewModel.status?.isServerEnabled == true {
                TabView {
                    // Exports tab
                    VStack(spacing: 0) {
                        HStack {
                            Text("NFS Exports")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            Spacer()

                            Button(action: {
                                Task {
                                    await viewModel.refreshExports()
                                }
                            }) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()

                        Divider()

                        if viewModel.isLoadingExports {
                            VStack(spacing: 20) {
                                ProgressView()
                                Text("Loading exports...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if viewModel.exports.isEmpty {
                            VStack(spacing: 20) {
                                Image(systemName: "folder.badge.questionmark")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("No Exports Configured")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                                Text("Add exports in /etc/exports")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List(viewModel.exports, selection: $selectedExport) { export in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: export.isActive ? "folder.fill" : "folder")
                                            .foregroundColor(export.isActive ? .green : .secondary)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(export.path)
                                                .font(.headline)

                                            HStack(spacing: 12) {
                                                Label(export.displayClients, systemImage: "network")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)

                                                if !export.options.isEmpty {
                                                    Label(export.options, systemImage: "gearshape")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                        }

                                        Spacer()

                                        Text(export.isActive ? "Active" : "Inactive")
                                            .font(.caption)
                                            .foregroundColor(export.isActive ? .green : .secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .tabItem {
                        Label("Exports", systemImage: "folder.badge.gearshape")
                    }

                    // Connected clients tab
                    VStack(spacing: 0) {
                        HStack {
                            Text("Connected Clients")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            Spacer()

                            Button(action: {
                                Task {
                                    await viewModel.refreshClients()
                                }
                            }) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()

                        Divider()

                        if viewModel.isLoadingClients {
                            VStack(spacing: 20) {
                                ProgressView()
                                Text("Loading clients...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if viewModel.clients.isEmpty {
                            VStack(spacing: 20) {
                                Image(systemName: "person.2.slash")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("No Connected Clients")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List(viewModel.clients) { client in
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                        .foregroundColor(.blue)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(client.hostname)
                                            .font(.headline)

                                        Text(client.mountedPath)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .tabItem {
                        Label("Clients", systemImage: "person.2")
                    }
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("NFS Server Not Running")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Start the server to manage exports and view clients")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showAddExport) {
            AddExportSheet(
                onAdd: { path, clients, options in
                    Task {
                        await viewModel.addExport(path: path, clients: clients, options: options)
                        showAddExport = false
                    }
                },
                onCancel: {
                    showAddExport = false
                }
            )
        }
    }
}

// MARK: - Mount Share Sheet

struct MountShareSheet: View {
    let onMount: (String, String, String, String, Bool) -> Void
    let onCancel: () -> Void

    @State private var server = ""
    @State private var remotePath = ""
    @State private var mountPoint = ""
    @State private var nfsVersion = "nfs"
    @State private var mountOptions = "rw,tcp"
    @State private var addToFstab = false

    var isValid: Bool {
        !server.isEmpty && !remotePath.isEmpty && !mountPoint.isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Mount NFS Share")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Text("NFS Server")
                    .font(.caption)
                TextField("hostname or IP", text: $server)
                    .textFieldStyle(.roundedBorder)

                Text("Remote Path")
                    .font(.caption)
                TextField("/path/to/export", text: $remotePath)
                    .textFieldStyle(.roundedBorder)

                Text("Local Mount Point")
                    .font(.caption)
                HStack {
                    TextField("/mnt/nfs", text: $mountPoint)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        selectMountPoint()
                    }
                    .buttonStyle(.bordered)
                }

                Text("NFS Version")
                    .font(.caption)
                Picker("Version", selection: $nfsVersion) {
                    Text("NFSv3").tag("nfs")
                    Text("NFSv4").tag("nfs4")
                }
                .pickerStyle(.segmented)

                Text("Mount Options")
                    .font(.caption)
                TextField("rw,tcp", text: $mountOptions)
                    .textFieldStyle(.roundedBorder)

                Text("Common options: rw (read-write), ro (read-only), tcp, soft, hard, intr, timeo=10")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Toggle("Add to /etc/fstab (mount at boot)", isOn: $addToFstab)
                    .toggleStyle(.switch)

                if addToFstab {
                    Text("This will persist the mount across reboots")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            .padding()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Mount") {
                    onMount(server, remotePath, mountPoint, mountOptions, addToFstab)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 500)
    }

    private func selectMountPoint() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Select mount point directory"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                mountPoint = url.path
            }
        }
        #endif
    }
}

// MARK: - Add Export Sheet

struct AddExportSheet: View {
    let onAdd: (String, String, String) -> Void
    let onCancel: () -> Void

    @State private var exportPath = ""
    @State private var clientRestriction = ""
    @State private var selectedOptions: Set<String> = ["rw"]

    let availableOptions = [
        "rw": "Read-Write",
        "ro": "Read-Only",
        "maproot": "Map root to user",
        "mapall": "Map all users",
        "network": "Network restriction",
        "mask": "Network mask"
    ]

    var isValid: Bool {
        !exportPath.isEmpty
    }

    var optionsString: String {
        selectedOptions.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Add NFS Export")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Text("Export Path")
                    .font(.caption)
                HStack {
                    TextField("/path/to/export", text: $exportPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        selectExportPath()
                    }
                    .buttonStyle(.bordered)
                }

                Text("Client Restrictions")
                    .font(.caption)
                TextField("Leave empty for all hosts, or specify host/network", text: $clientRestriction)
                    .textFieldStyle(.roundedBorder)

                Text("Examples: 192.168.1.10, 192.168.1.0/24, server.example.com")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text("Export Options")
                    .font(.caption)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Read-Write (rw)", isOn: Binding(
                        get: { selectedOptions.contains("rw") },
                        set: { if $0 { selectedOptions.insert("rw"); selectedOptions.remove("ro") } }
                    ))

                    Toggle("Read-Only (ro)", isOn: Binding(
                        get: { selectedOptions.contains("ro") },
                        set: { if $0 { selectedOptions.insert("ro"); selectedOptions.remove("rw") } }
                    ))

                    Toggle("Map Root User (maproot=root)", isOn: Binding(
                        get: { selectedOptions.contains("maproot") },
                        set: { if $0 { selectedOptions.insert("maproot") } else { selectedOptions.remove("maproot") } }
                    ))
                }

                Text("This will add an entry to /etc/exports and reload the exports")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Export") {
                    onAdd(exportPath, clientRestriction, optionsString)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 500)
    }

    private func selectExportPath() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Select directory to export"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                exportPath = url.path
            }
        }
        #endif
    }
}

// MARK: - View Model

@MainActor
class NFSViewModel: ObservableObject {
    @Published var status: NFSStatus?
    @Published var mounts: [NFSMount] = []
    @Published var exports: [NFSExport] = []
    @Published var clients: [NFSClient] = []
    @Published var isLoadingMounts = false
    @Published var isLoadingExports = false
    @Published var isLoadingClients = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadStatus() async {
        do {
            status = try await sshManager.getNFSStatus()

            // Auto-load data based on what's enabled
            if status?.isClientEnabled == true {
                await refreshMounts()
            }

            if status?.isServerEnabled == true {
                await refreshExports()
                await refreshClients()
            }
        } catch {
            self.error = "Failed to load NFS status: \(error.localizedDescription)"
        }
    }

    // MARK: - Client Methods

    func refreshMounts() async {
        isLoadingMounts = true
        error = nil

        do {
            mounts = try await sshManager.listNFSMounts()
        } catch {
            self.error = "Failed to load mounts: \(error.localizedDescription)"
            mounts = []
        }

        isLoadingMounts = false
    }

    func mountShare(server: String, remotePath: String, mountPoint: String, options: String, addToFstab: Bool) async {
        error = nil

        do {
            try await sshManager.mountNFSShare(
                server: server,
                remotePath: remotePath,
                mountPoint: mountPoint,
                options: options,
                addToFstab: addToFstab
            )
            await refreshMounts()
        } catch {
            self.error = "Failed to mount share: \(error.localizedDescription)"
        }
    }

    func unmount(mount: NFSMount) async {
        // Confirm unmount
        let alert = NSAlert()
        alert.messageText = "Unmount NFS Share?"
        alert.informativeText = "This will unmount \(mount.displayServer) from \(mount.mountPoint)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Unmount")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.unmountNFS(mountPoint: mount.mountPoint)
            await refreshMounts()
        } catch {
            self.error = "Failed to unmount share: \(error.localizedDescription)"
        }
    }

    func viewClientStats() async {
        do {
            let stats = try await sshManager.getNFSClientStats()
            // Display stats in an alert
            let alert = NSAlert()
            alert.messageText = "NFS Client Statistics"
            alert.informativeText = """
            Operations:
            GETATTR: \(stats.getattr)
            LOOKUP: \(stats.lookup)
            READ: \(stats.read)
            WRITE: \(stats.write)
            TOTAL: \(stats.total)
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            self.error = "Failed to get statistics: \(error.localizedDescription)"
        }
    }

    // MARK: - Server Methods

    func startServer() async {
        error = nil

        do {
            try await sshManager.startNFSServer()
            await loadStatus()
        } catch {
            self.error = "Failed to start server: \(error.localizedDescription)"
        }
    }

    func stopServer() async {
        // Confirm stop
        let alert = NSAlert()
        alert.messageText = "Stop NFS Server?"
        alert.informativeText = "This will disconnect all clients"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.stopNFSServer()
            await loadStatus()
        } catch {
            self.error = "Failed to stop server: \(error.localizedDescription)"
        }
    }

    func refreshExports() async {
        isLoadingExports = true
        error = nil

        do {
            exports = try await sshManager.listNFSExports()
        } catch {
            self.error = "Failed to load exports: \(error.localizedDescription)"
            exports = []
        }

        isLoadingExports = false
    }

    func addExport(path: String, clients: String, options: String) async {
        error = nil

        do {
            try await sshManager.addNFSExport(path: path, clients: clients, options: options)
            await refreshExports()
        } catch {
            self.error = "Failed to add export: \(error.localizedDescription)"
        }
    }

    func removeExport(export: NFSExport) async {
        // Confirm removal
        let alert = NSAlert()
        alert.messageText = "Remove Export?"
        alert.informativeText = "This will remove \(export.path) from /etc/exports"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.removeNFSExport(path: export.path)
            await refreshExports()
        } catch {
            self.error = "Failed to remove export: \(error.localizedDescription)"
        }
    }

    func reloadExports() async {
        error = nil

        do {
            try await sshManager.reloadNFSExports()
            await refreshExports()
        } catch {
            self.error = "Failed to reload exports: \(error.localizedDescription)"
        }
    }

    func refreshClients() async {
        isLoadingClients = true
        error = nil

        do {
            clients = try await sshManager.listNFSClients()
        } catch {
            self.error = "Failed to load clients: \(error.localizedDescription)"
            clients = []
        }

        isLoadingClients = false
    }

    func viewServerStats() async {
        do {
            let stats = try await sshManager.getNFSServerStats()
            // Display stats in an alert
            let alert = NSAlert()
            alert.messageText = "NFS Server Statistics"
            alert.informativeText = """
            Operations:
            GETATTR: \(stats.getattr)
            LOOKUP: \(stats.lookup)
            READ: \(stats.read)
            WRITE: \(stats.write)
            TOTAL: \(stats.total)
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            self.error = "Failed to get statistics: \(error.localizedDescription)"
        }
    }
}
