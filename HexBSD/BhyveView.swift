//
//  BhyveView.swift
//  HexBSD
//
//  Bhyve virtual machine management
//

import SwiftUI
import AppKit

// MARK: - Data Models

struct BhyveVM: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let status: VMStatus
    let cpu: String
    let memory: String
    let autostart: Bool
    let vncPort: Int?
    let serialPort: String?

    enum VMStatus: String {
        case running = "Running"
        case stopped = "Stopped"
        case starting = "Starting"
        case stopping = "Stopping"
        case unknown = "Unknown"
    }

    var statusColor: Color {
        switch status {
        case .running: return .green
        case .stopped: return .red
        case .starting, .stopping: return .orange
        case .unknown: return .secondary
        }
    }

    var hasVNC: Bool {
        vncPort != nil
    }

    var hasSerial: Bool {
        serialPort != nil && !serialPort!.isEmpty
    }
}

struct VMInfo: Identifiable {
    let id = UUID()
    let name: String
    let cpu: String
    let memory: String
    let disks: [String]
    let networks: [String]
    let bootrom: String
    let autostart: Bool
}

// MARK: - Main View

struct BhyveContentView: View {
    @StateObject private var viewModel = BhyveViewModel()
    @State private var showError = false
    @State private var showCreateVM = false
    @State private var selectedVM: BhyveVM?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("\(viewModel.vms.count) virtual machine(s)")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                if let vm = selectedVM {
                    // VM-specific actions
                    if vm.status == .running {
                        if vm.hasSerial {
                            Button(action: {
                                openConsole(vm: vm)
                            }) {
                                Label("Console", systemImage: "terminal")
                            }
                            .buttonStyle(.bordered)
                        }

                        if vm.hasVNC {
                            Button(action: {
                                openVNC(vm: vm)
                            }) {
                                Label("VNC", systemImage: "rectangle.on.rectangle")
                            }
                            .buttonStyle(.bordered)
                        }

                        Button(action: {
                            Task {
                                await viewModel.stopVM(vm: vm.name)
                            }
                        }) {
                            Label("Stop", systemImage: "stop.circle")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            Task {
                                await viewModel.restartVM(vm: vm.name)
                            }
                        }) {
                            Label("Restart", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    } else if vm.status == .stopped {
                        Button(action: {
                            Task {
                                await viewModel.startVM(vm: vm.name)
                            }
                        }) {
                            Label("Start", systemImage: "play.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button(action: {
                        Task {
                            await viewModel.showVMInfo(vm: vm.name)
                        }
                    }) {
                        Label("Info", systemImage: "info.circle")
                    }
                    .buttonStyle(.bordered)

                    if vm.status == .stopped {
                        Button(action: {
                            Task {
                                await viewModel.deleteVM(vm: vm.name)
                            }
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Button(action: {
                    showCreateVM = true
                }) {
                    Label("Create", systemImage: "plus.circle")
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

            // VMs list
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
                    Image(systemName: "cpu")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Virtual Machines")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Create a VM to get started")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.vms, selection: $selectedVM) { vm in
                    VMRow(vm: vm)
                }
            }
        }
        .alert("Bhyve Error", isPresented: $showError) {
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
            CreateVMSheet(
                onCreate: { name, cpu, memory, disk in
                    Task {
                        await viewModel.createVM(name: name, cpu: cpu, memory: memory, disk: disk)
                        showCreateVM = false
                    }
                },
                onCancel: {
                    showCreateVM = false
                }
            )
        }
        .onAppear {
            Task {
                await viewModel.loadVMs()
            }
        }
    }

    private func openConsole(vm: BhyveVM) {
        // Post notification to switch to terminal and run console command
        NotificationCenter.default.post(
            name: .openTerminalWithCommand,
            object: nil,
            userInfo: ["command": "vm console \(vm.name)"]
        )
    }

    private func openVNC(vm: BhyveVM) {
        guard let port = vm.vncPort else { return }

        // Get server address
        let host = SSHConnectionManager.shared.serverAddress

        // Open VNC URL
        if let url = URL(string: "vnc://\(host):\(port)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - VM Row

struct VMRow: View {
    let vm: BhyveVM

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(vm.statusColor)
                .frame(width: 12, height: 12)

            // VM icon
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(vm.name)
                    .font(.headline)

                HStack(spacing: 12) {
                    Label(vm.status.rawValue, systemImage: "")
                        .font(.caption)
                        .foregroundColor(vm.statusColor)

                    Label("\(vm.cpu) CPU", systemImage: "cpu")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Label(vm.memory, systemImage: "memorychip")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if vm.autostart {
                        Label("Autostart", systemImage: "power")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    if vm.hasVNC {
                        Label("VNC", systemImage: "rectangle.on.rectangle")
                            .font(.caption)
                            .foregroundColor(.green)
                    }

                    if vm.hasSerial {
                        Label("Serial", systemImage: "terminal")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Create VM Sheet

struct CreateVMSheet: View {
    let onCreate: (String, String, String, String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var cpu = "1"
    @State private var memory = "512M"
    @State private var diskSize = "10G"

    var isValid: Bool {
        !name.isEmpty && !cpu.isEmpty && !memory.isEmpty && !diskSize.isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Create Virtual Machine")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Text("VM Name")
                    .font(.caption)
                TextField("e.g., ubuntu-server", text: $name)
                    .textFieldStyle(.roundedBorder)

                Text("CPUs")
                    .font(.caption)
                TextField("Number of CPUs", text: $cpu)
                    .textFieldStyle(.roundedBorder)

                Text("Memory")
                    .font(.caption)
                TextField("e.g., 512M, 1G, 2G", text: $memory)
                    .textFieldStyle(.roundedBorder)

                Text("Disk Size")
                    .font(.caption)
                TextField("e.g., 10G, 20G, 50G", text: $diskSize)
                    .textFieldStyle(.roundedBorder)

                Text("This will create a new VM with default settings. You can configure it further after creation.")
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
                    onCreate(name, cpu, memory, diskSize)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 450)
    }
}

// MARK: - View Model

@MainActor
class BhyveViewModel: ObservableObject {
    @Published var vms: [BhyveVM] = []
    @Published var isLoading = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadVMs() async {
        isLoading = true
        error = nil

        do {
            vms = try await sshManager.listBhyveVMs()
        } catch {
            self.error = "Failed to load VMs: \(error.localizedDescription)"
            vms = []
        }

        isLoading = false
    }

    func refresh() async {
        await loadVMs()
    }

    func startVM(vm: String) async {
        error = nil

        do {
            try await sshManager.startBhyveVM(name: vm)
            // Wait a moment then refresh
            try await Task.sleep(nanoseconds: 2_000_000_000)
            await loadVMs()
        } catch {
            self.error = "Failed to start VM: \(error.localizedDescription)"
        }
    }

    func stopVM(vm: String) async {
        // Confirm stop
        let alert = NSAlert()
        alert.messageText = "Stop Virtual Machine?"
        alert.informativeText = "This will stop '\(vm)'. Any unsaved data may be lost."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.stopBhyveVM(name: vm)
            // Wait a moment then refresh
            try await Task.sleep(nanoseconds: 2_000_000_000)
            await loadVMs()
        } catch {
            self.error = "Failed to stop VM: \(error.localizedDescription)"
        }
    }

    func restartVM(vm: String) async {
        // Confirm restart
        let alert = NSAlert()
        alert.messageText = "Restart Virtual Machine?"
        alert.informativeText = "This will restart '\(vm)'."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.restartBhyveVM(name: vm)
            // Wait a moment then refresh
            try await Task.sleep(nanoseconds: 3_000_000_000)
            await loadVMs()
        } catch {
            self.error = "Failed to restart VM: \(error.localizedDescription)"
        }
    }

    func deleteVM(vm: String) async {
        // Confirm deletion
        let alert = NSAlert()
        alert.messageText = "Delete Virtual Machine?"
        alert.informativeText = "This will permanently delete '\(vm)' and all its data. This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.deleteBhyveVM(name: vm)
            await loadVMs()
        } catch {
            self.error = "Failed to delete VM: \(error.localizedDescription)"
        }
    }

    func showVMInfo(vm: String) async {
        do {
            let info = try await sshManager.getBhyveVMInfo(name: vm)

            // Display info in an alert
            let alert = NSAlert()
            alert.messageText = "VM Information: \(info.name)"
            alert.informativeText = """
            CPU: \(info.cpu)
            Memory: \(info.memory)
            Boot ROM: \(info.bootrom)
            Autostart: \(info.autostart ? "Yes" : "No")

            Disks:
            \(info.disks.isEmpty ? "None" : info.disks.joined(separator: "\n"))

            Networks:
            \(info.networks.isEmpty ? "None" : info.networks.joined(separator: "\n"))
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            self.error = "Failed to get VM info: \(error.localizedDescription)"
        }
    }

    func createVM(name: String, cpu: String, memory: String, disk: String) async {
        error = nil

        do {
            try await sshManager.createBhyveVM(name: name, cpu: cpu, memory: memory, disk: disk)
            await loadVMs()
        } catch {
            self.error = "Failed to create VM: \(error.localizedDescription)"
        }
    }
}
