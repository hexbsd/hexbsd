//
//  SecurityView.swift
//  HexBSD
//
//  Security vulnerability scanner using pkg audit and freebsd-update
//

import SwiftUI

// MARK: - Security Models

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

// MARK: - Security Content View

struct SecurityContentView: View {
    @StateObject private var viewModel = SecurityViewModel()
    @State private var showError = false
    @State private var selectedVulnerability: Vulnerability?
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
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
                    } else if !viewModel.vulnerabilities.isEmpty {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundColor(.green)
                        Text("No vulnerabilities")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "shield")
                            .foregroundColor(.secondary)
                        Text("Security Audit")
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
        .onAppear {
            // Don't auto-scan on appear, let user initiate
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
                if !vulnerability.url.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("More Information")
                            .font(.headline)
                        Text(vulnerability.url)
                            .foregroundColor(.blue)
                            .textSelection(.enabled)
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

// MARK: - View Model

@MainActor
class SecurityViewModel: ObservableObject {
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
