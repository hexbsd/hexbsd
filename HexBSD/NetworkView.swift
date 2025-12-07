//
//  NetworkView.swift
//  HexBSD
//
//  Network connections viewer using sockstat
//

import SwiftUI

// MARK: - Network Connection Models

struct NetworkConnection: Identifiable, Hashable {
    let id = UUID()
    let user: String
    let command: String
    let pid: String
    let proto: String
    let localAddress: String
    let foreignAddress: String
    let state: String

    var displayCommand: String {
        // Truncate long command names
        if command.count > 20 {
            return String(command.prefix(17)) + "..."
        }
        return command
    }

    var stateColor: Color {
        switch state.uppercased() {
        case "ESTABLISHED":
            return .green
        case "LISTEN":
            return .blue
        case "TIME_WAIT", "CLOSE_WAIT":
            return .orange
        case "SYN_SENT", "SYN_RCVD":
            return .yellow
        case "CLOSED", "FIN_WAIT_1", "FIN_WAIT_2":
            return .red
        default:
            return .secondary
        }
    }
}

// MARK: - Network Content View

struct NetworkContentView: View {
    @StateObject private var viewModel = NetworkViewModel()
    @State private var showError = false
    @State private var searchText = ""
    @State private var selectedProtocol = "all"
    @State private var selectedState = "all"

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                // Protocol filter
                Picker("", selection: $selectedProtocol) {
                    Text("All").tag("all")
                    Text("TCP").tag("tcp")
                    Text("UDP").tag("udp")
                    Text("IPv4").tag("4")
                    Text("IPv6").tag("6")
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

                Spacer()

                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search connections...", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 200)

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

                Button(action: {
                    Task {
                        await viewModel.refresh()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                Toggle(isOn: $viewModel.autoRefresh) {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .toggleStyle(.button)
                .help("Auto-refresh every 3 seconds")
            }
            .padding()

            Divider()

            // Connections table
            if viewModel.isLoading && viewModel.connections.isEmpty {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading connections...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredConnections.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(searchText.isEmpty ? "No active connections" : "No matching connections")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filteredConnections) {
                    TableColumn("User", value: \.user)
                        .width(min: 60, ideal: 80, max: 120)

                    TableColumn("Command") { conn in
                        Text(conn.displayCommand)
                            .textSelection(.enabled)
                    }
                    .width(min: 100, ideal: 150, max: 200)

                    TableColumn("PID", value: \.pid)
                        .width(min: 50, ideal: 60, max: 80)

                    TableColumn("Protocol", value: \.proto)
                        .width(min: 50, ideal: 70, max: 90)

                    TableColumn("Local Address") { conn in
                        Text(conn.localAddress)
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Foreign Address") { conn in
                        Text(conn.foreignAddress)
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("State") { conn in
                        if !conn.state.isEmpty {
                            Text(conn.state)
                                .foregroundColor(conn.stateColor)
                                .bold()
                        }
                    }
                    .width(min: 100, ideal: 120, max: 150)
                }

                // Summary
                HStack {
                    Text("\(filteredConnections.count) connections")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    if viewModel.autoRefresh {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                            Text("Auto-refreshing")
                                .font(.caption)
                        }
                        .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .alert("Sockstat Error", isPresented: $showError) {
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
                await viewModel.loadConnections()
            }
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            if viewModel.autoRefresh {
                Task {
                    await viewModel.refreshQuiet()
                }
            }
        }
    }

    private var filteredConnections: [NetworkConnection] {
        var results = viewModel.connections

        // Filter by protocol
        if selectedProtocol != "all" {
            results = results.filter { conn in
                conn.proto.lowercased().contains(selectedProtocol.lowercased())
            }
        }

        // Filter by search
        if !searchText.isEmpty {
            results = results.filter { conn in
                conn.user.localizedCaseInsensitiveContains(searchText) ||
                conn.command.localizedCaseInsensitiveContains(searchText) ||
                conn.pid.localizedCaseInsensitiveContains(searchText) ||
                conn.localAddress.localizedCaseInsensitiveContains(searchText) ||
                conn.foreignAddress.localizedCaseInsensitiveContains(searchText) ||
                conn.state.localizedCaseInsensitiveContains(searchText)
            }
        }

        return results
    }
}

// MARK: - View Model

@MainActor
class NetworkViewModel: ObservableObject {
    @Published var connections: [NetworkConnection] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var autoRefresh: Bool = false

    private let sshManager = SSHConnectionManager.shared

    func loadConnections() async {
        isLoading = true
        error = nil

        do {
            connections = try await sshManager.listNetworkConnections()
        } catch {
            self.error = "Failed to load network connections: \(error.localizedDescription)"
            connections = []
        }

        isLoading = false
    }

    func refresh() async {
        await loadConnections()
    }

    func refreshQuiet() async {
        // Refresh without showing loading indicator (for auto-refresh)
        error = nil

        do {
            connections = try await sshManager.listNetworkConnections()
        } catch {
            // Silently fail for auto-refresh to avoid spam
            print("Auto-refresh failed: \(error.localizedDescription)")
        }
    }
}
