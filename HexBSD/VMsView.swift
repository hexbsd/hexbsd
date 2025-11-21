//
//  VMsView.swift
//  HexBSD
//
//  Virtual Machine management using bhyve
//

import SwiftUI
import AppKit

// MARK: - Data Models

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
                        Text("\(viewModel.vms.count) virtual machine(s)")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        Spacer()

                        // Create VM button
                        Button(action: {
                            showCreateVM = true
                        }) {
                            Label("New VM", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)

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
                    } else if viewModel.vms.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 72))
                                .foregroundColor(.secondary)
                            Text("No Virtual Machines")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("No running bhyve VMs detected on this server")
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
        .onAppear {
            Task {
                await viewModel.loadVMs()
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

    private let sshManager = SSHConnectionManager.shared

    func loadVMs() async {
        isLoading = true
        error = nil

        do {
            vms = try await sshManager.listVirtualMachines()
        } catch {
            self.error = "Failed to load virtual machines: \(error.localizedDescription)"
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

    func getVMInfo(name: String) async -> String? {
        do {
            return try await sshManager.getVirtualMachineInfo(name: name)
        } catch {
            self.error = "Failed to get VM info: \(error.localizedDescription)"
            return nil
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
                .disabled(vmName.isEmpty || isCreating)
            }
            .padding()
        }
        .frame(width: 500, height: 450)
    }

    private func createVM() async {
        isCreating = true

        do {
            try await SSHConnectionManager.shared.createVirtualMachine(
                name: vmName,
                template: template,
                size: diskSize,
                datastore: datastore,
                cpu: cpuCount,
                memory: memory
            )

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
