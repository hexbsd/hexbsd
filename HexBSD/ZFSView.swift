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
        case snapshots = "Snapshots"
        case scrub = "Scrub"
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
                case .snapshots:
                    SnapshotsView(viewModel: viewModel)
                case .scrub:
                    ScrubView(viewModel: viewModel)
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

            // Pools table
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
                Table(viewModel.pools) {
                    TableColumn("Name") { pool in
                        HStack(spacing: 8) {
                            Image(systemName: "cylinder.fill")
                                .foregroundColor(.blue)
                            Text(pool.name)
                                .fontWeight(.medium)
                        }
                    }

                    TableColumn("Health") { pool in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(pool.healthColor)
                                .frame(width: 8, height: 8)
                            Text(pool.health)
                                .foregroundColor(pool.healthColor)
                        }
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Size", value: \.size)
                        .width(min: 80, ideal: 100)

                    TableColumn("Allocated", value: \.allocated)
                        .width(min: 80, ideal: 100)

                    TableColumn("Free", value: \.free)
                        .width(min: 80, ideal: 100)

                    TableColumn("Capacity") { pool in
                        HStack(spacing: 8) {
                            ProgressView(value: pool.capacityPercentage, total: 100)
                                .frame(width: 60)
                            Text(pool.capacity)
                                .font(.caption)
                        }
                    }
                    .width(min: 100, ideal: 120)

                    TableColumn("Fragmentation", value: \.fragmentation)
                        .width(min: 80, ideal: 100)
                }
            }
        }
    }
}

// MARK: - Datasets View

struct DatasetsView: View {
    @ObservedObject var viewModel: ZFSViewModel
    @State private var selectedDatasets: Set<ZFSDataset.ID> = []
    @State private var showCreateSnapshot = false
    @State private var showCloneDataset = false
    @State private var snapshotName = ""
    @State private var cloneDestination = ""

    private var selectedDataset: ZFSDataset? {
        guard let id = selectedDatasets.first else { return nil }
        return viewModel.datasets.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("\(viewModel.datasets.count) dataset(s)")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                if let dataset = selectedDataset {
                    Button(action: {
                        snapshotName = ""
                        showCreateSnapshot = true
                    }) {
                        Label("Snapshot", systemImage: "camera")
                    }
                    .buttonStyle(.bordered)
                    .disabled(dataset.isSnapshot)

                    Button(action: {
                        cloneDestination = ""
                        showCloneDataset = true
                    }) {
                        Label("Clone", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!dataset.isSnapshot)
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

            // Datasets table
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
                    Text("No Datasets")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(viewModel.datasets, selection: $selectedDatasets) {
                    TableColumn("Name") { dataset in
                        HStack(spacing: 8) {
                            Image(systemName: dataset.icon)
                                .foregroundColor(dataset.isSnapshot ? .orange : .blue)
                            Text(dataset.name)
                        }
                    }
                    .width(min: 200, ideal: 300)

                    TableColumn("Type", value: \.type)
                        .width(min: 80, ideal: 100)

                    TableColumn("Used", value: \.used)
                        .width(min: 80, ideal: 100)

                    TableColumn("Available", value: \.available)
                        .width(min: 80, ideal: 100)

                    TableColumn("Referenced", value: \.referenced)
                        .width(min: 80, ideal: 100)

                    TableColumn("Compression") { dataset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dataset.compression)
                                .font(.caption)
                            Text(dataset.compressRatio)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Quota", value: \.quota)
                        .width(min: 80, ideal: 100)

                    TableColumn("Mountpoint", value: \.mountpoint)
                        .width(min: 120, ideal: 200)
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
                    snapshotName: dataset.name,
                    destination: $cloneDestination,
                    onClone: {
                        Task {
                            await viewModel.cloneDataset(snapshot: dataset.name, destination: cloneDestination)
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

// MARK: - Snapshots View

struct SnapshotsView: View {
    @ObservedObject var viewModel: ZFSViewModel
    @State private var selectedSnapshots: Set<ZFSDataset.ID> = []

    var snapshots: [ZFSDataset] {
        viewModel.datasets.filter { $0.isSnapshot }
    }

    private var selectedSnapshot: ZFSDataset? {
        guard let id = selectedSnapshots.first else { return nil }
        return snapshots.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("\(snapshots.count) snapshot(s)")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                if let snapshot = selectedSnapshot {
                    Button(action: {
                        Task {
                            await viewModel.rollbackSnapshot(snapshot: snapshot.name)
                        }
                    }) {
                        Label("Rollback", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)

                    Button(action: {
                        Task {
                            await viewModel.deleteSnapshot(snapshot: snapshot.name)
                        }
                    }) {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
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

            // Snapshots table
            if viewModel.isLoadingDatasets {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading snapshots...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshots.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "camera")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Snapshots")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(snapshots, selection: $selectedSnapshots) {
                    TableColumn("Snapshot") { snapshot in
                        HStack(spacing: 8) {
                            Image(systemName: "camera")
                                .foregroundColor(.orange)
                            Text(snapshot.name)
                        }
                    }
                    .width(min: 200, ideal: 350)

                    TableColumn("Used", value: \.used)
                        .width(min: 80, ideal: 100)

                    TableColumn("Referenced", value: \.referenced)
                        .width(min: 80, ideal: 100)
                }
            }
        }
    }
}

// MARK: - Scrub View

struct ScrubView: View {
    @ObservedObject var viewModel: ZFSViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Pool Scrub Status")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    Task {
                        await viewModel.refreshScrubStatus()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // Scrub status
            if viewModel.isLoadingScrub {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading scrub status...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.scrubStatuses.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Scrub Information")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(viewModel.scrubStatuses) { status in
                            ScrubStatusCard(status: status, viewModel: viewModel)
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

struct ScrubStatusCard: View {
    let status: ZFSScrubStatus
    @ObservedObject var viewModel: ZFSViewModel

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "cylinder.fill")
                        .foregroundColor(.blue)
                    Text(status.poolName)
                        .font(.title3)
                        .fontWeight(.semibold)
                }

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(status.statusColor)
                        .frame(width: 8, height: 8)
                    Text(status.state)
                        .font(.caption)
                        .foregroundColor(status.statusColor)
                }
            }

            // Progress bar if in progress
            if status.isInProgress, let progress = status.progress {
                VStack(spacing: 4) {
                    ProgressView(value: progress, total: 100)
                    HStack {
                        Text(String(format: "%.1f%%", progress))
                            .font(.caption)
                        Spacer()
                        if let scanned = status.scanned {
                            Text("Scanned: \(scanned)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // Details
            VStack(spacing: 8) {
                if let duration = status.duration {
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
                    Text("\(status.errors)")
                        .font(.caption)
                        .foregroundColor(status.errors > 0 ? .red : .primary)
                }
            }

            // Actions
            HStack {
                if status.isInProgress {
                    Button(action: {
                        Task {
                            await viewModel.stopScrub(pool: status.poolName)
                        }
                    }) {
                        Label("Stop Scrub", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: {
                        Task {
                            await viewModel.startScrub(pool: status.poolName)
                        }
                    }) {
                        Label("Start Scrub", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1)
        )
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
    let snapshotName: String
    @Binding var destination: String
    let onClone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Clone Dataset")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 8) {
                Text("Source Snapshot")
                    .font(.caption)
                Text(snapshotName)
                    .font(.body)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                Text("Destination Dataset")
                    .font(.caption)
                TextField("e.g., pool/cloned-dataset", text: $destination)
                    .textFieldStyle(.roundedBorder)

                Text("This will create a new dataset from the snapshot")
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
        .frame(width: 450)
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

    func cloneDataset(snapshot: String, destination: String) async {
        error = nil

        do {
            try await sshManager.cloneZFSDataset(snapshot: snapshot, destination: destination)
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
