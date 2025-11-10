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
    let networkIn: String
    let networkOut: String

    // Helper to extract percentage from cpuUsage string
    var cpuPercentage: Double {
        let cleaned = cpuUsage.replacingOccurrences(of: "%", with: "")
        return Double(cleaned) ?? 0
    }

    // Helper to extract memory usage percentage
    var memoryPercentage: Double {
        let parts = memoryUsage.split(separator: "/")
        guard parts.count == 2,
              let used = Double(parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: "")),
              let total = Double(parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: ""))
        else { return 0 }
        return total > 0 ? (used / total) * 100 : 0
    }

    // Helper to extract storage usage percentage
    var storagePercentage: Double {
        let parts = storageUsage.split(separator: "/")
        guard parts.count == 2,
              let used = Double(parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: "")),
              let total = Double(parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: ""))
        else { return 0 }
        return total > 0 ? (used / total) * 100 : 0
    }

    // Helper to extract ZFS ARC usage percentage
    var arcPercentage: Double {
        let parts = zfsArcUsage.split(separator: "/")
        guard parts.count == 2,
              let used = Double(parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: "")),
              let total = Double(parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: ""))
        else { return 0 }
        return total > 0 ? (used / total) * 100 : 0
    }
}

// MARK: - Dashboard Components

struct CircularProgressView: View {
    let progress: Double // 0-100
    let color: Color
    let lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)

            // Progress circle
            Circle()
                .trim(from: 0, to: min(progress / 100, 1.0))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: progress)

            // Percentage text
            Text(String(format: "%.0f%%", progress))
                .font(.system(size: 24, weight: .bold))
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let progress: Double?
    let color: Color
    let systemImage: String

    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundColor(color)
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }

            if let progress = progress {
                CircularProgressView(progress: progress, color: color)
                    .frame(width: 120, height: 120)

                Text(value)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(value)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
        )
    }
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
    case dashboard = "Dashboard"
    case files = "Files"
    case logs = "Logs"
    case sysctl = "Sysctl"
    case sockstat = "Sockstat"
    case terminal = "Terminal"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "chart.bar"
        case .files: return "folder"
        case .logs: return "doc.text"
        case .sysctl: return "slider.horizontal.3"
        case .sockstat: return "network"
        case .terminal: return "terminal"
        }
    }
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
                    systemStatus: systemStatus
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
                onConnected: {
                    loadDataFromServer()
                    // Navigate to status screen after connection
                    selectedSection = .dashboard
                },
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

            // If already connected (e.g., in a new window), load data and navigate to status
            if sshManager.isConnected {
                loadDataFromServer()
                // Navigate to status screen if no section is selected
                if selectedSection == nil {
                    selectedSection = .dashboard
                }
            }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            // Auto-refresh dashboard every 5 seconds if connected and viewing dashboard
            if sshManager.isConnected && selectedSection == .dashboard {
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
                    // Navigate to status screen after successful connection
                    selectedSection = .dashboard
                }
            } catch {
                print("Connection failed: \(error.localizedDescription)")
            }
        }
    }

    func loadDataFromServer() {
        Task {
            do {
                let status = try await sshManager.fetchSystemStatus()
                await MainActor.run {
                    self.systemStatus = status
                }
            } catch {
                print("Error loading system status: \(error.localizedDescription)")
            }
        }
    }
}

struct DetailView: View {
    let section: SidebarSection
    let serverAddress: String
    let systemStatus: SystemStatus?

    var body: some View {
        VStack {
            if section == .dashboard {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let systemStatus = systemStatus {
                            // Row 1: CPU and Memory
                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: 20),
                                GridItem(.flexible(), spacing: 20)
                            ], spacing: 20) {
                                MetricCard(
                                    title: "CPU Usage",
                                    value: systemStatus.cpuUsage,
                                    progress: systemStatus.cpuPercentage,
                                    color: .blue,
                                    systemImage: "cpu"
                                )

                                MetricCard(
                                    title: "Memory",
                                    value: systemStatus.memoryUsage,
                                    progress: systemStatus.memoryPercentage,
                                    color: .green,
                                    systemImage: "memorychip"
                                )
                            }

                            // Row 2: Storage and ZFS ARC
                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: 20),
                                GridItem(.flexible(), spacing: 20)
                            ], spacing: 20) {
                                MetricCard(
                                    title: "Storage",
                                    value: systemStatus.storageUsage,
                                    progress: systemStatus.storagePercentage,
                                    color: .orange,
                                    systemImage: "internaldrive"
                                )

                                MetricCard(
                                    title: "ZFS ARC",
                                    value: systemStatus.zfsArcUsage,
                                    progress: systemStatus.arcPercentage,
                                    color: .purple,
                                    systemImage: "memorychip.fill"
                                )
                            }

                            // Row 3: Network Traffic (Real-time)
                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: 20),
                                GridItem(.flexible(), spacing: 20)
                            ], spacing: 20) {
                                MetricCard(
                                    title: "Network In",
                                    value: systemStatus.networkIn,
                                    progress: nil,
                                    color: .teal,
                                    systemImage: "arrow.down.circle"
                                )

                                MetricCard(
                                    title: "Network Out",
                                    value: systemStatus.networkOut,
                                    progress: nil,
                                    color: .indigo,
                                    systemImage: "arrow.up.circle"
                                )
                            }

                            // Row 4: System Uptime and Load Average
                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: 20),
                                GridItem(.flexible(), spacing: 20)
                            ], spacing: 20) {
                                MetricCard(
                                    title: "System Uptime",
                                    value: systemStatus.uptime,
                                    progress: nil,
                                    color: .cyan,
                                    systemImage: "clock"
                                )

                                MetricCard(
                                    title: "Load Average",
                                    value: systemStatus.loadAverage,
                                    progress: nil,
                                    color: .pink,
                                    systemImage: "chart.line.uptrend.xyaxis"
                                )
                            }
                        } else {
                            VStack(spacing: 20) {
                                ProgressView()
                                    .scaleEffect(1.5)
                                Text("Loading system status...")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(100)
                        }
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if section == .files {
                // Files browser view
                FilesContentView()
            } else if section == .logs {
                // Logs viewer
                LogsContentView()
            } else if section == .sysctl {
                // Sysctl browser
                SysctlContentView()
            } else if section == .sockstat {
                // Network connections viewer
                NetworkContentView()
            } else if section == .terminal {
                // Terminal view handled separately with its own coordinator
                TerminalContentView()
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

                    VStack(alignment: .leading, spacing: 10) {
                        Text("SwiftTerm")
                            .font(.headline)

                        Text("VT100/Xterm Terminal Emulator")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("Copyright (c) Miguel de Icaza")
                            .font(.caption)

                        Link("https://github.com/migueldeicaza/SwiftTerm", destination: URL(string: "https://github.com/migueldeicaza/SwiftTerm")!)
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
