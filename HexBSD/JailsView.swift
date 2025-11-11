//
//  JailsView.swift
//  HexBSD
//
//  FreeBSD jails management
//

import SwiftUI

// MARK: - Jail Models

struct Jail: Identifiable, Hashable {
    let id: String  // JID or name
    let jid: String
    let name: String
    let hostname: String
    let path: String
    let ip: String
    let status: JailStatus
    let isManaged: Bool  // True if configured in /etc/jail.conf or /etc/jail.conf.d/

    var isRunning: Bool {
        status == .running
    }
}

enum JailStatus: String {
    case running = "Running"
    case stopped = "Stopped"
    case unknown = "Unknown"

    var color: Color {
        switch self {
        case .running: return .green
        case .stopped: return .secondary
        case .unknown: return .orange
        }
    }

    var icon: String {
        switch self {
        case .running: return "play.circle.fill"
        case .stopped: return "stop.circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct JailConfig {
    let name: String
    let path: String
    let hostname: String
    let ip: String
    let parameters: [String: String]
}

struct JailResourceUsage {
    let cpuPercent: Double
    let memoryUsed: String
    let memoryLimit: String
    let processCount: Int
}

// MARK: - Jails Content View

struct JailsContentView: View {
    @StateObject private var viewModel = JailsViewModel()
    @State private var showError = false
    @State private var selectedJail: Jail?
    @State private var searchText = ""
    @State private var showConsole = false
    @State private var consoleJailName = ""

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "building.2")
                        .foregroundColor(.blue)
                    if viewModel.jails.isEmpty {
                        Text("No jails")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        let runningCount = viewModel.jails.filter { $0.isRunning }.count
                        Text("\(viewModel.jails.count) jail\(viewModel.jails.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: "circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 6))
                            Text("\(runningCount) running")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                Button(action: {
                    Task {
                        await viewModel.refresh()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                Toggle(isOn: $viewModel.autoRefresh) {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .toggleStyle(.button)
                .help("Auto-refresh every 5 seconds")
            }
            .padding()

            Divider()

            // Content area
            if viewModel.isLoading && viewModel.jails.isEmpty {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading jails...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.jails.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "building.2")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Jails Found")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text("No running or configured jails detected")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("To create a jail:")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("• Configure /etc/jail.conf for jail(8)")
                            .font(.caption2)
                        Text("• Or use your favorite jail manager")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    // Jails list
                    VStack(spacing: 0) {
                        // Search
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("Search jails...", text: $searchText)
                                .textFieldStyle(.plain)

                            if !searchText.isEmpty {
                                Button(action: {
                                    searchText = ""
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                        Divider()

                        List(filteredJails, selection: $selectedJail) { jail in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: jail.status.icon)
                                        .foregroundColor(jail.status.color)
                                        .font(.caption)
                                    Text(jail.name)
                                        .font(.headline)
                                    Spacer()
                                    Text(jail.status.rawValue)
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(jail.status.color.opacity(0.2))
                                        .foregroundColor(jail.status.color)
                                        .cornerRadius(4)
                                }

                                if !jail.hostname.isEmpty {
                                    HStack(spacing: 4) {
                                        Image(systemName: "network")
                                            .font(.caption2)
                                        Text(jail.hostname)
                                            .font(.caption)
                                    }
                                    .foregroundColor(.secondary)
                                }

                                if !jail.ip.isEmpty {
                                    HStack(spacing: 4) {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                            .font(.caption2)
                                        Text(jail.ip)
                                            .font(.caption)
                                    }
                                    .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(jail)
                        }
                    }
                    .frame(minWidth: 300, idealWidth: 400)

                    // Detail view
                    if let jail = selectedJail {
                        JailDetailView(jail: jail, viewModel: viewModel)
                    } else {
                        VStack(spacing: 20) {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("Select a jail to view details")
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .alert("Jails Error", isPresented: $showError) {
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
                await viewModel.loadJails()
            }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if viewModel.autoRefresh {
                Task {
                    await viewModel.refreshQuiet()
                }
            }
        }
    }

    private var filteredJails: [Jail] {
        guard !searchText.isEmpty else {
            return viewModel.jails
        }

        return viewModel.jails.filter { jail in
            jail.name.localizedCaseInsensitiveContains(searchText) ||
            jail.hostname.localizedCaseInsensitiveContains(searchText) ||
            jail.ip.localizedCaseInsensitiveContains(searchText) ||
            jail.path.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - Jail Detail View

struct JailDetailView: View {
    let jail: Jail
    @ObservedObject var viewModel: JailsViewModel
    @StateObject private var detailViewModel = JailDetailViewModel()
    @State private var showConfirmStop = false
    @State private var showConfirmRestart = false
    @State private var isPerformingAction = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with controls
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "building.2.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text(jail.name)
                                .font(.title)
                            if !jail.hostname.isEmpty {
                                Text(jail.hostname)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: jail.status.icon)
                                .foregroundColor(jail.status.color)
                            Text(jail.status.rawValue)
                                .fontWeight(.semibold)
                                .foregroundColor(jail.status.color)
                        }
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(jail.status.color.opacity(0.2))
                        .cornerRadius(6)
                    }

                    // Control buttons or privilege warning
                    if viewModel.hasElevatedPrivileges {
                        HStack(spacing: 8) {
                            if jail.isRunning {
                                // Only show stop/restart if jail is managed in rc.conf
                                if jail.isManaged {
                                    Button(action: {
                                        showConfirmStop = true
                                    }) {
                                        Label("Stop", systemImage: "stop.fill")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isPerformingAction)

                                    Button(action: {
                                        showConfirmRestart = true
                                    }) {
                                        Label("Restart", systemImage: "arrow.clockwise")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isPerformingAction)
                                }

                                Button(action: {
                                    openConsole()
                                }) {
                                    Label("Console", systemImage: "terminal")
                                }
                                .buttonStyle(.borderedProminent)
                            } else if jail.isManaged {
                                // Only show start button if jail is managed in rc.conf
                                Button(action: {
                                    Task {
                                        await startJail()
                                    }
                                }) {
                                    Label("Start", systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isPerformingAction)
                            }

                            if isPerformingAction {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                        }
                        .padding(.top, 8)

                        // Show info message if jail is not managed
                        if !jail.isManaged {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                                Text("Jail not configured in /etc/jail.conf or /etc/jail.conf.d/ - only console access available")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    } else {
                        // Show privilege warning
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Root access required")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Text("Start, stop, restart, and console access require root privileges")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                        .padding(.top, 8)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                // Basic info
                VStack(alignment: .leading, spacing: 12) {
                    Text("Information")
                        .font(.headline)

                    if !jail.jid.isEmpty {
                        InfoRow(label: "JID", value: jail.jid)
                    }
                    if !jail.path.isEmpty {
                        InfoRow(label: "Path", value: jail.path)
                    }
                    if !jail.ip.isEmpty {
                        InfoRow(label: "IP Address", value: jail.ip)
                    }

                    // For stopped jails, show helpful message
                    if jail.status == .stopped {
                        Text("Jail is configured but not currently running")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }

                // Resource usage
                if jail.isRunning, let usage = detailViewModel.resourceUsage {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Resource Usage")
                            .font(.headline)

                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("CPU")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f%%", usage.cpuPercent))
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.blue)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Memory")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(usage.memoryUsed)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.green)
                                if !usage.memoryLimit.isEmpty {
                                    Text("of \(usage.memoryLimit)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Processes")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(usage.processCount)")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.orange)
                            }
                        }
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                    }
                }

                // Configuration
                if let config = detailViewModel.config {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Configuration")
                            .font(.headline)

                        ForEach(Array(config.parameters.keys.sorted()), id: \.self) { key in
                            if let value = config.parameters[key] {
                                InfoRow(label: key, value: value)
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding()
        }
        .alert("Stop Jail", isPresented: $showConfirmStop) {
            Button("Cancel", role: .cancel) {}
            Button("Stop", role: .destructive) {
                Task {
                    await stopJail()
                }
            }
        } message: {
            Text("Are you sure you want to stop '\(jail.name)'?")
        }
        .alert("Restart Jail", isPresented: $showConfirmRestart) {
            Button("Cancel", role: .cancel) {}
            Button("Restart", role: .destructive) {
                Task {
                    await restartJail()
                }
            }
        } message: {
            Text("Are you sure you want to restart '\(jail.name)'?")
        }
        .onAppear {
            Task {
                await detailViewModel.loadDetails(for: jail)
            }
        }
    }

    private func startJail() async {
        isPerformingAction = true
        await viewModel.startJail(jail)
        isPerformingAction = false
    }

    private func stopJail() async {
        isPerformingAction = true
        await viewModel.stopJail(jail)
        isPerformingAction = false
    }

    private func restartJail() async {
        isPerformingAction = true
        await viewModel.restartJail(jail)
        isPerformingAction = false
    }

    private func openConsole() {
        // Post notification to open terminal with jexec command
        let command = "jexec \(jail.name) /bin/sh"
        print("DEBUG: JailsView posting console command: \(command)")
        NotificationCenter.default.post(
            name: .openTerminalWithCommand,
            object: nil,
            userInfo: ["command": command]
        )
        print("DEBUG: Notification posted successfully")
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

// MARK: - Jail Detail View Model

@MainActor
class JailDetailViewModel: ObservableObject {
    @Published var config: JailConfig?
    @Published var resourceUsage: JailResourceUsage?
    @Published var isLoading = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadDetails(for jail: Jail) async {
        isLoading = true
        error = nil

        do {
            // Load config
            config = try await sshManager.getJailConfig(name: jail.name)

            // Load resource usage if running
            if jail.isRunning {
                resourceUsage = try await sshManager.getJailResourceUsage(name: jail.name)
            }
        } catch {
            self.error = "Failed to load jail details: \(error.localizedDescription)"
        }

        isLoading = false
    }
}

// MARK: - Jails View Model

@MainActor
class JailsViewModel: ObservableObject {
    @Published var jails: [Jail] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var autoRefresh: Bool = false
    @Published var hasElevatedPrivileges: Bool = false

    private let sshManager = SSHConnectionManager.shared

    func loadJails() async {
        isLoading = true
        error = nil

        do {
            // Check for elevated privileges
            hasElevatedPrivileges = try await sshManager.hasElevatedPrivileges()

            // Load jails
            jails = try await sshManager.listJails()
        } catch {
            self.error = "Failed to load jails: \(error.localizedDescription)"
            jails = []
        }

        isLoading = false
    }

    func refresh() async {
        await loadJails()
    }

    func refreshQuiet() async {
        error = nil

        do {
            // Update privilege status
            hasElevatedPrivileges = try await sshManager.hasElevatedPrivileges()
            jails = try await sshManager.listJails()
        } catch {
            print("Auto-refresh failed: \(error.localizedDescription)")
        }
    }

    func startJail(_ jail: Jail) async {
        error = nil

        do {
            try await sshManager.startJail(name: jail.name)
            await loadJails()
        } catch {
            self.error = "Failed to start jail: \(error.localizedDescription)"
        }
    }

    func stopJail(_ jail: Jail) async {
        error = nil

        do {
            try await sshManager.stopJail(name: jail.name)
            await loadJails()
        } catch {
            self.error = "Failed to stop jail: \(error.localizedDescription)"
        }
    }

    func restartJail(_ jail: Jail) async {
        error = nil

        do {
            try await sshManager.restartJail(name: jail.name)
            await loadJails()
        } catch {
            self.error = "Failed to restart jail: \(error.localizedDescription)"
        }
    }
}
