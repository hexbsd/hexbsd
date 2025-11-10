//
//  LogsView.swift
//  HexBSD
//
//  System log viewer for FreeBSD /var/log
//

import SwiftUI

// MARK: - Log File Model

struct LogFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let size: String

    var icon: String {
        if name.contains("error") || name.contains("err") {
            return "exclamationmark.triangle"
        } else if name.contains("security") || name.contains("auth") {
            return "lock.shield"
        } else if name.contains("mail") {
            return "envelope"
        } else if name.contains("cron") {
            return "clock"
        } else {
            return "doc.text"
        }
    }
}

// MARK: - Logs Content View

struct LogsContentView: View {
    @StateObject private var viewModel = LogsViewModel()
    @State private var showError = false

    var body: some View {
        HSplitView {
            // Left: Log file list
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Log Files")
                        .font(.headline)

                    Spacer()

                    Button(action: {
                        Task {
                            await viewModel.refresh()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
                .padding()

                Divider()

                // File list
                if viewModel.isLoadingList {
                    VStack(spacing: 20) {
                        ProgressView()
                        Text("Loading logs...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewModel.logFiles, selection: $viewModel.selectedLog) { log in
                        HStack {
                            Image(systemName: log.icon)
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(log.name)
                                    .font(.body)
                                Text(log.size)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tag(log)
                    }
                }
            }
            .frame(minWidth: 200, idealWidth: 250, maxWidth: 350)

            // Right: Log content viewer
            VStack(spacing: 0) {
                // Toolbar
                HStack {
                    if let selectedLog = viewModel.selectedLog {
                        Text(selectedLog.name)
                            .font(.headline)
                    } else {
                        Text("Select a log file")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if viewModel.selectedLog != nil {
                        // Line count selector
                        Picker("Lines", selection: $viewModel.lineCount) {
                            Text("100").tag(100)
                            Text("500").tag(500)
                            Text("1000").tag(1000)
                            Text("All").tag(10000)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 250)

                        Toggle(isOn: $viewModel.autoRefresh) {
                            Image(systemName: "arrow.clockwise.circle")
                        }
                        .toggleStyle(.button)
                        .help("Auto-refresh every 5 seconds")

                        Button(action: {
                            Task {
                                await viewModel.refreshContent()
                            }
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)

                        Button(action: {
                            viewModel.exportLog()
                        }) {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .help("Export log file")
                    }
                }
                .padding()

                Divider()

                // Log content
                if viewModel.isLoadingContent {
                    VStack(spacing: 20) {
                        ProgressView()
                        Text("Loading log content...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.selectedLog == nil {
                    VStack(spacing: 20) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 72))
                            .foregroundColor(.secondary)
                        Text("Select a log file to view")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(viewModel.logContent)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .id("logContent")
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                        .onChange(of: viewModel.logContent) { oldValue, newValue in
                            // Auto-scroll to bottom when content updates
                            if viewModel.autoRefresh {
                                proxy.scrollTo("logContent", anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .alert("Logs Error", isPresented: $showError) {
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
        .onChange(of: viewModel.selectedLog) { oldValue, newValue in
            if newValue != nil {
                Task {
                    await viewModel.loadLogContent()
                }
            }
        }
        .onChange(of: viewModel.lineCount) { oldValue, newValue in
            Task {
                await viewModel.loadLogContent()
            }
        }
        .onAppear {
            Task {
                await viewModel.loadLogFiles()
            }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if viewModel.autoRefresh && viewModel.selectedLog != nil {
                Task {
                    await viewModel.refreshContent()
                }
            }
        }
    }
}

// MARK: - View Model

@MainActor
class LogsViewModel: ObservableObject {
    @Published var logFiles: [LogFile] = []
    @Published var selectedLog: LogFile?
    @Published var logContent: String = ""
    @Published var isLoadingList = false
    @Published var isLoadingContent = false
    @Published var error: String?
    @Published var lineCount: Int = 100
    @Published var autoRefresh: Bool = false

    private let sshManager = SSHConnectionManager.shared

    func loadLogFiles() async {
        isLoadingList = true
        error = nil

        do {
            logFiles = try await sshManager.listLogFiles()
        } catch {
            self.error = "Failed to load log files: \(error.localizedDescription)"
            logFiles = []
        }

        isLoadingList = false
    }

    func refresh() async {
        await loadLogFiles()
    }

    func loadLogContent() async {
        guard let log = selectedLog else { return }

        isLoadingContent = true
        error = nil

        do {
            logContent = try await sshManager.readLogFile(path: log.path, lines: lineCount)
        } catch {
            self.error = "Failed to read log: \(error.localizedDescription)"
            logContent = ""
        }

        isLoadingContent = false
    }

    func refreshContent() async {
        await loadLogContent()
    }

    func exportLog() {
        guard let log = selectedLog, !logContent.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = log.name
        panel.allowedContentTypes = [.plainText]
        panel.message = "Save log file"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try logContent.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            self.error = "Failed to export log: \(error.localizedDescription)"
        }
    }
}
