//
//  SessionsView.swift
//  HexBSD
//
//  User sessions viewer using w command
//

import SwiftUI

// MARK: - User Session Models

struct UserSession: Identifiable, Hashable {
    let id = UUID()
    let user: String
    let tty: String
    let from: String
    let loginTime: String
    let idle: String
    let what: String

    var displayFrom: String {
        from.isEmpty ? "local" : from
    }

    var isLocal: Bool {
        from.isEmpty || from == "-"
    }

    var isIdle: Bool {
        !idle.isEmpty && idle != "-" && idle != "0" && idle != "0.00s"
    }
}

// MARK: - Sessions Content View

struct SessionsContentView: View {
    @StateObject private var viewModel = SessionsViewModel()
    @State private var showError = false
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search sessions...", text: $searchText)
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

                Spacer()

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
                .help("Auto-refresh every 5 seconds")
            }
            .padding()

            Divider()

            // Sessions table
            if viewModel.isLoading && viewModel.sessions.isEmpty {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading sessions...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSessions.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "person.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(searchText.isEmpty ? "No active sessions" : "No matching sessions")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filteredSessions) {
                    TableColumn("User") { session in
                        HStack(spacing: 6) {
                            Image(systemName: "person.fill")
                                .foregroundColor(.blue)
                                .font(.caption)
                            Text(session.user)
                                .textSelection(.enabled)
                        }
                    }
                    .width(min: 80, ideal: 100, max: 150)

                    TableColumn("TTY") { session in
                        Text(session.tty)
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 80, ideal: 100, max: 120)

                    TableColumn("From") { session in
                        HStack(spacing: 6) {
                            if session.isLocal {
                                Image(systemName: "desktopcomputer")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            } else {
                                Image(systemName: "network")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            }
                            Text(session.displayFrom)
                                .textSelection(.enabled)
                        }
                    }
                    .width(min: 120, ideal: 180, max: 250)

                    TableColumn("Login Time") { session in
                        Text(session.loginTime)
                            .textSelection(.enabled)
                    }
                    .width(min: 100, ideal: 120, max: 150)

                    TableColumn("Idle") { session in
                        HStack(spacing: 6) {
                            if session.isIdle {
                                Image(systemName: "moon.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                            }
                            Text(session.idle)
                                .foregroundColor(session.isIdle ? .orange : .secondary)
                        }
                    }
                    .width(min: 80, ideal: 100, max: 120)

                    TableColumn("Command") { session in
                        Text(session.what)
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    .width(min: 150, ideal: 250)
                }

                // Summary
                HStack {
                    Text("\(filteredSessions.count) active session\(filteredSessions.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    let remoteCount = filteredSessions.filter { !$0.isLocal }.count
                    if remoteCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                                .font(.caption)
                            Text("\(remoteCount) remote")
                                .font(.caption)
                        }
                        .foregroundColor(.green)
                    }

                    if viewModel.autoRefresh {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                            Text("Auto-refreshing")
                                .font(.caption)
                        }
                        .foregroundColor(.blue)
                        .padding(.leading, 8)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
        }
        .alert("Sessions Error", isPresented: $showError) {
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
                await viewModel.loadSessions()
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

    private var filteredSessions: [UserSession] {
        guard !searchText.isEmpty else {
            return viewModel.sessions
        }

        return viewModel.sessions.filter { session in
            session.user.localizedCaseInsensitiveContains(searchText) ||
            session.tty.localizedCaseInsensitiveContains(searchText) ||
            session.from.localizedCaseInsensitiveContains(searchText) ||
            session.what.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - View Model

@MainActor
class SessionsViewModel: ObservableObject {
    @Published var sessions: [UserSession] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var autoRefresh: Bool = false

    private let sshManager = SSHConnectionManager.shared

    func loadSessions() async {
        isLoading = true
        error = nil

        do {
            sessions = try await sshManager.listUserSessions()
        } catch {
            self.error = "Failed to load user sessions: \(error.localizedDescription)"
            sessions = []
        }

        isLoading = false
    }

    func refresh() async {
        await loadSessions()
    }

    func refreshQuiet() async {
        // Refresh without showing loading indicator (for auto-refresh)
        error = nil

        do {
            sessions = try await sshManager.listUserSessions()
        } catch {
            // Silently fail for auto-refresh to avoid spam
            print("Auto-refresh failed: \(error.localizedDescription)")
        }
    }
}
