//
//  SysctlView.swift
//  HexBSD
//
//  Sysctl browser for FreeBSD system configuration
//

import SwiftUI

// MARK: - Sysctl Models

struct SysctlEntry: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let value: String
    let writable: Bool

    var category: String {
        let components = name.split(separator: ".")
        return components.isEmpty ? "other" : String(components[0])
    }

    var displayName: String {
        return name
    }
}

// MARK: - Sysctl Content View

struct SysctlContentView: View {
    @StateObject private var viewModel = SysctlViewModel()
    @State private var showError = false
    @State private var searchText = ""
    @State private var selectedCategory = "all"

    var body: some View {
        HSplitView {
            // Left: Category browser
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Categories")
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

                // Category list
                if viewModel.isLoadingCategories {
                    VStack(spacing: 20) {
                        ProgressView()
                        Text("Loading...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewModel.categories, id: \.self, selection: $selectedCategory) { category in
                        HStack {
                            Image(systemName: iconForCategory(category))
                                .foregroundColor(.blue)
                            Text(category.capitalized)
                            Spacer()
                            Text("\(viewModel.countForCategory(category))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .tag(category)
                    }
                }
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)

            // Right: Sysctl list
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search sysctls...", text: $searchText)
                        .textFieldStyle(.plain)

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
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                // Sysctl table
                if viewModel.isLoadingSysctls {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Loading sysctls...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredSysctls.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text(searchText.isEmpty ? "Select a category" : "No matching sysctls")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(filteredSysctls) {
                        TableColumn("Name") { sysctl in
                            HStack(spacing: 4) {
                                if sysctl.writable {
                                    Image(systemName: "pencil")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                } else {
                                    Image(systemName: "lock.fill")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text(sysctl.displayName)
                                    .textSelection(.enabled)
                            }
                        }
                        .width(min: 200, ideal: 300)

                        TableColumn("Value") { sysctl in
                            Text(sysctl.value)
                                .textSelection(.enabled)
                                .foregroundColor(.primary)
                        }
                        .width(min: 150, ideal: 250)
                    }
                }
            }
        }
        .alert("Sysctl Error", isPresented: $showError) {
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
        .onChange(of: selectedCategory) { oldValue, newValue in
            Task {
                await viewModel.loadCategory(newValue)
            }
        }
        .onAppear {
            Task {
                // Just load categories initially, not sysctls
                await viewModel.loadSysctls()
            }
        }
    }

    private var filteredSysctls: [SysctlEntry] {
        var results = viewModel.sysctls

        // Filter by search
        if !searchText.isEmpty {
            results = results.filter { sysctl in
                sysctl.name.localizedCaseInsensitiveContains(searchText) ||
                sysctl.value.localizedCaseInsensitiveContains(searchText)
            }
        }

        return results
    }

    private func iconForCategory(_ category: String) -> String {
        switch category.lowercased() {
        case "hw": return "cpu"
        case "kern": return "terminal"
        case "net": return "network"
        case "vm": return "memorychip"
        case "security": return "lock.shield"
        case "vfs": return "folder"
        case "debug": return "ant"
        case "dev": return "externaldrive"
        case "machdep": return "cpu.fill"
        case "user": return "person"
        case "kstat": return "chart.bar"
        case "compat": return "arrow.triangle.2.circlepath"
        default: return "gear"
        }
    }
}

// MARK: - View Model

@MainActor
class SysctlViewModel: ObservableObject {
    @Published var sysctls: [SysctlEntry] = []
    @Published var categories: [String] = []
    @Published var isLoadingCategories = false
    @Published var isLoadingSysctls = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared
    private var categoryCache: [String: [SysctlEntry]] = [:]
    private var categoryCounts: [String: Int] = [:]

    func loadSysctls() async {
        isLoadingCategories = true
        error = nil

        do {
            categories = try await sshManager.listSysctlCategories()
        } catch {
            self.error = "Failed to load categories: \(error.localizedDescription)"
            categories = []
        }

        isLoadingCategories = false
    }

    func loadCategory(_ category: String) async {
        // Check cache first
        if let cached = categoryCache[category] {
            sysctls = cached
            return
        }

        isLoadingSysctls = true
        error = nil

        do {
            let entries = try await sshManager.listSysctlsForCategory(category)
            sysctls = entries

            // Cache the results
            categoryCache[category] = entries
            categoryCounts[category] = entries.count
        } catch {
            self.error = "Failed to load sysctls for \(category): \(error.localizedDescription)"
            sysctls = []
        }

        isLoadingSysctls = false
    }

    func refresh() async {
        // Clear cache and reload
        categoryCache.removeAll()
        categoryCounts.removeAll()
        sysctls = []
        await loadSysctls()
    }

    func countForCategory(_ category: String) -> Int {
        return categoryCounts[category] ?? 0
    }
}
