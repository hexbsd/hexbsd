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

// MARK: - Log Search Result Model

struct LogSearchResult: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let size: String
    let matchCount: Int

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

// MARK: - Highlighted Text View

struct HighlightedText: View {
    let text: String
    let highlight: String

    var body: some View {
        if highlight.isEmpty {
            Text(text)
        } else {
            highlightedText
        }
    }

    private var highlightedText: Text {
        guard !highlight.isEmpty else { return Text(text) }

        var result = Text("")
        var remaining = text[...]

        while let range = remaining.range(of: highlight, options: .caseInsensitive) {
            // Add text before the match
            let before = String(remaining[..<range.lowerBound])
            result = result + Text(before)

            // Add the highlighted match with bold + color (no background on Text)
            let match = String(remaining[range])
            result = result + Text(match)
                .foregroundColor(.orange)
                .bold()

            // Move past this match
            remaining = remaining[range.upperBound...]
        }

        // Add any remaining text
        result = result + Text(String(remaining))

        return result
    }
}

// MARK: - Logs Content View

struct LogsContentView: View {
    @StateObject private var viewModel = LogsViewModel()
    @State private var showError = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HSplitView {
            // Left: Log file list
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Log Files")
                        .font(.headline)

                    Spacer()
                }
                .padding()

                // Global search field
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search all logs...", text: $viewModel.globalSearchText)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            Task {
                                await viewModel.searchAllLogs()
                            }
                        }
                    if viewModel.isSearchingAll {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else if !viewModel.globalSearchText.isEmpty {
                        Button(action: { viewModel.clearGlobalSearch() }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .padding(.horizontal)
                .padding(.bottom, 8)

                Divider()

                // Search results or file list
                if viewModel.showingSearchResults {
                    // Search results view
                    VStack(spacing: 0) {
                        HStack {
                            Text("\(viewModel.searchResults.count) files, \(viewModel.totalSearchMatches) matches")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Show All") {
                                viewModel.clearGlobalSearch()
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)

                        Divider()

                        List(viewModel.searchResults) { result in
                            Button(action: {
                                viewModel.selectLogFromSearch(result)
                            }) {
                                HStack {
                                    Image(systemName: result.icon)
                                        .foregroundColor(.blue)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.name)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        HStack {
                                            Text(result.size)
                                            Text("•")
                                            Text("\(result.matchCount) matches")
                                                .foregroundColor(.orange)
                                        }
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else if viewModel.isLoadingList {
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
                        // Search field
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("Search logs...", text: $viewModel.searchText)
                                .textFieldStyle(.plain)
                                .frame(width: 150)
                                .focused($isSearchFocused)
                            if !viewModel.searchText.isEmpty {
                                Text("\(viewModel.matchCount) matches")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Button(action: { viewModel.searchText = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)

                        Divider()
                            .frame(height: 16)

                        // Line count selector
                        Picker("Lines", selection: $viewModel.lineCount) {
                            Text("100").tag(100)
                            Text("500").tag(500)
                            Text("1000").tag(1000)
                            Text("All").tag(10000)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 250)

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
                            if viewModel.searchText.isEmpty {
                                Text(viewModel.logContent)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                                    .id("logContent")
                            } else {
                                // Show filtered content with highlighted matches
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(viewModel.filteredLogContent.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                                        HighlightedText(text: line, highlight: viewModel.searchText)
                                            .font(.system(.body, design: .monospaced))
                                            .textSelection(.enabled)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .id("logContent")
                            }
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                        .onChange(of: viewModel.logContent) { oldValue, newValue in
                            // Auto-scroll to bottom when streaming
                            if viewModel.isStreaming {
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
            Task {
                await viewModel.startStreaming()
            }
        }
        .onChange(of: viewModel.lineCount) { oldValue, newValue in
            Task {
                await viewModel.startStreaming()
            }
        }
        .onAppear {
            Task {
                await viewModel.loadLogFiles()
            }
        }
        .onDisappear {
            viewModel.stopStreaming()
        }
        .background {
            Button("") {
                if viewModel.selectedLog != nil {
                    isSearchFocused = true
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
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
    @Published var isStreaming: Bool = false
    @Published var searchText: String = ""

    // Global search
    @Published var globalSearchText: String = ""
    @Published var searchResults: [LogSearchResult] = []
    @Published var isSearchingAll = false
    @Published var showingSearchResults = false

    // Streaming task
    private var streamTask: Task<Void, Never>?

    var filteredLogContent: String {
        guard !searchText.isEmpty else { return logContent }
        let lines = logContent.components(separatedBy: "\n")
        let filtered = lines.filter { $0.localizedCaseInsensitiveContains(searchText) }
        return filtered.joined(separator: "\n")
    }

    var matchCount: Int {
        guard !searchText.isEmpty else { return 0 }
        let lines = logContent.components(separatedBy: "\n")
        return lines.filter { $0.localizedCaseInsensitiveContains(searchText) }.count
    }

    var totalSearchMatches: Int {
        searchResults.reduce(0) { $0 + $1.matchCount }
    }

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

    func startStreaming() async {
        // Stop any existing stream
        stopStreaming()

        guard let log = selectedLog else {
            logContent = ""
            return
        }

        isLoadingContent = true
        error = nil

        // First load initial content
        do {
            logContent = try await sshManager.readLogFile(path: log.path, lines: lineCount)
        } catch {
            self.error = "Failed to read log: \(error.localizedDescription)"
            logContent = ""
            isLoadingContent = false
            return
        }

        isLoadingContent = false
        isStreaming = true

        // Start streaming with tail -f
        let logPath = log.path
        streamTask = Task {
            await streamLogUpdates(path: logPath)
        }
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    private func streamLogUpdates(path: String) async {
        do {
            try await sshManager.streamLogFile(path: path) { [weak self] newLine in
                Task { @MainActor in
                    guard let self = self, !Task.isCancelled else { return }
                    self.logContent += newLine + "\n"
                }
            }
        } catch {
            if !Task.isCancelled {
                await MainActor.run {
                    self.isStreaming = false
                }
            }
        }
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

    func searchAllLogs() async {
        guard !globalSearchText.isEmpty else {
            searchResults = []
            showingSearchResults = false
            return
        }

        isSearchingAll = true
        error = nil

        do {
            searchResults = try await sshManager.searchAllLogs(pattern: globalSearchText)
            showingSearchResults = true
        } catch {
            self.error = "Search failed: \(error.localizedDescription)"
            searchResults = []
        }

        isSearchingAll = false
    }

    func selectLogFromSearch(_ result: LogSearchResult) {
        // Find the matching log file and select it
        if let logFile = logFiles.first(where: { $0.path == result.path }) {
            selectedLog = logFile
            // Set the local search filter to highlight matches
            searchText = globalSearchText
        }
        showingSearchResults = false
    }

    func clearGlobalSearch() {
        globalSearchText = ""
        searchResults = []
        showingSearchResults = false
    }
}
