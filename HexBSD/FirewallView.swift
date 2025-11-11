//
//  FirewallView.swift
//  HexBSD
//
//  IPFW firewall management
//

import SwiftUI
import AppKit

// MARK: - Data Models

struct FirewallStatus: Identifiable {
    let id = UUID()
    let enabled: Bool
    let ruleCount: Int
    let stateCount: Int
}

struct FirewallRule: Identifiable, Hashable {
    let id = UUID()
    let number: String
    let action: String
    let proto: String
    let source: String
    let destination: String
    let options: String
    let packets: String?
    let bytes: String?

    var actionColor: Color {
        switch action.lowercased() {
        case "allow", "pass": return .green
        case "deny", "block": return .red
        case "reject": return .orange
        default: return .secondary
        }
    }
}

struct FirewallState: Identifiable, Hashable {
    let id = UUID()
    let proto: String
    let source: String
    let destination: String
    let state: String

    var stateColor: Color {
        switch state.uppercased() {
        case "ESTABLISHED": return .green
        case "SYN_SENT", "SYN_RECV": return .orange
        case "CLOSED", "TIME_WAIT": return .secondary
        default: return .blue
        }
    }
}

struct FirewallStats: Identifiable {
    let id = UUID()
    let packetsIn: String
    let packetsOut: String
    let bytesIn: String
    let bytesOut: String
    let blocked: String
    let passed: String
}

// MARK: - Main View

struct FirewallContentView: View {
    @StateObject private var viewModel = FirewallViewModel()
    @State private var selectedView: FirewallViewType = .rules
    @State private var showError = false

    enum FirewallViewType: String, CaseIterable {
        case rules = "Rules"
        case states = "States"
        case stats = "Statistics"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack {
                if let status = viewModel.status {
                    HStack(spacing: 12) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.title2)
                            .foregroundColor(status.enabled ? .green : .red)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("IPFW Firewall")
                                .font(.headline)

                            HStack(spacing: 12) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(status.enabled ? Color.green : Color.red)
                                        .frame(width: 8, height: 8)
                                    Text(status.enabled ? "Enabled" : "Disabled")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Text("\(status.ruleCount) rules")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if status.stateCount > 0 {
                                    Text("\(status.stateCount) states")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Text("Loading IPFW status...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    Task {
                        await viewModel.reloadRules()
                    }
                }) {
                    Label("Reload Rules", systemImage: "arrow.clockwise.circle")
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
            .padding()

            Divider()

            // Segmented control for view selection
            Picker("View", selection: $selectedView) {
                ForEach(FirewallViewType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // Content based on selected view
            Group {
                switch selectedView {
                case .rules:
                    RulesView(viewModel: viewModel)
                case .states:
                    StatesView(viewModel: viewModel)
                case .stats:
                    StatsView(viewModel: viewModel)
                }
            }
        }
        .alert("IPFW Error", isPresented: $showError) {
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

// MARK: - Rules View

struct RulesView: View {
    @ObservedObject var viewModel: FirewallViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("IPFW Rules")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding()

            Divider()

            if viewModel.isLoadingRules {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading rules...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.rules.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No IPFW Rules")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("IPFW is not enabled or no rules are configured")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(viewModel.rules) {
                    TableColumn("#", value: \.number)
                        .width(min: 60, ideal: 80, max: 100)

                    TableColumn("Action") { rule in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(rule.actionColor)
                                .frame(width: 8, height: 8)
                            Text(rule.action)
                                .foregroundColor(rule.actionColor)
                        }
                    }
                    .width(min: 80, ideal: 100, max: 120)

                    TableColumn("Proto", value: \.proto)
                        .width(min: 60, ideal: 80, max: 100)

                    TableColumn("Source", value: \.source)
                        .width(min: 120, ideal: 200)

                    TableColumn("Destination", value: \.destination)
                        .width(min: 120, ideal: 200)

                    TableColumn("Options", value: \.options)
                        .width(min: 100, ideal: 150)

                    TableColumn("Packets") { rule in
                        Text(rule.packets ?? "-")
                            .font(.caption)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Bytes") { rule in
                        Text(rule.bytes ?? "-")
                            .font(.caption)
                    }
                    .width(min: 80, ideal: 100)
                }
            }
        }
    }
}

// MARK: - States View

struct StatesView: View {
    @ObservedObject var viewModel: FirewallViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connection States")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    Task {
                        await viewModel.refreshStates()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            if viewModel.isLoadingStates {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading states...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.states.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "network")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Active Connections")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No connection states tracked")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(viewModel.states) {
                    TableColumn("Protocol", value: \.proto)
                        .width(min: 80, ideal: 100)

                    TableColumn("Source", value: \.source)
                        .width(min: 150, ideal: 250)

                    TableColumn("Destination", value: \.destination)
                        .width(min: 150, ideal: 250)

                    TableColumn("State") { state in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(state.stateColor)
                                .frame(width: 8, height: 8)
                            Text(state.state)
                                .foregroundColor(state.stateColor)
                        }
                    }
                    .width(min: 120, ideal: 150)
                }
            }
        }
    }
}

// MARK: - Stats View

struct StatsView: View {
    @ObservedObject var viewModel: FirewallViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("IPFW Statistics")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    Task {
                        await viewModel.refreshStats()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            if viewModel.isLoadingStats {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading statistics...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let stats = viewModel.stats {
                ScrollView {
                    VStack(spacing: 20) {
                        // Traffic overview
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 20) {
                            StatCard(
                                title: "Packets In",
                                value: stats.packetsIn,
                                icon: "arrow.down.circle",
                                color: .blue
                            )

                            StatCard(
                                title: "Packets Out",
                                value: stats.packetsOut,
                                icon: "arrow.up.circle",
                                color: .green
                            )

                            StatCard(
                                title: "Bytes In",
                                value: stats.bytesIn,
                                icon: "arrow.down",
                                color: .blue
                            )

                            StatCard(
                                title: "Bytes Out",
                                value: stats.bytesOut,
                                icon: "arrow.up",
                                color: .green
                            )

                            StatCard(
                                title: "Blocked",
                                value: stats.blocked,
                                icon: "xmark.shield",
                                color: .red
                            )

                            StatCard(
                                title: "Passed",
                                value: stats.passed,
                                icon: "checkmark.shield",
                                color: .green
                            )
                        }
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Statistics Available")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Text(title)
                    .font(.headline)
                Spacer()
            }

            Text(value)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1)
        )
    }
}

// MARK: - View Model

@MainActor
class FirewallViewModel: ObservableObject {
    @Published var status: FirewallStatus?
    @Published var rules: [FirewallRule] = []
    @Published var states: [FirewallState] = []
    @Published var stats: FirewallStats?
    @Published var isLoadingRules = false
    @Published var isLoadingStates = false
    @Published var isLoadingStats = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadStatus() async {
        do {
            status = try await sshManager.getFirewallStatus()

            // Auto-load rules and stats
            await refreshRules()
            await refreshStates()
            await refreshStats()
        } catch {
            self.error = "Failed to load firewall status: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        await loadStatus()
    }

    func refreshRules() async {
        isLoadingRules = true
        error = nil

        do {
            rules = try await sshManager.getFirewallRules()
        } catch {
            self.error = "Failed to load rules: \(error.localizedDescription)"
            rules = []
        }

        isLoadingRules = false
    }

    func refreshStates() async {
        isLoadingStates = true
        error = nil

        do {
            states = try await sshManager.getFirewallStates()
        } catch {
            self.error = "Failed to load states: \(error.localizedDescription)"
            states = []
        }

        isLoadingStates = false
    }

    func refreshStats() async {
        isLoadingStats = true
        error = nil

        do {
            stats = try await sshManager.getFirewallStats()
        } catch {
            self.error = "Failed to load statistics: \(error.localizedDescription)"
            stats = nil
        }

        isLoadingStats = false
    }

    func reloadRules() async {
        let alert = NSAlert()
        alert.messageText = "Reload IPFW Rules?"
        alert.informativeText = "This will reload the IPFW configuration from /etc/rc.firewall or your custom script."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.reloadFirewallRules()
            await refresh()
        } catch {
            self.error = "Failed to reload rules: \(error.localizedDescription)"
        }
    }
}
