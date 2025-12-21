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

    // Custom Equatable implementation - includes state for proper UI updates
    static func == (lhs: VirtualMachine, rhs: VirtualMachine) -> Bool {
        lhs.name == rhs.name &&
        lhs.state == rhs.state &&
        lhs.vnc == rhs.vnc &&
        lhs.console == rhs.console &&
        lhs.autostart == rhs.autostart
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
                            Task {
                                await viewModel.loadVMs()
                            }
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
        .sheet(isPresented: $showISOManagement) {
            ISOManagementSheet(viewModel: viewModel)
        }
        .onChange(of: viewModel.vms) { _, newVMs in
            // Update selectedVM to the matching VM from the refreshed list
            // This ensures the toolbar reflects the current VM state
            if let selected = selectedVM,
               let updated = newVMs.first(where: { $0.name == selected.name }) {
                selectedVM = updated
            }
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
    @Published var bridges: [BridgeInterface] = []

    private let sshManager = SSHConnectionManager.shared

    /// Check if any bridges exist (required before VM setup)
    var hasBridges: Bool {
        !bridges.isEmpty
    }

    /// Check if setup is complete (all requirements met, including bridge)
    var setupComplete: Bool {
        hasBridges && isInstalled && serviceEnabled && templatesInstalled && firmwareInstalled && publicSwitchConfigured
    }

    /// Setup vm-bhyve with streaming output
    func setupVMBhyve(zfsDataset: String, bridgeName: String?, onOutput: @escaping (String) -> Void) async throws {
        try await sshManager.setupVMBhyveStreaming(zfsDataset: zfsDataset, bridgeName: bridgeName, onOutput: onOutput)
        // Reload status after setup
        await loadVMs()
    }

    /// List existing bridges that can be used for VM networking
    func listBridges() async -> [BridgeInterface] {
        do {
            return try await sshManager.listBridges()
        } catch {
            print("Failed to list bridges: \(error.localizedDescription)")
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
            // First check if bridges exist (required for VM networking)
            bridges = try await sshManager.listBridges()

            // Then check if vm-bhyve is installed and enabled
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
        await uploadISO(localURL: localURL, detailedProgress: { _, _, _, _ in }, cancelCheck: { false })
    }

    func uploadISO(
        localURL: URL,
        detailedProgress: @escaping (Int64, Int64, String, String) -> Void,
        cancelCheck: @escaping () -> Bool
    ) async {
        error = nil

        do {
            let fileName = localURL.lastPathComponent
            let tempPath = "/tmp/\(fileName)"

            // Get file size
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
            let fileSize = fileAttributes[.size] as? Int64 ?? 0

            print("DEBUG: Starting ISO upload: \(fileName)")
            print("DEBUG: Temp path: \(tempPath)")
            print("DEBUG: File size: \(fileSize) bytes")

            // Check for cancellation
            if cancelCheck() {
                print("DEBUG: Upload cancelled before start")
                return
            }

            // ========== STEP 1: Upload to /tmp ==========
            print("DEBUG: Step 1/2: Uploading to temp location...")
            detailedProgress(0, fileSize, "", "Step 1/2: Uploading to server...")

            try await sshManager.uploadFile(
                localURL: localURL,
                remotePath: tempPath,
                detailedProgressCallback: { transferred, total, rate in
                    detailedProgress(transferred, total, rate, "Step 1/2: Uploading to server...")
                },
                cancelCheck: cancelCheck
            )

            // Check for cancellation
            if cancelCheck() {
                print("DEBUG: Upload cancelled after transfer")
                _ = try? await sshManager.executeCommand("rm -f \(tempPath)")
                return
            }

            // ========== STEP 2: Import with vm iso ==========
            print("DEBUG: Step 2/2: Importing with vm iso...")

            // Show animated progress during import (5 seconds)
            let importTask = Task {
                do {
                    _ = try await sshManager.executeCommand("vm iso \(tempPath)")
                    print("DEBUG: vm iso command completed")
                } catch {
                    print("DEBUG: vm iso returned error (may be normal): \(error)")
                }
                // Clean up temp file
                _ = try? await sshManager.executeCommand("rm -f \(tempPath)")
                print("DEBUG: Temp file cleaned up")
            }

            // Animate progress for 5 seconds while import runs
            for i in 0..<5 {
                if cancelCheck() {
                    importTask.cancel()
                    return
                }
                let progress = Int64((Double(i + 1) / 5.0) * Double(fileSize))
                detailedProgress(progress, fileSize, "", "Step 2/2: Importing ISO...")
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            }

            // Wait for import to finish if it hasn't already
            await importTask.value

            // Mark as complete
            print("DEBUG: Upload and import complete!")
            detailedProgress(fileSize, fileSize, "", "Complete!")

            // Give UI a moment to show completion before dismissing
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        } catch {
            if !cancelCheck() {
                print("DEBUG: Upload error: \(error)")
                self.error = "Failed to upload ISO: \(error.localizedDescription)"
            }
        }
    }

    private func formatTransferRate(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        let mb = kb / 1024

        if mb >= 1 {
            return String(format: "%.1f MB/s", mb)
        } else if kb >= 1 {
            return String(format: "%.0f KB/s", kb)
        } else {
            return String(format: "%.0f B/s", bytesPerSecond)
        }
    }

    func deleteISO(iso: ISOImage) async {
        error = nil

        do {
            // Get the VM directory path
            let vmDirOutput = try await sshManager.executeCommand("sysrc -n vm_dir 2>/dev/null || echo '/zroot/vms'")
            var vmDirPath = vmDirOutput.trimmingCharacters(in: .whitespacesAndNewlines)

            // Handle zfs: prefix - need to get the actual mountpoint
            if vmDirPath.hasPrefix("zfs:") {
                let dataset = String(vmDirPath.dropFirst(4))
                // Get the ZFS mountpoint
                let mountOutput = try await sshManager.executeCommand("zfs get -H -o value mountpoint \(dataset) 2>/dev/null || echo '/\(dataset)'")
                vmDirPath = mountOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let isoPath = "\(vmDirPath)/.iso/\(iso.name)"

            print("DEBUG: Deleting ISO: \(iso.name)")
            print("DEBUG: ISO path: \(isoPath)")

            // Check if file exists first
            let existsCheck = try await sshManager.executeCommand("test -f '\(isoPath)' && echo 'exists' || echo 'notfound'")
            if existsCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "notfound" {
                print("DEBUG: ISO file not found at \(isoPath)")
                self.error = "ISO file not found: \(iso.name)"
                return
            }

            // Delete the ISO file directly (vm-bhyve doesn't have a delete command for ISOs)
            let output = try await sshManager.executeCommand("rm -f '\(isoPath)'")
            print("DEBUG: Delete output: '\(output)'")

            // Verify deletion
            let verifyCheck = try await sshManager.executeCommand("test -f '\(isoPath)' && echo 'exists' || echo 'deleted'")
            if verifyCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "exists" {
                self.error = "Failed to delete ISO - file still exists"
            } else {
                print("DEBUG: ISO deleted successfully")
            }
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
    @State private var memory: String = "4G"
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

                    TextField("Memory (e.g., 4G, 512M):", text: $memory)
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

    // Detailed progress state
    @State private var transferredBytes: Int64 = 0
    @State private var totalBytes: Int64 = 0
    @State private var transferRate: String = ""
    @State private var uploadCancelled = false
    @State private var uploadPhase: String = "Uploading"

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

                if isUploading {
                    Button(action: {
                        uploadCancelled = true
                    }) {
                        Label("Cancel Upload", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding()

            Divider()

            // Content
            VStack(spacing: 16) {
                if isUploading {
                    VStack(spacing: 12) {
                        // File name
                        if let url = selectedFileURL {
                            Text(url.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        // Phase indicator
                        Text(uploadPhase)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // Progress bar
                        ProgressView(value: uploadProgress, total: 1.0)
                            .progressViewStyle(.linear)

                        // Progress details
                        HStack {
                            Text(formatBytes(transferredBytes))
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer()

                            if !transferRate.isEmpty {
                                Text(transferRate)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Text(formatBytes(totalBytes))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // Percentage
                        Text("\(Int(uploadProgress * 100))%")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.accentColor)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(width: 500, height: 350)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024

        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        } else if mb >= 1 {
            return String(format: "%.2f MB", mb)
        } else if kb >= 1 {
            return String(format: "%.1f KB", kb)
        } else {
            return "\(bytes) B"
        }
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

            // Get file size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                totalBytes = size
            }

            Task { @MainActor in
                await uploadISO(url: url)
            }
        }
    }

    private func uploadISO(url: URL) async {
        isUploading = true
        uploadProgress = 0
        uploadCancelled = false
        transferredBytes = 0
        transferRate = ""
        uploadPhase = "Uploading to server..."

        await viewModel.uploadISO(
            localURL: url,
            detailedProgress: { transferred, total, rate, phase in
                Task { @MainActor in
                    self.transferredBytes = transferred
                    self.totalBytes = total
                    self.transferRate = rate
                    self.uploadPhase = phase
                    self.uploadProgress = total > 0 ? Double(transferred) / Double(total) * 0.9 : 0
                }
            },
            cancelCheck: { self.uploadCancelled }
        )

        isUploading = false

        if viewModel.error == nil && !uploadCancelled {
            onUploaded()
            dismiss()
        } else if uploadCancelled {
            // Reset state on cancel
            uploadProgress = 0
            transferredBytes = 0
            transferRate = ""
        }
    }
}

// MARK: - Bhyve Setup Wizard View

struct BhyveSetupWizardView: View {
    @ObservedObject var viewModel: VMsViewModel
    @State private var selectedPool: ZFSPool?
    @State private var datasetName = "vms"
    @State private var pools: [ZFSPool] = []
    @State private var selectedBridge: BridgeInterface?
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
        // Need bridge selected unless switch already exists
        if !viewModel.publicSwitchConfigured && selectedBridge == nil {
            return false
        }
        return true
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

                    Text("Virtual machines require a network bridge for connectivity.\nPlease create a bridge in the Network section first.")
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
                        title: "Network Bridge",
                        isComplete: viewModel.hasBridges,
                        detail: viewModel.hasBridges ? "\(viewModel.bridges.count) bridge(s) available" : "No bridges configured"
                    )
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
                    } else {
                        Picker("Network Bridge:", selection: $selectedBridge) {
                            Text("Select a bridge...").tag(nil as BridgeInterface?)
                            ForEach(viewModel.bridges) { bridge in
                                HStack {
                                    Text(bridge.name)
                                    if !bridge.members.isEmpty {
                                        Text("(\(bridge.members.joined(separator: ", ")))")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .tag(bridge as BridgeInterface?)
                            }
                        }
                        .pickerStyle(.menu)

                        Text("A 'public' switch will be created using the selected bridge for VM networking")
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
            } // end else (bridges exist)
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

        // Load pools (bridges are already loaded in viewModel)
        pools = await viewModel.listZFSPools()

        // Auto-select if only one pool
        if pools.count == 1 {
            selectedPool = pools.first
        }

        // Auto-select first bridge if only one
        if viewModel.bridges.count == 1 {
            selectedBridge = viewModel.bridges.first
        }

        isLoadingPools = false
    }

    private func performSetup() async {
        isSettingUp = true
        setupError = nil
        setupOutput = ""

        do {
            try await viewModel.setupVMBhyve(zfsDataset: zfsDataset, bridgeName: selectedBridge?.name) { output in
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

