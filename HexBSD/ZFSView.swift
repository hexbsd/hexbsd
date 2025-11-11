//
//  ZFSView.swift
//  HexBSD
//
//  ZFS pool and dataset management
//

import SwiftUI
import AppKit

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

    var isSnapshot: Bool {
        type == "snapshot" || name.contains("@")
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
        switch type {
        case "filesystem":
            return "folder.fill"
        case "volume":
            return "externaldrive.fill"
        default:
            return "cylinder"
        }
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
    @State private var selectedView: ZFSViewType = .pools
    @State private var showError = false

    enum ZFSViewType: String, CaseIterable {
        case pools = "Pools"
        case datasets = "Datasets"
        case bootEnvironments = "Boot Environments"
        case replication = "Replication"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segmented control for view selection
            Picker("View", selection: $selectedView) {
                ForEach(ZFSViewType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // Content based on selected view
            Group {
                switch selectedView {
                case .pools:
                    PoolsView(viewModel: viewModel)
                case .datasets:
                    DatasetsView(viewModel: viewModel)
                case .bootEnvironments:
                    BootEnvironmentsContentView()
                case .replication:
                    ReplicationView(viewModel: viewModel)
                }
            }
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

// MARK: - Pools View

struct PoolsView: View {
    @ObservedObject var viewModel: ZFSViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("\(viewModel.pools.count) pool(s)")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    Task {
                        await viewModel.refreshPools()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
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

    var hasChildren: Bool {
        !children.isEmpty
    }

    init(dataset: ZFSDataset) {
        self.dataset = dataset
    }
}

struct DatasetsView: View {
    @ObservedObject var viewModel: ZFSViewModel
    @State private var selectedDataset: ZFSDataset?
    @State private var showCreateSnapshot = false
    @State private var showCloneDataset = false
    @State private var snapshotName = ""
    @State private var cloneDestination = ""
    @State private var expandedDatasets: Set<String> = []

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

        // Add snapshots as children of their parent datasets
        let snapshots = viewModel.datasets.filter { $0.isSnapshot }.sorted { $0.name < $1.name }
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
            // Toolbar
            HStack {
                Text("\(datasetsCount) dataset(s), \(snapshotsCount) snapshot(s)")
                    .font(.headline)
                    .foregroundColor(.secondary)

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
                            Task {
                                await viewModel.deleteSnapshot(snapshot: dataset.name)
                            }
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        // Dataset actions
                        Button(action: {
                            snapshotName = ""
                            showCreateSnapshot = true
                        }) {
                            Label("Create Snapshot", systemImage: "camera")
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: {
                            cloneDestination = ""
                            showCloneDataset = true
                        }) {
                            Label("Clone", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Button(action: {
                    Task {
                        await viewModel.refreshDatasets()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
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
                List(selection: $selectedDataset) {
                    ForEach(buildHierarchy()) { node in
                        DatasetNodeView(
                            node: node,
                            level: 0,
                            expandedDatasets: $expandedDatasets,
                            selectedDataset: $selectedDataset
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showCreateSnapshot) {
            if let dataset = selectedDataset {
                CreateSnapshotSheet(
                    datasetName: dataset.name,
                    snapshotName: $snapshotName,
                    onCreate: {
                        Task {
                            await viewModel.createSnapshot(dataset: dataset.name, snapshotName: snapshotName)
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
    }
}

// MARK: - Dataset Node View

struct DatasetNodeView: View {
    @ObservedObject var node: DatasetNode
    let level: Int
    @Binding var expandedDatasets: Set<String>
    @Binding var selectedDataset: ZFSDataset?

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

                    HStack(spacing: 12) {
                        Label(node.dataset.used, systemImage: "")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if node.dataset.compression != "off" && node.dataset.compression != "-" {
                            Label("\(node.dataset.compression) (\(node.dataset.compressRatio))", systemImage: "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if node.dataset.mountpoint != "-" && !node.dataset.isSnapshot {
                            Label(node.dataset.mountpoint, systemImage: "folder")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

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
            }
            .padding(.vertical, 4)
            .padding(.leading, 8)
            .contentShape(Rectangle())
            .background(selectedDataset?.id == node.dataset.id ? Color.accentColor.opacity(0.2) : Color.clear)
            .onTapGesture {
                selectedDataset = node.dataset
            }

            // Children (if expanded)
            if node.isExpanded {
                ForEach(node.children) { childNode in
                    DatasetNodeView(
                        node: childNode,
                        level: level + 1,
                        expandedDatasets: $expandedDatasets,
                        selectedDataset: $selectedDataset
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

// MARK: - Create Snapshot Sheet

struct CreateSnapshotSheet: View {
    let datasetName: String
    @Binding var snapshotName: String
    let onCreate: () -> Void
    let onCancel: () -> Void

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
                TextField("e.g., backup-2025-01-01", text: $snapshotName)
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
        // Confirm deletion
        let alert = NSAlert()
        alert.messageText = "Delete snapshot?"
        alert.informativeText = "This will permanently delete the snapshot \(snapshot)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.deleteZFSSnapshot(snapshot: snapshot)
            await refreshDatasets()
        } catch {
            self.error = "Failed to delete snapshot: \(error.localizedDescription)"
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
}
