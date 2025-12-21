//
//  JailsView.swift
//  HexBSD
//
//  FreeBSD jails management with support for all jail types
//

import SwiftUI

// MARK: - Jail Models

enum JailType: String, CaseIterable, Identifiable {
    case thick = "Thick (ZFS Dataset)"
    case thin = "Thin (ZFS Clone)"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .thick:
            return "Dedicated ZFS dataset with full base system. Maximum isolation, independent updates."
        case .thin:
            return "ZFS clone from template snapshot. Fast deployment, space-efficient."
        }
    }

    var icon: String {
        switch self {
        case .thick: return "square.stack.3d.up.fill"
        case .thin: return "cylinder.split.1x2"
        }
    }
}

enum JailIPMode: String, CaseIterable, Identifiable {
    case dhcp = "DHCP"
    case staticIP = "Static IP"

    var id: String { rawValue }
}

struct Jail: Identifiable, Hashable {
    let id: String
    let jid: String
    let name: String
    let hostname: String
    let path: String
    let ip: String
    let status: JailStatus
    let isManaged: Bool
    var jailType: JailType?
    var template: String?

    init(id: String = UUID().uuidString, jid: String, name: String, hostname: String, path: String, ip: String, status: JailStatus, isManaged: Bool, jailType: JailType? = nil, template: String? = nil) {
        self.id = id
        self.jid = jid
        self.name = name
        self.hostname = hostname
        self.path = path
        self.ip = ip
        self.status = status
        self.isManaged = isManaged
        self.jailType = jailType
        self.template = template
    }

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

struct JailTemplate: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let version: String
    let isZFS: Bool
    let hasSnapshot: Bool
}

struct JailResourceUsage {
    let cpuPercent: Double
    let memoryUsed: String
    let memoryLimit: String
    let processCount: Int
}

// MARK: - Jails Content View

enum JailsTab: String, CaseIterable {
    case jails = "Jails"
    case templates = "Templates"
}

struct JailsContentView: View {
    @StateObject private var viewModel = JailsViewModel()
    @State private var showError = false
    @State private var selectedJail: Jail?
    @State private var searchText = ""
    @State private var showCreateJail = false
    @State private var selectedTab: JailsTab = .jails

    /// Check if jail infrastructure is ready (bridge exists, directories exist and jails enabled - templates are optional)
    private var isSetupComplete: Bool {
        viewModel.hasBridges &&
        viewModel.jailSetupStatus.directoriesExist &&
        viewModel.jailSetupStatus.jailEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                // Tab picker
                Picker("", selection: $selectedTab) {
                    ForEach(JailsTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(viewModel.isLongRunningOperation)
                .frame(width: 200)

                Spacer()

                if isSetupComplete && selectedTab == .jails {
                    Button(action: {
                        showCreateJail = true
                    }) {
                        Label("Create Jail", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }

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
            if viewModel.isLoading && viewModel.jails.isEmpty && viewModel.templates.isEmpty {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !isSetupComplete {
                // Show setup wizard when infrastructure is not ready
                JailSetupWizardView(viewModel: viewModel)
            } else {
                // Show selected tab content
                switch selectedTab {
                case .jails:
                    jailsTabContent
                case .templates:
                    TemplatesTabView(viewModel: viewModel)
                }
            }
        }
        .sheet(isPresented: $showCreateJail) {
            JailCreateSheet(viewModel: viewModel)
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
                await viewModel.loadTemplates()
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

    @ViewBuilder
    private var jailsTabContent: some View {
        if viewModel.jails.isEmpty {
            VStack(spacing: 20) {
                Image(systemName: "building.2")
                    .font(.system(size: 72))
                    .foregroundColor(.secondary)
                Text("No Jails")
                    .font(.title)
                    .foregroundColor(.secondary)
                Text("Create a jail or template to get started")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
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
                        JailRowView(jail: jail)
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

// MARK: - Jail Row View

struct JailRowView: View {
    let jail: Jail

    var body: some View {
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
    }
}

// MARK: - Jail Detail View

struct JailDetailView: View {
    let jail: Jail
    @ObservedObject var viewModel: JailsViewModel
    @StateObject private var detailViewModel = JailDetailViewModel()
    @State private var showConfirmStop = false
    @State private var showConfirmRestart = false
    @State private var showConfirmDelete = false
    @State private var showEditConfig = false
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

                    // Control buttons
                    if viewModel.hasElevatedPrivileges {
                        HStack(spacing: 8) {
                            if jail.isRunning {
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

                            Spacer()

                            if jail.isManaged {
                                Button(action: {
                                    showEditConfig = true
                                }) {
                                    Label("Edit Config", systemImage: "doc.text")
                                }
                                .buttonStyle(.bordered)

                                Button(action: {
                                    showConfirmDelete = true
                                }) {
                                    Label("Delete", systemImage: "trash")
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                                .disabled(jail.isRunning)
                            }

                            if isPerformingAction {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                        }
                        .padding(.top, 8)

                        if !jail.isManaged {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                                Text("Jail not configured in /etc/jail.conf.d/ - limited management available")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Root access required")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Text("Jail management requires root privileges")
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
                GroupBox("Information") {
                    VStack(alignment: .leading, spacing: 12) {
                        if !jail.jid.isEmpty && jail.jid != "0" {
                            JailInfoRow(label: "JID", value: jail.jid)
                        }
                        if !jail.path.isEmpty {
                            JailInfoRow(label: "Path", value: jail.path)
                        }
                        if !jail.ip.isEmpty {
                            JailInfoRow(label: "IP Address", value: jail.ip)
                        }
                        if let template = jail.template {
                            JailInfoRow(label: "Template", value: template)
                        }

                        if jail.status == .stopped {
                            Text("Jail is configured but not currently running")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.vertical, 8)
                }

                // Configuration
                if jail.isManaged, let config = detailViewModel.config {
                    GroupBox("Configuration") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(config.parameters.keys.sorted()), id: \.self) { key in
                                if let value = config.parameters[key] {
                                    JailInfoRow(label: key, value: value)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }

                // Resource usage (if running)
                if jail.isRunning, let usage = detailViewModel.resourceUsage {
                    GroupBox("Resource Usage") {
                        VStack(alignment: .leading, spacing: 12) {
                            JailInfoRow(label: "Processes", value: "\(usage.processCount)")
                            if !usage.memoryUsed.isEmpty {
                                JailInfoRow(label: "Memory", value: usage.memoryUsed)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }

                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showEditConfig) {
            if jail.isManaged {
                EditJailConfigSheet(jail: jail, viewModel: viewModel)
            }
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
        .alert("Delete Jail", isPresented: $showConfirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await deleteJail()
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(jail.name)'? This will remove the configuration and optionally the jail data.")
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

    private func deleteJail() async {
        isPerformingAction = true
        await viewModel.deleteJail(jail)
        isPerformingAction = false
    }

    private func openConsole() {
        let command = "jexec \(jail.name) /bin/sh"
        NotificationCenter.default.post(
            name: .openTerminalWithCommand,
            object: nil,
            userInfo: ["command": command]
        )
    }
}

// MARK: - Jail Info Row

struct JailInfoRow: View {
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

// MARK: - Create Jail Sheet

struct JailCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: JailsViewModel

    // Basic settings
    @State private var jailName = ""
    @State private var hostname = ""
    @State private var jailType: JailType = .thick

    // Network settings (vNET only, simplified)
    @State private var ipMode: JailIPMode = .dhcp
    @State private var ipAddress = ""
    @State private var networkInterface = "em0"

    // Template settings
    @State private var selectedTemplate: JailTemplate?
    @State private var freebsdVersion = ""
    @State private var availableReleases: [String] = []
    @State private var isLoadingReleases = false

    // State
    @State private var isCreating = false
    @State private var createError: String?
    @State private var currentStep = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Create New Jail")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
            }
            .padding()

            Divider()

            // Step indicator
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.vertical, 8)

            // Content
            TabView(selection: $currentStep) {
                // Step 1: Basic Info
                basicInfoStep
                    .tag(0)

                // Step 2: Network
                networkStep
                    .tag(1)

                // Step 3: Review
                reviewStep
                    .tag(2)
            }
            .tabViewStyle(.automatic)

            Divider()

            // Error message
            if let error = createError {
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

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation {
                            currentStep -= 1
                        }
                    }
                }

                Spacer()

                if currentStep < 2 {
                    Button("Next") {
                        withAnimation {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
                } else {
                    Button(isCreating ? "Creating..." : "Create Jail") {
                        Task {
                            await createJail()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreating || !canCreate)
                }
            }
            .padding()
        }
        .frame(width: 600, height: 550)
        .onAppear {
            Task {
                await viewModel.loadTemplates()
                await viewModel.loadNetworkInfo()
                await loadAvailableReleases()
            }
        }
        .onChange(of: viewModel.availableInterfaces) { _, interfaces in
            if !interfaces.isEmpty && !interfaces.contains(networkInterface) {
                networkInterface = interfaces.first ?? "em0"
            }
        }
    }

    @FocusState private var jailNameFocused: Bool

    private var basicInfoStep: some View {
        Form {
            Section("Jail Identity") {
                TextField("Jail Name", text: $jailName)
                    .textFieldStyle(.roundedBorder)
                    .focused($jailNameFocused)
                    .onChange(of: jailNameFocused) { _, isFocused in
                        if !isFocused && hostname.isEmpty && !jailName.isEmpty {
                            hostname = jailName
                        }
                    }
                TextField("Hostname", text: $hostname)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Jail Type") {
                Picker("Type", selection: $jailType) {
                    ForEach(JailType.allCases) { type in
                        HStack {
                            Image(systemName: type.icon)
                            Text(type.rawValue)
                        }
                        .tag(type)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(jailType.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if jailType == .thin {
                Section("Template") {
                    if viewModel.templates.isEmpty {
                        Text("No templates found. Create a template first in Setup.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Template", selection: $selectedTemplate) {
                            Text("Select template...").tag(nil as JailTemplate?)
                            ForEach(viewModel.templates) { template in
                                Text("\(template.name) (\(template.version))").tag(template as JailTemplate?)
                            }
                        }
                    }
                }
            }

            if jailType == .thick {
                Section("FreeBSD Version") {
                    if isLoadingReleases {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading available releases...")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Picker("Version", selection: $freebsdVersion) {
                            ForEach(availableReleases, id: \.self) { release in
                                Text(release).tag(release)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var networkStep: some View {
        Form {
            Section {
                Text("This jail will use vNET for full network virtualization with its own network stack.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("IP Configuration") {
                Picker("IP Mode", selection: $ipMode) {
                    ForEach(JailIPMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if ipMode == .staticIP {
                    TextField("IP Address (e.g., 192.168.1.100/24)", text: $ipAddress)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("Bridge Interface") {
                Picker("Interface", selection: $networkInterface) {
                    ForEach(viewModel.availableInterfaces, id: \.self) { iface in
                        Text(iface).tag(iface)
                    }
                }
                Text("The jail's virtual interface will be bridged to this interface.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var reviewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Summary") {
                    VStack(alignment: .leading, spacing: 12) {
                        JailInfoRow(label: "Name", value: jailName)
                        JailInfoRow(label: "Hostname", value: hostname)
                        JailInfoRow(label: "Type", value: jailType.rawValue)
                        JailInfoRow(label: "Network", value: "vNET (\(ipMode.rawValue))")
                        if ipMode == .staticIP && !ipAddress.isEmpty {
                            JailInfoRow(label: "IP Address", value: ipAddress)
                        }
                    }
                    .padding(.vertical, 8)
                }

                GroupBox("Configuration Preview") {
                    ScrollView {
                        Text(generateConfigPreview())
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 200)
                }

                // Warning for thin jails without template snapshot
                if jailType == .thin && (selectedTemplate == nil || !selectedTemplate!.hasSnapshot) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Thin jails require a template with a snapshot. Please select a valid template.")
                            .font(.caption)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

                Text("This will create /etc/jail.conf.d/\(jailName).conf")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }

    private var canProceed: Bool {
        switch currentStep {
        case 0:
            return !jailName.isEmpty && jailName.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil
        case 1:
            if ipMode == .staticIP {
                return !ipAddress.isEmpty
            }
            return true
        default:
            return true
        }
    }

    private var canCreate: Bool {
        guard canProceed && !jailName.isEmpty else { return false }

        // Thin jails require a template with a snapshot
        if jailType == .thin {
            guard let template = selectedTemplate, template.hasSnapshot else {
                return false
            }
        }

        return true
    }

    private func generateConfigPreview() -> String {
        // networkInterface is the physical interface (e.g., vtnet0, em0)
        let physIface = networkInterface.isEmpty ? "vtnet0" : networkInterface

        // Simple vNET config following FreeBSD Handbook pattern
        var config = """
        \(jailName) {
            path = "/jails/containers/\(jailName)";
            host.hostname = "\(hostname.isEmpty ? jailName : hostname)";

            # vNET
            vnet;
            vnet.interface = "${epair}b";

            $id = "1";  # Auto-assigned on creation
            $epair = "epair${id}";

            # Create bridge if needed, add physical interface and epair
            exec.prestart  = "/sbin/ifconfig ${epair} create up";
            exec.prestart += "/sbin/ifconfig bridge0 create 2>/dev/null || true";
            exec.prestart += "/sbin/ifconfig bridge0 addm \(physIface) 2>/dev/null || true";
            exec.prestart += "/sbin/ifconfig bridge0 addm ${epair}a up";

        """

        if ipMode == .dhcp {
            config += """
                exec.start     = "/sbin/dhclient ${epair}b";
                exec.start    += "/bin/sh /etc/rc";

            """
        } else {
            let ip = ipAddress.isEmpty ? "192.168.1.100/24" : ipAddress
            // Extract gateway from IP (assume .1 on same subnet)
            var gateway = "192.168.1.1"
            if let slashIndex = ip.firstIndex(of: "/"),
               let lastDot = ip[..<slashIndex].lastIndex(of: ".") {
                gateway = String(ip[..<lastDot]) + ".1"
            }
            config += """
                exec.start     = "/sbin/ifconfig ${epair}b \(ip) up";
                exec.start    += "/sbin/route add default \(gateway)";
                exec.start    += "/bin/sh /etc/rc";

            """
        }

        config += """
            exec.stop      = "/bin/sh /etc/rc.shutdown jail";
            exec.poststop  = "/sbin/ifconfig ${epair}a destroy";

            exec.clean;
            mount.devfs;
            devfs_ruleset = 11;
        }
        """

        return config
    }

    private func loadAvailableReleases() async {
        isLoadingReleases = true
        do {
            availableReleases = try await SSHConnectionManager.shared.getAvailableFreeBSDReleases()
            if freebsdVersion.isEmpty, let first = availableReleases.first {
                freebsdVersion = first
            }
        } catch {
            // Fallback releases if fetch fails
            availableReleases = ["14.2-RELEASE", "14.1-RELEASE", "13.4-RELEASE", "13.3-RELEASE"]
            if freebsdVersion.isEmpty {
                freebsdVersion = "14.2-RELEASE"
            }
        }
        isLoadingReleases = false
    }

    private func createJail() async {
        isCreating = true
        createError = nil

        do {
            try await viewModel.createJail(
                name: jailName,
                hostname: hostname.isEmpty ? jailName : hostname,
                type: jailType,
                ipMode: ipMode,
                ipAddress: ipAddress,
                networkInterface: networkInterface,
                template: selectedTemplate,
                freebsdVersion: freebsdVersion
            )
            dismiss()
        } catch {
            createError = error.localizedDescription
        }

        isCreating = false
    }
}

// MARK: - Edit Jail Config Sheet

struct EditJailConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    let jail: Jail
    @ObservedObject var viewModel: JailsViewModel

    @State private var configContent = ""
    @State private var originalContent = ""
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
                    Text("Edit Jail Configuration")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("/etc/jail.conf.d/\(jail.name).conf")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            // Editor
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
            }

            // Error
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

            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }

                if hasChanges {
                    Button("Revert") {
                        configContent = originalContent
                    }
                }

                Spacer()

                Button(isSaving ? "Saving..." : "Save") {
                    Task {
                        await saveConfig()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || isSaving)
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
        do {
            configContent = try await SSHConnectionManager.shared.getJailConfigFile(name: jail.name)
            originalContent = configContent
        } catch {
            configContent = "# Failed to load configuration: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func saveConfig() async {
        isSaving = true
        saveError = nil

        do {
            try await SSHConnectionManager.shared.saveJailConfigFile(name: jail.name, content: configContent)
            originalContent = configContent
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }

        isSaving = false
    }
}

// MARK: - Jail Setup Sheet

struct JailSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: JailsViewModel

    @State private var selectedTab = 0
    @State private var isSettingUp = false
    @State private var setupError: String?
    @State private var setupOutput: String = ""

    // Paths (ZFS-only)
    @State private var jailsBasePath = "/jails"
    @State private var zfsDataset = "zroot/jails"

    // Template creation
    @State private var templateVersion = "14.2-RELEASE"
    @State private var templateName = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Jail Setup")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }
            .padding()

            Divider()

            TabView(selection: $selectedTab) {
                // Directory Setup
                directorySetupTab
                    .tabItem {
                        Label("Directories", systemImage: "folder")
                    }
                    .tag(0)

                // Templates
                templatesTab
                    .tabItem {
                        Label("Templates", systemImage: "doc.on.doc")
                    }
                    .tag(1)

                // System Config
                systemConfigTab
                    .tabItem {
                        Label("System", systemImage: "gearshape")
                    }
                    .tag(2)
            }
            .padding()

            // Error/Output
            if let error = setupError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal)
            }

            if !setupOutput.isEmpty {
                GroupBox("Output") {
                    ScrollView {
                        Text(setupOutput)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 100)
                }
                .padding(.horizontal)
            }
        }
        .frame(width: 650, height: 550)
        .onAppear {
            Task {
                await viewModel.checkJailSetup()
            }
        }
    }

    private var directorySetupTab: some View {
        Form {
            Section("ZFS Jail Directory Structure") {
                TextField("Base Path", text: $jailsBasePath)
                    .textFieldStyle(.roundedBorder)

                TextField("ZFS Dataset", text: $zfsDataset)
                    .textFieldStyle(.roundedBorder)
                    .help("Parent ZFS dataset for all jail data")

                Text("This will create ZFS datasets:\n• \(zfsDataset)/media\n• \(zfsDataset)/templates\n• \(zfsDataset)/containers\n\nMounted at: \(jailsBasePath)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button(isSettingUp ? "Setting up..." : "Create Directory Structure") {
                    Task {
                        await setupDirectories()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSettingUp)
            }

            Section("Current Status") {
                HStack {
                    Image(systemName: viewModel.jailSetupStatus.directoriesExist ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(viewModel.jailSetupStatus.directoriesExist ? .green : .red)
                    Text("Directories configured")
                }
                HStack {
                    Image(systemName: viewModel.jailSetupStatus.jailEnabled ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(viewModel.jailSetupStatus.jailEnabled ? .green : .red)
                    Text("jail_enable in rc.conf")
                }
                HStack {
                    Image(systemName: viewModel.jailSetupStatus.hasTemplates ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(viewModel.jailSetupStatus.hasTemplates ? .green : .orange)
                    Text("Templates available")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var templatesTab: some View {
        VStack(spacing: 20) {
            // Existing templates
            GroupBox("Existing Templates") {
                if viewModel.templates.isEmpty {
                    Text("No templates found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    List(viewModel.templates) { template in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(template.name)
                                    .font(.headline)
                                Text(template.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(template.version)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if template.hasSnapshot {
                                Image(systemName: "camera.fill")
                                    .foregroundColor(.blue)
                                    .help("Has ZFS snapshot")
                            }
                        }
                    }
                    .frame(height: 150)
                }
            }

            // Create new template
            GroupBox("Create New Template") {
                Form {
                    Picker("FreeBSD Version", selection: $templateVersion) {
                        Text("14.2-RELEASE").tag("14.2-RELEASE")
                        Text("14.1-RELEASE").tag("14.1-RELEASE")
                        Text("13.4-RELEASE").tag("13.4-RELEASE")
                    }

                    TextField("Template Name (optional)", text: $templateName)
                        .textFieldStyle(.roundedBorder)

                    Text("Will download base.txz and create template at:\n\(jailsBasePath)/templates/\(templateName.isEmpty ? templateVersion : templateName)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(isSettingUp ? "Creating..." : "Create Template") {
                        Task {
                            await createTemplate()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSettingUp)
                }
            }
        }
        .padding()
    }

    private var systemConfigTab: some View {
        Form {
            Section("rc.conf Settings") {
                HStack {
                    Text("jail_enable")
                    Spacer()
                    Text(viewModel.jailSetupStatus.jailEnabled ? "YES" : "NO")
                        .foregroundColor(viewModel.jailSetupStatus.jailEnabled ? .green : .secondary)
                }

                HStack {
                    Text("jail_parallel_start")
                    Spacer()
                    Text(viewModel.jailSetupStatus.parallelStart ? "YES" : "NO")
                        .foregroundColor(viewModel.jailSetupStatus.parallelStart ? .green : .secondary)
                }

                Button("Enable Jails in rc.conf") {
                    Task {
                        await enableJails()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.jailSetupStatus.jailEnabled)
            }

            Section("jail.conf") {
                Text("Using individual files in /etc/jail.conf.d/ for each jail")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Ensure jail.conf.d include") {
                    Task {
                        await ensureJailConfInclude()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .formStyle(.grouped)
    }

    private func setupDirectories() async {
        isSettingUp = true
        setupError = nil
        setupOutput = ""

        do {
            setupOutput = try await viewModel.setupJailDirectories(
                basePath: jailsBasePath,
                zfsDataset: zfsDataset
            )
            await viewModel.checkJailSetup()
        } catch {
            setupError = error.localizedDescription
        }

        isSettingUp = false
    }

    private func createTemplate() async {
        isSettingUp = true
        setupError = nil
        setupOutput = ""

        do {
            setupOutput = try await viewModel.createTemplate(
                version: templateVersion,
                name: templateName.isEmpty ? templateVersion : templateName,
                basePath: jailsBasePath,
                zfsDataset: zfsDataset
            )
            await viewModel.loadTemplates()
        } catch {
            setupError = error.localizedDescription
        }

        isSettingUp = false
    }

    private func enableJails() async {
        isSettingUp = true
        setupError = nil

        do {
            try await viewModel.enableJailsInRcConf()
            await viewModel.checkJailSetup()
        } catch {
            setupError = error.localizedDescription
        }

        isSettingUp = false
    }

    private func ensureJailConfInclude() async {
        isSettingUp = true
        setupError = nil

        do {
            try await viewModel.ensureJailConfInclude()
        } catch {
            setupError = error.localizedDescription
        }

        isSettingUp = false
    }
}

// MARK: - Templates Tab View

struct TemplatesTabView: View {
    @ObservedObject var viewModel: JailsViewModel
    @State private var selectedVersion = ""
    @State private var availableReleases: [String] = []
    @State private var isLoadingReleases = false
    @State private var isCreating = false
    @State private var createOutput = ""
    @State private var createError: String?
    @State private var showDeleteConfirm = false
    @State private var templateToDelete: JailTemplate?

    var body: some View {
        HSplitView {
            // Templates list
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Templates")
                        .font(.headline)
                    Spacer()
                    Text("\(viewModel.templates.count)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
                .padding()

                Divider()

                if viewModel.templates.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Templates")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Create a template to enable thin jails")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(viewModel.templates) { template in
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading) {
                                    Text(template.name)
                                        .font(.headline)
                                    Text(template.path)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(action: {
                                    templateToDelete = template
                                    showDeleteConfirm = true
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 350)

            // Create template panel
            VStack(alignment: .leading, spacing: 16) {
                Text("Create New Template")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Download a FreeBSD base system to use as a template for thin jails. Templates use ZFS snapshots for fast cloning.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Form {
                    if isLoadingReleases {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading available releases...")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Picker("FreeBSD Version", selection: $selectedVersion) {
                            ForEach(availableReleases, id: \.self) { release in
                                Text(release).tag(release)
                            }
                        }
                    }

                    Text("Downloads base.txz (~180MB) and creates a ZFS snapshot for cloning.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .formStyle(.grouped)

                HStack {
                    Spacer()
                    Button(isCreating ? "Creating..." : "Create Template") {
                        Task {
                            await createTemplate()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreating || selectedVersion.isEmpty)
                }

                if let error = createError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                        Spacer()
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

                // Terminal output during creation
                if !createOutput.isEmpty || isCreating {
                    GroupBox {
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(createOutput.isEmpty ? "Starting..." : createOutput)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("bottom")
                            }
                            .onChange(of: createOutput) { _, _ in
                                withAnimation {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            }
                        }
                        .frame(height: 200)
                    } label: {
                        HStack {
                            if isCreating {
                                ProgressView()
                                    .scaleEffect(0.6)
                            }
                            Text("Terminal Output")
                        }
                    }
                }

                Spacer()
            }
            .padding()
            .frame(minWidth: 400)
        }
        .onAppear {
            Task {
                await loadAvailableReleases()
            }
        }
        .alert("Delete Template", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let template = templateToDelete {
                    Task {
                        await deleteTemplate(template)
                    }
                }
            }
        } message: {
            if let template = templateToDelete {
                Text("Are you sure you want to delete the template '\(template.name)'? This cannot be undone.")
            }
        }
    }

    private func loadAvailableReleases() async {
        isLoadingReleases = true
        do {
            availableReleases = try await SSHConnectionManager.shared.getAvailableFreeBSDReleases()
            if selectedVersion.isEmpty, let first = availableReleases.first {
                selectedVersion = first
            }
        } catch {
            availableReleases = ["14.2-RELEASE", "14.1-RELEASE", "13.4-RELEASE", "13.3-RELEASE"]
            if selectedVersion.isEmpty {
                selectedVersion = "14.2-RELEASE"
            }
        }
        isLoadingReleases = false
    }

    private func createTemplate() async {
        isCreating = true
        viewModel.isLongRunningOperation = true
        NotificationCenter.default.post(name: .sidebarNavigationLock, object: nil, userInfo: ["locked": true])
        createError = nil
        createOutput = ""

        do {
            try await viewModel.createTemplateStreaming(
                version: selectedVersion,
                name: selectedVersion,
                basePath: "/jails",
                zfsDataset: "zroot/jails"
            ) { output in
                createOutput += output
            }
            await viewModel.loadTemplates()
            createOutput += "\nTemplate created successfully!\n"
        } catch {
            createError = error.localizedDescription
        }

        isCreating = false
        viewModel.isLongRunningOperation = false
        NotificationCenter.default.post(name: .sidebarNavigationLock, object: nil, userInfo: ["locked": false])
    }

    private func deleteTemplate(_ template: JailTemplate) async {
        do {
            try await viewModel.deleteTemplate(template)
            await viewModel.loadTemplates()
        } catch {
            createError = "Failed to delete template: \(error.localizedDescription)"
        }
    }
}

// MARK: - Jail Setup Wizard View (Inline)

struct JailSetupWizardView: View {
    @ObservedObject var viewModel: JailsViewModel
    @State private var selectedPool: ZFSPool?
    @State private var datasetName = "jails"
    @State private var pools: [ZFSPool] = []
    @State private var isLoadingPools = false
    @State private var isSettingUp = false
    @State private var setupOutput = ""
    @State private var setupError: String?

    private var zfsDataset: String {
        guard let pool = selectedPool else { return "" }
        return "\(pool.name)/\(datasetName)"
    }

    private var basePath: String {
        "/\(datasetName)"
    }

    var body: some View {
        VStack(spacing: 24) {
            // Check for bridges first - this is required before any other setup
            if !viewModel.hasBridges {
                // No bridges exist - show message and navigation button
                VStack(spacing: 20) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 64))
                        .foregroundColor(.orange)

                    Text("Network Bridge Required")
                        .font(.title)
                        .fontWeight(.semibold)

                    Text("Jails require a network bridge for connectivity.\nPlease create a bridge in the Network section first.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button(action: {
                        NotificationCenter.default.post(name: .navigateToNetworkBridges, object: nil)
                    }) {
                        HStack {
                            Image(systemName: "network")
                            Text("Setup Network Bridge")
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Bridges exist - show normal setup wizard
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)
                    Text("Jail Setup Required")
                        .font(.title)
                        .fontWeight(.semibold)
                    Text("Configure your jail infrastructure before creating jails")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 20)

                Divider()

                // Status indicators
                VStack(alignment: .leading, spacing: 12) {
                    StatusRow(
                        title: "Network Bridge",
                        isComplete: viewModel.hasBridges,
                        detail: viewModel.hasBridges ? "\(viewModel.bridges.count) bridge(s) available" : "No bridges configured"
                    )
                    StatusRow(
                        title: "ZFS Datasets",
                        isComplete: viewModel.jailSetupStatus.directoriesExist,
                        detail: viewModel.jailSetupStatus.directoriesExist ? "Created" : "Not created"
                    )
                    StatusRow(
                        title: "Jail Configuration",
                        isComplete: viewModel.jailSetupStatus.jailConfExists,
                        detail: viewModel.jailSetupStatus.jailConfExists ? "/etc/jail.conf exists" : "/etc/jail.conf missing"
                    )
                    StatusRow(
                        title: "Jail Service",
                        isComplete: viewModel.jailSetupStatus.jailEnabled,
                        detail: viewModel.jailSetupStatus.jailEnabled ? "Enabled in rc.conf" : "Not enabled"
                    )
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                // Setup form
                Form {
                Section("ZFS Configuration") {
                    if isLoadingPools {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading ZFS pools...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if pools.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("No ZFS pools found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Retry") {
                                Task { await loadPools() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        Picker("ZFS Pool:", selection: $selectedPool) {
                            Text("Select a pool...").tag(nil as ZFSPool?)
                            ForEach(pools) { pool in
                                HStack {
                                    Text(pool.name)
                                    Spacer()
                                    Text("\(pool.free) free of \(pool.size)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .tag(pool as ZFSPool?)
                            }
                        }
                        .pickerStyle(.menu)

                        TextField("Dataset Name:", text: $datasetName)
                            .textFieldStyle(.roundedBorder)

                        if !zfsDataset.isEmpty {
                            Text("Will create: \(zfsDataset)/templates, \(zfsDataset)/media, \(zfsDataset)/containers")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Mount path: \(basePath)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            // Action button
            HStack {
                Spacer()
                Button(isSettingUp ? "Setting up..." : "Complete Setup") {
                    Task {
                        await performSetup()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSettingUp || zfsDataset.isEmpty || selectedPool == nil)
            }

            // Error display
            if let error = setupError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                    Spacer()
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            // Output display - terminal-like view during operations
            if !setupOutput.isEmpty || isSettingUp {
                GroupBox {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(setupOutput.isEmpty ? "Starting..." : setupOutput)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("bottom")
                        }
                        .onChange(of: setupOutput) { _, _ in
                            withAnimation {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .frame(height: 150)
                } label: {
                    HStack {
                        if isSettingUp {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        Text("Terminal Output")
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }

            Spacer()
            } // end else (bridges exist)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task { await loadPools() }
        }
    }

    private func loadPools() async {
        isLoadingPools = true
        setupError = nil

        pools = await viewModel.listZFSPools()

        // Auto-select if only one pool
        if pools.count == 1 {
            selectedPool = pools.first
        }

        isLoadingPools = false
    }

    private func performSetup() async {
        isSettingUp = true
        setupError = nil
        setupOutput = ""

        do {
            // Step 1: Create ZFS datasets if needed
            if !viewModel.jailSetupStatus.directoriesExist {
                setupOutput += "Creating ZFS datasets at \(zfsDataset) (mount: \(basePath))...\n"
                let output = try await viewModel.setupJailDirectories(basePath: basePath, zfsDataset: zfsDataset)
                setupOutput += output + "\n"
            }

            // Step 2: Ensure jail.conf exists
            if !viewModel.jailSetupStatus.jailConfExists {
                setupOutput += "Creating /etc/jail.conf...\n"
                try await viewModel.ensureJailConfInclude()
                setupOutput += "Created /etc/jail.conf with jail.conf.d include\n"
            }

            // Step 3: Enable jail service if needed
            if !viewModel.jailSetupStatus.jailEnabled {
                setupOutput += "Enabling jail service...\n"
                try await viewModel.enableJailsInRcConf()
                setupOutput += "jail_enable=YES set in rc.conf\n"
            }

            setupOutput += "\nSetup complete!\n"
            await viewModel.checkJailSetup()
        } catch {
            setupError = error.localizedDescription
        }

        isSettingUp = false
    }
}

// MARK: - Jail Setup Status
// JailSetupStatus is defined in SSHConnectionManager.swift
typealias JailSetupStatus = SSHConnectionManager.JailSetupStatus

// MARK: - Status Row Helper

private struct StatusRow: View {
    let title: String
    let isComplete: Bool
    let detail: String

    var body: some View {
        HStack {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(isComplete ? .green : .orange)
            Text(title)
                .fontWeight(.medium)
            Spacer()
            Text(detail)
                .foregroundColor(.secondary)
                .font(.caption)
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
            if jail.isManaged {
                config = try await sshManager.getJailConfig(name: jail.name)
            }

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
    @Published var templates: [JailTemplate] = []
    @Published var availableInterfaces: [String] = []
    @Published var bridges: [BridgeInterface] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var autoRefresh: Bool = false
    @Published var hasElevatedPrivileges: Bool = false
    @Published var jailSetupStatus = JailSetupStatus()
    @Published var isLongRunningOperation = false  // Locks navigation during template creation, etc.

    private let sshManager = SSHConnectionManager.shared

    /// Check if any bridges exist (required before jail setup)
    var hasBridges: Bool {
        !bridges.isEmpty
    }

    func loadJails() async {
        isLoading = true
        error = nil

        do {
            // First check if bridges exist (required for jail networking)
            bridges = try await sshManager.listBridges()

            hasElevatedPrivileges = try await sshManager.hasElevatedPrivileges()
            jails = try await sshManager.listJails()
            // Also check jail setup status for the wizard
            jailSetupStatus = try await sshManager.checkJailSetup()
            print("DEBUG: Jail setup status - directoriesExist: \(jailSetupStatus.directoriesExist), hasTemplates: \(jailSetupStatus.hasTemplates), jailEnabled: \(jailSetupStatus.jailEnabled)")
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
            hasElevatedPrivileges = try await sshManager.hasElevatedPrivileges()
            jails = try await sshManager.listJails()
        } catch {
            print("Auto-refresh failed: \(error.localizedDescription)")
        }
    }

    func loadTemplates() async {
        do {
            templates = try await sshManager.listJailTemplates()
        } catch {
            print("Failed to load templates: \(error.localizedDescription)")
        }
    }

    /// List available ZFS pools
    func listZFSPools() async -> [ZFSPool] {
        do {
            return try await sshManager.listZFSPoolsForVMSetup()
        } catch {
            self.error = "Failed to list ZFS pools: \(error.localizedDescription)"
            return []
        }
    }

    func loadNetworkInfo() async {
        do {
            availableInterfaces = try await sshManager.listBridgeableInterfaces()
        } catch {
            print("Failed to load network info: \(error.localizedDescription)")
        }
    }

    func checkJailSetup() async {
        do {
            jailSetupStatus = try await sshManager.checkJailSetup()
        } catch {
            print("Failed to check jail setup: \(error.localizedDescription)")
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

    func deleteJail(_ jail: Jail) async {
        error = nil
        do {
            try await sshManager.deleteJail(name: jail.name, removePath: false)
            await loadJails()
        } catch {
            self.error = "Failed to delete jail: \(error.localizedDescription)"
        }
    }

    func createJail(
        name: String,
        hostname: String,
        type: JailType,
        ipMode: JailIPMode,
        ipAddress: String,
        networkInterface: String,
        template: JailTemplate?,
        freebsdVersion: String
    ) async throws {
        try await sshManager.createJail(
            name: name,
            hostname: hostname,
            type: type,
            ipMode: ipMode,
            ipAddress: ipAddress,
            networkInterface: networkInterface,
            template: template,
            freebsdVersion: freebsdVersion
        )
        await loadJails()
    }

    func setupJailDirectories(basePath: String, zfsDataset: String) async throws -> String {
        return try await sshManager.setupJailDirectories(basePath: basePath, zfsDataset: zfsDataset)
    }

    func createTemplate(version: String, name: String, basePath: String, zfsDataset: String) async throws -> String {
        return try await sshManager.createJailTemplate(version: version, name: name, basePath: basePath, zfsDataset: zfsDataset)
    }

    func createTemplateStreaming(version: String, name: String, basePath: String, zfsDataset: String, onOutput: @escaping (String) -> Void) async throws {
        try await sshManager.createJailTemplateStreaming(version: version, name: name, basePath: basePath, zfsDataset: zfsDataset, onOutput: onOutput)
    }

    func enableJailsInRcConf() async throws {
        try await sshManager.enableJailsInRcConf()
    }

    func ensureJailConfInclude() async throws {
        try await sshManager.ensureJailConfInclude()
    }

    func deleteTemplate(_ template: JailTemplate) async throws {
        try await sshManager.deleteJailTemplate(template)
    }
}
