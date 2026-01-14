//
//  SecurityView.swift
//  HexBSD
//
//  Security center with vulnerability scanning, network connections, and firewall management
//

import SwiftUI

// MARK: - Security Tab Enum

enum SecurityTab: String, CaseIterable {
    case audit = "Audit"
    case connections = "Connections"
    case firewall = "Firewall"

    var icon: String {
        switch self {
        case .audit: return "exclamationmark.shield"
        case .connections: return "network"
        case .firewall: return "flame"
        }
    }
}

// MARK: - Main Security Content View

struct SecurityContentView: View {
    @State private var selectedTab: SecurityTab = .audit

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(SecurityTab.allCases, id: \.self) { tab in
                    Button(action: {
                        selectedTab = tab
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                            Text(tab.rawValue)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
                        .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Tab content
            switch selectedTab {
            case .audit:
                AuditTabView()
            case .connections:
                ConnectionsTabView()
            case .firewall:
                FirewallTabView()
            }
        }
    }
}

// MARK: - Vulnerability Models

struct Vulnerability: Identifiable, Hashable {
    let id = UUID()
    let packageName: String
    let version: String
    let vuln: String  // CVE or VuXML ID
    let description: String
    let url: String

    var severity: VulnerabilitySeverity {
        // Parse severity from description or CVE
        let desc = description.lowercased()
        if desc.contains("critical") || desc.contains("remote code execution") {
            return .critical
        } else if desc.contains("high") || desc.contains("privilege escalation") {
            return .high
        } else if desc.contains("medium") || desc.contains("moderate") {
            return .medium
        } else {
            return .low
        }
    }
}

enum VulnerabilitySeverity: String {
    case critical = "Critical"
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    var color: Color {
        switch self {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        }
    }

    var icon: String {
        switch self {
        case .critical: return "exclamationmark.triangle.fill"
        case .high: return "exclamationmark.triangle"
        case .medium: return "exclamationmark.circle"
        case .low: return "info.circle"
        }
    }
}

struct SecurityStatus {
    let hasVulnerabilities: Bool
    let totalVulnerabilities: Int
    let criticalCount: Int
    let highCount: Int
    let mediumCount: Int
    let lowCount: Int
    let hasBaseUpdates: Bool
    let baseUpdatesAvailable: Int
    let lastAuditDate: String
}

// MARK: - Audit Tab View

struct AuditTabView: View {
    @StateObject private var viewModel = AuditViewModel()
    @State private var showError = false
    @State private var selectedVulnerability: Vulnerability?
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar - only show after initial scan or when loading/has results
            if viewModel.isLoading || viewModel.hasScanned {
                HStack {
                    HStack(spacing: 4) {
                        if viewModel.isLoading {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else if viewModel.status.hasVulnerabilities {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundColor(.red)
                            Text("\(viewModel.status.totalVulnerabilities) vulnerabilities found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundColor(.green)
                            Text("No vulnerabilities")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Button(action: {
                        Task {
                            await viewModel.refresh()
                        }
                    }) {
                        Label("Scan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
                .padding()

                Divider()
            }

            // Content area
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Scanning for vulnerabilities...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(viewModel.loadingMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.vulnerabilities.isEmpty && !viewModel.hasScanned {
                // Initial state
                VStack(spacing: 20) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 72))
                        .foregroundColor(.blue)
                    Text("Security Vulnerability Scanner")
                        .font(.title)
                        .foregroundColor(.primary)
                    Text("Scan your system for known security vulnerabilities")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button(action: {
                        Task {
                            await viewModel.scanVulnerabilities()
                        }
                    }) {
                        Label("Start Security Scan", systemImage: "play.fill")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("This scan will:")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("• Check installed packages against VuXML database")
                            .font(.caption2)
                        Text("• Check for base system security updates")
                            .font(.caption2)
                        Text("• Identify CVE vulnerabilities")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if viewModel.vulnerabilities.isEmpty {
                // No vulnerabilities found
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 72))
                        .foregroundColor(.green)
                    Text("System is Secure")
                        .font(.title)
                        .foregroundColor(.primary)
                    Text("No known vulnerabilities found")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if !viewModel.status.lastAuditDate.isEmpty {
                        Text("Last scanned: \(viewModel.status.lastAuditDate)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Show vulnerabilities
                HSplitView {
                    // List view
                    VStack(spacing: 0) {
                        // Summary cards
                        HStack(spacing: 12) {
                            if viewModel.status.criticalCount > 0 {
                                SeverityCard(severity: .critical, count: viewModel.status.criticalCount)
                            }
                            if viewModel.status.highCount > 0 {
                                SeverityCard(severity: .high, count: viewModel.status.highCount)
                            }
                            if viewModel.status.mediumCount > 0 {
                                SeverityCard(severity: .medium, count: viewModel.status.mediumCount)
                            }
                            if viewModel.status.lowCount > 0 {
                                SeverityCard(severity: .low, count: viewModel.status.lowCount)
                            }
                        }
                        .padding()

                        Divider()

                        // Search
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("Search vulnerabilities...", text: $searchText)
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

                        // Vulnerability list
                        List(filteredVulnerabilities, selection: $selectedVulnerability) { vuln in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: vuln.severity.icon)
                                        .foregroundColor(vuln.severity.color)
                                        .font(.caption)
                                    Text(vuln.packageName)
                                        .font(.headline)
                                    Spacer()
                                    Text(vuln.severity.rawValue)
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(vuln.severity.color.opacity(0.2))
                                        .foregroundColor(vuln.severity.color)
                                        .cornerRadius(4)
                                }

                                Text(vuln.vuln)
                                    .font(.caption)
                                    .foregroundColor(.blue)

                                Text(vuln.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                            .tag(vuln)
                        }
                    }
                    .frame(minWidth: 300, idealWidth: 400)

                    // Detail view
                    if let vuln = selectedVulnerability {
                        VulnerabilityDetailView(vulnerability: vuln)
                    } else {
                        VStack(spacing: 20) {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("Select a vulnerability to view details")
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .alert("Security Scan Error", isPresented: $showError) {
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
    }

    private var filteredVulnerabilities: [Vulnerability] {
        guard !searchText.isEmpty else {
            return viewModel.vulnerabilities
        }

        return viewModel.vulnerabilities.filter { vuln in
            vuln.packageName.localizedCaseInsensitiveContains(searchText) ||
            vuln.vuln.localizedCaseInsensitiveContains(searchText) ||
            vuln.description.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - Severity Card

struct SeverityCard: View {
    let severity: VulnerabilitySeverity
    let count: Int

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: severity.icon)
                    .foregroundColor(severity.color)
                    .font(.caption)
                Text(severity.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text("\(count)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(severity.color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(severity.color.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Vulnerability Detail View

struct VulnerabilityDetailView: View {
    let vulnerability: Vulnerability

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: vulnerability.severity.icon)
                            .font(.system(size: 36))
                            .foregroundColor(vulnerability.severity.color)
                        VStack(alignment: .leading) {
                            Text(vulnerability.packageName)
                                .font(.title)
                            Text(vulnerability.version)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(vulnerability.severity.rawValue)
                            .font(.headline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(vulnerability.severity.color.opacity(0.2))
                            .foregroundColor(vulnerability.severity.color)
                            .cornerRadius(6)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                // CVE/VuXML ID
                VStack(alignment: .leading, spacing: 8) {
                    Text("Vulnerability ID")
                        .font(.headline)
                    Text(vulnerability.vuln)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundColor(.blue)
                }

                // Description
                VStack(alignment: .leading, spacing: 8) {
                    Text("Description")
                        .font(.headline)
                    Text(vulnerability.description)
                        .textSelection(.enabled)
                }

                // URL
                if !vulnerability.url.isEmpty, let url = URL(string: vulnerability.url) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("More Information")
                            .font(.headline)
                        Link(vulnerability.url, destination: url)
                            .onHover { hovering in
                                if hovering {
                                    NSCursor.pointingHand.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                    }
                }

                // Recommendations
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recommended Action")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "1.circle.fill")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Update the package")
                                    .fontWeight(.semibold)
                                Text("pkg upgrade \(vulnerability.packageName)")
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .cornerRadius(6)
                                    .textSelection(.enabled)
                            }
                        }

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "2.circle.fill")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Or update all packages")
                                    .fontWeight(.semibold)
                                Text("pkg upgrade")
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .cornerRadius(6)
                                    .textSelection(.enabled)
                            }
                        }

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "3.circle.fill")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Verify the fix")
                                    .fontWeight(.semibold)
                                Text("pkg audit -F")
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .cornerRadius(6)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding()
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(8)
                }

                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - Audit View Model

@MainActor
class AuditViewModel: ObservableObject {
    @Published var vulnerabilities: [Vulnerability] = []
    @Published var status = SecurityStatus(
        hasVulnerabilities: false,
        totalVulnerabilities: 0,
        criticalCount: 0,
        highCount: 0,
        mediumCount: 0,
        lowCount: 0,
        hasBaseUpdates: false,
        baseUpdatesAvailable: 0,
        lastAuditDate: ""
    )
    @Published var isLoading = false
    @Published var loadingMessage = ""
    @Published var error: String?
    @Published var hasScanned = false

    private let sshManager = SSHConnectionManager.shared

    func scanVulnerabilities() async {
        isLoading = true
        loadingMessage = "Fetching VuXML database..."
        error = nil
        hasScanned = true

        do {
            vulnerabilities = try await sshManager.auditPackageVulnerabilities()

            // Calculate status
            let critical = vulnerabilities.filter { $0.severity == .critical }.count
            let high = vulnerabilities.filter { $0.severity == .high }.count
            let medium = vulnerabilities.filter { $0.severity == .medium }.count
            let low = vulnerabilities.filter { $0.severity == .low }.count

            status = SecurityStatus(
                hasVulnerabilities: !vulnerabilities.isEmpty,
                totalVulnerabilities: vulnerabilities.count,
                criticalCount: critical,
                highCount: high,
                mediumCount: medium,
                lowCount: low,
                hasBaseUpdates: false,
                baseUpdatesAvailable: 0,
                lastAuditDate: formatDate(Date())
            )
        } catch {
            self.error = "Security scan failed: \(error.localizedDescription)"
            vulnerabilities = []
        }

        isLoading = false
    }

    func refresh() async {
        await scanVulnerabilities()
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Network Connection Models

struct NetworkConnection: Identifiable, Hashable {
    let id = UUID()
    let user: String
    let command: String
    let pid: String
    let proto: String
    let localAddress: String
    let foreignAddress: String
    let state: String

    var displayCommand: String {
        if command.count > 20 {
            return String(command.prefix(17)) + "..."
        }
        return command
    }

    var stateColor: Color {
        switch state.uppercased() {
        case "ESTABLISHED":
            return .green
        case "LISTEN":
            return .blue
        case "TIME_WAIT", "CLOSE_WAIT":
            return .orange
        case "SYN_SENT", "SYN_RCVD":
            return .yellow
        case "CLOSED", "FIN_WAIT_1", "FIN_WAIT_2":
            return .red
        default:
            return .secondary
        }
    }
}

// MARK: - Connections Tab View

struct ConnectionsTabView: View {
    @StateObject private var viewModel = ConnectionsViewModel()
    @State private var showError = false
    @State private var searchText = ""
    @State private var selectedProtocol = "all"

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                // Protocol filter
                Picker("", selection: $selectedProtocol) {
                    Text("All").tag("all")
                    Text("TCP").tag("tcp")
                    Text("UDP").tag("udp")
                    Text("IPv4").tag("4")
                    Text("IPv6").tag("6")
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

                Spacer()

                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search connections...", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 200)

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

                Button(action: {
                    Task {
                        await viewModel.refresh()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                Toggle(isOn: $viewModel.autoRefresh) {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .toggleStyle(.button)
                .help("Auto-refresh every 3 seconds")
            }
            .padding()

            Divider()

            // Connections table
            if viewModel.isLoading && viewModel.connections.isEmpty {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading connections...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredConnections.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(searchText.isEmpty ? "No active connections" : "No matching connections")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filteredConnections) {
                    TableColumn("User", value: \.user)
                        .width(min: 60, ideal: 80, max: 120)

                    TableColumn("Command") { conn in
                        Text(conn.displayCommand)
                            .textSelection(.enabled)
                    }
                    .width(min: 100, ideal: 150, max: 200)

                    TableColumn("PID", value: \.pid)
                        .width(min: 50, ideal: 60, max: 80)

                    TableColumn("Protocol", value: \.proto)
                        .width(min: 50, ideal: 70, max: 90)

                    TableColumn("Local Address") { conn in
                        Text(conn.localAddress)
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Foreign Address") { conn in
                        Text(conn.foreignAddress)
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("State") { conn in
                        if !conn.state.isEmpty {
                            Text(conn.state)
                                .foregroundColor(conn.stateColor)
                                .bold()
                        }
                    }
                    .width(min: 100, ideal: 120, max: 150)
                }

                // Summary
                HStack {
                    Text("\(filteredConnections.count) connections")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    if viewModel.autoRefresh {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                            Text("Auto-refreshing")
                                .font(.caption)
                        }
                        .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .alert("Connection Error", isPresented: $showError) {
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
                await viewModel.loadConnections()
            }
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            if viewModel.autoRefresh {
                Task {
                    await viewModel.refreshQuiet()
                }
            }
        }
    }

    private var filteredConnections: [NetworkConnection] {
        var results = viewModel.connections

        // Filter by protocol
        if selectedProtocol != "all" {
            results = results.filter { conn in
                conn.proto.lowercased().contains(selectedProtocol.lowercased())
            }
        }

        // Filter by search
        if !searchText.isEmpty {
            results = results.filter { conn in
                conn.user.localizedCaseInsensitiveContains(searchText) ||
                conn.command.localizedCaseInsensitiveContains(searchText) ||
                conn.pid.localizedCaseInsensitiveContains(searchText) ||
                conn.localAddress.localizedCaseInsensitiveContains(searchText) ||
                conn.foreignAddress.localizedCaseInsensitiveContains(searchText) ||
                conn.state.localizedCaseInsensitiveContains(searchText)
            }
        }

        return results
    }
}

// MARK: - Connections View Model

@MainActor
class ConnectionsViewModel: ObservableObject {
    @Published var connections: [NetworkConnection] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var autoRefresh: Bool = false

    private let sshManager = SSHConnectionManager.shared

    func loadConnections() async {
        isLoading = true
        error = nil

        do {
            connections = try await sshManager.listNetworkConnections()
        } catch {
            self.error = "Failed to load network connections: \(error.localizedDescription)"
            connections = []
        }

        isLoading = false
    }

    func refresh() async {
        await loadConnections()
    }

    func refreshQuiet() async {
        error = nil

        do {
            connections = try await sshManager.listNetworkConnections()
        } catch {
            print("Auto-refresh failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Firewall Models

struct FirewallRule: Identifiable, Hashable {
    let id = UUID()
    let ruleNumber: Int
    let action: String      // allow, deny, count, etc.
    let proto: String       // tcp, udp, ip, icmp, etc.
    let source: String
    let destination: String
    let options: String     // port numbers, flags, etc.
    let comment: String     // Comment after // in rule
    let rawRule: String     // Original rule text

    var actionColor: Color {
        switch action.lowercased() {
        case "allow", "pass", "permit":
            return .green
        case "deny", "drop", "reject":
            return .red
        case "count":
            return .orange
        default:
            return .secondary
        }
    }

    var isSystemRule: Bool {
        // Rules that shouldn't be deleted (loopback, outbound, deny-all)
        return ruleNumber == 100 || ruleNumber == 200 || ruleNumber >= 65534
    }

    var port: Int? {
        // Extract port from options
        let parts = options.components(separatedBy: .whitespaces)
        for part in parts {
            if let p = Int(part) {
                return p
            }
        }
        return nil
    }
}

enum FirewallStatus {
    case unknown
    case disabled
    case enabled
    case notInstalled
}

// MARK: - Common Services

struct FirewallService: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let icon: String
    let port: Int
    let proto: String
    let description: String

    static let commonServices: [FirewallService] = [
        FirewallService(name: "SSH", icon: "terminal", port: 22, proto: "tcp", description: "Secure Shell"),
        FirewallService(name: "HTTP", icon: "globe", port: 80, proto: "tcp", description: "Web Server"),
        FirewallService(name: "HTTPS", icon: "lock.shield", port: 443, proto: "tcp", description: "Secure Web Server"),
        FirewallService(name: "FTP", icon: "folder", port: 21, proto: "tcp", description: "File Transfer"),
        FirewallService(name: "SMTP", icon: "envelope", port: 25, proto: "tcp", description: "Email (Send)"),
        FirewallService(name: "DNS", icon: "network", port: 53, proto: "udp", description: "Domain Name Service"),
        FirewallService(name: "POP3", icon: "envelope.open", port: 110, proto: "tcp", description: "Email (Receive)"),
        FirewallService(name: "IMAP", icon: "tray", port: 143, proto: "tcp", description: "Email (IMAP)"),
        FirewallService(name: "MySQL", icon: "cylinder", port: 3306, proto: "tcp", description: "MySQL Database"),
        FirewallService(name: "PostgreSQL", icon: "cylinder.fill", port: 5432, proto: "tcp", description: "PostgreSQL Database"),
        FirewallService(name: "Redis", icon: "memorychip", port: 6379, proto: "tcp", description: "Redis Cache"),
        FirewallService(name: "MongoDB", icon: "leaf", port: 27017, proto: "tcp", description: "MongoDB Database"),
        FirewallService(name: "VNC", icon: "display", port: 5900, proto: "tcp", description: "Remote Desktop"),
        FirewallService(name: "RDP", icon: "desktopcomputer", port: 3389, proto: "tcp", description: "Windows Remote Desktop"),
        FirewallService(name: "Samba", icon: "externaldrive.connected.to.line.below", port: 445, proto: "tcp", description: "Windows File Sharing"),
        FirewallService(name: "NFS", icon: "externaldrive", port: 2049, proto: "tcp", description: "Network File System"),
    ]
}

// MARK: - Firewall Tab View

struct FirewallTabView: View {
    @StateObject private var viewModel = FirewallViewModel()
    @State private var showError = false
    @State private var showEnableConfirmation = false
    @State private var showDisableConfirmation = false
    @State private var showAddRuleSheet = false
    @State private var showDeleteConfirmation = false
    @State private var ruleToDelete: FirewallRule?
    @State private var selectedRule: FirewallRule?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar - only show when firewall is enabled or not installed
            if viewModel.status == .enabled || viewModel.status == .notInstalled {
                HStack {
                    HStack(spacing: 4) {
                        if viewModel.status == .enabled {
                            Image(systemName: "flame.fill")
                                .foregroundColor(.green)
                            Text("Firewall Active")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if viewModel.status == .notInstalled {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.red)
                            Text("ipfw not available")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    if viewModel.status == .enabled {
                        Button(action: {
                            showAddRuleSheet = true
                        }) {
                            Label("Add Rule", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)

                        Button(action: {
                            showDisableConfirmation = true
                        }) {
                            Label("Disable", systemImage: "stop.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.red)
                    }
                }
                .padding()

                Divider()
            }

            // Content
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text(viewModel.status == .unknown ? "Checking firewall status..." : "Configuring firewall...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.status == .disabled || viewModel.status == .unknown {
                // Firewall not enabled - show setup prompt
                VStack(spacing: 20) {
                    Image(systemName: "flame")
                        .font(.system(size: 72))
                        .foregroundColor(.orange)
                    Text("Firewall Not Configured")
                        .font(.title)
                        .foregroundColor(.primary)
                    Text("Enable the ipfw firewall to protect your system")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button(action: {
                        showEnableConfirmation = true
                    }) {
                        Label("Enable Firewall", systemImage: "flame.fill")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default configuration will:")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("• Allow SSH connections (port 22)")
                            .font(.caption2)
                        Text("• Allow established connections")
                            .font(.caption2)
                        Text("• Allow loopback traffic")
                            .font(.caption2)
                        Text("• Block all other incoming traffic")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if viewModel.status == .notInstalled {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 72))
                        .foregroundColor(.red)
                    Text("Firewall Not Available")
                        .font(.title)
                        .foregroundColor(.primary)
                    Text("ipfw is not available on this system")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Show firewall services (macOS-style)
                FirewallServicesView(viewModel: viewModel, showAddServiceSheet: $showAddRuleSheet)
            }
        }
        .alert("Enable Firewall", isPresented: $showEnableConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Enable") {
                Task {
                    await viewModel.enableFirewall()
                }
            }
        } message: {
            Text("This will enable ipfw with default rules that allow SSH (port 22) and block other incoming connections.")
        }
        .alert("Disable Firewall", isPresented: $showDisableConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Disable", role: .destructive) {
                Task {
                    await viewModel.disableFirewall()
                }
            }
        } message: {
            Text("This will disable the firewall and remove all rules. Your system will be unprotected from network attacks.")
        }
        .alert("Firewall Error", isPresented: $showError) {
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
                await viewModel.checkStatus()
            }
        }
    }
}

// MARK: - Firewall Services View (macOS-style)

struct FirewallServicesView: View {
    @ObservedObject var viewModel: FirewallViewModel
    @Binding var showAddServiceSheet: Bool

    // Get list of allowed ports from current rules
    var allowedPorts: Set<Int> {
        Set(viewModel.rules.compactMap { $0.port })
    }

    // Services that are currently allowed
    var allowedServices: [FirewallService] {
        FirewallService.commonServices.filter { allowedPorts.contains($0.port) }
    }

    // Custom ports (not in common services)
    var customAllowedPorts: [FirewallRule] {
        let commonPorts = Set(FirewallService.commonServices.map { $0.port })
        return viewModel.rules.filter { rule in
            if let port = rule.port, !commonPorts.contains(port) && rule.options.contains("in") {
                return true
            }
            return false
        }
    }

    // Services that are not allowed (available to add)
    var availableServices: [FirewallService] {
        FirewallService.commonServices.filter { !allowedPorts.contains($0.port) }
    }

    var body: some View {
        servicesContent
            .sheet(isPresented: $showAddServiceSheet) {
                AddServiceSheet(viewModel: viewModel, availableServices: availableServices)
            }
    }

    @ViewBuilder
    var servicesContent: some View {
        VStack(spacing: 0) {
            // Inbound policy toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Block all incoming connections")
                        .font(.subheadline)
                    Text("Only allow services listed below")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Allowed services list
            if allowedServices.isEmpty && customAllowedPorts.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "shield.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No services allowed")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("All incoming connections are blocked")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: { showAddServiceSheet = true }) {
                        Label("Allow a Service", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // Common services
                    ForEach(allowedServices) { service in
                        ServiceRow(service: service, isAllowed: true) {
                            Task {
                                await disableService(service)
                            }
                        }
                    }

                    // Custom ports
                    ForEach(customAllowedPorts) { rule in
                        CustomPortRow(rule: rule) {
                            Task {
                                await viewModel.deleteRule(rule)
                            }
                        }
                    }
                }
            }

            // Footer
            HStack {
                Text("\(allowedServices.count + customAllowedPorts.count) services allowed")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func disableService(_ service: FirewallService) async {
        // Find the rule for this service and delete it
        if let rule = viewModel.rules.first(where: { $0.port == service.port }) {
            await viewModel.deleteRule(rule)
        }
    }
}

// MARK: - Custom Port Row

struct CustomPortRow: View {
    let rule: FirewallRule
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "number")
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.comment.isEmpty ? "Port \(rule.port ?? 0)" : rule.comment)
                    .font(.headline)
                Text("Custom port")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("Port \(rule.port ?? 0)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(4)

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red)
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .help("Block this port")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Service Row

struct ServiceRow: View {
    let service: FirewallService
    let isAllowed: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: service.icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.headline)
                Text(service.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("Port \(service.port)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(4)

            Button(action: onToggle) {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red)
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .help("Block this service")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Add Service Sheet

struct AddServiceSheet: View {
    @ObservedObject var viewModel: FirewallViewModel
    @Environment(\.dismiss) private var dismiss
    let availableServices: [FirewallService]

    @State private var isAdding = false
    @State private var searchText = ""
    @State private var showCustomPort = false
    @State private var customPort = ""
    @State private var customProto = "tcp"
    @State private var customName = ""

    var filteredServices: [FirewallService] {
        if searchText.isEmpty {
            return availableServices
        }
        return availableServices.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText) ||
            String($0.port).contains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Allow Incoming Connections")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search services...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .padding()

            Divider()

            List {
                // Custom port section
                Section {
                    if showCustomPort {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                TextField("Port number", text: $customPort)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)

                                Picker("", selection: $customProto) {
                                    Text("TCP").tag("tcp")
                                    Text("UDP").tag("udp")
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 120)

                                TextField("Name (optional)", text: $customName)
                                    .textFieldStyle(.roundedBorder)

                                Button(action: {
                                    Task { await addCustomPort() }
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.title2)
                                }
                                .buttonStyle(.plain)
                                .disabled(customPort.isEmpty || Int(customPort) == nil || isAdding)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button(action: { showCustomPort = true }) {
                            HStack(spacing: 12) {
                                Image(systemName: "number")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Custom Port")
                                        .font(.headline)
                                    Text("Allow a specific port number")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Custom")
                }

                // Common services section
                Section {
                    if filteredServices.isEmpty && !searchText.isEmpty {
                        Text("No matching services")
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(filteredServices) { service in
                            AddServiceRow(service: service, isAdding: isAdding) {
                                Task {
                                    await allowService(service)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Common Services")
                }
            }
        }
        .frame(width: 500, height: 450)
    }

    private func allowService(_ service: FirewallService) async {
        isAdding = true

        do {
            let userRules = viewModel.rules.filter { $0.ruleNumber >= 1000 && $0.ruleNumber < 65000 }
            let nextRuleNum = (userRules.map { $0.ruleNumber }.max() ?? 999) + 1

            try await viewModel.addRule(
                ruleNumber: nextRuleNum,
                action: "allow",
                proto: service.proto,
                source: "any",
                destination: "any",
                port: service.port,
                direction: "in",
                comment: service.name
            )
        } catch {
            viewModel.error = error.localizedDescription
        }

        isAdding = false
    }

    private func addCustomPort() async {
        guard let port = Int(customPort) else { return }

        isAdding = true

        do {
            let userRules = viewModel.rules.filter { $0.ruleNumber >= 1000 && $0.ruleNumber < 65000 }
            let nextRuleNum = (userRules.map { $0.ruleNumber }.max() ?? 999) + 1

            let name = customName.isEmpty ? "Port \(port)" : customName

            try await viewModel.addRule(
                ruleNumber: nextRuleNum,
                action: "allow",
                proto: customProto,
                source: "any",
                destination: "any",
                port: port,
                direction: "in",
                comment: name
            )

            // Reset form
            customPort = ""
            customName = ""
            showCustomPort = false
        } catch {
            viewModel.error = error.localizedDescription
        }

        isAdding = false
    }
}

// MARK: - Add Service Row

struct AddServiceRow: View {
    let service: FirewallService
    let isAdding: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: service.icon)
                .font(.title2)
                .foregroundColor(.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .font(.headline)
                Text(service.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("Port \(service.port)")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(isAdding)
            .help("Allow this service")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Firewall View Model

@MainActor
class FirewallViewModel: ObservableObject {
    @Published var status: FirewallStatus = .unknown
    @Published var rules: [FirewallRule] = []
    @Published var isLoading = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func checkStatus() async {
        isLoading = true
        error = nil

        do {
            let result = try await sshManager.getFirewallStatus()
            status = result.status
            rules = result.rules
        } catch {
            self.error = "Failed to check firewall status: \(error.localizedDescription)"
            status = .unknown
        }

        isLoading = false
    }

    func enableFirewall() async {
        isLoading = true
        error = nil

        do {
            try await sshManager.enableFirewall()
            await checkStatus()
        } catch {
            self.error = "Failed to enable firewall: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func disableFirewall() async {
        isLoading = true
        error = nil

        do {
            try await sshManager.disableFirewall()
            await checkStatus()
        } catch {
            self.error = "Failed to disable firewall: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func refresh() async {
        await checkStatus()
    }

    func addRule(ruleNumber: Int, action: String, proto: String, source: String, destination: String, port: Int?, direction: String?, comment: String?) async throws {
        isLoading = true
        error = nil

        do {
            try await sshManager.addFirewallRule(
                ruleNumber: ruleNumber,
                action: action,
                proto: proto,
                source: source,
                destination: destination,
                port: port,
                direction: direction,
                comment: comment
            )
            await checkStatus()
        } catch {
            self.error = "Failed to add rule: \(error.localizedDescription)"
            isLoading = false
            throw error
        }

        isLoading = false
    }

    func deleteRule(_ rule: FirewallRule) async {
        isLoading = true
        error = nil

        do {
            try await sshManager.deleteFirewallRule(ruleNumber: rule.ruleNumber)
            await checkStatus()
        } catch {
            self.error = "Failed to delete rule: \(error.localizedDescription)"
        }

        isLoading = false
    }
}
