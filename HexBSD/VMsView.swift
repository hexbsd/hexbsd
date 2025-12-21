//
//  VMsView.swift
//  HexBSD
//
//  Virtual Machine management using bhyve
//

import SwiftUI
import AppKit

// MARK: - Notification Names

extension Notification.Name {
    static let launchVNCForVM = Notification.Name("launchVNCForVM")
}

// MARK: - Data Models

struct VMBhyveInfo: Equatable {
    let isInstalled: Bool
    let serviceEnabled: Bool
    let vmDir: String
    let templatesInstalled: Bool
    let firmwareInstalled: Bool
    let publicSwitchConfigured: Bool
}

struct VirtualSwitch: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let interface: String?
    let address: String?

    init(name: String, type: String, interface: String? = nil, address: String? = nil) {
        self.id = name
        self.name = name
        self.type = type
        self.interface = interface
        self.address = address
    }
}

struct VMNetworkInterface: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let isUp: Bool
    let hasIPv4: Bool

    init(name: String, description: String = "", isUp: Bool = false, hasIPv4: Bool = false) {
        self.id = name
        self.name = name
        self.description = description
        self.isUp = isUp
        self.hasIPv4 = hasIPv4
    }
}

struct ISOImage: Identifiable, Hashable {
    let id: String
    let name: String
    let size: String?

    init(name: String, size: String? = nil) {
        self.id = name
        self.name = name
        self.size = size
    }
}

struct VirtualMachine: Identifiable, Hashable {
    var id: String { name } // Use VM name as ID (unique in vm-bhyve)
    let name: String
    let state: VMState
    let datastore: String?
    let loader: String?
    let pid: String?
    let cpu: String
    let memory: String
    let console: String?
    let vnc: String?
    let autostart: Bool

    enum VMState: String, Hashable {
        case running = "Running"
        case stopped = "Stopped"
        case unknown = "Unknown"
    }

    // Initialize with default values for new fields
    init(name: String, state: VMState, datastore: String? = nil, loader: String? = nil,
         pid: String? = nil, cpu: String, memory: String, console: String? = nil,
         vnc: String? = nil, autostart: Bool = false) {
        self.name = name
        self.state = state
        self.datastore = datastore
        self.loader = loader
        self.pid = pid
        self.cpu = cpu
        self.memory = memory
        self.console = console
        self.vnc = vnc
        self.autostart = autostart
    }

    // Custom Hashable implementation based on name
    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    // Custom Equatable implementation based on name
    static func == (lhs: VirtualMachine, rhs: VirtualMachine) -> Bool {
        lhs.name == rhs.name
    }

    var statusIcon: String {
        switch state {
        case .running:
            return "play.circle.fill"
        case .stopped:
            return "stop.circle.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    var statusColor: Color {
        switch state {
        case .running:
            return .green
        case .stopped:
            return .secondary
        case .unknown:
            return .orange
        }
    }
}

// MARK: - Main View

struct VMsContentView: View {
    @StateObject private var viewModel = VMsViewModel()
    @State private var showError = false
    @State private var selectedVM: VirtualMachine?
    @State private var showConsole = false
    @State private var showVNC = false
    @State private var showCreateVM = false
    @State private var showVMInfo = false
    @State private var showSnapshot = false
    @State private var embeddedVNCVM: VirtualMachine?
    @State private var showNetworkSwitches = false
    @State private var showISOManagement = false

    var body: some View {
        VStack(spacing: 0) {
            // Show embedded VNC if active
            if let vncVM = embeddedVNCVM, let vnc = vncVM.vnc {
                // Embedded VNC Viewer
                VStack(spacing: 0) {
                    // Header with back button
                    HStack {
                        Button(action: {
                            embeddedVNCVM = nil
                        }) {
                            Label("Back to VMs", systemImage: "chevron.left")
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Text("VNC: \(vncVM.name)")
                            .font(.headline)

                        Spacer()

                        // Placeholder for symmetry
                        Color.clear.frame(width: 120)
                    }
                    .padding()
                    .background(Color(NSColor.windowBackgroundColor))

                    Divider()

                    // VNC Viewer
                    let components = vnc.split(separator: ":")
                    let host = String(components.first ?? "")
                    let port = Int(components.last ?? "5900") ?? 5900

                    VNCViewerView(host: host, port: port)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                }
            } else {
                // Normal VM list view
                VStack(spacing: 0) {
                    // Toolbar
                    HStack {
                        // Only show status indicator if setup is incomplete
                        if !viewModel.setupComplete {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.orange)
                                Text("Setup required")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        // Create VM button
                        Button(action: {
                            showCreateVM = true
                        }) {
                            Label("New VM", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.setupComplete)

                        // Network switches button
                        Button(action: {
                            showNetworkSwitches = true
                        }) {
                            Label("Network Switches", systemImage: "network")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.setupComplete)

                        // ISO management button
                        Button(action: {
                            showISOManagement = true
                        }) {
                            Label("ISOs", systemImage: "opticaldiscdrive")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.setupComplete)

                        if let vm = selectedVM {
                            Divider()
                                .frame(height: 20)
                                .padding(.horizontal, 8)

                            // VM Info button
                            Button(action: {
                                showVMInfo = true
                            }) {
                                Label("Info", systemImage: "info.circle")
                            }
                            .buttonStyle(.bordered)

                            // Console access button
                            if let console = vm.console, !console.isEmpty {
                                Button(action: {
                                    showConsole = true
                                }) {
                                    Label("Console", systemImage: "terminal")
                                }
                                .buttonStyle(.bordered)
                            }

                            // VNC access button
                            if let vnc = vm.vnc, !vnc.isEmpty {
                                Button(action: {
                                    embeddedVNCVM = vm
                                }) {
                                    Label("VNC", systemImage: "rectangle.on.rectangle")
                                }
                                .buttonStyle(.bordered)
                            }

                            // Snapshot button
                            Button(action: {
                                showSnapshot = true
                            }) {
                                Label("Snapshot", systemImage: "camera")
                            }
                            .buttonStyle(.bordered)

                            // Delete button (only enabled when VM is stopped)
                            Button(action: {
                                Task {
                                    await viewModel.deleteVM(name: vm.name)
                                }
                            }) {
                                Label("Delete", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .disabled(vm.state != .stopped)

                            Divider()
                                .frame(height: 20)
                                .padding(.horizontal, 8)

                            // Start/Stop/Restart buttons
                            if vm.state == .stopped {
                                Button(action: {
                                    Task {
                                        await viewModel.startVM(name: vm.name)
                                    }
                                }) {
                                    Label("Start", systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                            } else if vm.state == .running {
                                Button(action: {
                                    Task {
                                        await viewModel.restartVM(name: vm.name)
                                    }
                                }) {
                                    Label("Restart", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)

                                Button(action: {
                                    Task {
                                        await viewModel.stopVM(name: vm.name)
                                    }
                                }) {
                                    Label("Stop", systemImage: "stop.fill")
                                }
                                .buttonStyle(.bordered)
                                .tint(.orange)

                                Button(action: {
                                    Task {
                                        await viewModel.poweroffVM(name: vm.name)
                                    }
                                }) {
                                    Label("Force Off", systemImage: "power")
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }
                        }

                        Divider()
                            .frame(height: 20)
                            .padding(.horizontal, 8)

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

                    // Virtual machines list
                    if viewModel.isLoading {
                        VStack(spacing: 20) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Loading virtual machines...")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !viewModel.setupComplete {
                        // Show setup wizard when any requirement is missing
                        BhyveSetupWizardView(viewModel: viewModel)
                    } else if viewModel.vms.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 72))
                                .foregroundColor(.secondary)
                            Text("No Virtual Machines")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("No bhyve VMs detected on this server")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(viewModel.vms, id: \.id, selection: $selectedVM) { vm in
                            VirtualMachineRow(vm: vm)
                                .tag(vm)
                        }
                        .listStyle(.inset)
                    }
                }
            }
        }
        .alert("Virtual Machine Error", isPresented: $showError) {
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
        .sheet(isPresented: $showCreateVM) {
            VMCreateSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showVMInfo) {
            if let vm = selectedVM {
                VMInfoSheet(vm: vm, viewModel: viewModel)
            }
        }
        .sheet(isPresented: $showSnapshot) {
            if let vm = selectedVM {
                VMSnapshotSheet(vm: vm, viewModel: viewModel)
            }
        }
        .sheet(isPresented: $showConsole) {
            if let vm = selectedVM, let console = vm.console {
                VMConsoleSheet(vmName: vm.name, consolePath: console)
            }
        }
        .sheet(isPresented: $showNetworkSwitches) {
            NetworkSwitchesSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showISOManagement) {
            ISOManagementSheet(viewModel: viewModel)
        }
        .onAppear {
            Task {
                await viewModel.loadVMs()
            }

            // Listen for VNC launch notifications
            NotificationCenter.default.addObserver(
                forName: .launchVNCForVM,
                object: nil,
                queue: .main
            ) { notification in
                if let vmName = notification.userInfo?["vmName"] as? String {
                    // Wait a bit for VMs to refresh, then launch VNC
                    Task {
                        // Refresh VMs to get the latest state with VNC info
                        await viewModel.loadVMs()

                        // Find the VM and launch VNC
                        if let vm = viewModel.vms.first(where: { $0.name == vmName }) {
                            embeddedVNCVM = vm
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Virtual Machine Row

struct VirtualMachineRow: View {
    let vm: VirtualMachine

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            Image(systemName: vm.statusIcon)
                .font(.title2)
                .foregroundColor(vm.statusColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(vm.name)
                        .font(.headline)

                    if vm.autostart {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                            .help("Autostart enabled")
                    }
                }

                HStack(spacing: 12) {
                    Label(vm.state.rawValue, systemImage: "")
                        .font(.caption)
                        .foregroundColor(vm.statusColor)

                    if let datastore = vm.datastore {
                        Label(datastore, systemImage: "internaldrive")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let loader = vm.loader {
                        Label(loader, systemImage: "memorychip")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !vm.cpu.isEmpty {
                        Label("\(vm.cpu) CPU", systemImage: "cpu")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !vm.memory.isEmpty {
                        Label(vm.memory, systemImage: "memorychip.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let pid = vm.pid {
                        Label("PID: \(pid)", systemImage: "number")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Access indicators
            HStack(spacing: 8) {
                if vm.console != nil {
                    Image(systemName: "terminal.fill")
                        .foregroundColor(.blue)
                        .help("Console available")
                }
                if vm.vnc != nil {
                    Image(systemName: "rectangle.on.rectangle.fill")
                        .foregroundColor(.purple)
                        .help("VNC available")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Console Sheet

struct VMConsoleSheet: View {
    let vmName: String
    let consolePath: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("VM Console: \(vmName)")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Close") {
                    dismiss()
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Console Device")
                    .font(.caption)

                Text(consolePath)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                Text("To connect to this VM console, use:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("cu -l \(consolePath)")
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("cu -l \(consolePath)", forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy to clipboard")
                }

                Button("Open in Terminal Tab") {
                    // Send notification to open terminal with console command
                    NotificationCenter.default.post(
                        name: .openTerminalWithCommand,
                        object: nil,
                        userInfo: ["command": "cu -l \(consolePath)"]
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .padding()
        .frame(width: 500)
    }
}

// MARK: - VNC Sheet

struct VMVNCSheet: View {
    let vmName: String
    let vncAddress: String
    @Environment(\.dismiss) private var dismiss
    @State private var showEmbeddedViewer = false

    var body: some View {
        VStack(spacing: 0) {
            // Header - draggable area
            HStack {
                Text("VM VNC: \(vmName)")
                    .font(.title2)
                    .bold()
                Spacer()
                if showEmbeddedViewer {
                    Button("Back") {
                        showEmbeddedViewer = false
                    }
                    .buttonStyle(.bordered)
                }
                Button("Close") {
                    dismiss()
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            if showEmbeddedViewer {
                // Embedded VNC Viewer
                let components = vncAddress.split(separator: ":")
                let host = String(components.first ?? "")
                let port = Int(components.last ?? "5900") ?? 5900

                VNCViewerView(host: host, port: port)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                // Connection options
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("VNC Server")
                            .font(.caption)

                HStack {
                    Text(vncAddress)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(vncAddress, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy to clipboard")
                }

                Divider()

                Text("Connection Instructions:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("• Click 'Open VNC Connection' (uses Screen Sharing)")
                    Text("• If Screen Sharing still prompts, install RealVNC Viewer or TigerVNC")
                    Text("• These clients handle passwordless VNC connections properly")
                }
                .font(.caption)
                .foregroundColor(.secondary)

                HStack {
                    Text("Recommended:")
                        .font(.caption)
                        .bold()
                    Button("Get RealVNC Viewer") {
                        if let url = URL(string: "https://www.realvnc.com/en/connect/download/viewer/") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .foregroundColor(.secondary)

                        // Primary button - Embedded viewer
                        Button("Open Embedded Viewer (No Password!)") {
                            showEmbeddedViewer = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Divider()
                            .padding(.vertical, 8)

                        Text("Alternative Options:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button("Use Screen Sharing") {
                        // Use VNC URL with empty password to bypass authentication prompt
                        // Format: vnc://:@host:port (colon before @ indicates empty password)
                        if let url = URL(string: "vnc://:@\(vncAddress)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Open in Browser (noVNC)") {
                        // Many vm-bhyve setups also have noVNC web interface
                        // Try common noVNC port (6080) or VNC port + 1000
                        if let vncPort = vncAddress.split(separator: ":").last,
                           let portNum = Int(vncPort) {
                            let host = vncAddress.split(separator: ":").first ?? ""
                            let noVNCPort = portNum + 1000 // Common noVNC offset
                            if let url = URL(string: "http://\(host):\(noVNCPort)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 900, height: 700)
    }
}

// MARK: - View Model

@MainActor
class VMsViewModel: ObservableObject {
    @Published var vms: [VirtualMachine] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var isInstalled = false
    @Published var serviceEnabled = false
    @Published var vmDir = ""
    @Published var templatesInstalled = false
    @Published var firmwareInstalled = false
    @Published var publicSwitchConfigured = false

    private let sshManager = SSHConnectionManager.shared

    /// Check if setup is complete (all requirements met)
    var setupComplete: Bool {
        isInstalled && serviceEnabled && templatesInstalled && firmwareInstalled && publicSwitchConfigured
    }

    /// Setup vm-bhyve with streaming output
    func setupVMBhyve(zfsDataset: String, networkInterface: String?, onOutput: @escaping (String) -> Void) async throws {
        try await sshManager.setupVMBhyveStreaming(zfsDataset: zfsDataset, networkInterface: networkInterface, onOutput: onOutput)
        // Reload status after setup
        await loadVMs()
    }

    /// List network interfaces suitable for bridging (excludes bridge interfaces)
    func listBridgeableInterfaces() async -> [String] {
        do {
            return try await sshManager.listBridgeableInterfaces()
        } catch {
            print("Failed to list bridgeable interfaces: \(error.localizedDescription)")
            return []
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

    func loadVMs() async {
        isLoading = true
        error = nil

        do {
            // First check if vm-bhyve is installed and enabled
            let info = try await sshManager.checkVMBhyve()
            isInstalled = info.isInstalled
            serviceEnabled = info.serviceEnabled
            vmDir = info.vmDir
            templatesInstalled = info.templatesInstalled
            firmwareInstalled = info.firmwareInstalled
            publicSwitchConfigured = info.publicSwitchConfigured

            // Only try to list VMs if setup is complete
            if setupComplete {
                vms = try await sshManager.listVirtualMachines()
            } else {
                vms = []
            }
        } catch {
            // Don't show errors about loading VMs if setup isn't complete yet
            if setupComplete {
                self.error = "Failed to load virtual machines: \(error.localizedDescription)"
            }
            vms = []
        }

        isLoading = false
    }

    func refresh() async {
        await loadVMs()
    }

    func startVM(name: String) async {
        // Confirm start
        let alert = NSAlert()
        alert.messageText = "Start Virtual Machine?"
        alert.informativeText = "This will start the VM '\(name)'."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.startVirtualMachine(name: name)
            await loadVMs()
        } catch {
            self.error = "Failed to start virtual machine: \(error.localizedDescription)"
        }
    }

    func stopVM(name: String) async {
        // Confirm stop
        let alert = NSAlert()
        alert.messageText = "Stop Virtual Machine?"
        alert.informativeText = "This will send an ACPI shutdown signal to VM '\(name)'."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.stopVirtualMachine(name: name)
            await loadVMs()
        } catch {
            self.error = "Failed to stop virtual machine: \(error.localizedDescription)"
        }
    }

    func restartVM(name: String) async {
        error = nil

        do {
            try await sshManager.restartVirtualMachine(name: name)
            await loadVMs()
        } catch {
            self.error = "Failed to restart virtual machine: \(error.localizedDescription)"
        }
    }

    func poweroffVM(name: String) async {
        // Confirm poweroff
        let alert = NSAlert()
        alert.messageText = "Force Poweroff Virtual Machine?"
        alert.informativeText = "This will forcefully poweroff the VM '\(name)'. Data may be lost if not properly shut down."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Force Poweroff")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.poweroffVirtualMachine(name: name)
            await loadVMs()
        } catch {
            self.error = "Failed to poweroff virtual machine: \(error.localizedDescription)"
        }
    }

    func deleteVM(name: String) async {
        // Confirm deletion
        let alert = NSAlert()
        alert.messageText = "Delete Virtual Machine?"
        alert.informativeText = "This will permanently delete the VM '\(name)' and all its data. This action cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.destroyVirtualMachine(name: name, force: true)
            await loadVMs()
        } catch {
            self.error = "Failed to delete virtual machine: \(error.localizedDescription)"
        }
    }

    func getVMInfo(name: String) async -> String? {
        do {
            return try await sshManager.getVirtualMachineInfo(name: name)
        } catch {
            self.error = "Failed to get VM info: \(error.localizedDescription)"
            return nil
        }
    }

    func listNetworkInterfaces() async -> [VMNetworkInterface] {
        do {
            let output = try await sshManager.executeCommand("ifconfig -l")
            let interfaceNames = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")

            var interfaces: [VMNetworkInterface] = []
            for name in interfaceNames {
                let ifName = String(name)
                // Get detailed info for each interface
                let detailOutput = try await sshManager.executeCommand("ifconfig \(ifName)")
                let isUp = detailOutput.contains("status: active") || detailOutput.contains("UP")
                let hasIPv4 = detailOutput.contains("inet ")

                // Skip loopback
                guard ifName != "lo0" else { continue }

                interfaces.append(VMNetworkInterface(
                    name: ifName,
                    description: ifName,
                    isUp: isUp,
                    hasIPv4: hasIPv4
                ))
            }

            return interfaces.sorted { $0.name < $1.name }
        } catch {
            self.error = "Failed to list network interfaces: \(error.localizedDescription)"
            return []
        }
    }

    func listVirtualSwitches() async -> [VirtualSwitch] {
        do {
            let output = try await sshManager.listVirtualSwitches()
            return parseVirtualSwitches(output)
        } catch {
            self.error = "Failed to list virtual switches: \(error.localizedDescription)"
            return []
        }
    }

    private func parseVirtualSwitches(_ output: String) -> [VirtualSwitch] {
        var switches: [VirtualSwitch] = []
        let lines = output.split(separator: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Parse vm switch list output
            // Format: NAME TYPE IFACE ADDRESS
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }

            let name = String(parts[0])
            let type = String(parts[1])
            let interface = parts.count > 2 ? String(parts[2]) : nil
            let address = parts.count > 3 ? String(parts[3]) : nil

            // Skip header line
            guard name.lowercased() != "name" else { continue }

            switches.append(VirtualSwitch(
                name: name,
                type: type,
                interface: interface != "-" ? interface : nil,
                address: address != "-" ? address : nil
            ))
        }

        return switches
    }

    func createVirtualSwitch(name: String, type: String, interface: String?) async {
        error = nil

        do {
            try await sshManager.createVirtualSwitch(name: name, type: type, interface: interface)
        } catch {
            self.error = "Failed to create virtual switch: \(error.localizedDescription)"
        }
    }

    func destroyVirtualSwitch(name: String) async {
        error = nil

        do {
            try await sshManager.destroyVirtualSwitch(name: name)
        } catch {
            self.error = "Failed to destroy virtual switch: \(error.localizedDescription)"
        }
    }

    func listISOs() async -> [ISOImage] {
        do {
            let output = try await sshManager.listISOs(datastore: nil)
            print("DEBUG: vm iso output: '\(output)'")
            return parseISOs(output)
        } catch {
            self.error = "Failed to list ISOs: \(error.localizedDescription)"
            return []
        }
    }

    private func parseISOs(_ output: String) -> [ISOImage] {
        var isos: [ISOImage] = []
        let lines = output.split(separator: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // vm iso output format:
            // DATASTORE           FILENAME
            // default             GhostBSD-26.1-R15.0b3-11-29-09.iso

            // Split by whitespace and take the last component (filename)
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else {
                print("DEBUG: Skipping line (not enough parts): '\(trimmed)'")
                continue
            }

            let filename = String(parts.last!)

            // Only include .iso files
            guard filename.lowercased().hasSuffix(".iso") else {
                print("DEBUG: Skipping line (not .iso): '\(trimmed)'")
                continue
            }

            // Store both datastore and filename
            let datastore = String(parts[0])
            isos.append(ISOImage(name: filename, size: datastore))
        }

        print("DEBUG: Parsed \(isos.count) ISOs")
        return isos.sorted { $0.name < $1.name }
    }

    func uploadISO(localURL: URL, progress: @escaping (Double) -> Void) async {
        error = nil

        do {
            let fileName = localURL.lastPathComponent
            let tempPath = "/tmp/\(fileName)"

            print("DEBUG: Starting ISO upload: \(fileName)")
            print("DEBUG: Temp path: \(tempPath)")

            // Step 1: Upload to /tmp with progress tracking (90% of progress)
            print("DEBUG: Uploading to temp location...")
            try await sshManager.uploadFile(localURL: localURL, remotePath: tempPath, progressCallback: { uploadProgress in
                // Upload is 90% of the total
                let totalProgress = uploadProgress * 0.9
                print("DEBUG: Upload progress: \(totalProgress)")
                progress(totalProgress)
            })

            print("DEBUG: Upload complete, importing with vm iso...")
            // Step 2: Import using vm iso command (10% of progress)
            // Note: vm iso writes to stderr even on success, so we ignore errors here
            do {
                let importOutput = try await sshManager.executeCommand("vm iso \(tempPath)")
                print("DEBUG: vm iso output: '\(importOutput)'")
            } catch {
                // vm iso often returns output via stderr which appears as an error
                // Check if the ISO was actually imported by listing ISOs
                print("DEBUG: vm iso command completed (may have written to stderr)")
            }

            progress(0.95)

            // Step 3: Clean up temp file
            print("DEBUG: Cleaning up temp file...")
            _ = try await sshManager.executeCommand("rm -f \(tempPath)")

            // Mark as complete
            print("DEBUG: Upload and import complete!")
            progress(1.0)

            // Give UI a moment to show 100% before dismissing
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        } catch {
            print("DEBUG: Upload error: \(error)")
            self.error = "Failed to upload ISO: \(error.localizedDescription)"
        }
    }

    func deleteISO(iso: ISOImage) async {
        error = nil

        do {
            // Get the datastore (stored in size field for now)
            let datastore = iso.size ?? "default"

            // Get VM directory and construct path to ISO
            let vmDirPath = vmDir.hasPrefix("zfs:") ? String(vmDir.dropFirst(4)) : vmDir
            let isoPath = "\(vmDirPath)/.iso/\(iso.name)"

            print("DEBUG: Deleting ISO: \(iso.name) from datastore: \(datastore)")
            print("DEBUG: ISO path: \(isoPath)")

            // Delete the ISO file directly (vm-bhyve doesn't have a delete command for ISOs)
            let output = try await sshManager.executeCommand("rm -f '\(isoPath)'")
            print("DEBUG: Delete output: '\(output)'")
        } catch {
            print("DEBUG: Delete error: \(error)")
            self.error = "Failed to delete ISO: \(error.localizedDescription)"
        }
    }
}

// MARK: - VM Info Sheet

struct VMInfoSheet: View {
    let vm: VirtualMachine
    let viewModel: VMsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var vmInfo: String = "Loading..."

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("VM Information")
                        .font(.title2)
                        .bold()
                    Text(vm.name)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            // Info content
            ScrollView {
                Text(vmInfo)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(width: 700, height: 600)
        .onAppear {
            Task {
                if let info = await viewModel.getVMInfo(name: vm.name) {
                    vmInfo = info
                } else {
                    vmInfo = "Failed to load VM information"
                }
            }
        }
    }
}

// MARK: - VM Create Sheet

struct VMCreateSheet: View {
    let viewModel: VMsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var vmName: String = ""
    @State private var template: String = "windows"
    @State private var datastore: String = "default"
    @State private var diskSize: String = "20G"
    @State private var cpuCount: String = "2"
    @State private var memory: String = "2G"
    @State private var isCreating = false
    @State private var selectedISO: ISOImage?
    @State private var availableISOs: [ISOImage] = []
    @State private var isLoadingISOs = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Create Virtual Machine")
                        .font(.title2)
                        .bold()
                    Text("Create a new VM using vm-bhyve")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Form
            Form {
                Section("Basic Configuration") {
                    TextField("VM Name:", text: $vmName)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Resources") {
                    TextField("CPU Cores:", text: $cpuCount)
                        .textFieldStyle(.roundedBorder)

                    TextField("Memory (e.g., 2G, 512M):", text: $memory)
                        .textFieldStyle(.roundedBorder)

                    TextField("Disk Size (e.g., 20G, 50G):", text: $diskSize)
                        .textFieldStyle(.roundedBorder)
                }

                Section("OS Installation") {
                    if isLoadingISOs {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading ISOs...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if availableISOs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No ISOs available")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Upload or download an ISO first")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Picker("ISO Image:", selection: $selectedISO) {
                            Text("Select ISO...").tag(nil as ISOImage?)
                            ForEach(availableISOs) { iso in
                                Text(iso.name).tag(iso as ISOImage?)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            .padding()
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Spacer()

                if isCreating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 8)
                }

                Button("Create") {
                    Task {
                        await createVM()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vmName.isEmpty || isCreating || selectedISO == nil)
            }
            .padding()
        }
        .frame(width: 500, height: 600)
        .onAppear {
            Task {
                await loadISOs()
            }
        }
    }

    private func loadISOs() async {
        isLoadingISOs = true
        availableISOs = await viewModel.listISOs()
        isLoadingISOs = false
    }

    private func createVM() async {
        isCreating = true

        do {
            // Step 1: Create the VM
            try await SSHConnectionManager.shared.createVirtualMachine(
                name: vmName,
                template: template,
                size: diskSize,
                datastore: datastore,
                cpu: cpuCount,
                memory: memory
            )

            // Step 2: Install from ISO and auto-launch VNC
            if let iso = selectedISO {
                // Run vm install in background so it doesn't block the UI
                // Use nohup and & to run the command in background on the server
                let installCommand = "nohup vm install -f \(vmName) \(iso.name) > /dev/null 2>&1 &"
                try await SSHConnectionManager.shared.executeCommand(installCommand)

                // Wait a moment for the VM to start
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

                // Auto-launch VNC viewer
                NotificationCenter.default.post(
                    name: .launchVNCForVM,
                    object: nil,
                    userInfo: ["vmName": vmName]
                )
            }

            await viewModel.loadVMs()
            dismiss()
        } catch {
            viewModel.error = "Failed to create VM: \(error.localizedDescription)"
        }

        isCreating = false
    }
}

// MARK: - VM Snapshot Sheet

struct VMSnapshotSheet: View {
    let vm: VirtualMachine
    let viewModel: VMsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var snapshotName: String = ""
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Create Snapshot")
                        .font(.title2)
                        .bold()
                    Text(vm.name)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Form
            VStack(alignment: .leading, spacing: 16) {
                Text("Create a ZFS snapshot of this virtual machine")
                    .font(.body)
                    .foregroundColor(.secondary)

                TextField("Snapshot Name (optional):", text: $snapshotName)
                    .textFieldStyle(.roundedBorder)

                Text("Leave empty to auto-generate a timestamp-based name")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Spacer()

            Divider()

            // Footer
            HStack {
                Spacer()

                if isCreating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 8)
                }

                Button("Create Snapshot") {
                    Task {
                        await createSnapshot()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating)
            }
            .padding()
        }
        .frame(width: 450, height: 250)
    }

    private func createSnapshot() async {
        isCreating = true

        do {
            try await SSHConnectionManager.shared.snapshotVirtualMachine(
                name: vm.name,
                snapshotName: snapshotName.isEmpty ? nil : snapshotName,
                force: vm.state == .running
            )

            await viewModel.loadVMs()
            dismiss()
        } catch {
            viewModel.error = "Failed to create snapshot: \(error.localizedDescription)"
        }

        isCreating = false
    }
}

// MARK: - Network Switches Sheet

struct NetworkSwitchesSheet: View {
    let viewModel: VMsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var switches: [VirtualSwitch] = []
    @State private var isLoading = false
    @State private var showCreateSwitch = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Network Switches")
                        .font(.title2)
                        .bold()
                    Text("Manage virtual network switches for VMs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Toolbar
            HStack {
                Button(action: {
                    Task {
                        await loadSwitches()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)

                Spacer()

                Button(action: {
                    showCreateSwitch = true
                }) {
                    Label("Create Switch", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            }
            .padding()

            Divider()

            // Switches list
            if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading network switches...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if switches.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "network")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Virtual Switches")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Create a virtual switch to enable VM networking")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(switches) { switch_ in
                        VirtualSwitchRow(switch_: switch_, onDelete: {
                            Task {
                                await deleteSwitch(switch_)
                            }
                        })
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 700, height: 500)
        .sheet(isPresented: $showCreateSwitch) {
            CreateSwitchSheet(viewModel: viewModel) {
                Task {
                    await loadSwitches()
                }
            }
        }
        .onAppear {
            Task {
                await loadSwitches()
            }
        }
    }

    private func loadSwitches() async {
        isLoading = true
        switches = await viewModel.listVirtualSwitches()
        isLoading = false
    }

    private func deleteSwitch(_ switch_: VirtualSwitch) async {
        // Confirm deletion
        let alert = NSAlert()
        alert.messageText = "Delete Virtual Switch?"
        alert.informativeText = "Are you sure you want to delete the switch '\(switch_.name)'? VMs using this switch may lose network connectivity."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        await viewModel.destroyVirtualSwitch(name: switch_.name)
        await loadSwitches()
    }
}

struct VirtualSwitchRow: View {
    let switch_: VirtualSwitch
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(switch_.name)
                    .font(.headline)

                HStack(spacing: 12) {
                    Label(switch_.type, systemImage: "")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let interface = switch_.interface {
                        Label(interface, systemImage: "cable.connector")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let address = switch_.address {
                        Label(address, systemImage: "number")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete switch")
        }
        .padding(.vertical, 4)
    }
}

struct CreateSwitchSheet: View {
    let viewModel: VMsViewModel
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var switchName = ""
    @State private var selectedInterface: VMNetworkInterface?
    @State private var interfaces: [VMNetworkInterface] = []
    @State private var isLoading = false
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Create Virtual Switch")
                        .font(.title2)
                        .bold()
                    Text("Create a new virtual network switch")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Switch name
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Switch Name")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Switch name (e.g., public, private)", text: $switchName)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Network adapter selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Network Adapter (Optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else if interfaces.isEmpty {
                            Text("No network interfaces found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Picker("Adapter", selection: $selectedInterface) {
                                Text("None").tag(nil as VMNetworkInterface?)
                                ForEach(interfaces) { interface in
                                    HStack {
                                        Text(interface.name)
                                        if interface.isUp {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                        }
                                        if interface.hasIPv4 {
                                            Text("(IPv4)")
                                                .font(.caption2)
                                        }
                                    }
                                    .tag(interface as VMNetworkInterface?)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        Text("Select a physical network adapter to bridge to this switch")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // Info box
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Network Switch Configuration")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text("Virtual switches allow VMs to communicate with each other and optionally with external networks through a bridged physical adapter.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.opacity(0.1))
                    )
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Spacer()

                if isCreating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 8)
                }

                Button("Create") {
                    Task {
                        await createSwitch()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(switchName.isEmpty || isCreating)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 550)
        .onAppear {
            Task {
                await loadInterfaces()
            }
        }
    }

    private func loadInterfaces() async {
        isLoading = true
        interfaces = await viewModel.listNetworkInterfaces()
        isLoading = false
    }

    private func createSwitch() async {
        isCreating = true

        await viewModel.createVirtualSwitch(
            name: switchName,
            type: "standard",
            interface: selectedInterface?.name
        )

        isCreating = false

        if viewModel.error == nil {
            onCreated()
            dismiss()
        }
    }
}

// MARK: - ISO Management Sheet

struct ISOManagementSheet: View {
    let viewModel: VMsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isos: [ISOImage] = []
    @State private var isLoading = false
    @State private var showUploadISO = false
    @State private var uploadProgress: Double = 0
    @State private var isUploading = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("ISO Management")
                        .font(.title2)
                        .bold()
                    Text("Manage ISO images for VM installation")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Toolbar
            HStack {
                Button(action: {
                    Task {
                        await loadISOs()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)

                Spacer()

                Button(action: {
                    showUploadISO = true
                }) {
                    Label("Upload ISO", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || isUploading)
            }
            .padding()

            Divider()

            // Upload progress
            if isUploading {
                VStack(spacing: 8) {
                    ProgressView(value: uploadProgress, total: 1.0)
                        .progressViewStyle(.linear)
                    Text("Uploading ISO... \(Int(uploadProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                Divider()
            }

            // ISOs list
            if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading ISO images...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isos.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "opticaldiscdrive")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No ISO Images")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Upload or download ISO images to install operating systems")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(isos) { iso in
                        ISORow(iso: iso, onDelete: {
                            Task {
                                await deleteISO(iso)
                            }
                        })
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 700, height: 500)
        .sheet(isPresented: $showUploadISO) {
            UploadISOSheet(viewModel: viewModel) {
                Task {
                    await loadISOs()
                }
            }
        }
        .onAppear {
            Task {
                await loadISOs()
            }
        }
    }

    private func loadISOs() async {
        isLoading = true
        isos = await viewModel.listISOs()
        isLoading = false
    }

    private func deleteISO(_ iso: ISOImage) async {
        // Confirm deletion
        let alert = NSAlert()
        alert.messageText = "Delete ISO Image?"
        alert.informativeText = "Are you sure you want to delete '\(iso.name)'?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        await viewModel.deleteISO(iso: iso)
        await loadISOs()
    }
}

struct ISORow: View {
    let iso: ISOImage
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "opticaldiscdrive.fill")
                .font(.title2)
                .foregroundColor(.orange)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(iso.name)
                    .font(.headline)

                if let datastore = iso.size {
                    Label("Datastore: \(datastore)", systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete ISO")
        }
        .padding(.vertical, 4)
    }
}

struct UploadISOSheet: View {
    let viewModel: VMsViewModel
    let onUploaded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var selectedFileURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Upload ISO")
                        .font(.title2)
                        .bold()
                    Text("Select an ISO file from your computer")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isUploading)
            }
            .padding()

            Divider()

            // Content
            VStack(spacing: 16) {
                if isUploading {
                    VStack(spacing: 12) {
                        ProgressView(value: uploadProgress, total: 1.0)
                            .progressViewStyle(.linear)
                        Text("Uploading ISO... \(Int(uploadProgress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let url = selectedFileURL {
                            Text(url.lastPathComponent)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "arrow.up.doc.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.blue)

                        Text("Select an ISO file to upload")
                            .font(.headline)

                        Button("Choose File...") {
                            selectFile()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 300)
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.diskImage]
        panel.allowsOtherFileTypes = true
        panel.message = "Select an ISO file to upload"

        if panel.runModal() == .OK, let url = panel.url {
            selectedFileURL = url
            Task { @MainActor in
                await uploadISO(url: url)
            }
        }
    }

    private func uploadISO(url: URL) async {
        isUploading = true
        uploadProgress = 0

        await viewModel.uploadISO(localURL: url, progress: { progress in
            Task { @MainActor in
                self.uploadProgress = progress
            }
        })

        isUploading = false

        if viewModel.error == nil {
            onUploaded()
            dismiss()
        }
    }
}

// MARK: - Bhyve Setup Wizard View

struct BhyveSetupWizardView: View {
    @ObservedObject var viewModel: VMsViewModel
    @State private var selectedPool: ZFSPool?
    @State private var datasetName = "vms"
    @State private var pools: [ZFSPool] = []
    @State private var interfaces: [String] = []
    @State private var selectedInterface: String?
    @State private var isLoadingPools = false
    @State private var isSettingUp = false
    @State private var setupOutput = ""
    @State private var setupError: String?

    private var zfsDataset: String {
        guard let pool = selectedPool else { return "" }
        return "\(pool.name)/\(datasetName)"
    }

    private var canStartSetup: Bool {
        // Need pool selected
        guard selectedPool != nil, !zfsDataset.isEmpty else { return false }
        // Need interface selected unless switch already exists
        if !viewModel.publicSwitchConfigured && selectedInterface == nil {
            return false
        }
        return true
    }

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)
                Text("Virtual Machine Setup Required")
                    .font(.title)
                    .fontWeight(.semibold)
                Text("Configure bhyve infrastructure before creating virtual machines")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)

            Divider()

            // Status indicators
            VStack(alignment: .leading, spacing: 12) {
                VMStatusRow(
                    title: "vm-bhyve",
                    isComplete: viewModel.isInstalled,
                    detail: viewModel.isInstalled ? "Installed" : "Not installed"
                )
                VMStatusRow(
                    title: "bhyve-firmware",
                    isComplete: viewModel.firmwareInstalled,
                    detail: viewModel.firmwareInstalled ? "Installed" : "Not installed"
                )
                VMStatusRow(
                    title: "VM Service",
                    isComplete: viewModel.serviceEnabled,
                    detail: viewModel.serviceEnabled ? "Enabled in rc.conf" : "Not enabled"
                )
                VMStatusRow(
                    title: "VM Templates",
                    isComplete: viewModel.templatesInstalled,
                    detail: viewModel.templatesInstalled ? "Installed" : "Not installed"
                )
                VMStatusRow(
                    title: "Network Switch",
                    isComplete: viewModel.publicSwitchConfigured,
                    detail: viewModel.publicSwitchConfigured ? "'public' switch configured" : "Not configured"
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
                                Task { await loadData() }
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
                            Text("Virtual machines will be stored in zfs:\(zfsDataset)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Network Configuration") {
                    if viewModel.publicSwitchConfigured {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("'public' switch already configured")
                                .foregroundColor(.secondary)
                        }
                    } else if interfaces.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("No network interfaces found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Picker("Network Interface:", selection: $selectedInterface) {
                            Text("Select an interface...").tag(nil as String?)
                            ForEach(interfaces, id: \.self) { iface in
                                Text(iface).tag(iface as String?)
                            }
                        }
                        .pickerStyle(.menu)

                        Text("A 'public' switch will be created using this interface for VM networking")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                .disabled(isSettingUp || !canStartSetup)
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
                                .textSelection(.enabled)
                                .id("bottom")
                        }
                        .onChange(of: setupOutput) { _, _ in
                            withAnimation {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .frame(height: 200)
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
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task { await loadData() }
        }
    }

    private func loadData() async {
        isLoadingPools = true
        setupError = nil

        // Load pools and interfaces in parallel
        async let poolsTask = viewModel.listZFSPools()
        async let interfacesTask = viewModel.listBridgeableInterfaces()

        pools = await poolsTask
        interfaces = await interfacesTask

        // Auto-select if only one pool
        if pools.count == 1 {
            selectedPool = pools.first
        }

        // Auto-select first interface if only one
        if interfaces.count == 1 {
            selectedInterface = interfaces.first
        }

        isLoadingPools = false
    }

    private func performSetup() async {
        isSettingUp = true
        setupError = nil
        setupOutput = ""

        do {
            try await viewModel.setupVMBhyve(zfsDataset: zfsDataset, networkInterface: selectedInterface) { output in
                Task { @MainActor in
                    setupOutput += output
                }
            }
        } catch {
            setupError = error.localizedDescription
        }

        isSettingUp = false
    }
}

// MARK: - VM Status Row Helper

private struct VMStatusRow: View {
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

