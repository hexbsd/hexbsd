//
//  BootEnvironmentsView.swift
//  HexBSD
//
//  Boot Environment management using bectl
//

import SwiftUI
import AppKit

// MARK: - Data Models

struct BootEnvironment: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let active: Bool      // Active on current boot
    let mountpoint: String
    let space: String
    let created: String
    let activeOnReboot: Bool  // Will be active on next reboot

    var statusIcon: String {
        if active {
            return "checkmark.circle.fill"
        } else if activeOnReboot {
            return "clock.circle.fill"
        } else {
            return "circle"
        }
    }

    var statusColor: Color {
        if active {
            return .green
        } else if activeOnReboot {
            return .orange
        } else {
            return .secondary
        }
    }

    var statusText: String {
        if active && activeOnReboot {
            return "Active (Now & On Reboot)"
        } else if active {
            return "Active Now"
        } else if activeOnReboot {
            return "Active On Reboot"
        } else {
            return "Inactive"
        }
    }
}

// MARK: - Main View

struct BootEnvironmentsContentView: View {
    @StateObject private var viewModel = BootEnvironmentsViewModel()
    @State private var showError = false
    @State private var showCreateBE = false
    @State private var showRenameBE = false
    @State private var selectedBE: BootEnvironment?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("\(viewModel.bootEnvironments.count) boot environment(s)")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                if let be = selectedBE {
                    // Actions for selected BE
                    if !be.active {
                        Button(action: {
                            Task {
                                await viewModel.activate(be: be.name)
                            }
                        }) {
                            Label("Activate", systemImage: "power")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if be.mountpoint == "-" {
                        Button(action: {
                            Task {
                                await viewModel.mount(be: be.name)
                            }
                        }) {
                            Label("Mount", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.bordered)
                    } else if be.mountpoint != "/" {
                        Button(action: {
                            Task {
                                await viewModel.unmount(be: be.name)
                            }
                        }) {
                            Label("Unmount", systemImage: "eject")
                        }
                        .buttonStyle(.bordered)
                    }

                    if !be.active {
                        Button(action: {
                            showRenameBE = true
                        }) {
                            Label("Rename", systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)
                    }

                    if !be.active {
                        Button(action: {
                            Task {
                                await viewModel.delete(be: be.name)
                            }
                        }) {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Button(action: {
                    showCreateBE = true
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

            // Boot environments list
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading boot environments...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.bootEnvironments.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Boot Environments")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Boot environments allow you to snapshot and revert your system")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.bootEnvironments, selection: $selectedBE) { be in
                    BootEnvironmentRow(bootEnvironment: be)
                }
            }
        }
        .alert("Boot Environment Error", isPresented: $showError) {
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
        .sheet(isPresented: $showCreateBE) {
            CreateBootEnvironmentSheet(
                existingBEs: viewModel.bootEnvironments.map { $0.name },
                onCreate: { name, source in
                    Task {
                        await viewModel.create(name: name, source: source)
                        showCreateBE = false
                    }
                },
                onCancel: {
                    showCreateBE = false
                }
            )
        }
        .sheet(isPresented: $showRenameBE) {
            if let be = selectedBE {
                RenameBootEnvironmentSheet(
                    currentName: be.name,
                    existingBEs: viewModel.bootEnvironments.map { $0.name },
                    onRename: { newName in
                        Task {
                            await viewModel.rename(oldName: be.name, newName: newName)
                            showRenameBE = false
                            selectedBE = nil
                        }
                    },
                    onCancel: {
                        showRenameBE = false
                    }
                )
            }
        }
        .onAppear {
            Task {
                await viewModel.loadBootEnvironments()
            }
        }
    }
}

// MARK: - Boot Environment Row

struct BootEnvironmentRow: View {
    let bootEnvironment: BootEnvironment

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            Image(systemName: bootEnvironment.statusIcon)
                .font(.title2)
                .foregroundColor(bootEnvironment.statusColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(bootEnvironment.name)
                    .font(.headline)

                HStack(spacing: 12) {
                    Label(bootEnvironment.statusText, systemImage: "")
                        .font(.caption)
                        .foregroundColor(bootEnvironment.statusColor)

                    if bootEnvironment.mountpoint != "-" {
                        Label(bootEnvironment.mountpoint, systemImage: "folder")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Label(bootEnvironment.space, systemImage: "externaldrive")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Label(bootEnvironment.created, systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Create Boot Environment Sheet

struct CreateBootEnvironmentSheet: View {
    let existingBEs: [String]
    let onCreate: (String, String?) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var sourceEnvironment = ""
    @State private var useSource = false

    var isNameValid: Bool {
        !name.isEmpty && !existingBEs.contains(name)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Create Boot Environment")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Text("Name")
                    .font(.caption)
                TextField("e.g., pre-upgrade", text: $name)
                    .textFieldStyle(.roundedBorder)

                if !isNameValid && !name.isEmpty {
                    Text("Name already exists or is invalid")
                        .font(.caption2)
                        .foregroundColor(.red)
                }

                Toggle("Clone from existing BE", isOn: $useSource)
                    .toggleStyle(.switch)

                if useSource {
                    Text("Source Boot Environment")
                        .font(.caption)
                    Picker("Source", selection: $sourceEnvironment) {
                        Text("Current").tag("")
                        ForEach(existingBEs, id: \.self) { be in
                            Text(be).tag(be)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("Creates a copy of the selected boot environment")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Creates a snapshot of the current running system")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    onCreate(name, useSource ? (sourceEnvironment.isEmpty ? nil : sourceEnvironment) : nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isNameValid)
            }
        }
        .padding()
        .frame(width: 450)
    }
}

// MARK: - Rename Boot Environment Sheet

struct RenameBootEnvironmentSheet: View {
    let currentName: String
    let existingBEs: [String]
    let onRename: (String) -> Void
    let onCancel: () -> Void

    @State private var newName = ""

    var isNameValid: Bool {
        !newName.isEmpty && !existingBEs.contains(newName) && newName != currentName
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Boot Environment")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Text("Current Name")
                    .font(.caption)
                Text(currentName)
                    .font(.body)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                Text("New Name")
                    .font(.caption)
                TextField("Enter new name", text: $newName)
                    .textFieldStyle(.roundedBorder)

                if !isNameValid && !newName.isEmpty {
                    Text("Name already exists or is invalid")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
            .padding()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Rename") {
                    onRename(newName)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isNameValid)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            newName = currentName
        }
    }
}

// MARK: - View Model

@MainActor
class BootEnvironmentsViewModel: ObservableObject {
    @Published var bootEnvironments: [BootEnvironment] = []
    @Published var isLoading = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadBootEnvironments() async {
        isLoading = true
        error = nil

        do {
            bootEnvironments = try await sshManager.listBootEnvironments()
        } catch {
            self.error = "Failed to load boot environments: \(error.localizedDescription)"
            bootEnvironments = []
        }

        isLoading = false
    }

    func refresh() async {
        await loadBootEnvironments()
    }

    func create(name: String, source: String?) async {
        error = nil

        do {
            try await sshManager.createBootEnvironment(name: name, source: source)
            await loadBootEnvironments()
        } catch {
            self.error = "Failed to create boot environment: \(error.localizedDescription)"
        }
    }

    func activate(be: String) async {
        // Confirm activation
        let alert = NSAlert()
        alert.messageText = "Activate Boot Environment?"
        alert.informativeText = "The system will boot into '\(be)' on next reboot. You can switch back if needed."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Activate")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.activateBootEnvironment(name: be)
            await loadBootEnvironments()
        } catch {
            self.error = "Failed to activate boot environment: \(error.localizedDescription)"
        }
    }

    func delete(be: String) async {
        // Confirm deletion
        let alert = NSAlert()
        alert.messageText = "Delete Boot Environment?"
        alert.informativeText = "This will permanently delete '\(be)'. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        error = nil

        do {
            try await sshManager.deleteBootEnvironment(name: be)
            await loadBootEnvironments()
        } catch {
            self.error = "Failed to delete boot environment: \(error.localizedDescription)"
        }
    }

    func rename(oldName: String, newName: String) async {
        error = nil

        do {
            try await sshManager.renameBootEnvironment(oldName: oldName, newName: newName)
            await loadBootEnvironments()
        } catch {
            self.error = "Failed to rename boot environment: \(error.localizedDescription)"
        }
    }

    func mount(be: String) async {
        error = nil

        do {
            try await sshManager.mountBootEnvironment(name: be)
            await loadBootEnvironments()
        } catch {
            self.error = "Failed to mount boot environment: \(error.localizedDescription)"
        }
    }

    func unmount(be: String) async {
        error = nil

        do {
            try await sshManager.unmountBootEnvironment(name: be)
            await loadBootEnvironments()
        } catch {
            self.error = "Failed to unmount boot environment: \(error.localizedDescription)"
        }
    }
}
