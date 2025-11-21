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
    let id = UUID()
    let name: String
    let state: VMState
    let pid: String?
    let cpu: String
    let memory: String
    let console: String?
    let vnc: String?

    enum VMState: String {
        case running = "Running"
        case stopped = "Stopped"
        case unknown = "Unknown"
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

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("\(viewModel.vms.count) virtual machine(s)")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                if let vm = selectedVM {
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
                            showVNC = true
                        }) {
                            Label("VNC", systemImage: "rectangle.on.rectangle")
                        }
                        .buttonStyle(.bordered)
                    }

                    // Start/Stop buttons
                    if vm.state == .stopped {
                        Button(action: {
                            Task {
                                await viewModel.startVM(name: vm.name)
                            }
                        }) {
                            Label("Start", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    } else if vm.state == .running {
                        Button(action: {
                            Task {
                                await viewModel.stopVM(name: vm.name)
                            }
                        }) {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
                }

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
                List(viewModel.vms, selection: $selectedVM) { vm in
                    VirtualMachineRow(vm: vm)
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
        .sheet(isPresented: $showConsole) {
            if let vm = selectedVM, let console = vm.console {
                VMConsoleSheet(vmName: vm.name, consolePath: console)
            }
        }
        .sheet(isPresented: $showVNC) {
            if let vm = selectedVM, let vnc = vm.vnc {
                VMVNCSheet(vmName: vm.name, vncAddress: vnc)
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
                Text(vm.name)
                    .font(.headline)

                HStack(spacing: 12) {
                    Label(vm.state.rawValue, systemImage: "")
                        .font(.caption)
                        .foregroundColor(vm.statusColor)

                    if !vm.cpu.isEmpty {
                        Label(vm.cpu, systemImage: "cpu")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !vm.memory.isEmpty {
                        Label(vm.memory, systemImage: "memorychip")
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

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("VM VNC: \(vmName)")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Close") {
                    dismiss()
                }
            }

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

                Text("Connect using a VNC client:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("• macOS: Screen Sharing app or VNC viewer")
                    Text("• Command: open vnc://\(vncAddress)")
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Button("Open VNC Connection") {
                    if let url = URL(string: "vnc://\(vncAddress)") {
                        NSWorkspace.shared.open(url)
                    }
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
        alert.informativeText = "This will forcefully stop the VM '\(name)'. Data may be lost if not properly shut down."
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
}
