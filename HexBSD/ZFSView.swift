//
//  ZFSView.swift
//  HexBSD
//
//  ZFS pool and dataset management
//

import SwiftUI
import AppKit
import Network

// MARK: - Data Models

struct ZFSPool: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let size: String
    let allocated: String
    let free: String
    let fragmentation: String
    let capacity: String
    let health: String
    let altroot: String

    var healthColor: Color {
        switch health.uppercased() {
        case "ONLINE": return .green
        case "DEGRADED": return .orange
        case "FAULTED", "UNAVAIL": return .red
        default: return .secondary
        }
    }

    var capacityPercentage: Double {
        let cleaned = capacity.replacingOccurrences(of: "%", with: "")
        return Double(cleaned) ?? 0
    }
}

struct AvailableDisk: Identifiable, Hashable {
    let id = UUID()
    let name: String        // e.g., "da0", "ada1"
    let size: String        // e.g., "500G", "1T"
    let description: String // e.g., "VBOX HARDDISK"
    var isSelected: Bool = false
    var hasPartitions: Bool = false  // True if disk has partition table
    var partitionScheme: String = "" // e.g., "GPT", "MBR"
}

struct ZFSDataset: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let used: String
    let available: String
    let referenced: String
    let mountpoint: String
    let compression: String
    let compressRatio: String
    let quota: String
    let reservation: String
    let type: String  // filesystem, volume, snapshot
    let sharenfs: String

    var isSnapshot: Bool {
        type == "snapshot" || name.contains("@")
    }

    var isShared: Bool {
        sharenfs != "off" && sharenfs != "-"
    }

    var displayName: String {
        // For snapshots, show just the snapshot name after @
        if name.contains("@") {
            let parts = name.split(separator: "@")
            return "@" + (parts.last.map(String.init) ?? name)
        }
        return name
    }

    var parentDataset: String {
        // Get parent dataset name
        if name.contains("@") {
            return String(name.split(separator: "@")[0])
        }

        let parts = name.split(separator: "/")
        if parts.count > 1 {
            return parts.dropLast().joined(separator: "/")
        }
        return ""
    }

    var icon: String {
        if isSnapshot {
            return "camera"
        }

        // Show network icon if shared
        if isShared {
            return "network"
        }

        switch type {
        case "filesystem":
            return "folder.fill"
        case "volume":
            return "externaldrive.fill"
        default:
            return "cylinder"
        }
    }

    /// Indicates if this dataset is protected from deletion (system-critical)
    var isProtected: Bool {
        // Pool root datasets (no slash in name)
        if !name.contains("/") {
            return true
        }

        // Currently mounted as root filesystem
        if mountpoint == "/" {
            return true
        }

        // Boot environment container (e.g., zroot/ROOT)
        if name.hasSuffix("/ROOT") {
            return true
        }

        // Critical system datasets
        let criticalPaths = ["/var", "/tmp", "/usr", "/home"]
        if criticalPaths.contains(mountpoint) {
            return true
        }

        return false
    }

    /// Reason why the dataset is protected (for tooltip/display)
    var protectionReason: String? {
        if !name.contains("/") {
            return "Pool root dataset"
        }
        if mountpoint == "/" {
            return "Active root filesystem"
        }
        if name.hasSuffix("/ROOT") {
            return "Boot environments container"
        }
        let criticalPaths = ["/var", "/tmp", "/usr", "/home"]
        if criticalPaths.contains(mountpoint) {
            return "Critical system dataset"
        }
        return nil
    }
}

struct ZFSScrubStatus: Identifiable {
    let id = UUID()
    let poolName: String
    let state: String  // in progress, completed, none
    let progress: Double?  // 0-100 for in progress
    let scanned: String?
    let issued: String?
    let duration: String?
    let errors: Int

    var isInProgress: Bool {
        state.lowercased().contains("progress") || state.lowercased().contains("scanning")
    }

    var statusColor: Color {
        if errors > 0 {
            return .red
        } else if isInProgress {
            return .blue
        } else if state.lowercased().contains("completed") {
            return .green
        } else {
            return .secondary
        }
    }
}

// MARK: - Main View

struct ZFSContentView: View {
    @StateObject private var viewModel = ZFSViewModel()
    @State private var showError = false
    @State private var showBootEnvironments = false
    @State private var showPools = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar with Boot Environments and Pools buttons
            HStack {
                Button(action: {
                    showBootEnvironments = true
                }) {
                    Label("Boot Environments", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.bordered)

                Button(action: {
                    showPools = true
                }) {
                    Label("Pools", systemImage: "cylinder.fill")
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding()

            Divider()

            // Datasets view is the main content
            DatasetsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showBootEnvironments) {
            BootEnvironmentsSheet()
        }
        .sheet(isPresented: $showPools) {
            PoolsSheet(viewModel: viewModel)
        }
        .alert("ZFS Error", isPresented: $showError) {
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
                await viewModel.loadAll()
            }
        }
    }
}

// MARK: - Boot Environments Sheet

struct BootEnvironmentsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Boot Environments")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Boot environments content
            BootEnvironmentsSection()
                .padding()

            Spacer()
        }
        .frame(width: 700, height: 500)
    }
}

// MARK: - Pools Sheet

struct PoolsSheet: View {
    @ObservedObject var viewModel: ZFSViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var availableDisks: [AvailableDisk] = []
    @State private var isLoadingDisks = false
    @State private var showCreatePool = false
    @State private var scrubRefreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("ZFS Pools")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                // New Pool button - disabled if no available disks
                Button(action: {
                    showCreatePool = true
                }) {
                    Label("New Pool", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(availableDisks.isEmpty || isLoadingDisks)

                if isLoadingDisks {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Pools content
            if viewModel.isLoadingPools {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading pools...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.pools.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "cylinder")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No ZFS Pools")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    if !availableDisks.isEmpty {
                        Text("\(availableDisks.count) disk(s) available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(viewModel.pools, id: \.name) { pool in
                            PoolCard(
                                pool: pool,
                                scrubStatus: viewModel.scrubStatuses.first(where: { $0.poolName == pool.name }),
                                viewModel: viewModel
                            )
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 600, height: 500)
        .onAppear {
            Task {
                await viewModel.refreshPools()
                await viewModel.refreshScrubStatus()
                await loadAvailableDisks()
            }
            // Auto-refresh scrub status every 5 seconds
            scrubRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                Task {
                    await viewModel.refreshScrubStatus()
                }
            }
        }
        .onDisappear {
            scrubRefreshTimer?.invalidate()
            scrubRefreshTimer = nil
        }
        .sheet(isPresented: $showCreatePool) {
            CreatePoolSheet(
                availableDisks: $availableDisks,
                onCreate: { poolName, selectedDisks, raidType in
                    Task {
                        await viewModel.createPool(name: poolName, disks: selectedDisks, raidType: raidType)
                        await loadAvailableDisks()
                    }
                },
                onCancel: {
                    showCreatePool = false
                },
                onWipe: { diskName in
                    do {
                        // Destroy all partitions on the disk
                        let _ = try await SSHConnectionManager.shared.executeCommand("gpart destroy -F /dev/\(diskName) 2>/dev/null || true")
                        // Also clear the first few sectors to remove any residual partition table
                        let _ = try await SSHConnectionManager.shared.executeCommand("dd if=/dev/zero of=/dev/\(diskName) bs=512 count=2048 2>/dev/null || true")
                        await loadAvailableDisks()
                    } catch {
                        // Ignore errors, disk list will be refreshed
                        await loadAvailableDisks()
                    }
                }
            )
        }
    }

    private func loadAvailableDisks() async {
        await MainActor.run {
            isLoadingDisks = true
        }

        do {
            // Get all disks in the system
            let geomOutput = try await SSHConnectionManager.shared.executeCommand("geom disk list")

            // Get disks currently used by ZFS - get both full paths and extract base disk names
            let zpoolOutput = try await SSHConnectionManager.shared.executeCommand("zpool status 2>/dev/null | grep -E '^\\s+(ada|da|nvd|nda|vtbd|diskid)' | awk '{print $1}'")
            var usedDisks = Set<String>()
            for line in zpoolOutput.components(separatedBy: .newlines) {
                let diskName = line.trimmingCharacters(in: .whitespaces)
                if !diskName.isEmpty {
                    usedDisks.insert(diskName)
                    // Also add the base disk name without partition suffix (p1, p2, s1, etc.)
                    let baseName = diskName.replacingOccurrences(of: "p[0-9]+$", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "s[0-9]+[a-z]?$", with: "", options: .regularExpression)
                    usedDisks.insert(baseName)
                }
            }

            // Get mounted disks
            let mountOutput = try await SSHConnectionManager.shared.executeCommand("mount | grep '^/dev/' | awk '{print $1}' | sed 's|/dev/||'")
            var mountedDisks = Set<String>()
            for line in mountOutput.components(separatedBy: .newlines) {
                let diskName = line.trimmingCharacters(in: .whitespaces)
                if !diskName.isEmpty {
                    mountedDisks.insert(diskName)
                    // Also add the base disk name
                    let baseName = diskName.replacingOccurrences(of: "p[0-9]+$", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "s[0-9]+[a-z]?$", with: "", options: .regularExpression)
                    mountedDisks.insert(baseName)
                }
            }

            // Get partition info for all disks
            let gpartOutput = try await SSHConnectionManager.shared.executeCommand("gpart show 2>/dev/null || true")
            var partitionedDisks: [String: String] = [:]  // diskName -> scheme (GPT, MBR, etc.)
            for line in gpartOutput.components(separatedBy: .newlines) {
                // Lines like "=>      40  41942960  da0  GPT  (20G)"
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("=>") {
                    let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if parts.count >= 4 {
                        let diskName = parts[3]
                        let scheme = parts.count >= 5 ? parts[4] : "Unknown"
                        partitionedDisks[diskName] = scheme
                    }
                }
            }

            // Parse geom output to get disk info
            var disks: [AvailableDisk] = []
            var currentDisk: (name: String, size: String, desc: String)? = nil

            for line in geomOutput.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.hasPrefix("Geom name:") {
                    // Save previous disk if exists and not in use by ZFS or mounted
                    if let disk = currentDisk {
                        let baseName = disk.name.replacingOccurrences(of: "p[0-9]+$", with: "", options: .regularExpression)
                        // Filter out optical drives (cd0, cd1, etc.)
                        if !disk.name.hasPrefix("cd") &&
                           !usedDisks.contains(disk.name) && !usedDisks.contains(baseName) &&
                           !mountedDisks.contains(disk.name) && !mountedDisks.contains(baseName) {
                            let hasPartitions = partitionedDisks[disk.name] != nil
                            let scheme = partitionedDisks[disk.name] ?? ""
                            disks.append(AvailableDisk(name: disk.name, size: disk.size, description: disk.desc, hasPartitions: hasPartitions, partitionScheme: scheme))
                        }
                    }
                    let name = trimmed.replacingOccurrences(of: "Geom name: ", with: "")
                    currentDisk = (name: name, size: "", desc: "")
                } else if trimmed.hasPrefix("Mediasize:") {
                    // Extract human-readable size (e.g., "Mediasize: 21474836480 (20G)")
                    if let match = trimmed.range(of: "\\([^)]+\\)", options: .regularExpression) {
                        let size = String(trimmed[match]).replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
                        currentDisk?.size = size
                    }
                } else if trimmed.hasPrefix("descr:") {
                    let desc = trimmed.replacingOccurrences(of: "descr: ", with: "")
                    currentDisk?.desc = desc
                }
            }

            // Don't forget the last disk
            if let disk = currentDisk {
                let baseName = disk.name.replacingOccurrences(of: "p[0-9]+$", with: "", options: .regularExpression)
                // Filter out optical drives (cd0, cd1, etc.)
                if !disk.name.hasPrefix("cd") &&
                   !usedDisks.contains(disk.name) && !usedDisks.contains(baseName) &&
                   !mountedDisks.contains(disk.name) && !mountedDisks.contains(baseName) {
                    let hasPartitions = partitionedDisks[disk.name] != nil
                    let scheme = partitionedDisks[disk.name] ?? ""
                    disks.append(AvailableDisk(name: disk.name, size: disk.size, description: disk.desc, hasPartitions: hasPartitions, partitionScheme: scheme))
                }
            }

            await MainActor.run {
                availableDisks = disks
                isLoadingDisks = false
            }
        } catch {
            await MainActor.run {
                availableDisks = []
                isLoadingDisks = false
            }
        }
    }
}

// MARK: - Replication Key Setup Sheet

struct ReplicationKeySetupSheet: View {
    let server: SavedServer
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var keyExists = false
    @State private var keyAuthorized = false
    @State private var isChecking = true
    @State private var isCreatingKey = false
    @State private var isAddingToRemote = false
    @State private var publicKey = ""
    @State private var errorMessage: String?
    @State private var statusMessage = "Checking replication key status..."

    private let replicationKeyPath = NSHomeDirectory() + "/.ssh/id_replication"
    private let replicationPubKeyPath = NSHomeDirectory() + "/.ssh/id_replication.pub"

    var body: some View {
        VStack(spacing: 0) {
            Text("Replication Key Setup")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                // Server info
                VStack(alignment: .leading, spacing: 8) {
                    Text("Target Server")
                        .font(.headline)
                    Text("\(server.username)@\(server.host)")
                        .font(.body)
                        .foregroundColor(.primary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                }

                Divider()

                // Status section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Setup Status")
                        .font(.headline)

                    // Step 1: Local key
                    HStack(spacing: 12) {
                        if isCreatingKey {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: keyExists ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(keyExists ? .green : .secondary)
                        }
                        VStack(alignment: .leading) {
                            Text("Replication SSH Key")
                                .font(.subheadline)
                            Text(keyExists ? "Key exists at ~/.ssh/id_replication" : "Key not found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if !keyExists && !isCreatingKey {
                            Button("Create Key") {
                                createReplicationKey()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // Step 2: Remote authorization
                    HStack(spacing: 12) {
                        if isAddingToRemote {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: keyAuthorized ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(keyAuthorized ? .green : .secondary)
                        }
                        VStack(alignment: .leading) {
                            Text("Key Authorized on Remote")
                                .font(.subheadline)
                            Text(keyAuthorized ? "Key is in remote authorized_keys" : "Key not yet authorized")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if keyExists && !keyAuthorized && !isAddingToRemote {
                            Button("Add to Remote") {
                                addKeyToRemote()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                }

                if !publicKey.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Public Key")
                            .font(.headline)
                        Text(publicKey)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding()

            Spacer()

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Continue") {
                    onComplete()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!keyExists || !keyAuthorized)
            }
            .padding()
        }
        .frame(width: 550, height: 500)
        .onAppear {
            checkKeyStatus()
        }
    }

    private func checkKeyStatus() {
        isChecking = true
        keyExists = FileManager.default.fileExists(atPath: replicationKeyPath)

        if keyExists {
            // Read public key
            if let pubKeyData = FileManager.default.contents(atPath: replicationPubKeyPath),
               let pubKey = String(data: pubKeyData, encoding: .utf8) {
                publicKey = pubKey.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Check if key is authorized on remote
            Task {
                await checkRemoteAuthorization()
            }
        } else {
            isChecking = false
        }
    }

    private func createReplicationKey() {
        isCreatingKey = true
        errorMessage = nil

        Task {
            do {
                // Create .ssh directory if needed
                let sshDir = NSHomeDirectory() + "/.ssh"
                try FileManager.default.createDirectory(atPath: sshDir, withIntermediateDirectories: true)

                // Generate key using ssh-keygen
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
                process.arguments = ["-t", "ed25519", "-f", replicationKeyPath, "-N", "", "-C", "HexBSD-replication"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                try process.run()
                process.waitUntilExit()

                await MainActor.run {
                    if process.terminationStatus == 0 {
                        keyExists = true
                        // Read the public key
                        if let pubKeyData = FileManager.default.contents(atPath: replicationPubKeyPath),
                           let pubKey = String(data: pubKeyData, encoding: .utf8) {
                            publicKey = pubKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } else {
                        errorMessage = "Failed to create SSH key"
                    }
                    isCreatingKey = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Error creating key: \(error.localizedDescription)"
                    isCreatingKey = false
                }
            }
        }
    }

    private func checkRemoteAuthorization() async {
        // Connect to server and check if our key is in authorized_keys
        do {
            let manager = SSHConnectionManager()
            let keyURL = URL(fileURLWithPath: server.keyPath)
            let authMethod = SSHAuthMethod(username: server.username, privateKeyURL: keyURL)

            try await manager.connect(host: server.host, port: server.port, authMethod: authMethod)

            // Check if our public key is in authorized_keys
            let checkCommand = "grep -F '\(publicKey.components(separatedBy: " ").dropLast().joined(separator: " "))' ~/.ssh/authorized_keys 2>/dev/null && echo 'FOUND' || echo 'NOT_FOUND'"
            let result = try await manager.executeCommand(checkCommand)

            await MainActor.run {
                keyAuthorized = result.contains("FOUND")
                isChecking = false
            }
        } catch {
            await MainActor.run {
                keyAuthorized = false
                isChecking = false
            }
        }
    }

    private func addKeyToRemote() {
        isAddingToRemote = true
        errorMessage = nil

        Task {
            do {
                let manager = SSHConnectionManager()
                let keyURL = URL(fileURLWithPath: server.keyPath)
                let authMethod = SSHAuthMethod(username: server.username, privateKeyURL: keyURL)

                try await manager.connect(host: server.host, port: server.port, authMethod: authMethod)

                // Add key to authorized_keys
                let escapedKey = publicKey.replacingOccurrences(of: "'", with: "'\\''")
                let addCommand = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(escapedKey)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
                _ = try await manager.executeCommand(addCommand)

                await MainActor.run {
                    keyAuthorized = true
                    isAddingToRemote = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to add key to remote: \(error.localizedDescription)"
                    isAddingToRemote = false
                }
            }
        }
    }
}

// MARK: - Server-to-Server SSH Setup Sheet

struct ServerToServerSSHSetupSheet: View {
    let server: SavedServer
    let status: String
    let error: String?
    let isSettingUp: Bool
    let onSetup: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Server-to-Server SSH Setup")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                // Explanation
                VStack(alignment: .leading, spacing: 8) {
                    Text("Replication Setup Required")
                        .font(.headline)
                    Text("For scheduled replication to work, the source server needs SSH access to **\(server.host)**.")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Text("This will:")
                        .font(.subheadline)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Create a replication SSH key on the source server", systemImage: "key.fill")
                        Label("Add the key to \(server.host)'s authorized_keys", systemImage: "checkmark.shield.fill")
                        Label("Update the source server's known_hosts", systemImage: "network")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                // Status area
                if isSettingUp {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text(status)
                            .font(.body)
                            .foregroundColor(.blue)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }

                if let error = error {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            .padding()

            Spacer()

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Set Up SSH") {
                    onSetup()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSettingUp)
            }
            .padding()
        }
        .frame(width: 500, height: 450)
        .onAppear {
            // Automatically start setup when sheet appears
            onSetup()
        }
    }
}

// MARK: - Replication Choice Sheet

struct ReplicationChoiceSheet: View {
    let sourceDataset: ZFSDataset
    let targetParent: ZFSDataset?
    let targetServer: SavedServer
    let onOneTime: () -> Void
    let onSchedule: (String) -> Void
    let onCancel: () -> Void

    @State private var isSettingUpSSH = false
    @State private var sshSetupError: String?
    @State private var sshSetupComplete = false
    @State private var sshSetupStatus: String = ""

    // Set up SSH between source and target servers for replication
    // Uses id_replication key (consistent with HexBSD naming convention)
    // Since the Mac app can connect to both servers, it can:
    // 1. Check/create id_replication key on source server
    // 2. Get source server's id_replication.pub
    // 3. Add it to target server's authorized_keys
    // 4. Update known_hosts on source server
    @MainActor
    private func setupSSHForReplication() async {
        isSettingUpSSH = true
        sshSetupError = nil
        sshSetupStatus = "Checking replication key on source server..."

        do {
            let targetHost = targetServer.host
            let targetUser = targetServer.username
            let replicationKeyPath = "~/.ssh/id_replication"
            let replicationPubKeyPath = "~/.ssh/id_replication.pub"

            // Step 1: Check if source server has id_replication key
            print("DEBUG: Checking for replication key at \(replicationKeyPath)")
            let keyCheckResult = try await SSHConnectionManager.shared.executeCommand(
                "test -f \(replicationKeyPath) && echo 'KEY_EXISTS' || echo 'NO_KEY'"
            )
            print("DEBUG: Key check result: \(keyCheckResult)")

            var sourcePubKey: String

            if keyCheckResult.contains("NO_KEY") {
                // Create id_replication key on source server
                print("DEBUG: Creating replication key...")
                sshSetupStatus = "Creating replication key on source server..."
                let createResult = try await SSHConnectionManager.shared.executeCommand(
                    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -f \(replicationKeyPath) -N '' -C 'HexBSD-replication' -q && echo 'KEY_CREATED'"
                )
                print("DEBUG: Key creation result: \(createResult)")
            }

            // Get the public key
            sshSetupStatus = "Reading replication public key..."
            sourcePubKey = try await SSHConnectionManager.shared.executeCommand("cat \(replicationPubKeyPath)")
            sourcePubKey = sourcePubKey.trimmingCharacters(in: .whitespacesAndNewlines)
            print("DEBUG: Public key: \(sourcePubKey.prefix(50))...")

            if sourcePubKey.isEmpty {
                throw NSError(domain: "SSHSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read replication public key"])
            }

            // Step 2: Update known_hosts on source server (add target's host key)
            sshSetupStatus = "Updating known_hosts for \(targetHost)..."
            print("DEBUG: Updating known_hosts for \(targetHost)")
            let _ = try await SSHConnectionManager.shared.executeCommand(
                "ssh-keygen -R \(targetHost) 2>/dev/null; ssh-keyscan -H \(targetHost) >> ~/.ssh/known_hosts 2>/dev/null"
            )

            // Step 3: Test if SSH connection works from source to target using the replication key
            sshSetupStatus = "Testing SSH to \(targetHost)..."
            print("DEBUG: Testing SSH connection to \(targetUser)@\(targetHost)")
            let testResult = try await SSHConnectionManager.shared.executeCommand(
                "ssh -i \(replicationKeyPath) -o BatchMode=yes -o ConnectTimeout=5 \(targetUser)@\(targetHost) 'echo SSH_OK' 2>&1; true"
            )
            print("DEBUG: SSH test result: \(testResult)")

            if testResult.contains("SSH_OK") {
                // Connection works, proceed
                sshSetupStatus = "SSH connection verified!"
                print("DEBUG: SSH connection verified!")
            } else if testResult.contains("Permission denied") || testResult.contains("publickey") {
                // Auth failure - need to add source's replication key to target's authorized_keys
                print("DEBUG: Auth failed, adding key to target...")
                sshSetupStatus = "Adding replication key to \(targetHost)..."
                try await addPublicKeyToTarget(pubKey: sourcePubKey)

                // Test again after setting up auth
                sshSetupStatus = "Verifying SSH connection..."
                let retestResult = try await SSHConnectionManager.shared.executeCommand(
                    "ssh -i \(replicationKeyPath) -o BatchMode=yes -o ConnectTimeout=5 \(targetUser)@\(targetHost) 'echo SSH_OK' 2>&1; true"
                )
                print("DEBUG: Retest result: \(retestResult)")

                if !retestResult.contains("SSH_OK") {
                    throw NSError(domain: "SSHSetup", code: 2, userInfo: [NSLocalizedDescriptionKey: "SSH setup failed. Error: \(retestResult)"])
                }

                sshSetupStatus = "SSH key authorization complete!"
            } else if testResult.contains("Could not resolve") || testResult.contains("No route to host") || testResult.contains("Connection refused") {
                // Network/connectivity issue
                throw NSError(domain: "SSHSetup", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot reach \(targetHost). Check network connectivity."])
            } else {
                // Unknown error
                throw NSError(domain: "SSHSetup", code: 5, userInfo: [NSLocalizedDescriptionKey: "SSH test failed: \(testResult)"])
            }

            sshSetupComplete = true

            // Proceed to schedule after a brief delay to show success
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            onSchedule(replicationCommand)

        } catch {
            print("DEBUG: SSH setup error: \(error)")
            sshSetupError = error.localizedDescription
            sshSetupStatus = ""
        }

        isSettingUpSSH = false
    }

    // Add source server's public key to target server's authorized_keys
    // This works because the Mac app can connect to the target server directly
    private func addPublicKeyToTarget(pubKey: String) async throws {
        // Connect to the target server using the server's configured key (the one that works)
        let targetManager = SSHConnectionManager()

        sshSetupStatus = "Connecting to \(targetServer.host) to add SSH key..."

        // Use the server's configured keyPath - this is what the user set up for this server
        let keyPath = (targetServer.keyPath as NSString).expandingTildeInPath
        print("DEBUG: Connecting to \(targetServer.host) using configured key: \(keyPath)")

        let authMethod = SSHAuthMethod(
            username: targetServer.username,
            privateKeyURL: URL(fileURLWithPath: keyPath)
        )

        try await targetManager.connect(
            host: targetServer.host,
            port: targetServer.port,
            authMethod: authMethod
        )

        // First check if the key is already in authorized_keys
        sshSetupStatus = "Checking authorized_keys on \(targetServer.host)..."
        let existingKeys = try await targetManager.executeCommand("cat ~/.ssh/authorized_keys 2>/dev/null || echo ''")

        if existingKeys.contains(pubKey) {
            print("DEBUG: Key already exists in authorized_keys")
            sshSetupStatus = "Key already authorized on \(targetServer.host)"
        } else {
            print("DEBUG: Adding key to authorized_keys")
            sshSetupStatus = "Adding SSH key to \(targetServer.host)..."

            // Add the public key to authorized_keys on the target
            // Use sort -u to avoid duplicates
            let _ = try await targetManager.executeCommand(
                "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(pubKey)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys"
            )
        }

        await targetManager.disconnect()
    }

    private var sourceBaseName: String {
        sourceDataset.name.components(separatedBy: "@")[0]
    }

    private var destinationPath: String {
        if let parent = targetParent {
            let lastComponent = sourceBaseName.components(separatedBy: "/").last ?? sourceBaseName
            return "\(parent.name)/\(lastComponent)"
        } else {
            return sourceBaseName
        }
    }

    private var replicationCommand: String {
        // Generate an incremental-capable replication command
        let dataset = sourceBaseName
        let target = "\(targetServer.username)@\(targetServer.host)"
        let dest = destinationPath

        // This command:
        // 1. Creates a timestamped snapshot
        // 2. Finds the previous auto- snapshot if any
        // 3. Does incremental send if previous exists, otherwise full send
        // NOTE: % must be escaped as \% in crontab (% means newline in cron)
        // Uses id_replication key for server-to-server SSH
        return """
SNAP="\(dataset)@auto-$(date +\\%Y\\%m\\%d-\\%H\\%M\\%S)" && zfs snapshot "$SNAP" && PREV=$(zfs list -t snapshot -o name -S creation \(dataset) 2>/dev/null | grep '@auto-' | sed -n '2p') && if [ -n "$PREV" ]; then zfs send -i "$PREV" "$SNAP" | ssh -i ~/.ssh/id_replication -o StrictHostKeyChecking=no \(target) 'zfs receive -F \(dest)'; else zfs send "$SNAP" | ssh -i ~/.ssh/id_replication -o StrictHostKeyChecking=no \(target) 'zfs receive -F \(dest)'; fi
"""
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Replicate Dataset")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                // Source info
                VStack(alignment: .leading, spacing: 8) {
                    Text("Source")
                        .font(.headline)
                    HStack {
                        Image(systemName: sourceDataset.isSnapshot ? "camera.fill" : "folder.fill")
                            .foregroundColor(sourceDataset.isSnapshot ? .orange : .blue)
                        Text(sourceDataset.name)
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                }

                // Target info
                VStack(alignment: .leading, spacing: 8) {
                    Text("Destination")
                        .font(.headline)
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundColor(.green)
                        Text("\(targetServer.name): \(destinationPath)")
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                }

                Divider()

                // Choice buttons
                Text("How would you like to replicate?")
                    .font(.headline)

                VStack(spacing: 12) {
                    // One-time option
                    Button(action: onOneTime) {
                        HStack {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("One-Time Replication")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text("Replicate now and done")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    // Scheduled option
                    Button(action: {
                        Task {
                            await setupSSHForReplication()
                        }
                    }) {
                        HStack {
                            if isSettingUpSSH {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 24, height: 24)
                            } else {
                                Image(systemName: sshSetupComplete ? "checkmark.circle.fill" : "clock.fill")
                                    .font(.title2)
                                    .foregroundColor(sshSetupComplete ? .green : .orange)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Schedule Recurring Replication")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                if isSettingUpSSH {
                                    Text(sshSetupStatus)
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                } else {
                                    Text("Set up automatic backups (hourly, daily, etc.)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSettingUpSSH)

                    // Show error if SSH setup failed
                    if let error = sshSetupError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding()

            Spacer()

            Divider()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding()
        }
        .frame(width: 500, height: 580)
    }
}

// MARK: - Schedule Replication Task Sheet

struct ScheduleReplicationTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    let command: String
    let onSave: (String, String, String, String, String, String, String) -> Void
    let onCancel: () -> Void

    @State private var frequency = 0 // 0=minute, 1=hourly, 2=daily, 3=weekly, 4=monthly
    @State private var minuteInterval = 5 // For "every X minutes" option
    @State private var selectedMinute = 0
    @State private var selectedHour = 2 // Default to 2 AM
    @State private var selectedDayOfWeek = 0
    @State private var selectedDayOfMonth = 1
    @State private var editedCommand: String

    init(command: String, onSave: @escaping (String, String, String, String, String, String, String) -> Void, onCancel: @escaping () -> Void) {
        self.command = command
        self.onSave = onSave
        self.onCancel = onCancel
        self._editedCommand = State(initialValue: command)
    }

    private var computedCronSchedule: (String, String, String, String, String) {
        switch frequency {
        case 0: // Every X minutes
            return ("*/\(minuteInterval)", "*", "*", "*", "*")
        case 1: // Hourly
            return ("\(selectedMinute)", "*", "*", "*", "*")
        case 2: // Daily
            return ("\(selectedMinute)", "\(selectedHour)", "*", "*", "*")
        case 3: // Weekly
            return ("\(selectedMinute)", "\(selectedHour)", "*", "*", "\(selectedDayOfWeek)")
        case 4: // Monthly
            return ("\(selectedMinute)", "\(selectedHour)", "\(selectedDayOfMonth)", "*", "*")
        default:
            return ("0", "2", "*", "*", "*")
        }
    }

    private var scheduleDescription: String {
        switch frequency {
        case 0:
            return "Every \(minuteInterval) minute\(minuteInterval == 1 ? "" : "s")"
        case 1:
            return "Every hour at :\(String(format: "%02d", selectedMinute))"
        case 2:
            return "Daily at \(String(format: "%02d:%02d", selectedHour, selectedMinute))"
        case 3:
            let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            return "Every \(days[selectedDayOfWeek]) at \(String(format: "%02d:%02d", selectedHour, selectedMinute))"
        case 4:
            return "Monthly on day \(selectedDayOfMonth) at \(String(format: "%02d:%02d", selectedHour, selectedMinute))"
        default:
            return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Schedule Replication")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Frequency selection
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Frequency")
                            .font(.headline)

                        Picker("Run", selection: $frequency) {
                            Text("Minute").tag(0)
                            Text("Hourly").tag(1)
                            Text("Daily").tag(2)
                            Text("Weekly").tag(3)
                            Text("Monthly").tag(4)
                        }
                        .pickerStyle(.segmented)

                        // Time settings
                        VStack(alignment: .leading, spacing: 12) {
                            if frequency == 0 {
                                // Every X minutes
                                HStack {
                                    Text("Every:")
                                        .frame(width: 80, alignment: .trailing)
                                    Stepper(value: $minuteInterval, in: 1...59) {
                                        Text("\(minuteInterval)")
                                            .frame(width: 30, alignment: .center)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color(nsColor: .controlBackgroundColor))
                                            .cornerRadius(4)
                                    }
                                    Text("minute\(minuteInterval == 1 ? "" : "s")")
                                        .foregroundColor(.secondary)
                                }
                            } else if frequency >= 2 {
                                HStack {
                                    Text("At time:")
                                        .frame(width: 80, alignment: .trailing)
                                    Picker("Hour", selection: $selectedHour) {
                                        ForEach(0..<24, id: \.self) { hour in
                                            Text(String(format: "%02d", hour)).tag(hour)
                                        }
                                    }
                                    .frame(width: 70)

                                    Text(":")

                                    Picker("Minute", selection: $selectedMinute) {
                                        ForEach([0, 15, 30, 45], id: \.self) { min in
                                            Text(String(format: "%02d", min)).tag(min)
                                        }
                                    }
                                    .frame(width: 70)
                                }
                            } else if frequency == 1 {
                                // Hourly - just pick minute
                                HStack {
                                    Text("At minute:")
                                        .frame(width: 80, alignment: .trailing)
                                    Picker("Minute", selection: $selectedMinute) {
                                        ForEach([0, 15, 30, 45], id: \.self) { min in
                                            Text(String(format: ":%02d", min)).tag(min)
                                        }
                                    }
                                    .frame(width: 80)
                                }
                            }

                            if frequency == 3 {
                                // Weekly - pick day
                                HStack {
                                    Text("On:")
                                        .frame(width: 80, alignment: .trailing)
                                    Picker("Day", selection: $selectedDayOfWeek) {
                                        Text("Sunday").tag(0)
                                        Text("Monday").tag(1)
                                        Text("Tuesday").tag(2)
                                        Text("Wednesday").tag(3)
                                        Text("Thursday").tag(4)
                                        Text("Friday").tag(5)
                                        Text("Saturday").tag(6)
                                    }
                                    .frame(width: 150)
                                }
                            }

                            if frequency == 4 {
                                // Monthly - pick day of month
                                HStack {
                                    Text("On day:")
                                        .frame(width: 80, alignment: .trailing)
                                    Picker("Day", selection: $selectedDayOfMonth) {
                                        ForEach(1...28, id: \.self) { day in
                                            Text("\(day)").tag(day)
                                        }
                                    }
                                    .frame(width: 80)
                                    Text("of the month")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        // Schedule preview
                        HStack {
                            Image(systemName: "clock")
                                .foregroundColor(.blue)
                            Text(scheduleDescription)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 8)
                    }

                    Divider()

                    // Command preview
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Replication Command")
                            .font(.headline)

                        TextEditor(text: $editedCommand)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 80)
                            .border(Color(nsColor: .separatorColor), width: 1)

                        Text("This command creates a snapshot and replicates incrementally to the target")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Schedule Task") {
                    let schedule = computedCronSchedule
                    onSave(schedule.0, schedule.1, schedule.2, schedule.3, schedule.4, editedCommand, "root")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 580, height: 550)
    }
}

// MARK: - Pools View (Legacy - can be removed later)

struct PoolsView: View {
    @ObservedObject var viewModel: ZFSViewModel
    @State private var availableDisks: [AvailableDisk] = []
    @State private var isLoadingDisks = false
    @State private var showCreatePool = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("\(viewModel.pools.count) pool(s)")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                // Show plus button - disabled if no available disks
                Button(action: {
                    showCreatePool = true
                }) {
                    Label("New Pool", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(availableDisks.isEmpty || isLoadingDisks)

                if isLoadingDisks {
                    ProgressView()
                        .controlSize(.small)
                }

            }
            .padding()

            Divider()

            // Pools list
            if viewModel.isLoadingPools {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading pools...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.pools.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "cylinder")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No ZFS Pools")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        // Boot Environments section
                        BootEnvironmentsSection()

                        ForEach(viewModel.pools, id: \.name) { pool in
                            PoolCard(
                                pool: pool,
                                scrubStatus: viewModel.scrubStatuses.first(where: { $0.poolName == pool.name }),
                                viewModel: viewModel
                            )
                        }
                    }
                    .padding()
                }
            }
        }
        .onAppear {
            Task {
                await loadAvailableDisks()
            }
        }
        .sheet(isPresented: $showCreatePool) {
            CreatePoolSheet(
                availableDisks: $availableDisks,
                onCreate: { poolName, selectedDisks, raidType in
                    Task {
                        await viewModel.createPool(name: poolName, disks: selectedDisks, raidType: raidType)
                        await loadAvailableDisks()
                    }
                },
                onCancel: {
                    showCreatePool = false
                },
                onWipe: { diskName in
                    do {
                        // Destroy all partitions on the disk
                        let _ = try await SSHConnectionManager.shared.executeCommand("gpart destroy -F /dev/\(diskName) 2>/dev/null || true")
                        // Also clear the first few sectors to remove any residual partition table
                        let _ = try await SSHConnectionManager.shared.executeCommand("dd if=/dev/zero of=/dev/\(diskName) bs=512 count=2048 2>/dev/null || true")
                        await loadAvailableDisks()
                    } catch {
                        // Ignore errors, disk list will be refreshed
                        await loadAvailableDisks()
                    }
                }
            )
        }
    }

    private func loadAvailableDisks() async {
        await MainActor.run {
            isLoadingDisks = true
        }

        do {
            // Get all disks in the system
            let geomOutput = try await SSHConnectionManager.shared.executeCommand("geom disk list")

            // Get disks currently used by ZFS - get both full paths and extract base disk names
            let zpoolOutput = try await SSHConnectionManager.shared.executeCommand("zpool status 2>/dev/null | grep -E '^\\s+(ada|da|nvd|nda|vtbd|diskid)' | awk '{print $1}'")
            var usedDisks = Set<String>()
            for line in zpoolOutput.components(separatedBy: .newlines) {
                let diskName = line.trimmingCharacters(in: .whitespaces)
                if !diskName.isEmpty {
                    usedDisks.insert(diskName)
                    // Also add the base disk name without partition suffix (p1, p2, s1, etc.)
                    let baseName = diskName.replacingOccurrences(of: "p[0-9]+$", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "s[0-9]+[a-z]?$", with: "", options: .regularExpression)
                    usedDisks.insert(baseName)
                }
            }

            // Get mounted disks
            let mountOutput = try await SSHConnectionManager.shared.executeCommand("mount | grep '^/dev/' | awk '{print $1}' | sed 's|/dev/||'")
            var mountedDisks = Set<String>()
            for line in mountOutput.components(separatedBy: .newlines) {
                let diskName = line.trimmingCharacters(in: .whitespaces)
                if !diskName.isEmpty {
                    mountedDisks.insert(diskName)
                    // Also add the base disk name
                    let baseName = diskName.replacingOccurrences(of: "p[0-9]+$", with: "", options: .regularExpression)
                        .replacingOccurrences(of: "s[0-9]+[a-z]?$", with: "", options: .regularExpression)
                    mountedDisks.insert(baseName)
                }
            }

            // Get partition info for all disks
            let gpartOutput = try await SSHConnectionManager.shared.executeCommand("gpart show 2>/dev/null || true")
            var partitionedDisks: [String: String] = [:]  // diskName -> scheme (GPT, MBR, etc.)
            for line in gpartOutput.components(separatedBy: .newlines) {
                // Lines like "=>      40  41942960  da0  GPT  (20G)"
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("=>") {
                    let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if parts.count >= 4 {
                        let diskName = parts[3]
                        let scheme = parts.count >= 5 ? parts[4] : "Unknown"
                        partitionedDisks[diskName] = scheme
                    }
                }
            }

            // Parse geom output to get disk info
            var disks: [AvailableDisk] = []
            var currentDisk: (name: String, size: String, desc: String)? = nil

            for line in geomOutput.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.hasPrefix("Geom name:") {
                    // Save previous disk if exists and not in use by ZFS or mounted
                    if let disk = currentDisk {
                        let baseName = disk.name.replacingOccurrences(of: "p[0-9]+$", with: "", options: .regularExpression)
                        // Filter out optical drives (cd0, cd1, etc.)
                        if !disk.name.hasPrefix("cd") &&
                           !usedDisks.contains(disk.name) && !usedDisks.contains(baseName) &&
                           !mountedDisks.contains(disk.name) && !mountedDisks.contains(baseName) {
                            let hasPartitions = partitionedDisks[disk.name] != nil
                            let scheme = partitionedDisks[disk.name] ?? ""
                            disks.append(AvailableDisk(name: disk.name, size: disk.size, description: disk.desc, hasPartitions: hasPartitions, partitionScheme: scheme))
                        }
                    }
                    let name = trimmed.replacingOccurrences(of: "Geom name: ", with: "")
                    currentDisk = (name: name, size: "", desc: "")
                } else if trimmed.hasPrefix("Mediasize:") {
                    // Extract human-readable size (e.g., "Mediasize: 21474836480 (20G)")
                    if let match = trimmed.range(of: "\\([^)]+\\)", options: .regularExpression) {
                        let size = String(trimmed[match]).replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
                        currentDisk?.size = size
                    }
                } else if trimmed.hasPrefix("descr:") {
                    let desc = trimmed.replacingOccurrences(of: "descr: ", with: "")
                    currentDisk?.desc = desc
                }
            }

            // Don't forget the last disk
            if let disk = currentDisk {
                let baseName = disk.name.replacingOccurrences(of: "p[0-9]+$", with: "", options: .regularExpression)
                // Filter out optical drives (cd0, cd1, etc.)
                if !disk.name.hasPrefix("cd") &&
                   !usedDisks.contains(disk.name) && !usedDisks.contains(baseName) &&
                   !mountedDisks.contains(disk.name) && !mountedDisks.contains(baseName) {
                    let hasPartitions = partitionedDisks[disk.name] != nil
                    let scheme = partitionedDisks[disk.name] ?? ""
                    disks.append(AvailableDisk(name: disk.name, size: disk.size, description: disk.desc, hasPartitions: hasPartitions, partitionScheme: scheme))
                }
            }

            await MainActor.run {
                availableDisks = disks
                isLoadingDisks = false
            }
        } catch {
            await MainActor.run {
                availableDisks = []
                isLoadingDisks = false
            }
        }
    }
}

// MARK: - Boot Environments Section

struct BootEnvironmentsSection: View {
    @StateObject private var viewModel = BootEnvironmentsViewModel()
    @State private var showError = false
    @State private var showCreateBE = false
    @State private var showRenameBE = false
    @State private var selectedBE: BootEnvironment?

    var body: some View {
        VStack(spacing: 0) {
            // Header - Always visible
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Boot Environments")
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text("\(viewModel.bootEnvironments.count) environment(s)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Content - Always expanded
            VStack(spacing: 12) {
                    // Actions toolbar
                    HStack {
                        if let be = selectedBE {
                            // Actions for selected BE
                            if !be.active {
                                Button(action: {
                                    Task {
                                        await viewModel.activate(be: be.name)
                                    }
                                }) {
                                    Label("Activate", systemImage: "power")
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            if be.mountpoint == "-" {
                                Button(action: {
                                    Task {
                                        await viewModel.mount(be: be.name)
                                    }
                                }) {
                                    Label("Mount", systemImage: "arrow.down.circle")
                                }
                                .buttonStyle(.bordered)
                            } else if be.mountpoint != "/" {
                                Button(action: {
                                    Task {
                                        await viewModel.unmount(be: be.name)
                                    }
                                }) {
                                    Label("Unmount", systemImage: "eject")
                                }
                                .buttonStyle(.bordered)
                            }

                            if !be.active {
                                Button(action: {
                                    showRenameBE = true
                                }) {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .buttonStyle(.bordered)
                            }

                            if !be.active {
                                Button(action: {
                                    Task {
                                        await viewModel.delete(be: be.name)
                                    }
                                }) {
                                    Label("Delete", systemImage: "trash")
                                }
                                .buttonStyle(.bordered)
                            }
                        }

                        Spacer()

                        Button(action: {
                            showCreateBE = true
                        }) {
                            Label("Create", systemImage: "plus.circle")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            Task {
                                await viewModel.refresh()
                            }
                        }) {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 8)

                    // Boot environments list
                    if viewModel.isLoading {
                        VStack(spacing: 20) {
                            ProgressView()
                            Text("Loading boot environments...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(height: 100)
                    } else if viewModel.bootEnvironments.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("No Boot Environments")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("Boot environments allow you to snapshot and revert your system")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(viewModel.bootEnvironments) { be in
                                BootEnvironmentRow(bootEnvironment: be)
                                    .padding(8)
                                    .background(selectedBE?.id == be.id ? Color.accentColor.opacity(0.2) : Color.clear)
                                    .cornerRadius(6)
                                    .onTapGesture {
                                        selectedBE = be
                                    }
                            }
                        }
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }
        .cornerRadius(8)
        .alert("Boot Environment Error", isPresented: $showError) {
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
        .sheet(isPresented: $showCreateBE) {
            CreateBootEnvironmentSheet(
                existingBEs: viewModel.bootEnvironments.map { $0.name },
                onCreate: { name, source in
                    Task {
                        await viewModel.create(name: name, source: source)
                        showCreateBE = false
                    }
                },
                onCancel: {
                    showCreateBE = false
                }
            )
        }
        .sheet(isPresented: $showRenameBE) {
            if let be = selectedBE {
                RenameBootEnvironmentSheet(
                    currentName: be.name,
                    existingBEs: viewModel.bootEnvironments.map { $0.name },
                    onRename: { newName in
                        Task {
                            await viewModel.rename(oldName: be.name, newName: newName)
                            showRenameBE = false
                            selectedBE = nil
                        }
                    },
                    onCancel: {
                        showRenameBE = false
                    }
                )
            }
        }
        .onAppear {
            if viewModel.bootEnvironments.isEmpty {
                Task {
                    await viewModel.loadBootEnvironments()
                }
            }
        }
    }
}

struct PoolCard: View {
    let pool: ZFSPool
    let scrubStatus: ZFSScrubStatus?
    @ObservedObject var viewModel: ZFSViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header - Always visible
            HStack(spacing: 12) {
                Image(systemName: "cylinder.fill")
                    .font(.title2)
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text(pool.name)
                        .font(.title3)
                        .fontWeight(.semibold)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(pool.healthColor)
                            .frame(width: 8, height: 8)
                        Text(pool.health)
                            .font(.caption)
                            .foregroundColor(pool.healthColor)
                    }
                }

                Spacer()

                // Capacity indicator
                VStack(alignment: .trailing, spacing: 4) {
                    Text(pool.capacity)
                        .font(.headline)
                    Text("used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()

            // Pool details - Always visible
            Divider()

            VStack(spacing: 16) {
                    // Pool stats
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 16) {
                        StatItem(label: "Size", value: pool.size)
                        StatItem(label: "Allocated", value: pool.allocated)
                        StatItem(label: "Free", value: pool.free)
                        StatItem(label: "Fragmentation", value: pool.fragmentation)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Capacity")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ProgressView(value: pool.capacityPercentage, total: 100)
                                .frame(height: 8)
                        }
                    }

                    Divider()

                    // Scrub status and controls
                    if let scrub = scrubStatus {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "waveform.path.ecg")
                                    .foregroundColor(.blue)
                                Text("Scrub Status")
                                    .font(.headline)

                                Spacer()

                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(scrub.statusColor)
                                        .frame(width: 8, height: 8)
                                    Text(scrub.state)
                                        .font(.caption)
                                        .foregroundColor(scrub.statusColor)
                                }
                            }

                            // Progress bar if in progress
                            if scrub.isInProgress, let progress = scrub.progress {
                                VStack(spacing: 4) {
                                    ProgressView(value: progress, total: 100)
                                    HStack {
                                        Text(String(format: "%.1f%%", progress))
                                            .font(.caption)
                                        Spacer()
                                        if let scanned = scrub.scanned {
                                            Text("Scanned: \(scanned)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }

                            // Details
                            if let duration = scrub.duration {
                                HStack {
                                    Text("Duration:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(duration)
                                        .font(.caption)
                                }
                            }

                            HStack {
                                Text("Errors:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(scrub.errors)")
                                    .font(.caption)
                                    .foregroundColor(scrub.errors > 0 ? .red : .primary)
                            }

                            // Actions
                            HStack {
                                if scrub.isInProgress {
                                    Button(action: {
                                        Task {
                                            await viewModel.stopScrub(pool: pool.name)
                                        }
                                    }) {
                                        Label("Stop Scrub", systemImage: "stop.fill")
                                    }
                                    .buttonStyle(.bordered)
                                } else {
                                    Button(action: {
                                        Task {
                                            await viewModel.startScrub(pool: pool.name)
                                        }
                                    }) {
                                        Label("Start Scrub", systemImage: "play.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    } else {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading scrub status...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1)
        )
    }
}

struct StatItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Datasets View

// Helper class for hierarchical dataset structure
class DatasetNode: Identifiable, ObservableObject {
    let id = UUID()
    let dataset: ZFSDataset
    @Published var children: [DatasetNode] = []
    @Published var isExpanded: Bool = false

    // For grouping snapshots under a single collapsible node
    var isSnapshotsGroup: Bool = false
    var snapshotCount: Int = 0

    var hasChildren: Bool {
        !children.isEmpty
    }

    init(dataset: ZFSDataset) {
        self.dataset = dataset
    }

    // Create a synthetic "Snapshots" group node
    static func snapshotsGroup(parentName: String, snapshots: [ZFSDataset]) -> DatasetNode {
        // Create a placeholder dataset for the group
        let groupDataset = ZFSDataset(
            name: "\(parentName)/@snapshots",
            used: "-",
            available: "-",
            referenced: "-",
            mountpoint: "-",
            compression: "-",
            compressRatio: "-",
            quota: "-",
            reservation: "-",
            type: "snapshots_group",
            sharenfs: "-"
        )
        let node = DatasetNode(dataset: groupDataset)
        node.isSnapshotsGroup = true
        node.snapshotCount = snapshots.count
        node.isExpanded = false  // Collapsed by default

        // Add individual snapshots as children of this group
        for snapshot in snapshots {
            node.children.append(DatasetNode(dataset: snapshot))
        }

        return node
    }
}

struct DatasetsView: View {
    @ObservedObject var viewModel: ZFSViewModel
    @EnvironmentObject var appState: AppState
    @State private var selectedDataset: ZFSDataset?
    @State private var showCreateSnapshot = false
    @State private var showCloneDataset = false
    @State private var showCreateDataset = false
    @State private var showCreateZvol = false
    @State private var showShareDataset = false
    @State private var showModifyProperties = false
    @State private var snapshotName = ""
    @State private var cloneDestination = ""
    @State private var expandedDatasets: Set<String> = []
    @State private var selectedSnapshots: Set<String> = []  // Multi-select for snapshots
    @State private var selectedReplicationServer: String? = nil
    @State private var savedServers: [SavedServer] = []
    @State private var targetManager: SSHConnectionManager?
    @State private var targetDatasets: [ZFSDataset] = []
    @State private var targetPools: [ZFSPool] = []
    @State private var isLoadingTarget = false
    @State private var expandedTargetDatasets: Set<String> = []
    @State private var draggedDataset: ZFSDataset?
    @State private var pendingReplicationServer: SavedServer? = nil
    @State private var pendingReplicationInfo: PendingReplication? = nil
    @State private var pendingScheduledReplication: ScheduledReplicationInfo? = nil
    @State private var pendingServerToServerSetup: SavedServer? = nil
    @State private var serverToServerSetupStatus: String = ""
    @State private var serverToServerSetupError: String? = nil
    @State private var isSettingUpServerToServer = false
    @State private var onlineServers: Set<String> = []  // Server IDs that are online
    @State private var hasCheckedServers = false  // True after initial check completes
    @State private var showServerPicker = false
    @State private var serverCheckTimer: Timer?

    struct PendingReplication: Identifiable {
        let id = UUID()
        let source: ZFSDataset
        let target: ZFSDataset?
        let server: SavedServer
    }

    struct ScheduledReplicationInfo: Identifiable {
        let id = UUID()
        let command: String
    }

    private var datasetsCount: Int {
        viewModel.datasets.filter { !$0.isSnapshot }.count
    }

    private var snapshotsCount: Int {
        viewModel.datasets.filter { $0.isSnapshot }.count
    }

    // Build hierarchical tree from flat dataset list
    private func buildHierarchy() -> [DatasetNode] {
        var nodes: [String: DatasetNode] = [:]
        var rootNodes: [DatasetNode] = []

        // Create nodes for all datasets (not snapshots)
        let datasets = viewModel.datasets.filter { !$0.isSnapshot }.sorted { $0.name < $1.name }

        for dataset in datasets {
            let node = DatasetNode(dataset: dataset)
            node.isExpanded = expandedDatasets.contains(dataset.name)
            nodes[dataset.name] = node
        }

        // Build parent-child relationships
        for node in nodes.values {
            let name = node.dataset.name

            // Find parent by removing last component
            if let lastSlash = name.lastIndex(of: "/") {
                let parentName = String(name[..<lastSlash])
                if let parent = nodes[parentName] {
                    parent.children.append(node)
                } else {
                    // Parent doesn't exist (maybe filtered out), add as root
                    rootNodes.append(node)
                }
            } else {
                // No slash means it's a pool-level dataset (root)
                rootNodes.append(node)
                // Expand root datasets by default
                if !expandedDatasets.contains(name) {
                    expandedDatasets.insert(name)
                    node.isExpanded = true
                }
            }
        }

        // Sort children for each node
        for node in nodes.values {
            node.children.sort { $0.dataset.name < $1.dataset.name }
        }

        // Auto-expand protected datasets so users can see unprotected children
        for node in nodes.values {
            if node.dataset.isProtected && node.hasChildren {
                if !expandedDatasets.contains(node.dataset.name) {
                    expandedDatasets.insert(node.dataset.name)
                    node.isExpanded = true
                }
            }
        }

        // Group snapshots by parent dataset and add as a collapsible "Snapshots" node
        let snapshots = viewModel.datasets.filter { $0.isSnapshot }.sorted { $0.name < $1.name }
        var snapshotsByParent: [String: [ZFSDataset]] = [:]
        for snapshot in snapshots {
            let parentName = snapshot.name.components(separatedBy: "@")[0]
            snapshotsByParent[parentName, default: []].append(snapshot)
        }

        for (parentName, parentSnapshots) in snapshotsByParent {
            if let parent = nodes[parentName], !parentSnapshots.isEmpty {
                let snapshotsGroupNode = DatasetNode.snapshotsGroup(parentName: parentName, snapshots: parentSnapshots)
                // Sync expanded state with expandedDatasets
                snapshotsGroupNode.isExpanded = expandedDatasets.contains(snapshotsGroupNode.dataset.name)
                parent.children.insert(snapshotsGroupNode, at: 0)  // Insert at beginning
            }
        }

        return rootNodes.sorted { $0.dataset.name < $1.dataset.name }
    }

    // Build hierarchical tree from target datasets
    private func buildTargetHierarchy() -> [DatasetNode] {
        var nodes: [String: DatasetNode] = [:]
        var rootNodes: [DatasetNode] = []

        // Create nodes for all datasets (not snapshots)
        let datasets = targetDatasets.filter { !$0.isSnapshot }.sorted { $0.name < $1.name }

        for dataset in datasets {
            let node = DatasetNode(dataset: dataset)
            node.isExpanded = expandedTargetDatasets.contains(dataset.name)
            nodes[dataset.name] = node
        }

        // Build parent-child relationships
        for node in nodes.values {
            let name = node.dataset.name

            // Find parent by removing last component
            if let lastSlash = name.lastIndex(of: "/") {
                let parentName = String(name[..<lastSlash])
                if let parent = nodes[parentName] {
                    parent.children.append(node)
                } else {
                    // Parent doesn't exist (maybe filtered out), add as root
                    rootNodes.append(node)
                }
            } else {
                // No slash means it's a pool-level dataset (root)
                rootNodes.append(node)
                // Expand root datasets by default
                if !expandedTargetDatasets.contains(name) {
                    expandedTargetDatasets.insert(name)
                    node.isExpanded = true
                }
            }
        }

        // Sort children for each node
        for node in nodes.values {
            node.children.sort { $0.dataset.name < $1.dataset.name }
        }

        // Add snapshots as children of their parent datasets
        let snapshots = targetDatasets.filter { $0.isSnapshot }.sorted { $0.name < $1.name }
        for snapshot in snapshots {
            let parentName = snapshot.name.components(separatedBy: "@")[0]
            if let parent = nodes[parentName] {
                let snapshotNode = DatasetNode(dataset: snapshot)
                parent.children.append(snapshotNode)
            }
        }

        return rootNodes.sorted { $0.dataset.name < $1.dataset.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar with replication server picker
            HStack {
                Text("\(datasetsCount) dataset(s), \(snapshotsCount) snapshot(s)")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                // Replication server picker
                HStack(spacing: 8) {
                    Text("Replicate to:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button(action: {
                        showServerPicker = true
                        // Check all servers when dropdown is clicked
                        Task {
                            await checkServersOnline()
                        }
                    }) {
                        HStack {
                            if let serverId = selectedReplicationServer,
                               let server = savedServers.first(where: { $0.id.uuidString == serverId }) {
                                Text(server.name)
                            } else {
                                Text("Select Server...")
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(width: 180)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showServerPicker, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            // None option
                            Button(action: {
                                selectedReplicationServer = nil
                                showServerPicker = false
                                handleServerSelection(nil)
                            }) {
                                HStack {
                                    Text("None")
                                    Spacer()
                                    if selectedReplicationServer == nil {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .padding(.vertical, 4)

                            // Server list
                            ForEach(savedServers, id: \.id) { server in
                                let isOnline = onlineServers.contains(server.id.uuidString)
                                Button(action: {
                                    if hasCheckedServers && isOnline {
                                        selectedReplicationServer = server.id.uuidString
                                        showServerPicker = false
                                        handleServerSelection(server.id.uuidString)
                                    }
                                }) {
                                    HStack {
                                        if !hasCheckedServers {
                                            ProgressView()
                                                .controlSize(.small)
                                                .frame(width: 10, height: 10)
                                        } else {
                                            Circle()
                                                .fill(isOnline ? Color.green : Color.red)
                                                .frame(width: 8, height: 8)
                                        }
                                        Text(server.name)
                                            .foregroundColor(hasCheckedServers && isOnline ? .primary : .secondary)
                                        Spacer()
                                        if selectedReplicationServer == server.id.uuidString {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.accentColor)
                                        }
                                        if hasCheckedServers && !isOnline {
                                            Text("offline")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!hasCheckedServers || !isOnline)
                            }
                        }
                        .frame(minWidth: 200)
                        .padding(.vertical, 8)
                    }

                    // Show setup progress or error
                    if isSettingUpServerToServer {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text(serverToServerSetupStatus)
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    } else if let error = serverToServerSetupError {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding()

            Divider()

            // Show split view if server selected, otherwise normal view
            if selectedReplicationServer != nil {
                replicationSplitView
            } else {
                datasetManagementView
            }
        }
        .onAppear {
            loadSavedServers()
            // Initial check immediately
            Task {
                await checkServersOnline()
            }
            // Then recheck every 5 seconds
            serverCheckTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                Task {
                    await checkServersOnline()
                }
            }
        }
        .onDisappear {
            serverCheckTimer?.invalidate()
            serverCheckTimer = nil
        }
        .sheet(isPresented: $showCreateSnapshot) {
            if let dataset = selectedDataset {
                CreateSnapshotSheet(
                    datasetName: dataset.name,
                    snapshotName: $snapshotName,
                    onCreate: {
                        Task {
                            await viewModel.createSnapshot(dataset: dataset.name, snapshotName: snapshotName)
                            // Expand parent dataset and snapshots group to show new snapshot
                            expandedDatasets.insert(dataset.name)
                            expandedDatasets.insert("\(dataset.name)/@snapshots")
                            showCreateSnapshot = false
                        }
                    },
                    onCancel: {
                        showCreateSnapshot = false
                    }
                )
            }
        }
        .sheet(isPresented: $showCloneDataset) {
            if let dataset = selectedDataset {
                CloneDatasetSheet(
                    sourceName: dataset.name,
                    isSnapshot: dataset.isSnapshot,
                    destination: $cloneDestination,
                    onClone: {
                        Task {
                            await viewModel.cloneDataset(source: dataset.name, isSnapshot: dataset.isSnapshot, destination: cloneDestination)
                            showCloneDataset = false
                        }
                    },
                    onCancel: {
                        showCloneDataset = false
                    }
                )
            }
        }
        .sheet(isPresented: $showCreateDataset) {
            if let dataset = selectedDataset {
                CreateDatasetSheet(
                    parentDataset: dataset.name,
                    onCreate: { name, properties in
                        Task {
                            await viewModel.createDataset(name: name, type: "filesystem", properties: properties)
                            // Expand parent dataset to show new child
                            expandedDatasets.insert(dataset.name)
                            showCreateDataset = false
                        }
                    },
                    onCancel: {
                        showCreateDataset = false
                    }
                )
            }
        }
        .sheet(isPresented: $showCreateZvol) {
            if let dataset = selectedDataset {
                CreateZvolSheet(
                    parentDataset: dataset.name,
                    onCreate: { name, properties in
                        Task {
                            await viewModel.createDataset(name: name, type: "volume", properties: properties)
                            // Expand parent dataset to show new ZVOL
                            expandedDatasets.insert(dataset.name)
                            showCreateZvol = false
                        }
                    },
                    onCancel: {
                        showCreateZvol = false
                    }
                )
            }
        }
        .sheet(isPresented: $showShareDataset) {
            if let dataset = selectedDataset {
                ShareDatasetSheet(
                    dataset: dataset,
                    onSave: { shareOptions in
                        Task {
                            await viewModel.setProperty(dataset: dataset.name, property: "sharenfs", value: shareOptions)
                            await viewModel.refreshDatasets()
                            showShareDataset = false
                        }
                    },
                    onCancel: {
                        showShareDataset = false
                    }
                )
            }
        }
        .sheet(isPresented: $showModifyProperties) {
            if let dataset = selectedDataset {
                ModifyPropertiesSheet(
                    dataset: dataset,
                    onSave: { property, value in
                        Task {
                            await viewModel.setProperty(dataset: dataset.name, property: property, value: value)
                            await viewModel.refreshDatasets()
                            showModifyProperties = false
                        }
                    },
                    onCancel: {
                        showModifyProperties = false
                    }
                )
            }
        }
        .sheet(item: $pendingReplicationInfo) { info in
            ReplicationChoiceSheet(
                sourceDataset: info.source,
                targetParent: info.target,
                targetServer: info.server,
                onOneTime: {
                    pendingReplicationInfo = nil
                    Task {
                        await replicateDataset(source: info.source, targetParent: info.target)
                    }
                },
                onSchedule: { command in
                    pendingReplicationInfo = nil
                    pendingScheduledReplication = ScheduledReplicationInfo(command: command)
                },
                onCancel: {
                    pendingReplicationInfo = nil
                }
            )
        }
        .sheet(item: $pendingScheduledReplication) { info in
            ScheduleReplicationTaskSheet(
                command: info.command,
                onSave: { minute, hour, dayOfMonth, month, dayOfWeek, command, user in
                    Task {
                        do {
                            try await SSHConnectionManager.shared.addCronTask(
                                minute: minute,
                                hour: hour,
                                dayOfMonth: dayOfMonth,
                                month: month,
                                dayOfWeek: dayOfWeek,
                                command: command,
                                user: user
                            )
                            // Navigate to Tasks page after successful scheduling
                            await MainActor.run {
                                pendingScheduledReplication = nil
                                NotificationCenter.default.post(name: .navigateToTasks, object: nil)
                            }
                        } catch {
                            await MainActor.run {
                                viewModel.error = "Failed to schedule task: \(error.localizedDescription)"
                            }
                        }
                    }
                },
                onCancel: {
                    pendingScheduledReplication = nil
                }
            )
        }
    }

    private var datasetManagementView: some View {
        VStack(spacing: 0) {
            // Pool statistics
            if !viewModel.pools.isEmpty {
                HStack(spacing: 20) {
                    ForEach(viewModel.pools, id: \.name) { pool in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pool.name)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack(spacing: 12) {
                                Label(pool.allocated, systemImage: "cylinder.fill")
                                    .font(.callout)
                                    .foregroundColor(.blue)
                                Text("used")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                Label(pool.free, systemImage: "cylinder")
                                    .font(.callout)
                                    .foregroundColor(.green)
                                Text("available")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top)
            }

            // Action toolbar
            HStack {
                // Show selected snapshots count and delete button
                if !selectedSnapshots.isEmpty {
                    Text("\(selectedSnapshots.count) snapshot\(selectedSnapshots.count == 1 ? "" : "s") selected")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: {
                        selectedSnapshots.removeAll()
                    }) {
                        Text("Clear")
                    }
                    .buttonStyle(.bordered)

                    Button(action: {
                        confirmDeleteSelectedSnapshots()
                    }) {
                        Label("Delete Selected", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                Spacer()

                if let dataset = selectedDataset {
                    if dataset.isSnapshot {
                        // Snapshot actions
                        Button(action: {
                            Task {
                                await viewModel.rollbackSnapshot(snapshot: dataset.name)
                            }
                        }) {
                            Label("Rollback", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            cloneDestination = ""
                            showCloneDataset = true
                        }) {
                            Label("Clone", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            confirmDeleteSnapshot(dataset)
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        // Dataset actions
                        Button(action: {
                            showCreateDataset = true
                        }) {
                            Label("New Dataset", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: {
                            showCreateZvol = true
                        }) {
                            Label("New ZVOL", systemImage: "externaldrive.fill")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            snapshotName = ""
                            showCreateSnapshot = true
                        }) {
                            Label("Snapshot", systemImage: "camera")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            cloneDestination = ""
                            showCloneDataset = true
                        }) {
                            Label("Clone", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            showShareDataset = true
                        }) {
                            Label("Share", systemImage: "network")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            showModifyProperties = true
                        }) {
                            Label("Properties", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            confirmDeleteDataset(dataset)
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .disabled(dataset.isProtected)
                        .help(dataset.protectionReason ?? "Delete this dataset")
                    }
                }
            }
            .padding()

            Divider()

            // Datasets hierarchical list
            if viewModel.isLoadingDatasets {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading datasets...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.datasets.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "folder")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Datasets or Snapshots")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Datasets and snapshots will appear here")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    // Column headers
                    HStack(spacing: 0) {
                        Text("Name")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(width: 300, alignment: .leading)
                            .padding(.leading, 8)

                        Text("Used")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)

                        Text("Available")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)

                        Text("Compression")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(width: 120, alignment: .leading)

                        Text("Quota")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)

                        Text("Mountpoint")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(minWidth: 150, alignment: .leading)

                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(buildHierarchy()) { node in
                                DatasetNodeView(
                                    node: node,
                                    level: 0,
                                    expandedDatasets: $expandedDatasets,
                                    selectedDataset: $selectedDataset,
                                    selectedSnapshots: $selectedSnapshots
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var replicationSplitView: some View {
        HSplitView {
            // Source (local) side
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack {
                        Text("Source (Local)")
                            .font(.headline)
                        Spacer()
                        Text("Drag to target to replicate")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // Invisible spacer to match target's refresh button
                        Button(action: {}) {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .hidden()
                    }

                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text("Note: Source server must have SSH key access to target server for replication.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .padding()

                // Pool statistics for source
                if !viewModel.pools.isEmpty {
                    HStack(spacing: 20) {
                        ForEach(viewModel.pools, id: \.name) { pool in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pool.name)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                HStack(spacing: 12) {
                                    Label(pool.allocated, systemImage: "cylinder.fill")
                                        .font(.callout)
                                        .foregroundColor(.blue)
                                    Text("used")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    Label(pool.free, systemImage: "cylinder")
                                        .font(.callout)
                                        .foregroundColor(.green)
                                    Text("available")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                }

                Divider()

                // Source datasets list (draggable)
                VStack(spacing: 0) {
                    // Column headers
                    HStack(spacing: 0) {
                        Text("Name")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 8)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()

                    List(selection: $selectedDataset) {
                        ForEach(buildHierarchy()) { node in
                            DraggableDatasetNodeView(
                                node: node,
                                level: 0,
                                expandedDatasets: $expandedDatasets,
                                selectedDataset: $selectedDataset,
                                onDragStarted: { dataset in
                                    draggedDataset = dataset
                                }
                            )
                        }
                    }
                }
            }
            .frame(minWidth: 300)

            // Target (remote) side
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack {
                        if let serverId = selectedReplicationServer,
                           let server = savedServers.first(where: { $0.id.uuidString == serverId }) {
                            Text("Target: \(server.name)")
                                .font(.headline)
                        }
                        Spacer()
                        Button(action: {
                            Task {
                                await loadTargetData()
                            }
                        }) {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text("Note: Target server must have source server's public key in ~/.ssh/authorized_keys for root user.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .padding()

                // Pool statistics for target
                if !targetPools.isEmpty {
                    HStack(spacing: 20) {
                        ForEach(targetPools, id: \.name) { pool in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pool.name)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                HStack(spacing: 12) {
                                    Label(pool.allocated, systemImage: "cylinder.fill")
                                        .font(.callout)
                                        .foregroundColor(.blue)
                                    Text("used")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    Label(pool.free, systemImage: "cylinder")
                                        .font(.callout)
                                        .foregroundColor(.green)
                                    Text("available")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                }

                Divider()

                if isLoadingTarget {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Loading target datasets...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if targetDatasets.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No datasets found")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("The target server has no ZFS datasets")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        // Column headers
                        HStack(spacing: 0) {
                            Text("Name")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 8)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                        .background(Color(nsColor: .controlBackgroundColor))

                        Divider()

                        List {
                            ForEach(buildTargetHierarchy()) { node in
                                DroppableDatasetNodeView(
                                    node: node,
                                    level: 0,
                                    expandedDatasets: $expandedTargetDatasets,
                                    onDropped: { targetDataset in
                                        if let sourceDataset = draggedDataset,
                                           let serverId = selectedReplicationServer,
                                           let server = savedServers.first(where: { $0.id.uuidString == serverId }) {
                                            pendingReplicationInfo = PendingReplication(
                                                source: sourceDataset,
                                                target: targetDataset,
                                                server: server
                                            )
                                        }
                                    }
                                )
                            }
                        }
                        .onDrop(of: [.text], isTargeted: nil) { providers in
                            // Drop on empty space - replicate to root
                            if let sourceDataset = draggedDataset,
                               let serverId = selectedReplicationServer,
                               let server = savedServers.first(where: { $0.id.uuidString == serverId }) {
                                pendingReplicationInfo = PendingReplication(
                                    source: sourceDataset,
                                    target: nil,
                                    server: server
                                )
                                return true
                            }
                            return false
                        }
                    }
                }
            }
            .frame(minWidth: 300)
        }
    }

    private func loadSavedServers() {
        if let data = UserDefaults.standard.data(forKey: "savedServers"),
           let decoded = try? JSONDecoder().decode([SavedServer].self, from: data) {
            // Filter out the currently connected server
            savedServers = decoded.filter { $0.host != SSHConnectionManager.shared.serverAddress }
        }
    }

    // Check connectivity to each saved server (quick TCP check to port 22)
    private func checkServersOnline() async {
        var online: Set<String> = []

        await withTaskGroup(of: (String, Bool).self) { group in
            for server in savedServers {
                group.addTask {
                    let isOnline = await self.checkHostReachable(host: server.host, port: server.port)
                    return (server.id.uuidString, isOnline)
                }
            }

            for await (serverId, isOnline) in group {
                if isOnline {
                    online.insert(serverId)
                }
            }
        }

        await MainActor.run {
            onlineServers = online
            hasCheckedServers = true
        }
    }

    // Quick TCP connectivity check
    private func checkHostReachable(host: String, port: Int) async -> Bool {
        return await withCheckedContinuation { continuation in
            var hasResumed = false
            let lock = NSLock()

            func resumeOnce(with result: Bool) {
                lock.lock()
                defer { lock.unlock() }
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(returning: result)
                }
            }

            let socket = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )

            socket.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    socket.cancel()
                    resumeOnce(with: true)
                case .failed, .cancelled:
                    resumeOnce(with: false)
                default:
                    break
                }
            }

            socket.start(queue: .global())

            // Timeout after 2 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                socket.cancel()
                resumeOnce(with: false)
            }
        }
    }

    private func handleServerSelection(_ serverId: String?) {
        guard let serverId = serverId,
              let server = savedServers.first(where: { $0.id.uuidString == serverId }) else {
            targetManager = nil
            targetDatasets = []
            return
        }

        // Do all SSH setup automatically, then connect
        Task {
            await setupAndConnectToTarget(server)
        }
    }

    // Unified function to set up all SSH requirements and connect to target
    @MainActor
    private func setupAndConnectToTarget(_ server: SavedServer) async {
        isSettingUpServerToServer = true
        serverToServerSetupError = nil
        serverToServerSetupStatus = "Setting up replication..."

        do {
            let targetHost = server.host
            let targetUser = server.username
            let replicationKeyPath = "~/.ssh/id_replication"
            let replicationPubKeyPath = "~/.ssh/id_replication.pub"

            // Step 1: Ensure source server has id_replication key
            serverToServerSetupStatus = "Checking replication key..."
            let keyCheckResult = try await SSHConnectionManager.shared.executeCommand(
                "test -f \(replicationKeyPath) && echo 'KEY_EXISTS' || echo 'NO_KEY'"
            )

            var sourcePubKey: String

            if keyCheckResult.contains("NO_KEY") {
                serverToServerSetupStatus = "Creating replication key..."
                let _ = try await SSHConnectionManager.shared.executeCommand(
                    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -f \(replicationKeyPath) -N '' -C 'HexBSD-replication' -q"
                )
            }

            // Get the public key
            sourcePubKey = try await SSHConnectionManager.shared.executeCommand("cat \(replicationPubKeyPath)")
            sourcePubKey = sourcePubKey.trimmingCharacters(in: .whitespacesAndNewlines)

            if sourcePubKey.isEmpty {
                throw NSError(domain: "SSHSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read replication public key"])
            }

            // Step 2: Test SSH from source to target (with StrictHostKeyChecking=no to handle host key changes)
            serverToServerSetupStatus = "Testing connection to \(targetHost)..."
            let testResult = try await SSHConnectionManager.shared.executeCommand(
                "ssh -i \(replicationKeyPath) -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \(targetUser)@\(targetHost) 'echo SSH_OK' 2>&1; true"
            )

            if !testResult.contains("SSH_OK") {
                // Auth failed - add source key to target's authorized_keys
                if testResult.contains("Permission denied") || testResult.contains("publickey") {
                    serverToServerSetupStatus = "Authorizing key on \(targetHost)..."
                    try await addSourceKeyToTarget(pubKey: sourcePubKey, server: server)

                    // Verify it works now
                    let retestResult = try await SSHConnectionManager.shared.executeCommand(
                        "ssh -i \(replicationKeyPath) -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \(targetUser)@\(targetHost) 'echo SSH_OK' 2>&1; true"
                    )

                    if !retestResult.contains("SSH_OK") {
                        throw NSError(domain: "SSHSetup", code: 2, userInfo: [NSLocalizedDescriptionKey: "SSH setup failed: \(retestResult)"])
                    }
                } else {
                    throw NSError(domain: "SSHSetup", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot connect: \(testResult)"])
                }
            }

            // All good - connect and load target data
            serverToServerSetupStatus = "Loading datasets..."
            serverToServerSetupError = nil
            await connectToTargetServer(server)

        } catch {
            serverToServerSetupError = error.localizedDescription
        }

        isSettingUpServerToServer = false
        serverToServerSetupStatus = ""
    }

    // Check and set up server-to-server SSH (source → target) - DEPRECATED, use setupAndConnectToTarget
    @MainActor
    private func checkAndSetupServerToServerSSH(_ server: SavedServer) async {
        isSettingUpServerToServer = true
        serverToServerSetupError = nil
        serverToServerSetupStatus = "Checking server-to-server SSH setup..."

        do {
            let targetHost = server.host
            let targetUser = server.username
            let replicationKeyPath = "~/.ssh/id_replication"
            let replicationPubKeyPath = "~/.ssh/id_replication.pub"

            // Step 1: Check if source server has id_replication key
            print("DEBUG: Checking for replication key on source server...")
            serverToServerSetupStatus = "Checking replication key on source server..."
            let keyCheckResult = try await SSHConnectionManager.shared.executeCommand(
                "test -f \(replicationKeyPath) && echo 'KEY_EXISTS' || echo 'NO_KEY'"
            )
            print("DEBUG: Key check result: \(keyCheckResult)")

            var sourcePubKey: String

            if keyCheckResult.contains("NO_KEY") {
                // Create id_replication key on source server
                print("DEBUG: Creating replication key on source server...")
                serverToServerSetupStatus = "Creating replication key on source server..."
                let createResult = try await SSHConnectionManager.shared.executeCommand(
                    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -f \(replicationKeyPath) -N '' -C 'HexBSD-replication' -q && echo 'KEY_CREATED'"
                )
                print("DEBUG: Key creation result: \(createResult)")
            }

            // Get the public key
            serverToServerSetupStatus = "Reading replication public key..."
            sourcePubKey = try await SSHConnectionManager.shared.executeCommand("cat \(replicationPubKeyPath)")
            sourcePubKey = sourcePubKey.trimmingCharacters(in: .whitespacesAndNewlines)
            print("DEBUG: Source public key: \(sourcePubKey.prefix(50))...")

            if sourcePubKey.isEmpty {
                throw NSError(domain: "SSHSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read replication public key from source server"])
            }

            // Step 2: Update known_hosts on source server
            // Remove old entries for hostname, FQDN, and IP, then add fresh ones
            serverToServerSetupStatus = "Updating known_hosts for \(targetHost)..."
            print("DEBUG: Updating known_hosts for \(targetHost)...")
            let _ = try await SSHConnectionManager.shared.executeCommand(
                """
                # Get IP and FQDN for the host
                HOST_IP=$(getent hosts \(targetHost) 2>/dev/null | awk '{print $1}' | head -1)
                HOST_FQDN=$(getent hosts \(targetHost) 2>/dev/null | awk '{print $2}' | head -1)
                # Remove all possible entries
                ssh-keygen -R \(targetHost) 2>/dev/null
                [ -n "$HOST_IP" ] && ssh-keygen -R "$HOST_IP" 2>/dev/null
                [ -n "$HOST_FQDN" ] && ssh-keygen -R "$HOST_FQDN" 2>/dev/null
                # Add fresh host keys
                ssh-keyscan -H \(targetHost) >> ~/.ssh/known_hosts 2>/dev/null
                [ -n "$HOST_IP" ] && ssh-keyscan -H "$HOST_IP" >> ~/.ssh/known_hosts 2>/dev/null
                true
                """
            )

            // Step 3: Test SSH connection from source to target
            // Note: We append "; true" to ensure command returns 0 even if SSH fails,
            // so we can check the output for specific error messages
            serverToServerSetupStatus = "Testing SSH to \(targetHost)..."
            print("DEBUG: Testing SSH from source to \(targetUser)@\(targetHost)...")
            let testResult = try await SSHConnectionManager.shared.executeCommand(
                "ssh -i \(replicationKeyPath) -o BatchMode=yes -o ConnectTimeout=5 \(targetUser)@\(targetHost) 'echo SSH_OK' 2>&1; true"
            )
            print("DEBUG: SSH test result: \(testResult)")

            if testResult.contains("SSH_OK") {
                serverToServerSetupStatus = "Server-to-server SSH verified!"
                print("DEBUG: Server-to-server SSH verified!")
            } else if testResult.contains("Host key verification failed") || testResult.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
                // Host key changed (e.g., VM rolled back) - use StrictHostKeyChecking=no to accept new key
                print("DEBUG: Host key mismatch, accepting new host key...")
                serverToServerSetupStatus = "Host key changed, accepting new key..."

                // Use StrictHostKeyChecking=no to accept the new key and update known_hosts automatically
                // This is safe here because we're explicitly handling a known host key change scenario
                serverToServerSetupStatus = "Retrying SSH connection with new host key..."
                let retestResult = try await SSHConnectionManager.shared.executeCommand(
                    "ssh -i \(replicationKeyPath) -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \(targetUser)@\(targetHost) 'echo SSH_OK' 2>&1; true"
                )
                print("DEBUG: Retest with StrictHostKeyChecking=no: \(retestResult)")

                if retestResult.contains("SSH_OK") {
                    serverToServerSetupStatus = "Host key updated, connection verified!"
                } else if retestResult.contains("Permission denied") || retestResult.contains("publickey") {
                    // Now it's an auth issue - add the key
                    print("DEBUG: Auth failed after host key fix, adding key to target...")
                    serverToServerSetupStatus = "Adding replication key to \(targetHost)..."
                    try await addSourceKeyToTarget(pubKey: sourcePubKey, server: server)

                    // Final verification - use StrictHostKeyChecking=no since we just handled a host key change
                    serverToServerSetupStatus = "Verifying SSH connection..."
                    print("DEBUG: Final verification SSH from source to target...")
                    let finalResult = try await SSHConnectionManager.shared.executeCommand(
                        "ssh -i \(replicationKeyPath) -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \(targetUser)@\(targetHost) 'echo SSH_OK' 2>&1; true"
                    )
                    print("DEBUG: Final verification result: \(finalResult)")
                    if !finalResult.contains("SSH_OK") {
                        throw NSError(domain: "SSHSetup", code: 2, userInfo: [NSLocalizedDescriptionKey: "SSH setup failed: \(finalResult)"])
                    }
                    print("DEBUG: SSH setup complete!")
                    serverToServerSetupStatus = "SSH key authorization complete!"
                } else {
                    throw NSError(domain: "SSHSetup", code: 5, userInfo: [NSLocalizedDescriptionKey: "SSH still failing: \(retestResult)"])
                }
            } else if testResult.contains("Permission denied") || testResult.contains("publickey") {
                // Auth failure - need to add source's key to target's authorized_keys
                print("DEBUG: Auth failed, adding key to target...")
                serverToServerSetupStatus = "Adding replication key to \(targetHost)..."
                try await addSourceKeyToTarget(pubKey: sourcePubKey, server: server)

                // Verify it works now
                serverToServerSetupStatus = "Verifying SSH connection..."
                let retestResult = try await SSHConnectionManager.shared.executeCommand(
                    "ssh -i \(replicationKeyPath) -o BatchMode=yes -o ConnectTimeout=5 \(targetUser)@\(targetHost) 'echo SSH_OK' 2>&1; true"
                )
                print("DEBUG: Retest result: \(retestResult)")

                if !retestResult.contains("SSH_OK") {
                    throw NSError(domain: "SSHSetup", code: 2, userInfo: [NSLocalizedDescriptionKey: "SSH setup failed: \(retestResult)"])
                }
                serverToServerSetupStatus = "SSH key authorization complete!"
            } else if testResult.contains("Could not resolve") || testResult.contains("No route to host") || testResult.contains("Connection refused") {
                throw NSError(domain: "SSHSetup", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot reach \(targetHost) from source server. Check network connectivity."])
            } else {
                throw NSError(domain: "SSHSetup", code: 5, userInfo: [NSLocalizedDescriptionKey: "SSH test failed: \(testResult)"])
            }

            // All good - now connect and load target data
            serverToServerSetupStatus = "Connecting to target..."
            pendingServerToServerSetup = nil
            await connectToTargetServer(server)

        } catch {
            print("DEBUG: Server-to-server SSH setup error: \(error)")
            serverToServerSetupError = error.localizedDescription
        }

        isSettingUpServerToServer = false
    }

    // Add source server's public key to target server's authorized_keys
    private func addSourceKeyToTarget(pubKey: String, server: SavedServer) async throws {
        // Connect to target from Mac using the server's configured key (the one that works)
        let targetManager = SSHConnectionManager()

        serverToServerSetupStatus = "Connecting to \(server.host) to add SSH key..."

        // Use the server's configured keyPath - this is what the user set up for this server
        let keyPath = (server.keyPath as NSString).expandingTildeInPath
        print("DEBUG: Connecting to \(server.host) using configured key: \(keyPath)")

        let authMethod = SSHAuthMethod(
            username: server.username,
            privateKeyURL: URL(fileURLWithPath: keyPath)
        )

        try await targetManager.connect(
            host: server.host,
            port: server.port,
            authMethod: authMethod
        )

        // First check if the key is already in authorized_keys
        serverToServerSetupStatus = "Checking authorized_keys on \(server.host)..."
        let existingKeys = try await targetManager.executeCommand("cat ~/.ssh/authorized_keys 2>/dev/null || echo ''")

        if existingKeys.contains(pubKey) {
            print("DEBUG: Key already exists in authorized_keys")
            serverToServerSetupStatus = "Key already authorized on \(server.host)"
        } else {
            print("DEBUG: Adding key to authorized_keys")
            serverToServerSetupStatus = "Adding SSH key to \(server.host)..."
            let _ = try await targetManager.executeCommand(
                "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(pubKey)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys"
            )
        }

        await targetManager.disconnect()
    }

    private func connectToTargetServer(_ server: SavedServer) async {
        isLoadingTarget = true
        targetDatasets = []
        targetPools = []

        do {
            let manager = SSHConnectionManager()
            let keyURL = URL(fileURLWithPath: server.keyPath)
            let authMethod = SSHAuthMethod(username: server.username, privateKeyURL: keyURL)

            try await manager.connect(
                host: server.host,
                port: server.port,
                authMethod: authMethod
            )
            targetManager = manager

            // Load datasets and pools from target
            await loadTargetData()
        } catch {
            // Connection failed
            targetManager = nil
            isLoadingTarget = false
        }
    }

    private func loadTargetData() async {
        guard let manager = targetManager else { return }

        isLoadingTarget = true
        do {
            async let datasets = manager.listZFSDatasets()
            async let pools = manager.listZFSPools()

            targetDatasets = try await datasets
            targetPools = try await pools
        } catch {
            targetDatasets = []
            targetPools = []
        }
        isLoadingTarget = false
    }

    private func confirmDeleteSnapshot(_ snapshot: ZFSDataset) {
        appState.isShowingDeleteConfirmation = true

        let alert = NSAlert()
        alert.messageText = "Delete Snapshot?"
        alert.informativeText = "Are you sure you want to delete '\(snapshot.name)'?\n\nThis will permanently delete the snapshot. This action cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        appState.isShowingDeleteConfirmation = false

        if response == .alertFirstButtonReturn {
            Task {
                await viewModel.deleteSnapshot(snapshot: snapshot.name)
            }
        }
    }

    private func confirmDeleteSelectedSnapshots() {
        guard !selectedSnapshots.isEmpty else { return }

        appState.isShowingDeleteConfirmation = true

        let alert = NSAlert()
        alert.messageText = "Delete \(selectedSnapshots.count) Snapshot\(selectedSnapshots.count == 1 ? "" : "s")?"
        let snapshotList = selectedSnapshots.sorted().prefix(5).joined(separator: "\n")
        let moreText = selectedSnapshots.count > 5 ? "\n...and \(selectedSnapshots.count - 5) more" : ""
        alert.informativeText = "Are you sure you want to delete:\n\n\(snapshotList)\(moreText)\n\nThis action cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete \(selectedSnapshots.count) Snapshot\(selectedSnapshots.count == 1 ? "" : "s")")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        appState.isShowingDeleteConfirmation = false

        if response == .alertFirstButtonReturn {
            let snapshotsToDelete = selectedSnapshots
            Task {
                for snapshotName in snapshotsToDelete {
                    await viewModel.deleteSnapshot(snapshot: snapshotName)
                }
                await MainActor.run {
                    selectedSnapshots.removeAll()
                }
            }
        }
    }

    private func confirmDeleteDataset(_ dataset: ZFSDataset) {
        appState.isShowingDeleteConfirmation = true

        let alert = NSAlert()
        alert.messageText = "Delete Dataset?"
        alert.informativeText = "Are you sure you want to delete '\(dataset.name)'?\n\nThis will permanently delete the dataset and all its contents. This action cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        appState.isShowingDeleteConfirmation = false

        if response == .alertFirstButtonReturn {
            Task {
                await viewModel.destroyDataset(name: dataset.name)
            }
        }
    }

    private func replicateDataset(source: ZFSDataset, targetParent: ZFSDataset?) async {
        guard targetManager != nil,
              let serverId = selectedReplicationServer,
              let targetServer = savedServers.first(where: { $0.id.uuidString == serverId }) else {
            viewModel.error = "No target server selected"
            return
        }

        do {
            // Create a snapshot if the source is not already a snapshot
            let snapshotToReplicate: String
            if source.isSnapshot {
                snapshotToReplicate = source.name
            } else {
                let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let snapshotName = "replication-\(timestamp)"
                try await SSHConnectionManager.shared.createZFSSnapshot(dataset: source.name, snapshotName: snapshotName)
                snapshotToReplicate = "\(source.name)@\(snapshotName)"
            }

            // Determine destination path
            let destinationPath: String
            if let parent = targetParent {
                // Drop on a specific dataset - replicate under that dataset
                let sourceName = source.name.components(separatedBy: "@")[0]
                let lastComponent = sourceName.components(separatedBy: "/").last ?? sourceName
                destinationPath = "\(parent.name)/\(lastComponent)"
            } else {
                // Drop on empty space - replicate to root with same name
                let sourceName = source.name.components(separatedBy: "@")[0]
                destinationPath = sourceName
            }

            // Server-to-server replication using zfs send/receive
            // The source server needs to be able to SSH to the target server
            let targetHost = targetServer.host
            let targetUser = targetServer.username

            // Execute replication command on source server
            // This will send the snapshot from source to target via SSH
            let replicationCommand = """
            zfs send \(snapshotToReplicate) | \
            ssh -o StrictHostKeyChecking=no -o BatchMode=yes \
            \(targetUser)@\(targetHost) \
            'zfs receive -F \(destinationPath)'
            """

            _ = try await SSHConnectionManager.shared.executeCommand(replicationCommand)

            // Refresh target datasets and pools
            await loadTargetData()

            // Show success message
            await MainActor.run {
                viewModel.error = nil
            }
        } catch {
            await MainActor.run {
                viewModel.error = "Replication failed: \(error.localizedDescription)\n\nNote: The source server must have SSH access to the target server. Ensure SSH keys are configured between the servers."
            }
        }
    }
}

// MARK: - Dataset Node View

struct DatasetNodeView: View {
    @ObservedObject var node: DatasetNode
    let level: Int
    @Binding var expandedDatasets: Set<String>
    @Binding var selectedDataset: ZFSDataset?
    @Binding var selectedSnapshots: Set<String>
    var parentSnapshotsGroup: DatasetNode? = nil  // Reference to parent snapshots group for selecting all

    var body: some View {
        VStack(spacing: 0) {
            // Current dataset row
            HStack(spacing: 0) {
                // Name column with indentation, chevron, and icon
                HStack(spacing: 4) {
                    // Indentation
                    if level > 0 {
                        ForEach(0..<level, id: \.self) { _ in
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: 20)
                        }
                    }

                    // Expand/collapse chevron
                    if node.hasChildren {
                        Button(action: {
                            withAnimation {
                                if expandedDatasets.contains(node.dataset.name) {
                                    expandedDatasets.remove(node.dataset.name)
                                } else {
                                    expandedDatasets.insert(node.dataset.name)
                                }
                                node.isExpanded.toggle()
                            }
                        }) {
                            Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: 16)
                    }

                    // Dataset icon
                    if node.isSnapshotsGroup {
                        Image(systemName: "camera.fill")
                            .foregroundColor(.orange)
                            .frame(width: 16)
                    } else {
                        Image(systemName: node.dataset.icon)
                            .foregroundColor(node.dataset.isProtected ? .gray : (node.dataset.isSnapshot ? .orange : .blue))
                            .frame(width: 16)
                    }

                    // Dataset name
                    HStack(spacing: 4) {
                        if node.isSnapshotsGroup {
                            Text("Snapshots")
                                .font(.body)
                                .foregroundColor(.secondary)
                            Text("(\(node.snapshotCount))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text(lastPathComponent(node.dataset.name))
                                .font(.body)
                                .foregroundColor(node.dataset.isProtected ? .secondary : .primary)

                            if node.dataset.isSnapshot {
                                Text("snapshot")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.2))
                                    .cornerRadius(3)
                            }

                            if node.dataset.isProtected {
                                Text("protected")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(3)
                                    .help(node.dataset.protectionReason ?? "System dataset")
                            }
                        }
                    }
                }
                .frame(width: 300, alignment: .leading)
                .padding(.leading, 8)

                // Used column
                Text(node.isSnapshotsGroup ? "" : node.dataset.used)
                    .font(.body)
                    .frame(width: 100, alignment: .leading)

                // Available column
                Text(node.isSnapshotsGroup ? "" : node.dataset.available)
                    .font(.body)
                    .frame(width: 100, alignment: .leading)

                // Compression column
                Text(node.isSnapshotsGroup ? "" : (node.dataset.compression != "-" ? "\(node.dataset.compression) (\(node.dataset.compressRatio))" : "-"))
                    .font(.body)
                    .frame(width: 120, alignment: .leading)

                // Quota column
                Text(node.isSnapshotsGroup ? "" : node.dataset.quota)
                    .font(.body)
                    .frame(width: 100, alignment: .leading)

                // Mountpoint column
                Text(node.isSnapshotsGroup ? "" : node.dataset.mountpoint)
                    .font(.body)
                    .lineLimit(1)
                    .frame(minWidth: 150, alignment: .leading)

                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(rowBackground)
            .onTapGesture {
                handleRowTap(commandKeyPressed: NSEvent.modifierFlags.contains(.command))
            }

            // Children (if expanded)
            if node.isExpanded {
                ForEach(node.children) { childNode in
                    DatasetNodeView(
                        node: childNode,
                        level: level + 1,
                        expandedDatasets: $expandedDatasets,
                        selectedDataset: $selectedDataset,
                        selectedSnapshots: $selectedSnapshots,
                        parentSnapshotsGroup: node.isSnapshotsGroup ? node : nil
                    )
                }
            }
        }
    }

    // Computed property for row background color
    private var rowBackground: Color {
        if node.isSnapshotsGroup {
            // Snapshots group - highlight if any snapshots are selected
            let groupSnapshotNames = Set(node.children.map { $0.dataset.name })
            let hasSelectedSnapshots = !selectedSnapshots.intersection(groupSnapshotNames).isEmpty
            return hasSelectedSnapshots ? Color.orange.opacity(0.1) : Color.clear
        } else if node.dataset.isSnapshot {
            // Individual snapshot - highlight if selected
            return selectedSnapshots.contains(node.dataset.name) ? Color.accentColor.opacity(0.2) : Color.clear
        } else {
            // Regular dataset
            return selectedDataset?.id == node.dataset.id ? Color.accentColor.opacity(0.2) : Color.clear
        }
    }

    // Handle row tap with optional Command key for multi-select
    private func handleRowTap(commandKeyPressed: Bool) {
        if node.isSnapshotsGroup {
            // Snapshots group - toggle expansion AND select/deselect all snapshots
            withAnimation {
                if expandedDatasets.contains(node.dataset.name) {
                    expandedDatasets.remove(node.dataset.name)
                } else {
                    expandedDatasets.insert(node.dataset.name)
                }
                node.isExpanded.toggle()
            }
            // Toggle selection of all snapshots in this group
            let groupSnapshotNames = Set(node.children.map { $0.dataset.name })
            let allSelected = groupSnapshotNames.isSubset(of: selectedSnapshots)
            if allSelected {
                // Deselect all
                selectedSnapshots.subtract(groupSnapshotNames)
            } else {
                // Select all
                selectedSnapshots.formUnion(groupSnapshotNames)
            }
            selectedDataset = nil
        } else if node.dataset.isSnapshot {
            // Individual snapshot - multi-select support
            if commandKeyPressed {
                // Command+Click: toggle this snapshot in selection
                if selectedSnapshots.contains(node.dataset.name) {
                    selectedSnapshots.remove(node.dataset.name)
                } else {
                    selectedSnapshots.insert(node.dataset.name)
                }
            } else {
                // Regular click: select only this snapshot
                selectedSnapshots = [node.dataset.name]
            }
            selectedDataset = nil
        } else {
            // Regular dataset
            selectedSnapshots.removeAll()
            selectedDataset = node.dataset
        }
    }

    private func lastPathComponent(_ path: String) -> String {
        // For snapshots, show the snapshot name
        if path.contains("@") {
            let parts = path.components(separatedBy: "@")
            return "@" + (parts.last ?? path)
        }

        // For datasets, show the last component
        if let lastSlash = path.lastIndex(of: "/") {
            return String(path[path.index(after: lastSlash)...])
        }
        return path
    }
}

// MARK: - Draggable Dataset Node View (for source side)

struct DraggableDatasetNodeView: View {
    @ObservedObject var node: DatasetNode
    let level: Int
    @Binding var expandedDatasets: Set<String>
    @Binding var selectedDataset: ZFSDataset?
    let onDragStarted: (ZFSDataset) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Current dataset row
            HStack(spacing: 0) {
                // Name column with indentation, chevron, and icon
                HStack(spacing: 4) {
                    // Indentation
                    if level > 0 {
                        ForEach(0..<level, id: \.self) { _ in
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: 20)
                        }
                    }

                    // Expand/collapse chevron
                    if node.hasChildren {
                        Button(action: {
                            withAnimation {
                                if expandedDatasets.contains(node.dataset.name) {
                                    expandedDatasets.remove(node.dataset.name)
                                } else {
                                    expandedDatasets.insert(node.dataset.name)
                                }
                                node.isExpanded.toggle()
                            }
                        }) {
                            Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: 16)
                    }

                    // Dataset icon
                    Image(systemName: node.dataset.icon)
                        .foregroundColor(node.dataset.isSnapshot ? .orange : .blue)
                        .frame(width: 16)

                    // Dataset name
                    HStack(spacing: 4) {
                        Text(lastPathComponent(node.dataset.name))
                            .font(.body)

                        if node.dataset.isSnapshot {
                            Text("snapshot")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.2))
                                .cornerRadius(3)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)

                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(selectedDataset?.id == node.dataset.id ? Color.accentColor.opacity(0.2) : Color.clear)
            .onTapGesture {
                selectedDataset = node.dataset
            }
            .onDrag {
                onDragStarted(node.dataset)
                return NSItemProvider(object: node.dataset.name as NSString)
            }

            // Children (if expanded)
            if node.isExpanded {
                ForEach(node.children) { childNode in
                    DraggableDatasetNodeView(
                        node: childNode,
                        level: level + 1,
                        expandedDatasets: $expandedDatasets,
                        selectedDataset: $selectedDataset,
                        onDragStarted: onDragStarted
                    )
                }
            }
        }
    }

    private func lastPathComponent(_ path: String) -> String {
        // For snapshots, show the snapshot name
        if path.contains("@") {
            let parts = path.components(separatedBy: "@")
            return "@" + (parts.last ?? path)
        }

        // For datasets, show the last component
        if let lastSlash = path.lastIndex(of: "/") {
            return String(path[path.index(after: lastSlash)...])
        }
        return path
    }
}

// MARK: - Droppable Dataset Node View (for target side)

struct DroppableDatasetNodeView: View {
    @ObservedObject var node: DatasetNode
    let level: Int
    @Binding var expandedDatasets: Set<String>
    let onDropped: (ZFSDataset) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // Current dataset row
            HStack(spacing: 0) {
                // Name column with indentation, chevron, and icon
                HStack(spacing: 4) {
                    // Indentation
                    if level > 0 {
                        ForEach(0..<level, id: \.self) { _ in
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: 20)
                        }
                    }

                    // Expand/collapse chevron
                    if node.hasChildren {
                        Button(action: {
                            withAnimation {
                                if expandedDatasets.contains(node.dataset.name) {
                                    expandedDatasets.remove(node.dataset.name)
                                } else {
                                    expandedDatasets.insert(node.dataset.name)
                                }
                                node.isExpanded.toggle()
                            }
                        }) {
                            Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: 16)
                    }

                    // Dataset icon
                    Image(systemName: node.dataset.icon)
                        .foregroundColor(node.dataset.isSnapshot ? .orange : .blue)
                        .frame(width: 16)

                    // Dataset name
                    HStack(spacing: 4) {
                        Text(lastPathComponent(node.dataset.name))
                            .font(.body)

                        if node.dataset.isSnapshot {
                            Text("snapshot")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.2))
                                .cornerRadius(3)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)

                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isTargeted ? Color.accentColor.opacity(0.3) : Color.clear)
            .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
                onDropped(node.dataset)
                return true
            }

            // Children (if expanded)
            if node.isExpanded {
                ForEach(node.children) { childNode in
                    DroppableDatasetNodeView(
                        node: childNode,
                        level: level + 1,
                        expandedDatasets: $expandedDatasets,
                        onDropped: onDropped
                    )
                }
            }
        }
    }

    private func lastPathComponent(_ path: String) -> String {
        // For snapshots, show the snapshot name
        if path.contains("@") {
            let parts = path.components(separatedBy: "@")
            return "@" + (parts.last ?? path)
        }

        // For datasets, show the last component
        if let lastSlash = path.lastIndex(of: "/") {
            return String(path[path.index(after: lastSlash)...])
        }
        return path
    }
}

// MARK: - Replication View

struct ReplicationView: View {
    @ObservedObject var viewModel: ZFSViewModel
    @State private var selectedTargetServer: SavedServer?
    @State private var savedServers: [SavedServer] = []
    @State private var targetManager: SSHConnectionManager?
    @State private var targetDatasets: [ZFSDataset] = []
    @State private var isConnectingToTarget = false
    @State private var isLoadingTargetData = false
    @State private var draggedDataset: ZFSDataset?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("ZFS Replication")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                // Target server selector
                if !savedServers.isEmpty {
                    Menu {
                        ForEach(savedServers) { server in
                            Button(action: {
                                connectToTargetServer(server)
                            }) {
                                HStack {
                                    Text(server.name)
                                    Text("(\(server.host))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "server.rack")
                            if let target = selectedTargetServer {
                                Text(target.name)
                            } else {
                                Text("Select Target Server")
                            }
                        }
                    }
                    .disabled(isConnectingToTarget)
                }

                Button(action: {
                    Task {
                        await refreshData()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // Split-screen replication view
            if selectedTargetServer == nil {
                VStack(spacing: 20) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("Select Target Server")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Choose a server from the dropdown to begin replication")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isConnectingToTarget {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Connecting to target server...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    // Local (source) datasets
                    ReplicationPaneView(
                        title: "Local (Source)",
                        subtitle: SSHConnectionManager.shared.serverAddress,
                        datasets: viewModel.datasets,
                        isLoading: viewModel.isLoadingDatasets,
                        isSource: true,
                        onDrop: { _ in false },
                        onDrag: { dataset in
                            draggedDataset = dataset
                        },
                        onReplicate: { dataset in
                            Task {
                                await replicateToTarget(dataset)
                            }
                        }
                    )

                    // Remote (target) datasets
                    ReplicationPaneView(
                        title: "Remote (Target)",
                        subtitle: selectedTargetServer?.host ?? "",
                        datasets: targetDatasets,
                        isLoading: isLoadingTargetData,
                        isSource: false,
                        onDrop: { dataset in
                            Task {
                                await replicateToTarget(dataset)
                            }
                            return true
                        },
                        onDrag: { dataset in
                            draggedDataset = dataset
                        },
                        onReplicate: { dataset in
                            Task {
                                await replicateFromTarget(dataset)
                            }
                        }
                    )
                }
            }
        }
        .onAppear {
            loadSavedServers()
        }
    }

    private func loadSavedServers() {
        if let data = UserDefaults.standard.data(forKey: "savedServers"),
           let servers = try? JSONDecoder().decode([SavedServer].self, from: data) {
            // Exclude the current connected server
            savedServers = servers.filter { $0.host != SSHConnectionManager.shared.serverAddress }
        }
    }

    private func connectToTargetServer(_ server: SavedServer) {
        selectedTargetServer = server
        isConnectingToTarget = true

        Task {
            do {
                // Create a new SSH manager for the target
                let manager = SSHConnectionManager()
                let keyURL = URL(fileURLWithPath: server.keyPath)
                let authMethod = SSHAuthMethod(username: server.username, privateKeyURL: keyURL)

                try await manager.connect(host: server.host, port: server.port, authMethod: authMethod)
                try await manager.validateFreeBSD()

                await MainActor.run {
                    targetManager = manager
                    isConnectingToTarget = false
                }

                // Load target datasets
                await loadTargetDatasets()
            } catch {
                await MainActor.run {
                    viewModel.error = "Failed to connect to target: \(error.localizedDescription)"
                    isConnectingToTarget = false
                    selectedTargetServer = nil
                }
            }
        }
    }

    private func loadTargetDatasets() async {
        guard let manager = targetManager else { return }

        await MainActor.run {
            isLoadingTargetData = true
        }

        do {
            let datasets = try await manager.listZFSDatasets()
            await MainActor.run {
                targetDatasets = datasets
                isLoadingTargetData = false
            }
        } catch {
            await MainActor.run {
                viewModel.error = "Failed to load target datasets: \(error.localizedDescription)"
                isLoadingTargetData = false
            }
        }
    }

    private func refreshData() async {
        await viewModel.refreshDatasets()
        if targetManager != nil {
            await loadTargetDatasets()
        }
    }

    private func replicateToTarget(_ dataset: ZFSDataset) async {
        guard let manager = targetManager, let target = selectedTargetServer else { return }

        do {
            try await SSHConnectionManager.shared.replicateDataset(
                dataset: dataset.name,
                targetHost: target.host,
                targetManager: manager
            )
            await MainActor.run {
                viewModel.error = nil
            }
            await loadTargetDatasets()
        } catch {
            await MainActor.run {
                viewModel.error = "Replication failed: \(error.localizedDescription)"
            }
        }
    }

    private func replicateFromTarget(_ dataset: ZFSDataset) async {
        guard let manager = targetManager else { return }

        do {
            try await manager.replicateDataset(
                dataset: dataset.name,
                targetHost: SSHConnectionManager.shared.serverAddress,
                targetManager: SSHConnectionManager.shared
            )
            await MainActor.run {
                viewModel.error = nil
            }
            await viewModel.refreshDatasets()
        } catch {
            await MainActor.run {
                viewModel.error = "Replication failed: \(error.localizedDescription)"
            }
        }
    }
}

struct ReplicationPaneView: View {
    let title: String
    let subtitle: String
    let datasets: [ZFSDataset]
    let isLoading: Bool
    let isSource: Bool
    let onDrop: (ZFSDataset) -> Bool
    let onDrag: (ZFSDataset) -> Void
    let onReplicate: (ZFSDataset) -> Void

    @State private var expandedDatasets: Set<String> = []

    // Build hierarchical tree from flat dataset list
    private func buildHierarchy() -> [DatasetNode] {
        var nodes: [String: DatasetNode] = [:]
        var rootNodes: [DatasetNode] = []

        // Create nodes for all datasets (not snapshots)
        let datasetsOnly = datasets.filter { !$0.isSnapshot }.sorted { $0.name < $1.name }

        for dataset in datasetsOnly {
            let node = DatasetNode(dataset: dataset)
            node.isExpanded = expandedDatasets.contains(dataset.name)
            nodes[dataset.name] = node
        }

        // Build parent-child relationships
        for node in nodes.values {
            let name = node.dataset.name

            // Find parent by removing last component
            if let lastSlash = name.lastIndex(of: "/") {
                let parentName = String(name[..<lastSlash])
                if let parent = nodes[parentName] {
                    parent.children.append(node)
                } else {
                    // Parent doesn't exist (maybe filtered out), add as root
                    rootNodes.append(node)
                }
            } else {
                // No slash means it's a pool-level dataset (root)
                rootNodes.append(node)
                // Expand root datasets by default
                if !expandedDatasets.contains(name) {
                    expandedDatasets.insert(name)
                    node.isExpanded = true
                }
            }
        }

        // Sort children for each node
        for node in nodes.values {
            node.children.sort { $0.dataset.name < $1.dataset.name }
        }

        // Add snapshots as children of their parent datasets
        let snapshots = datasets.filter { $0.isSnapshot }.sorted { $0.name < $1.name }
        for snapshot in snapshots {
            let parentName = snapshot.name.components(separatedBy: "@")[0]
            if let parent = nodes[parentName] {
                let snapshotNode = DatasetNode(dataset: snapshot)
                parent.children.append(snapshotNode)
            }
        }

        return rootNodes.sorted { $0.dataset.name < $1.dataset.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Datasets hierarchical list
            if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading datasets...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if datasets.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "folder")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Datasets")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(buildHierarchy()) { node in
                        ReplicationDatasetNodeView(
                            node: node,
                            level: 0,
                            isSource: isSource,
                            expandedDatasets: $expandedDatasets,
                            onDrag: onDrag,
                            onDrop: onDrop,
                            onReplicate: onReplicate
                        )
                    }
                }
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    // Handle drop on pane (for general replication)
                    return false
                }
            }
        }
    }
}

// MARK: - Replication Dataset Node View

struct ReplicationDatasetNodeView: View {
    @ObservedObject var node: DatasetNode
    let level: Int
    let isSource: Bool
    @Binding var expandedDatasets: Set<String>
    let onDrag: (ZFSDataset) -> Void
    let onDrop: (ZFSDataset) -> Bool
    let onReplicate: (ZFSDataset) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Current dataset row
            HStack(spacing: 8) {
                // Indentation
                if level > 0 {
                    ForEach(0..<level, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: 20)
                    }
                }

                // Expand/collapse chevron
                if node.hasChildren {
                    Button(action: {
                        withAnimation {
                            if expandedDatasets.contains(node.dataset.name) {
                                expandedDatasets.remove(node.dataset.name)
                            } else {
                                expandedDatasets.insert(node.dataset.name)
                            }
                            node.isExpanded.toggle()
                        }
                    }) {
                        Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                            .foregroundColor(.secondary)
                            .frame(width: 20)
                    }
                    .buttonStyle(.plain)
                } else {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 20)
                }

                // Dataset icon
                Image(systemName: node.dataset.icon)
                    .foregroundColor(node.dataset.isSnapshot ? .orange : .blue)

                // Dataset name (show only last component)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lastPathComponent(node.dataset.name))
                        .font(.body)

                    HStack(spacing: 8) {
                        Text(node.dataset.used)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if node.dataset.isSnapshot {
                            Text("snapshot")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.2))
                                .cornerRadius(3)
                        }
                    }
                }

                Spacer()

                // Replicate button
                Button(action: {
                    onReplicate(node.dataset)
                }) {
                    Image(systemName: isSource ? "arrow.right.circle" : "arrow.left.circle")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .help(isSource ? "Replicate to target" : "Replicate to local")
            }
            .padding(.vertical, 4)
            .padding(.leading, 8)
            .contentShape(Rectangle())
            .onDrag {
                onDrag(node.dataset)
                return NSItemProvider(object: node.dataset.name as NSString)
            }
            .onDrop(of: [.text], isTargeted: nil) { providers in
                return onDrop(node.dataset)
            }

            // Children (if expanded)
            if node.isExpanded {
                ForEach(node.children) { childNode in
                    ReplicationDatasetNodeView(
                        node: childNode,
                        level: level + 1,
                        isSource: isSource,
                        expandedDatasets: $expandedDatasets,
                        onDrag: onDrag,
                        onDrop: onDrop,
                        onReplicate: onReplicate
                    )
                }
            }
        }
    }

    private func lastPathComponent(_ path: String) -> String {
        // For snapshots, show the snapshot name
        if path.contains("@") {
            let parts = path.components(separatedBy: "@")
            return "@" + (parts.last ?? path)
        }

        // For datasets, show the last component
        if let lastSlash = path.lastIndex(of: "/") {
            return String(path[path.index(after: lastSlash)...])
        }
        return path
    }
}

// MARK: - Create Pool Sheet

struct CreatePoolSheet: View {
    @Binding var availableDisks: [AvailableDisk]
    let onCreate: (String, [String], String) -> Void  // poolName, selectedDisks, raidType
    let onCancel: () -> Void
    let onWipe: (String) async -> Void  // diskName

    @State private var poolName: String = ""
    @State private var selectedDisks: Set<String> = []
    @State private var raidType: String = "stripe"
    @State private var isWiping: String? = nil  // disk currently being wiped
    @Environment(\.dismiss) private var dismiss

    private let raidTypes = [
        ("stripe", "Stripe (No Redundancy)", 1),
        ("mirror", "Mirror (2+ disks)", 2),
        ("raidz1", "RAID-Z1 (3+ disks)", 3),
        ("raidz2", "RAID-Z2 (4+ disks)", 4),
        ("raidz3", "RAID-Z3 (5+ disks)", 5)
    ]

    private var canCreate: Bool {
        !poolName.isEmpty &&
        !selectedDisks.isEmpty &&
        selectedDisks.count >= minimumDisksForRaid
    }

    private var minimumDisksForRaid: Int {
        raidTypes.first(where: { $0.0 == raidType })?.2 ?? 1
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Create ZFS Pool")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 4) {
                Text("Pool Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("mypool", text: $poolName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("RAID Type")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $raidType) {
                    ForEach(raidTypes, id: \.0) { type in
                        Text(type.1).tag(type.0)
                    }
                }
                .pickerStyle(.segmented)

                if selectedDisks.count < minimumDisksForRaid {
                    Text("⚠️ \(raidType) requires at least \(minimumDisksForRaid) disk(s). Select \(minimumDisksForRaid - selectedDisks.count) more.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Available Disks")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(selectedDisks.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(availableDisks) { disk in
                            HStack {
                                if disk.hasPartitions {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                } else {
                                    Image(systemName: selectedDisks.contains(disk.name) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedDisks.contains(disk.name) ? .accentColor : .secondary)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(disk.name)
                                            .font(.body)
                                            .fontWeight(.medium)
                                        if disk.hasPartitions {
                                            Text("(\(disk.partitionScheme))")
                                                .font(.caption)
                                                .foregroundColor(.orange)
                                        }
                                    }
                                    Text("\(disk.size) - \(disk.description)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if disk.hasPartitions {
                                    if isWiping == disk.name {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Button("Wipe") {
                                            wipeDisk(disk.name)
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(.orange)
                                        .controlSize(.small)
                                        .disabled(isWiping != nil)
                                    }
                                } else {
                                    Text(disk.size)
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(disk.hasPartitions ? Color.orange.opacity(0.05) : (selectedDisks.contains(disk.name) ? Color.accentColor.opacity(0.1) : Color.clear))
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if !disk.hasPartitions {
                                    if selectedDisks.contains(disk.name) {
                                        selectedDisks.remove(disk.name)
                                    } else {
                                        selectedDisks.insert(disk.name)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(height: 200)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }

            if canCreate {
                // Preview command
                VStack(alignment: .leading, spacing: 2) {
                    Text("Command Preview")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(buildCommand())
                        .font(.system(.caption, design: .monospaced))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(4)
                }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                    onCancel()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Create Pool") {
                    onCreate(poolName, Array(selectedDisks), raidType)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 750, height: 520)
    }

    private func buildCommand() -> String {
        let disks = selectedDisks.sorted().map { "/dev/\($0)" }.joined(separator: " ")
        if raidType == "stripe" {
            return "zpool create \(poolName) \(disks)"
        } else {
            return "zpool create \(poolName) \(raidType) \(disks)"
        }
    }

    private func wipeDisk(_ diskName: String) {
        // Confirm wipe
        let alert = NSAlert()
        alert.messageText = "Wipe Disk \(diskName)?"
        alert.informativeText = "This will destroy all partitions and data on /dev/\(diskName). This action cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Wipe Disk")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        isWiping = diskName
        Task {
            await onWipe(diskName)
            await MainActor.run {
                isWiping = nil
            }
        }
    }
}

// MARK: - Create Snapshot Sheet

struct CreateSnapshotSheet: View {
    let datasetName: String
    @Binding var snapshotName: String
    let onCreate: () -> Void
    let onCancel: () -> Void

    private static func generateTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Create Snapshot")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 8) {
                Text("Dataset")
                    .font(.caption)
                Text(datasetName)
                    .font(.body)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                Text("Snapshot Name")
                    .font(.caption)
                TextField("Snapshot name", text: $snapshotName)
                    .textFieldStyle(.roundedBorder)

                Text("Full name will be: \(datasetName)@\(snapshotName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    onCreate()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(snapshotName.isEmpty)
            }
        }
        .padding()
        .frame(width: 450)
        .onAppear {
            if snapshotName.isEmpty {
                snapshotName = Self.generateTimestamp()
            }
        }
    }
}

// MARK: - Clone Dataset Sheet

struct CloneDatasetSheet: View {
    let sourceName: String
    let isSnapshot: Bool
    @Binding var destination: String
    let onClone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Clone Dataset")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 8) {
                Text(isSnapshot ? "Source Snapshot" : "Source Dataset")
                    .font(.caption)
                Text(sourceName)
                    .font(.body)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                if !isSnapshot {
                    Text("A snapshot will be created automatically for cloning")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .padding(.top, 2)
                }

                Text("Destination Dataset")
                    .font(.caption)
                    .padding(.top, 8)
                TextField("e.g., pool/cloned-dataset", text: $destination)
                    .textFieldStyle(.roundedBorder)

                Text(isSnapshot ? "This will create a new dataset from the snapshot" : "This will create a snapshot, then clone it to a new dataset")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Clone") {
                    onClone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(destination.isEmpty)
            }
        }
        .padding()
        .frame(width: 500)
    }
}

// MARK: - View Model

@MainActor
class ZFSViewModel: ObservableObject {
    @Published var pools: [ZFSPool] = []
    @Published var datasets: [ZFSDataset] = []
    @Published var scrubStatuses: [ZFSScrubStatus] = []
    @Published var isLoadingPools = false
    @Published var isLoadingDatasets = false
    @Published var isLoadingScrub = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.refreshPools() }
            group.addTask { await self.refreshDatasets() }
            group.addTask { await self.refreshScrubStatus() }
        }
    }

    func refreshPools() async {
        isLoadingPools = true
        error = nil

        do {
            pools = try await sshManager.listZFSPools()
        } catch {
            self.error = "Failed to load pools: \(error.localizedDescription)"
            pools = []
        }

        isLoadingPools = false
    }

    func refreshDatasets() async {
        isLoadingDatasets = true
        error = nil

        do {
            datasets = try await sshManager.listZFSDatasets()
        } catch {
            self.error = "Failed to load datasets: \(error.localizedDescription)"
            datasets = []
        }

        isLoadingDatasets = false
    }

    func refreshScrubStatus() async {
        isLoadingScrub = true
        error = nil

        do {
            scrubStatuses = try await sshManager.getZFSScrubStatus()
        } catch {
            self.error = "Failed to load scrub status: \(error.localizedDescription)"
            scrubStatuses = []
        }

        isLoadingScrub = false
    }

    func createSnapshot(dataset: String, snapshotName: String) async {
        error = nil

        do {
            try await sshManager.createZFSSnapshot(dataset: dataset, snapshotName: snapshotName)
            await refreshDatasets()
        } catch {
            self.error = "Failed to create snapshot: \(error.localizedDescription)"
        }
    }

    func deleteSnapshot(snapshot: String) async {
        error = nil

        do {
            try await sshManager.deleteZFSSnapshot(snapshot: snapshot)
            await refreshDatasets()
        } catch {
            self.error = "Failed to delete snapshot: \(error.localizedDescription)"
        }
    }

    func createPool(name: String, disks: [String], raidType: String) async {
        error = nil

        do {
            let diskPaths = disks.map { "/dev/\($0)" }.joined(separator: " ")
            let command: String
            if raidType == "stripe" {
                command = "zpool create \(name) \(diskPaths)"
            } else {
                command = "zpool create \(name) \(raidType) \(diskPaths)"
            }

            let _ = try await sshManager.executeCommand(command)
            await refreshPools()
            await refreshDatasets()
        } catch {
            self.error = "Failed to create pool: \(error.localizedDescription)"
        }
    }

    func rollbackSnapshot(snapshot: String) async {
        // Confirm rollback
        let alert = NSAlert()
        alert.messageText = "Rollback to snapshot?"
        alert.informativeText = "This will rollback the dataset to \(snapshot). All changes made after this snapshot will be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Rollback")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.rollbackZFSSnapshot(snapshot: snapshot)
            await refreshDatasets()
        } catch {
            self.error = "Failed to rollback snapshot: \(error.localizedDescription)"
        }
    }

    func cloneDataset(source: String, isSnapshot: Bool, destination: String) async {
        error = nil

        do {
            let snapshotToClone: String

            if isSnapshot {
                // Already a snapshot, use it directly
                snapshotToClone = source
            } else {
                // It's a dataset, create a snapshot first
                let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let snapshotName = "clone-\(timestamp)"
                try await sshManager.createZFSSnapshot(dataset: source, snapshotName: snapshotName)
                snapshotToClone = "\(source)@\(snapshotName)"
            }

            try await sshManager.cloneZFSDataset(snapshot: snapshotToClone, destination: destination)
            await refreshDatasets()
        } catch {
            self.error = "Failed to clone dataset: \(error.localizedDescription)"
        }
    }

    func startScrub(pool: String) async {
        error = nil

        do {
            try await sshManager.startZFSScrub(pool: pool)
            // Wait a moment then refresh status
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await refreshScrubStatus()
        } catch {
            self.error = "Failed to start scrub: \(error.localizedDescription)"
        }
    }

    func stopScrub(pool: String) async {
        error = nil

        do {
            try await sshManager.stopZFSScrub(pool: pool)
            // Wait a moment then refresh status
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await refreshScrubStatus()
        } catch {
            self.error = "Failed to stop scrub: \(error.localizedDescription)"
        }
    }

    func createDataset(name: String, type: String, properties: [String: String]) async {
        print("DEBUG: ViewModel.createDataset called - name: \(name), type: \(type), properties: \(properties)")
        error = nil

        do {
            try await sshManager.createZFSDataset(name: name, type: type, properties: properties)
            print("DEBUG: Dataset created successfully, refreshing...")
            await refreshDatasets()
        } catch {
            print("DEBUG: ViewModel.createDataset error: \(error)")
            self.error = "Failed to create dataset: \(error.localizedDescription)"
        }
    }

    func destroyDataset(name: String) async {
        error = nil

        do {
            // Destroy with recursive and force flags to handle datasets with snapshots/children
            try await sshManager.destroyZFSDataset(name: name, recursive: true, force: false)
            await refreshDatasets()
        } catch {
            self.error = "Failed to delete dataset: \(error.localizedDescription)"
        }
    }

    func setProperty(dataset: String, property: String, value: String) async {
        error = nil

        do {
            try await sshManager.setZFSDatasetProperty(dataset: dataset, property: property, value: value)
            await refreshDatasets()
        } catch {
            self.error = "Failed to set property: \(error.localizedDescription)"
        }
    }
}

// MARK: - Create Dataset Sheet

struct CreateDatasetSheet: View {
    let parentDataset: String
    let onCreate: (String, [String: String]) -> Void
    let onCancel: () -> Void

    @State private var datasetName = ""
    @State private var compression = "lz4"
    @State private var quota = ""
    @State private var mountpoint = ""
    @State private var recordsize = "128K"

    var body: some View {
        VStack(spacing: 0) {
            Text("Create New Dataset")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Parent dataset (read-only)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Parent Dataset")
                            .font(.headline)
                        Text(parentDataset)
                            .font(.body)
                            .foregroundColor(.primary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                        Text("New dataset will be created under this parent")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Dataset name
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dataset Name")
                            .font(.headline)
                        TextField("e.g., data", text: $datasetName)
                            .textFieldStyle(.roundedBorder)
                        Text("Enter just the name for the new dataset")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    Text("Properties")
                        .font(.headline)

                    // Compression
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Compression")
                            .font(.subheadline)
                        Picker("Compression", selection: $compression) {
                            Text("Off").tag("off")
                            Text("LZ4 (Recommended)").tag("lz4")
                            Text("GZIP").tag("gzip")
                            Text("ZLE").tag("zle")
                        }
                        .frame(width: 250)
                    }

                    // Record size
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Record Size")
                            .font(.subheadline)
                        Picker("Record Size", selection: $recordsize) {
                            Text("128K (Default)").tag("128K")
                            Text("64K").tag("64K")
                            Text("256K").tag("256K")
                            Text("512K").tag("512K")
                            Text("1M").tag("1M")
                        }
                        .frame(width: 250)
                    }

                    // Quota
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quota (Optional)")
                            .font(.subheadline)
                        TextField("e.g., 100G", text: $quota)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        Text("Leave empty for no quota")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Mountpoint
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mountpoint (Optional)")
                            .font(.subheadline)
                        TextField("Leave empty for default", text: $mountpoint)
                            .textFieldStyle(.roundedBorder)
                        Text("Custom mount location (default: /pool/dataset)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .frame(height: 400)

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create Dataset") {
                    var properties: [String: String] = [:]
                    properties["compression"] = compression
                    properties["recordsize"] = recordsize

                    if !mountpoint.isEmpty {
                        properties["mountpoint"] = mountpoint
                    }

                    if !quota.isEmpty {
                        properties["quota"] = quota
                    }

                    let fullName = "\(parentDataset)/\(datasetName)"
                    onCreate(fullName, properties)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(datasetName.isEmpty)
            }
            .padding()
        }
        .frame(width: 540)
    }
}

// MARK: - Create ZVOL Sheet

struct CreateZvolSheet: View {
    let parentDataset: String
    let onCreate: (String, [String: String]) -> Void
    let onCancel: () -> Void

    @State private var zvolName = ""
    @State private var volumeSize = ""
    @State private var compression = "lz4"
    @State private var volblocksize = "8K"
    @State private var sparse = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Create New ZVOL")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Parent dataset (read-only)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Parent Dataset")
                            .font(.headline)
                        Text(parentDataset)
                            .font(.body)
                            .foregroundColor(.primary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                        Text("New ZVOL will be created under this parent")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // ZVOL name
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ZVOL Name")
                            .font(.headline)
                        TextField("e.g., disk0", text: $zvolName)
                            .textFieldStyle(.roundedBorder)
                        Text("Enter just the name for the new ZVOL")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Volume Size (required)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Volume Size")
                                .font(.headline)
                            Text("(Required)")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        TextField("e.g., 10G", text: $volumeSize)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        Text("Size with suffix: K, M, G, T (e.g., 10G, 500M)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    Text("Properties")
                        .font(.headline)

                    // Compression
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Compression")
                            .font(.subheadline)
                        Picker("Compression", selection: $compression) {
                            Text("Off").tag("off")
                            Text("LZ4 (Recommended)").tag("lz4")
                            Text("GZIP").tag("gzip")
                            Text("ZLE").tag("zle")
                        }
                        .frame(width: 250)
                    }

                    // Block Size
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Block Size")
                            .font(.subheadline)
                        Picker("Block Size", selection: $volblocksize) {
                            Text("8K (Default)").tag("8K")
                            Text("4K").tag("4K")
                            Text("16K").tag("16K")
                            Text("32K").tag("32K")
                            Text("64K").tag("64K")
                            Text("128K").tag("128K")
                        }
                        .frame(width: 250)
                        Text("Smaller blocks = better random I/O, larger = better sequential")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Sparse option
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Sparse Volume (Thin Provisioning)", isOn: $sparse)
                            .font(.subheadline)
                        Text("Sparse volumes don't reserve space until data is written")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .frame(height: 450)

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create ZVOL") {
                    var properties: [String: String] = [:]
                    properties["volsize"] = volumeSize
                    properties["compression"] = compression
                    properties["volblocksize"] = volblocksize

                    if sparse {
                        properties["refreservation"] = "none"
                    }

                    let fullName = "\(parentDataset)/\(zvolName)"
                    onCreate(fullName, properties)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(zvolName.isEmpty || volumeSize.isEmpty)
            }
            .padding()
        }
        .frame(width: 540)
    }
}

// MARK: - Share Dataset Sheet

struct ShareDatasetSheet: View {
    let dataset: ZFSDataset
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var shareEnabled: Bool
    @State private var readOnly = false
    @State private var networkRestriction = ""
    @State private var mapRoot = false

    init(dataset: ZFSDataset, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.dataset = dataset
        self.onSave = onSave
        self.onCancel = onCancel
        // Initialize state based on current share status
        let isCurrentlyShared = dataset.sharenfs != "off" && dataset.sharenfs != "-"
        _shareEnabled = State(initialValue: isCurrentlyShared)
        // Parse existing options if shared
        if isCurrentlyShared && dataset.sharenfs != "on" {
            _readOnly = State(initialValue: dataset.sharenfs.contains("-ro"))
            _mapRoot = State(initialValue: dataset.sharenfs.contains("-maproot=root"))
            // Extract network if present
            if let networkRange = dataset.sharenfs.range(of: "-network\\s+\\S+", options: .regularExpression) {
                let networkPart = String(dataset.sharenfs[networkRange])
                let parts = networkPart.components(separatedBy: .whitespaces)
                if parts.count >= 2 {
                    _networkRestriction = State(initialValue: parts[1])
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("NFS Sharing")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                // Dataset info
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dataset")
                        .font(.headline)
                    Text(dataset.name)
                        .font(.body)
                        .foregroundColor(.primary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                }

                // Current status
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current Status")
                        .font(.headline)
                    HStack {
                        Circle()
                            .fill(dataset.isShared ? Color.green : Color.gray)
                            .frame(width: 10, height: 10)
                        Text(dataset.isShared ? "Shared" : "Not Shared")
                            .foregroundColor(dataset.isShared ? .green : .secondary)
                        if dataset.isShared && dataset.sharenfs != "on" {
                            Text("(\(dataset.sharenfs))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Divider()

                // Enable/disable sharing
                Toggle("Enable NFS Sharing", isOn: $shareEnabled)
                    .font(.headline)

                if shareEnabled {
                    // Sharing options
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Read-only", isOn: $readOnly)
                            .font(.subheadline)

                        Toggle("Map root user", isOn: $mapRoot)
                            .font(.subheadline)
                        Text("Allows root access from NFS clients")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Network Restriction (Optional)")
                                .font(.subheadline)
                            TextField("e.g., 192.168.1.0", text: $networkRestriction)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                            Text("Leave empty to allow all networks")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.leading, 20)
                }
            }
            .padding()

            Spacer()

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(shareEnabled ? "Apply Sharing" : "Disable Sharing") {
                    if shareEnabled {
                        var options: [String] = []
                        if readOnly {
                            options.append("-ro")
                        }
                        if mapRoot {
                            options.append("-maproot=root")
                        }
                        if !networkRestriction.isEmpty {
                            options.append("-network \(networkRestriction)")
                            options.append("-mask 255.255.255.0")
                        }
                        let shareValue = options.isEmpty ? "on" : options.joined(separator: " ")
                        onSave(shareValue)
                    } else {
                        onSave("off")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 480, height: 500)
    }
}

// MARK: - Modify Properties Sheet

struct ModifyPropertiesSheet: View {
    let dataset: ZFSDataset
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var selectedProperty = "compression"
    @State private var propertyValue = ""

    let commonProperties = [
        ("compression", "Compression algorithm"),
        ("quota", "Maximum size"),
        ("reservation", "Guaranteed space"),
        ("recordsize", "Record size (filesystem only)"),
        ("mountpoint", "Mount location (filesystem only)"),
        ("readonly", "Read-only mode"),
        ("atime", "Access time updates"),
        ("exec", "Allow program execution")
    ]

    var body: some View {
        VStack(spacing: 0) {
            Text("Modify Properties")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 20)
                .padding(.bottom, 8)

            Text(dataset.name)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.bottom, 16)

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                Text("Select a property to modify")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(commonProperties, id: \.0) { property, description in
                        VStack(alignment: .leading, spacing: 4) {
                            Button(action: {
                                selectedProperty = property
                                // Set default/current values
                                switch property {
                                case "compression":
                                    propertyValue = dataset.compression
                                case "quota":
                                    propertyValue = dataset.quota
                                case "reservation":
                                    propertyValue = dataset.reservation
                                case "mountpoint":
                                    propertyValue = dataset.mountpoint
                                default:
                                    propertyValue = ""
                                }
                            }) {
                                HStack {
                                    Image(systemName: selectedProperty == property ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedProperty == property ? .blue : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(property)
                                            .font(.body)
                                        Text(description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("New Value")
                        .font(.headline)
                    TextField("Enter new value", text: $propertyValue)
                        .textFieldStyle(.roundedBorder)

                    // Show hints based on selected property
                    if selectedProperty == "compression" {
                        Text("Examples: off, lz4, gzip, zle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if selectedProperty == "quota" || selectedProperty == "reservation" {
                        Text("Examples: 100G, 1T, none")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if selectedProperty == "recordsize" {
                        Text("Examples: 128K, 256K, 1M")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if selectedProperty == "readonly" || selectedProperty == "atime" || selectedProperty == "exec" {
                        Text("Values: on, off")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .frame(height: 450)

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    onSave(selectedProperty, propertyValue)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(propertyValue.isEmpty)
            }
            .padding()
        }
        .frame(width: 500)
        .onAppear {
            propertyValue = dataset.compression
        }
    }
}
