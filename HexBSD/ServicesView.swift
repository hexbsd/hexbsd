//
//  ServicesView.swift
//  HexBSD
//
//  FreeBSD service management for base and ports services
//

import SwiftUI
import AppKit

// MARK: - Data Models

enum ServiceSource: String, CaseIterable {
    case base = "Base System"
    case ports = "Ports"

    var path: String {
        switch self {
        case .base: return "/etc/rc.d"
        case .ports: return "/usr/local/etc/rc.d"
        }
    }

    var icon: String {
        switch self {
        case .base: return "gearshape"
        case .ports: return "shippingbox"
        }
    }
}

enum ServiceStatus: String {
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
        case .running: return "circle.fill"
        case .stopped: return "circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct FreeBSDService: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let source: ServiceSource
    var status: ServiceStatus
    var enabled: Bool
    let description: String
    let rcVar: String  // The rc.conf variable name (e.g., "sshd_enable")
    let configPath: String?  // Path to config file if one exists

    var displayName: String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var hasConfig: Bool {
        configPath != nil && !configPath!.isEmpty
    }
}

// MARK: - Filter Options

enum ServiceSourceFilter: String, CaseIterable {
    case all = "All"
    case base = "Base"
    case ports = "Ports"
}

enum ServiceStatusFilter: String, CaseIterable {
    case all = "All"
    case running = "Running"
    case stopped = "Stopped"
    case enabled = "Enabled"
    case disabled = "Disabled"

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .running: return "play.circle"
        case .stopped: return "stop.circle"
        case .enabled: return "checkmark.circle"
        case .disabled: return "xmark.circle"
        }
    }
}

// MARK: - Main View

struct ServicesContentView: View {
    @StateObject private var viewModel = ServicesViewModel()
    @State private var sourceFilter: ServiceSourceFilter = .all
    @State private var statusFilter: ServiceStatusFilter = .all
    @State private var searchText = ""
    @State private var serviceToEdit: FreeBSDService?
    @State private var showError = false

    var filteredServices: [FreeBSDService] {
        var services = viewModel.services

        // Apply source filter
        switch sourceFilter {
        case .all:
            break
        case .base:
            services = services.filter { $0.source == .base }
        case .ports:
            services = services.filter { $0.source == .ports }
        }

        // Apply status filter
        switch statusFilter {
        case .all:
            break
        case .running:
            services = services.filter { $0.status == .running }
        case .stopped:
            services = services.filter { $0.status == .stopped }
        case .enabled:
            services = services.filter { $0.enabled }
        case .disabled:
            services = services.filter { !$0.enabled }
        }

        // Apply search
        if !searchText.isEmpty {
            services = services.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText)
            }
        }

        return services
    }

    // Counts for the segmented control labels
    var baseCount: Int {
        viewModel.services.filter { $0.source == .base }.count
    }

    var portsCount: Int {
        viewModel.services.filter { $0.source == .ports }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Services")
                        .font(.headline)
                    Text("\(filteredServices.count) of \(viewModel.services.count) service\(viewModel.services.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Source segmented picker (All / Base / Ports)
                Picker("Source", selection: $sourceFilter) {
                    Text("All").tag(ServiceSourceFilter.all)
                    Text("Base (\(baseCount))").tag(ServiceSourceFilter.base)
                    Text("Ports (\(portsCount))").tag(ServiceSourceFilter.ports)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                // Status filter dropdown
                Picker("Status", selection: $statusFilter) {
                    ForEach(ServiceStatusFilter.allCases, id: \.self) { filter in
                        Label(filter.rawValue, systemImage: filter.icon)
                            .tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)

                // Search field
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)

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

            // Content
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading services...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.services.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Services Found")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Unable to retrieve service information from the server")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredServices.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Matching Services")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Try adjusting your filter or search terms")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filteredServices) {
                    TableColumn("Status") { service in
                        HStack(spacing: 4) {
                            Image(systemName: service.status.icon)
                                .foregroundColor(service.status.color)
                                .font(.system(size: 10))
                            Text(service.status.rawValue)
                                .font(.caption)
                                .foregroundColor(service.status.color)
                        }
                    }
                    .width(min: 80, ideal: 90, max: 100)

                    TableColumn("Source") { service in
                        HStack(spacing: 4) {
                            Image(systemName: service.source.icon)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(service.source.rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .width(min: 90, ideal: 100, max: 120)

                    TableColumn("Service") { service in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.name)
                                .font(.system(size: 12, weight: .medium))
                            if !service.description.isEmpty {
                                Text(service.description)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .width(min: 200, ideal: 300)

                    TableColumn("Enabled") { service in
                        HStack(spacing: 4) {
                            Image(systemName: service.enabled ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(service.enabled ? .green : .secondary)
                                .font(.system(size: 12))
                            Text(service.enabled ? "Yes" : "No")
                                .font(.caption)
                                .foregroundColor(service.enabled ? .green : .secondary)
                        }
                    }
                    .width(min: 70, ideal: 80, max: 90)

                    TableColumn("Actions") { service in
                        HStack(spacing: 6) {
                            // Start/Stop/Restart buttons
                            if service.status == .running {
                                Button("Stop") {
                                    Task {
                                        await viewModel.stopService(service)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.red)

                                Button("Restart") {
                                    Task {
                                        await viewModel.restartService(service)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else {
                                Button("Start") {
                                    Task {
                                        await viewModel.startService(service)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.green)
                            }

                            // Enable/Disable at boot toggle
                            Button(service.enabled ? "Disable" : "Enable") {
                                Task {
                                    await viewModel.toggleServiceEnabled(service)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(service.enabled ? .orange : .blue)
                            .help(service.enabled ? "Disable service at boot" : "Enable service at boot")

                            // Configure button (only if config file exists)
                            if service.hasConfig {
                                Button("Configure") {
                                    serviceToEdit = service
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .width(min: 280, ideal: 330, max: 380)
                }
            }
        }
        .sheet(item: $serviceToEdit) { service in
            ServiceConfigView(service: service, viewModel: viewModel)
        }
        .alert("Error", isPresented: $showError) {
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
                await viewModel.loadServices()
            }
        }
    }
}

// MARK: - Service Configuration View

struct ServiceConfigView: View {
    @Environment(\.dismiss) private var dismiss
    let service: FreeBSDService
    @ObservedObject var viewModel: ServicesViewModel
    @State private var configContent: String = ""
    @State private var originalContent: String = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var saveError: String?

    var hasChanges: Bool {
        configContent != originalContent
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: service.source.icon)
                            .foregroundColor(.secondary)
                        Text("Configure \(service.name)")
                            .font(.title2)
                            .fontWeight(.semibold)
                    }
                    if let path = service.configPath {
                        Text(path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Spacer()

                // Status badge
                HStack(spacing: 4) {
                    Image(systemName: service.status.icon)
                    Text(service.status.rawValue)
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(service.status.color.opacity(0.2))
                .foregroundColor(service.status.color)
                .cornerRadius(8)
            }
            .padding()

            Divider()

            // Config editor
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading configuration...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $configContent)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
            }

            Divider()

            // Error message
            if let error = saveError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            // Action buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if hasChanges {
                    Button("Revert") {
                        configContent = originalContent
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                if service.status == .running && hasChanges {
                    Button("Save & Restart") {
                        Task {
                            await saveAndRestart()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                }

                Button(isSaving ? "Saving..." : "Save") {
                    Task {
                        await saveConfig()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || isSaving)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 700, height: 550)
        .onAppear {
            Task {
                await loadConfig()
            }
        }
    }

    private func loadConfig() async {
        isLoading = true
        saveError = nil
        do {
            configContent = try await viewModel.getServiceConfig(service)
            originalContent = configContent
        } catch {
            configContent = "# Failed to load configuration: \(error.localizedDescription)"
            originalContent = configContent
        }
        isLoading = false
    }

    private func saveConfig() async {
        isSaving = true
        saveError = nil
        do {
            try await viewModel.saveServiceConfig(service, content: configContent)
            originalContent = configContent
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }

    private func saveAndRestart() async {
        isSaving = true
        saveError = nil
        do {
            try await viewModel.saveServiceConfig(service, content: configContent)
            originalContent = configContent
            await viewModel.restartService(service)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - View Model

@MainActor
class ServicesViewModel: ObservableObject {
    @Published var services: [FreeBSDService] = []
    @Published var isLoading = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadServices() async {
        isLoading = true
        error = nil

        do {
            services = try await sshManager.listServices()
        } catch {
            self.error = "Failed to load services: \(error.localizedDescription)"
            services = []
        }

        isLoading = false
    }

    func refresh() async {
        await loadServices()
    }

    func startService(_ service: FreeBSDService) async {
        error = nil

        do {
            try await sshManager.startService(name: service.name, source: service.source)
            await refresh()
        } catch {
            self.error = "Failed to start \(service.name): \(error.localizedDescription)"
        }
    }

    func stopService(_ service: FreeBSDService) async {
        error = nil

        do {
            try await sshManager.stopService(name: service.name, source: service.source)
            await refresh()
        } catch {
            self.error = "Failed to stop \(service.name): \(error.localizedDescription)"
        }
    }

    func restartService(_ service: FreeBSDService) async {
        error = nil

        do {
            try await sshManager.restartService(name: service.name, source: service.source)
            await refresh()
        } catch {
            self.error = "Failed to restart \(service.name): \(error.localizedDescription)"
        }
    }

    func toggleServiceEnabled(_ service: FreeBSDService) async {
        error = nil

        do {
            if service.enabled {
                try await sshManager.disableService(name: service.name, rcVar: service.rcVar)
            } else {
                try await sshManager.enableService(name: service.name, rcVar: service.rcVar)
            }
            await refresh()
        } catch {
            self.error = "Failed to \(service.enabled ? "disable" : "enable") \(service.name): \(error.localizedDescription)"
        }
    }

    func getServiceConfig(_ service: FreeBSDService) async throws -> String {
        guard let configPath = service.configPath else {
            throw NSError(domain: "ServicesViewModel", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No configuration file for this service"])
        }
        return try await sshManager.getServiceConfigFile(path: configPath)
    }

    func saveServiceConfig(_ service: FreeBSDService, content: String) async throws {
        guard let configPath = service.configPath else {
            throw NSError(domain: "ServicesViewModel", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No configuration file for this service"])
        }
        try await sshManager.saveServiceConfigFile(path: configPath, content: content)
    }
}
