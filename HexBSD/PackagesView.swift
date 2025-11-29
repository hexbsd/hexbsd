//
//  PackagesView.swift
//  HexBSD
//
//  Package management with repository switching
//

import SwiftUI
import AppKit

// MARK: - Data Models

enum PackageTab: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case upgradable = "Upgradable"
    case available = "Available"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .installed: return "shippingbox.fill"
        case .upgradable: return "arrow.up.circle"
        case .available: return "square.and.arrow.down"
        }
    }
}

struct Package: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let version: String
    let description: String
    let size: String

    var displayName: String {
        name
    }
}

struct UpgradablePackage: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let currentVersion: String
    let newVersion: String
    let description: String
}

struct AvailablePackage: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let version: String
    let description: String
}

enum RepositoryType: String, CaseIterable {
    case quarterly = "quarterly"
    case latest = "latest"

    var displayName: String {
        switch self {
        case .quarterly:
            return "Quarterly (Stable)"
        case .latest:
            return "Latest (Bleeding Edge)"
        }
    }

    var icon: String {
        switch self {
        case .quarterly:
            return "calendar.badge.clock"
        case .latest:
            return "sparkles"
        }
    }

    var color: Color {
        switch self {
        case .quarterly:
            return .blue
        case .latest:
            return .orange
        }
    }

    var description: String {
        switch self {
        case .quarterly:
            return "Stable packages updated quarterly"
        case .latest:
            return "Latest packages with frequent updates"
        }
    }
}

struct RepositoryInfo: Identifiable {
    let id = UUID()
    let url: String
    let type: RepositoryType
    let enabled: Bool
}

// MARK: - Main View

struct PackagesContentView: View {
    @StateObject private var viewModel = PackagesViewModel()
    @State private var showError = false
    @State private var searchText = ""
    @State private var showSwitchRepo = false
    @State private var selectedTab: PackageTab = .installed
    @State private var selectedPackage: Package?
    @State private var selectedUpgradablePackage: UpgradablePackage?
    @State private var selectedAvailablePackage: AvailablePackage?

    var filteredPackages: [Package] {
        if searchText.isEmpty {
            return viewModel.packages
        } else {
            return viewModel.packages.filter { pkg in
                pkg.name.localizedCaseInsensitiveContains(searchText) ||
                pkg.description.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var filteredUpgradablePackages: [UpgradablePackage] {
        if searchText.isEmpty {
            return viewModel.upgradablePackages
        } else {
            return viewModel.upgradablePackages.filter { pkg in
                pkg.name.localizedCaseInsensitiveContains(searchText) ||
                pkg.description.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var filteredAvailablePackages: [AvailablePackage] {
        if searchText.isEmpty {
            return viewModel.availablePackages
        } else {
            return viewModel.availablePackages.filter { pkg in
                pkg.name.localizedCaseInsensitiveContains(searchText) ||
                pkg.description.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var packageCountText: String {
        switch selectedTab {
        case .installed:
            return "\(viewModel.packages.count) package(s) installed"
        case .upgradable:
            return "\(viewModel.upgradablePackages.count) package(s) upgradable"
        case .available:
            return "\(viewModel.availablePackages.count) package(s) available"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(packageCountText)
                        .font(.headline)
                        .foregroundColor(.secondary)

                    if let repoType = viewModel.currentRepository {
                        HStack(spacing: 4) {
                            Image(systemName: repoType.icon)
                                .foregroundColor(repoType.color)
                            Text("Repository: \(repoType.displayName)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                if viewModel.updatesAvailable > 0 {
                    Text("\(viewModel.updatesAvailable) update(s) available")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                }

                Button(action: {
                    Task {
                        await viewModel.checkForUpdates()
                        // Automatically switch to Upgradable tab after checking
                        if viewModel.updatesAvailable > 0 {
                            selectedTab = .upgradable
                        }
                    }
                }) {
                    Label("Check Updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isLoading || viewModel.isUpgrading || viewModel.isSwitchingRepository)

                if viewModel.updatesAvailable > 0 {
                    Button(action: {
                        Task {
                            await viewModel.upgradePackages()
                        }
                    }) {
                        Label("Upgrade All", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isLoading || viewModel.isUpgrading || viewModel.isSwitchingRepository)
                }

                Button(action: {
                    showSwitchRepo = true
                }) {
                    Label("Switch Repo", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isLoading || viewModel.isUpgrading || viewModel.isSwitchingRepository)

                Button(action: {
                    Task {
                        await viewModel.refresh()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isLoading || viewModel.isUpgrading || viewModel.isSwitchingRepository)
            }
            .padding()

            Divider()

            // Tab Picker
            Picker("Package View", selection: $selectedTab) {
                ForEach(PackageTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .onChange(of: selectedTab) { oldValue, newValue in
                Task {
                    await viewModel.loadTabContent(for: newValue)
                }
            }

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search packages...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onChange(of: searchText) { oldValue, newValue in
                        if selectedTab == .available {
                            Task {
                                await viewModel.searchAvailablePackages(query: newValue)
                            }
                        }
                    }
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
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.top, 8)

            // Package list
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading packages...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isUpgrading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Upgrading packages...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("This may take several minutes")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if !viewModel.upgradeOutput.isEmpty {
                        ScrollView {
                            Text(viewModel.upgradeOutput)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .frame(maxHeight: 200)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(8)
                        .padding()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isSwitchingRepository {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Switching repository...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Updating package catalog, this may take up to a minute")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if !viewModel.repositorySwitchOutput.isEmpty {
                        ScrollView {
                            Text(viewModel.repositorySwitchOutput)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .frame(maxHeight: 200)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(8)
                        .padding()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Tab-specific content
                switch selectedTab {
                case .installed:
                    if viewModel.packages.isEmpty {
                        emptyStateView(
                            icon: "shippingbox",
                            title: "No Packages Installed",
                            message: "Install packages using pkg install"
                        )
                    } else if filteredPackages.isEmpty {
                        searchEmptyView()
                    } else {
                        List(filteredPackages, selection: $selectedPackage) { pkg in
                            InstalledPackageRow(package: pkg)
                        }
                    }

                case .upgradable:
                    if viewModel.upgradablePackages.isEmpty {
                        emptyStateView(
                            icon: "checkmark.circle",
                            title: "No Updates Available",
                            message: "All packages are up to date"
                        )
                    } else if filteredUpgradablePackages.isEmpty {
                        searchEmptyView()
                    } else {
                        List(filteredUpgradablePackages, selection: $selectedUpgradablePackage) { pkg in
                            UpgradablePackageRow(package: pkg)
                        }
                    }

                case .available:
                    if viewModel.availablePackages.isEmpty && !viewModel.isLoading {
                        emptyStateView(
                            icon: "square.and.arrow.down",
                            title: "Search for Packages",
                            message: "Enter a search term to find available packages"
                        )
                    } else if filteredAvailablePackages.isEmpty {
                        searchEmptyView()
                    } else {
                        List(filteredAvailablePackages, selection: $selectedAvailablePackage) { pkg in
                            AvailablePackageRow(package: pkg)
                        }
                    }
                }
            }
        }
        .alert("Package Error", isPresented: $showError) {
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
        .sheet(isPresented: $showSwitchRepo) {
            SwitchRepositorySheet(
                currentRepository: viewModel.currentRepository ?? .quarterly,
                onSwitch: { newRepo in
                    Task {
                        await viewModel.switchRepository(to: newRepo)
                        showSwitchRepo = false
                    }
                },
                onCancel: {
                    showSwitchRepo = false
                }
            )
        }
        .onAppear {
            Task {
                await viewModel.loadPackages()
            }
        }
    }

    // MARK: - Helper Views

    @ViewBuilder
    func emptyStateView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 72))
                .foregroundColor(.secondary)
            Text(title)
                .font(.title2)
                .foregroundColor(.secondary)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    func searchEmptyView() -> some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 72))
                .foregroundColor(.secondary)
            Text("No packages found")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Try a different search term")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Installed Package Row

struct InstalledPackageRow: View {
    let package: Package

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(package.name)
                    .font(.headline)

                HStack(spacing: 12) {
                    Label(package.version, systemImage: "number")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Label(package.size, systemImage: "externaldrive")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !package.description.isEmpty {
                    Text(package.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Upgradable Package Row

struct UpgradablePackageRow: View {
    let package: UpgradablePackage

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
                .foregroundColor(.orange)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(package.name)
                    .font(.headline)

                HStack(spacing: 12) {
                    Label(package.currentVersion, systemImage: "number")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundColor(.orange)

                    Label(package.newVersion, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if !package.description.isEmpty {
                    Text(package.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Available Package Row

struct AvailablePackageRow: View {
    let package: AvailablePackage

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: "square.and.arrow.down")
                .font(.title2)
                .foregroundColor(.green)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(package.name)
                    .font(.headline)

                Label(package.version, systemImage: "number")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !package.description.isEmpty {
                    Text(package.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Switch Repository Sheet

struct SwitchRepositorySheet: View {
    let currentRepository: RepositoryType
    let onSwitch: (RepositoryType) -> Void
    let onCancel: () -> Void

    @State private var selectedRepository: RepositoryType

    init(currentRepository: RepositoryType, onSwitch: @escaping (RepositoryType) -> Void, onCancel: @escaping () -> Void) {
        self.currentRepository = currentRepository
        self.onSwitch = onSwitch
        self.onCancel = onCancel
        _selectedRepository = State(initialValue: currentRepository)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Switch Package Repository")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 16) {
                Text("Current Repository")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Image(systemName: currentRepository.icon)
                        .foregroundColor(currentRepository.color)
                    Text(currentRepository.displayName)
                        .font(.body)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(currentRepository.color.opacity(0.1))
                .cornerRadius(8)

                Divider()
                    .padding(.vertical, 8)

                Text("Select New Repository")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(spacing: 12) {
                    ForEach(RepositoryType.allCases, id: \.self) { repo in
                        Button(action: {
                            selectedRepository = repo
                        }) {
                            HStack {
                                Image(systemName: repo.icon)
                                    .foregroundColor(repo.color)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(repo.displayName)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(repo.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if selectedRepository == repo {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(repo.color)
                                }
                            }
                            .padding(12)
                            .background(selectedRepository == repo ? repo.color.opacity(0.1) : Color.clear)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selectedRepository == repo ? repo.color : Color.clear, lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if selectedRepository != currentRepository {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("After switching, run 'Upgrade All' to update packages to the new repository versions.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            .padding()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Switch Repository") {
                    onSwitch(selectedRepository)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRepository == currentRepository)
            }
        }
        .padding()
        .frame(width: 500)
    }
}

// MARK: - View Model

@MainActor
class PackagesViewModel: ObservableObject {
    @Published var packages: [Package] = []
    @Published var upgradablePackages: [UpgradablePackage] = []
    @Published var availablePackages: [AvailablePackage] = []
    @Published var currentRepository: RepositoryType?
    @Published var updatesAvailable = 0
    @Published var isLoading = false
    @Published var isUpgrading = false
    @Published var upgradeOutput = ""
    @Published var isSwitchingRepository = false
    @Published var repositorySwitchOutput = ""
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadPackages() async {
        isLoading = true
        error = nil

        do {
            packages = try await sshManager.listInstalledPackages()
            currentRepository = try await sshManager.getCurrentRepository()
        } catch {
            self.error = "Failed to load packages: \(error.localizedDescription)"
            packages = []
        }

        isLoading = false
    }

    func refresh() async {
        await loadPackages()
    }

    func checkForUpdates() async {
        isLoading = true
        error = nil

        do {
            updatesAvailable = try await sshManager.checkPackageUpdates()

            // If there are updates, also load the upgradable packages list
            if updatesAvailable > 0 {
                upgradablePackages = try await sshManager.listUpgradablePackages()
            }
        } catch {
            self.error = "Failed to check for updates: \(error.localizedDescription)"
            updatesAvailable = 0
        }

        isLoading = false
    }

    func upgradePackages() async {
        // Confirm upgrade
        let alert = NSAlert()
        alert.messageText = "Upgrade All Packages?"
        alert.informativeText = "This will upgrade \(updatesAvailable) package(s) to their latest versions. This may take several minutes."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Upgrade")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        isUpgrading = true
        upgradeOutput = ""
        error = nil

        do {
            let output = try await sshManager.upgradePackages()
            upgradeOutput = output

            // Show success alert
            let successAlert = NSAlert()
            successAlert.messageText = "Upgrade Complete"
            successAlert.informativeText = "All packages have been upgraded successfully."
            successAlert.alertStyle = .informational
            successAlert.addButton(withTitle: "OK")
            successAlert.runModal()

            // Reload packages
            await loadPackages()
            updatesAvailable = 0
        } catch {
            self.error = "Failed to upgrade packages: \(error.localizedDescription)"
        }

        isUpgrading = false
        upgradeOutput = ""
    }

    func switchRepository(to newRepo: RepositoryType) async {
        isSwitchingRepository = true
        repositorySwitchOutput = ""
        error = nil

        do {
            let output = try await sshManager.switchPackageRepository(to: newRepo)
            repositorySwitchOutput = output
            currentRepository = newRepo

            // Show success and recommend checking for updates
            let alert = NSAlert()
            alert.messageText = "Repository Switched"
            alert.informativeText = "Package repository has been switched to \(newRepo.displayName). Click 'Check Updates' to see available packages from the new repository."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()

            // Reload packages
            await loadPackages()
        } catch {
            self.error = "Failed to switch repository: \(error.localizedDescription)"
        }

        isSwitchingRepository = false
        repositorySwitchOutput = ""
    }

    func loadTabContent(for tab: PackageTab) async {
        switch tab {
        case .installed:
            // Already loaded in loadPackages()
            break

        case .upgradable:
            // Only load if not already loaded (e.g., from checkForUpdates)
            if upgradablePackages.isEmpty {
                await loadUpgradablePackages()
            }

        case .available:
            // Available packages are loaded on-demand via search
            // For now, just clear if switching to this tab
            if availablePackages.isEmpty {
                // Optionally load popular packages or show empty state
            }
        }
    }

    func loadUpgradablePackages() async {
        isLoading = true
        error = nil

        do {
            upgradablePackages = try await sshManager.listUpgradablePackages()
        } catch {
            self.error = "Failed to load upgradable packages: \(error.localizedDescription)"
            upgradablePackages = []
        }

        isLoading = false
    }

    func searchAvailablePackages(query: String) async {
        guard !query.isEmpty else {
            availablePackages = []
            return
        }

        isLoading = true
        error = nil

        do {
            availablePackages = try await sshManager.searchPackages(query: query)
        } catch {
            self.error = "Failed to search packages: \(error.localizedDescription)"
            availablePackages = []
        }

        isLoading = false
    }
}
