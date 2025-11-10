//
//  ContentView.swift
//  HexBSD
//
//  Created by Joseph Maloney on 3/17/25.
//

import SwiftUI
import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

struct SystemStatus {
    let cpuUsage: String
    let memoryUsage: String
    let zfsArcUsage: String
    let storageUsage: String
    let uptime: String
    let loadAverage: String
}

struct SavedServer: Identifiable, Codable {
    var id = UUID()
    let name: String
    let host: String
    let port: Int
    let username: String
    let keyPath: String  // Store the actual path instead of bookmark

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, keyPath
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case accounts = "Accounts"
    case packages = "Packages"
    case services = "Services"
    case status = "Status"
    case storage = "Storage"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .accounts: return "person.2"
        case .packages: return "shippingbox"
        case .services: return "gear"
        case .storage: return "externaldrive"
        case .status: return "chart.bar"
        }
    }
}

struct UserAccount: Identifiable {
    let id = UUID()
    let username: String
    let uid: Int
    let primaryGroup: String
    let additionalGroups: [String]
    let shell: String
    let homeDirectory: String
}

struct Package: Identifiable {
    let id = UUID()
    let name: String
    let version: String
    let description: String
}

struct Service: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let status: String
}

struct ContentView: View {
    @State private var selectedSection: SidebarSection?
    @State private var showConnectSheet = false
    @State private var showAbout = false
    @State private var savedServers: [SavedServer] = []
    @State private var selectedServer: SavedServer?

    // Use shared SSH connection manager across all windows
    var sshManager = SSHConnectionManager.shared

    // Real data from SSH
    @State private var systemStatus: SystemStatus?
    @State private var accounts: [UserAccount] = []
    @State private var packages: [Package] = []
    @State private var services: [Service] = []
    @State private var zfsPools: [ZFSPool] = []
    @State private var zfsDatasets: [ZFSDataset] = []

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selectedSection) { section in
                NavigationLink(value: section) {
                    Label(section.rawValue, systemImage: section.icon)
                }
                .disabled(!sshManager.isConnected)
            }
            .navigationTitle("\(sshManager.isConnected ? sshManager.serverAddress : "HexBSD")")

#if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
        } detail: {
            if let section = selectedSection, sshManager.isConnected {
                DetailView(
                    section: section,
                    serverAddress: sshManager.serverAddress,
                    systemStatus: systemStatus,
                    accounts: accounts,
                    packages: packages,
                    services: services,
                    zfsPools: zfsPools,
                    zfsDatasets: zfsDatasets
                )
            } else {
                VStack {
                    Text("Servers")
                        .font(.title)
                        .bold()
                        .padding(.bottom, 10)

                    if savedServers.isEmpty {
                        Text("No servers configured")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        List(savedServers) { server in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(server.name)
                                        .font(.headline)
                                    Text("\(server.username)@\(server.host):\(server.port)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Button("Connect") {
                                    connectToServer(server)
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Remove") {
                                    removeServer(server)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 300)
                    }

                    Button("Add Server") {
                        selectedServer = nil
                        showConnectSheet.toggle()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top)
                }
                .padding()
            }
        }
        .sheet(isPresented: $showConnectSheet) {
            ConnectView(
                onConnected: loadDataFromServer,
                onServerSaved: { server in
                    savedServers.append(server)
                    saveServers()
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowAboutWindow"))) { _ in
            showAbout = true
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        .onAppear {
            loadSavedServers()

            // If already connected (e.g., in a new window), load data
            if sshManager.isConnected {
                loadDataFromServer()
            }
        }
    }

    func loadSavedServers() {
        if let data = UserDefaults.standard.data(forKey: "savedServers"),
           let servers = try? JSONDecoder().decode([SavedServer].self, from: data) {
            savedServers = servers
        }
    }

    func saveServers() {
        if let data = try? JSONEncoder().encode(savedServers) {
            UserDefaults.standard.set(data, forKey: "savedServers")
        }
    }

    func removeServer(_ server: SavedServer) {
        savedServers.removeAll { $0.id == server.id }
        saveServers()
    }

    func connectToServer(_ server: SavedServer) {
        Task {
            do {
                // Use the saved key path directly (relying on entitlements for access)
                let keyURL = URL(fileURLWithPath: server.keyPath)

                // Verify the key file still exists
                guard FileManager.default.fileExists(atPath: server.keyPath) else {
                    print("SSH key file not found at: \(server.keyPath)")
                    return
                }

                let authMethod = SSHAuthMethod(username: server.username, privateKeyURL: keyURL)

                try await sshManager.connect(host: server.host, port: server.port, authMethod: authMethod)

                await MainActor.run {
                    loadDataFromServer()
                }
            } catch {
                print("Connection failed: \(error.localizedDescription)")
            }
        }
    }

    func loadDataFromServer() {
        Task {
            // Load data individually to avoid failing everything on one error
            do {
                self.systemStatus = try await sshManager.fetchSystemStatus()
            } catch {
                print("Error loading system status: \(error.localizedDescription)")
            }

            do {
                self.accounts = try await sshManager.fetchUserAccounts()
            } catch {
                print("Error loading accounts: \(error.localizedDescription)")
            }

            do {
                self.packages = try await sshManager.fetchPackages()
            } catch {
                print("Error loading packages: \(error.localizedDescription)")
            }

            do {
                self.services = try await sshManager.fetchServices()
            } catch {
                print("Error loading services: \(error.localizedDescription)")
            }

            do {
                self.zfsPools = try await sshManager.fetchZFSPools()
            } catch {
                print("Error loading ZFS pools: \(error.localizedDescription)")
            }

            do {
                self.zfsDatasets = try await sshManager.fetchZFSDatasets()
            } catch {
                print("Error loading ZFS datasets: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - ZFS Storage Models
struct ZFSPool: Identifiable {
    let id = UUID()
    let name: String
    let size: String
    let used: String
    let available: String
    let status: String
}

struct ZFSDataset: Identifiable {
    let id = UUID()
    let name: String
    let pool: String
    let used: String
    let mountpoint: String
}

struct DetailView: View {
    let section: SidebarSection
    let serverAddress: String
    let systemStatus: SystemStatus?
    let accounts: [UserAccount]
    let packages: [Package]
    let services: [Service]
    let zfsPools: [ZFSPool]
    let zfsDatasets: [ZFSDataset]

    var body: some View {
        VStack {
            if section == .services {
                Text("System Services")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                Table(services) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Description", value: \.description)
                    TableColumn("Status", value: \.status)
                }
            } else if section == .packages {
                Text("Installed Packages")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                Table(packages) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Version", value: \.version)
                    TableColumn("Description", value: \.description)
                }
            } else if section == .accounts {
                Text("User Accounts")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                Table(accounts.filter { $0.username != "root" }) {
                    TableColumn("Username", value: \.username)
                    TableColumn("UID") { Text("\($0.uid)") }
                    TableColumn("Primary Group", value: \.primaryGroup)
                    TableColumn("Additional Groups") { Text($0.additionalGroups.joined(separator: ", ")) }
                    TableColumn("Shell", value: \.shell)
                    TableColumn("Home Directory", value: \.homeDirectory)
                }

                HStack {
                    Button("Add") {
                        // UI-only mockup, does nothing
                    }
                    Button("Edit") {
                        // UI-only mockup, does nothing
                    }
                    .disabled(true) // Always disabled in mockup

                    Button("Remove") {
                        // UI-only mockup, does nothing
                    }
                    .disabled(true) // Always disabled in mockup
                }
                .padding(.top, 10)
            } else if section == .storage {
                Text("ZFS Storage")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                Text("ZFS Pools")
                    .font(.title2)
                    .bold()
                    .padding(.top, 10)

                Table(zfsPools) {
                    TableColumn("Pool Name", value: \.name)
                    TableColumn("Size", value: \.size)
                    TableColumn("Used", value: \.used)
                    TableColumn("Available", value: \.available)
                    TableColumn("Status", value: \.status)
                }
                .padding(.bottom, 20)

                Text("ZFS Datasets")
                    .font(.title2)
                    .bold()
                    .padding(.top, 10)

                Table(zfsDatasets) {
                    TableColumn("Dataset Name", value: \.name)
                    TableColumn("Pool", value: \.pool)
                    TableColumn("Used", value: \.used)
                    TableColumn("Mountpoint", value: \.mountpoint)
                }
            } else if section == .status {
                Text("System Status Dashboard")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                if let systemStatus = systemStatus {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("CPU Usage: \(systemStatus.cpuUsage)")
                        Text("Memory Usage: \(systemStatus.memoryUsage)")
                        Text("ZFS ARC Usage: \(systemStatus.zfsArcUsage)")
                        Text("Storage Usage: \(systemStatus.storageUsage)")
                        Text("Uptime: \(systemStatus.uptime)")
                        Text("Load Average: \(systemStatus.loadAverage)")
                    }
                    .font(.title2)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.2)))
                    .padding()
                } else {
                    Text("Loading system status...")
                        .foregroundColor(.secondary)
                }
            } else {
                Text(section.rawValue)
                    .font(.largeTitle)
                    .bold()
            }
            Spacer()
        }
        .padding()
        .navigationTitle("\(serverAddress) - \(section.rawValue)")
    }
}

// MARK: - Connect View
struct ConnectView: View {
    @Environment(\.dismiss) private var dismiss
    let onConnected: () -> Void
    let onServerSaved: (SavedServer) -> Void

    // Use shared SSH connection manager
    var sshManager = SSHConnectionManager.shared

    @State private var serverName = ""
    @State private var inputAddress = ""
    @State private var username = ""
    @State private var port = "22"
    @State private var selectedKeyURL: URL?
    @State private var selectedKeyPath: String = "No key selected"
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showSavePrompt = false
    @State private var pendingServer: SavedServer?

    var body: some View {
        VStack(spacing: 16) {
            Text("Connect to FreeBSD Server")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 8) {
                Text("Server Name (optional)")
                    .font(.caption)
                TextField("Will use server address if empty", text: $serverName)
                    .textFieldStyle(.roundedBorder)

                Text("Server Address")
                    .font(.caption)
                TextField("hostname or IP", text: $inputAddress)
                    .textFieldStyle(.roundedBorder)

                Text("Port")
                    .font(.caption)
                TextField("22", text: $port)
                    .textFieldStyle(.roundedBorder)

                Text("Username")
                    .font(.caption)
                TextField("username", text: $username)
                    .textFieldStyle(.roundedBorder)

                Text("SSH Private Key")
                    .font(.caption)
                HStack {
                    Text(selectedKeyPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button("Choose...") {
                        openFilePicker()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isConnecting)

                Button(isConnecting ? "Connecting..." : "Connect") {
                    connectToServer()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isConnecting || inputAddress.isEmpty || username.isEmpty || selectedKeyURL == nil)
            }
        }
        .padding()
        .frame(width: 450)
        .alert("Save Server?", isPresented: $showSavePrompt) {
            Button("Save") {
                if let server = pendingServer {
                    onServerSaved(server)
                }
                onConnected()
                dismiss()
            }
            Button("Don't Save") {
                onConnected()
                dismiss()
            }
        } message: {
            Text("Would you like to save this server configuration for quick access next time?")
        }
    }

    private func openFilePicker() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.message = "Select your SSH private key"

        // Start in the .ssh directory if it exists
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let sshURL = homeURL.appendingPathComponent(".ssh")
        if FileManager.default.fileExists(atPath: sshURL.path) {
            panel.directoryURL = sshURL
        }

        panel.begin { response in
            if response == .OK, let url = panel.url {
                selectedKeyURL = url
                selectedKeyPath = url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            }
        }
        #endif
    }

    private func resolveHostname(_ hostname: String) async -> String? {
        // Try to resolve hostname to IP address to work around sandbox DNS issues
        // If it's already an IP, this will return it unchanged
        return await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_INET  // IPv4
            hints.ai_socktype = SOCK_STREAM

            var result: UnsafeMutablePointer<addrinfo>?

            guard getaddrinfo(hostname, nil, &hints, &result) == 0,
                  let addrInfo = result else {
                return nil
            }

            defer { freeaddrinfo(result) }

            var addr = addrInfo.pointee.ai_addr.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

            if getnameinfo(&addr, addrInfo.pointee.ai_addrlen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: hostname)
            }

            return nil
        }.value
    }

    private func connectToServer() {
        guard let keyURL = selectedKeyURL else {
            errorMessage = "Please select an SSH private key"
            return
        }

        isConnecting = true
        errorMessage = nil

        Task {
            do {
                let portInt = Int(port) ?? 22

                // Try to resolve hostname to IP to work around sandbox DNS issues
                var hostToConnect = inputAddress
                if let resolvedIP = await resolveHostname(inputAddress) {
                    print("DEBUG: Resolved \(inputAddress) to \(resolvedIP)")
                    hostToConnect = resolvedIP
                }

                let authMethod = SSHAuthMethod(username: username, privateKeyURL: keyURL)

                try await sshManager.connect(host: hostToConnect, port: portInt, authMethod: authMethod)

                // Connection successful - prompt to save server
                await MainActor.run {
                    // Create pending server for save prompt
                    if let keyURL = selectedKeyURL {
                        pendingServer = SavedServer(
                            name: serverName.isEmpty ? inputAddress : serverName,
                            host: inputAddress,
                            port: portInt,
                            username: username,
                            keyPath: keyURL.path
                        )
                        showSavePrompt = true
                    } else {
                        // No key selected, just connect without saving
                        onConnected()
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Connection failed: \(error.localizedDescription)"
                    isConnecting = false
                }
            }
        }
    }
}

// MARK: - About View
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("HexBSD")
                .font(.largeTitle)
                .bold()

            Text("Version 1.0")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Open Source Acknowledgments")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Citadel")
                            .font(.headline)

                        Text("Swift SSH Client")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("Copyright (c) Orlandos Technologies")
                            .font(.caption)

                        Link("https://github.com/orlandos-nl/Citadel", destination: URL(string: "https://github.com/orlandos-nl/Citadel")!)
                            .font(.caption)

                        Divider()

                        Text("MIT License")
                            .font(.caption)
                            .bold()

                        Text("""
                        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

                        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

                        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
                        """)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.1)))
                }
                .padding()
            }

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 600, height: 500)
    }
}

#Preview {
    ContentView()
        .navigationTitle("HexBSD")
}
