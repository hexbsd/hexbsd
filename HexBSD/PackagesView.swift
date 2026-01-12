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
    let repository: String  // The repository this package came from (e.g., "FreeBSD-ports", "FreeBSD-ports-kmods", "FreeBSD-base")

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

struct PackageInfo {
    var name: String
    var version: String = ""
    var origin: String = ""
    var comment: String = ""
    var description: String = ""
    var maintainer: String = ""
    var website: String = ""
    var flatSize: String = ""
    var license: String = ""
    var dependencies: [String] = []
    var requiredBy: [String] = []
    var isVital: Bool = false  // Vital packages cannot be removed
    var isLocked: Bool = false // Locked packages are protected from removal/modification
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
    @State private var selectedUpgradablePackages: Set<UpgradablePackage.ID> = []
    @State private var selectedAvailablePackage: AvailablePackage?
    @State private var selectedRepositoryFilter: String? = nil  // nil means "All Repositories"

    // Get unique repository names from installed packages
    var availableRepositories: [String] {
        let repos = Set(viewModel.packages.map { $0.repository })
        return repos.sorted()
    }

    var filteredPackages: [Package] {
        var packages = viewModel.packages

        // Filter by repository if one is selected
        if let repoFilter = selectedRepositoryFilter {
            packages = packages.filter { $0.repository == repoFilter }
        }

        // Filter by search text
        if !searchText.isEmpty {
            packages = packages.filter { pkg in
                pkg.name.localizedCaseInsensitiveContains(searchText) ||
                pkg.description.localizedCaseInsensitiveContains(searchText)
            }
        }

        return packages
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
            if let repo = selectedRepositoryFilter {
                let count = viewModel.packages.filter { $0.repository == repo }.count
                return "\(count) package(s) from \(repo)"
            }
            return "\(viewModel.packages.count) package(s) installed"
        case .upgradable:
            return "\(viewModel.upgradablePackages.count) package(s) upgradable"
        case .available:
            return "\(viewModel.availablePackages.count) package(s) available"
        }
    }

    var body: some View {
        Group {
            if viewModel.isUpgrading || viewModel.upgradeComplete {
                // Full-screen upgrade console
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Image(systemName: viewModel.upgradeComplete ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundColor(viewModel.upgradeComplete ? .green : .orange)

                        Text(viewModel.upgradeComplete ? "Upgrade Complete" : "Upgrading Packages...")
                            .font(.headline)

                        Spacer()

                        if !viewModel.upgradeComplete {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                    .padding()
                    .background(viewModel.upgradeComplete ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))

                    Divider()

                    // Console output
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(viewModel.upgradeOutput.isEmpty ? "Starting upgrade..." : viewModel.upgradeOutput)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .id("bottom")
                        }
                        .background(Color(NSColor.textBackgroundColor))
                        .onChange(of: viewModel.upgradeOutput) { _, _ in
                            withAnimation {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }

                    Divider()

                    // Close button when complete
                    if viewModel.upgradeComplete {
                        HStack {
                            Spacer()
                            Button("Close") {
                                Task {
                                    await viewModel.dismissUpgradeConsole()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.05))
                    }
                }
            } else {
                // Normal package view
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

                        // Show upgrade button when on upgradable tab and there are packages
                        if selectedTab == .upgradable && !viewModel.upgradablePackages.isEmpty {
                            Button(action: {
                                Task {
                                    if selectedUpgradablePackages.isEmpty {
                                        await viewModel.upgradePackages()
                                    } else {
                                        let packagesToUpgrade = viewModel.upgradablePackages
                                            .filter { selectedUpgradablePackages.contains($0.id) }
                                            .map { $0.name }
                                        await viewModel.upgradeSelectedPackages(names: packagesToUpgrade)
                                        selectedUpgradablePackages.removeAll()
                                    }
                                }
                            }) {
                                let count = selectedUpgradablePackages.isEmpty
                                    ? viewModel.upgradablePackages.count
                                    : selectedUpgradablePackages.count
                                Label("Upgrade \(count) Package\(count == 1 ? "" : "s")", systemImage: "arrow.up.circle")
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

            // Repository filter (only shown for installed tab when there are multiple repos)
            if selectedTab == .installed && availableRepositories.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // "All" button
                        Button(action: {
                            selectedRepositoryFilter = nil
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "shippingbox.fill")
                                Text("All (\(viewModel.packages.count))")
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selectedRepositoryFilter == nil ? Color.accentColor : Color.secondary.opacity(0.1))
                            .foregroundColor(selectedRepositoryFilter == nil ? .white : .primary)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        // Individual repository buttons
                        ForEach(availableRepositories, id: \.self) { repo in
                            let count = viewModel.packages.filter { $0.repository == repo }.count
                            Button(action: {
                                selectedRepositoryFilter = repo
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: repositoryIcon(for: repo))
                                    Text("\(repo) (\(count))")
                                }
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selectedRepositoryFilter == repo ? repositoryColor(for: repo) : Color.secondary.opacity(0.1))
                                .foregroundColor(selectedRepositoryFilter == repo ? .white : .primary)
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.top, 8)
            }

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
                // Tab-specific content with optional detail panel
                HSplitView {
                    // Package list
                    VStack(spacing: 0) {
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
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectedPackage = pkg
                                        }
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
                                List(filteredUpgradablePackages, selection: $selectedUpgradablePackages) { pkg in
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
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectedAvailablePackage = pkg
                                        }
                                }
                            }
                        }
                    }
                    .frame(minWidth: 300)

                    // Detail panel
                    if selectedTab == .installed, let pkg = selectedPackage {
                        InstalledPackageDetailView(
                            package: pkg,
                            viewModel: viewModel,
                            onDismiss: { selectedPackage = nil }
                        )
                    } else if selectedTab == .available, let pkg = selectedAvailablePackage {
                        AvailablePackageDetailView(
                            package: pkg,
                            viewModel: viewModel,
                            onDismiss: { selectedAvailablePackage = nil }
                        )
                    }
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

    // MARK: - Repository Helpers

    func repositoryIcon(for repo: String) -> String {
        let lowercased = repo.lowercased()
        if lowercased.contains("base") {
            return "gearshape.fill"
        } else if lowercased.contains("kmod") {
            return "cpu.fill"
        } else if lowercased.contains("ports") {
            return "shippingbox.fill"
        } else {
            return "archivebox.fill"
        }
    }

    func repositoryColor(for repo: String) -> Color {
        let lowercased = repo.lowercased()
        if lowercased.contains("base") {
            return .purple
        } else if lowercased.contains("kmod") {
            return .orange
        } else if lowercased.contains("ports") {
            return .blue
        } else {
            return .green
        }
    }
}

// MARK: - Installed Package Row

struct InstalledPackageRow: View {
    let package: Package

    private var repoColor: Color {
        let lowercased = package.repository.lowercased()
        if lowercased.contains("base") {
            return .purple
        } else if lowercased.contains("kmod") {
            return .orange
        } else if lowercased.contains("ports") {
            return .blue
        } else {
            return .green
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundColor(repoColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(package.name)
                        .font(.headline)

                    Text(package.repository)
                        .font(.system(size: 9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(repoColor.opacity(0.15))
                        .foregroundColor(repoColor)
                        .cornerRadius(4)
                }

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

// MARK: - Package Detail View (Installed)

struct InstalledPackageDetailView: View {
    let package: Package
    @ObservedObject var viewModel: PackagesViewModel
    let onDismiss: () -> Void

    @State private var packageInfo: PackageInfo?
    @State private var isLoadingInfo = true

    // Base packages should never be removable through the UI
    private var isBasePackage: Bool {
        package.repository.lowercased().contains("base")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(package.name)
                        .font(.title2)
                        .bold()

                    HStack(spacing: 8) {
                        Label(package.version, systemImage: "number")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(package.repository)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.secondary.opacity(0.05))

            Divider()

            if isLoadingInfo {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading package details...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let info = packageInfo {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Description
                        if !info.description.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Description")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(info.description)
                                    .font(.body)
                            }
                        }

                        Divider()

                        // Details Grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                            if !info.flatSize.isEmpty {
                                DetailItem(label: "Size", value: info.flatSize)
                            }
                            if !info.origin.isEmpty {
                                DetailItem(label: "Origin", value: info.origin)
                            }
                            if !info.license.isEmpty {
                                DetailItem(label: "License", value: info.license)
                            }
                            if !info.maintainer.isEmpty {
                                DetailItem(label: "Maintainer", value: info.maintainer)
                            }
                        }

                        if !info.website.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Website")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Link(info.website, destination: URL(string: info.website) ?? URL(string: "https://freshports.org")!)
                                    .font(.body)
                            }
                        }

                        // Dependencies
                        if !info.dependencies.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Dependencies (\(info.dependencies.count))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                ForEach(info.dependencies.prefix(10), id: \.self) { dep in
                                    Text(dep)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.primary)
                                }
                                if info.dependencies.count > 10 {
                                    Text("... and \(info.dependencies.count - 10) more")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        // Required By
                        if !info.requiredBy.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Required By (\(info.requiredBy.count))")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                ForEach(info.requiredBy.prefix(10), id: \.self) { req in
                                    Text(req)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.primary)
                                }
                                if info.requiredBy.count > 10 {
                                    Text("... and \(info.requiredBy.count - 10) more")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Could not load package details")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            // Action buttons
            HStack {
                // Show warning if other packages depend on this one (only for non-base packages)
                if !isBasePackage, let info = packageInfo, !info.requiredBy.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("\(info.requiredBy.count) package(s) depend on this")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                Spacer()

                if isBasePackage {
                    // No remove button for base packages
                    Text("Base system package")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Button(action: {
                        Task {
                            let success = await viewModel.removePackage(name: package.name)
                            if success {
                                onDismiss()
                            }
                        }
                    }) {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(viewModel.isLoading)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
        }
        .frame(minWidth: 350)
        .id(package.id)  // Force view recreation when package changes
        .task(id: package.id) {
            isLoadingInfo = true
            packageInfo = nil
            packageInfo = await viewModel.getPackageInfo(name: package.name)
            isLoadingInfo = false
        }
    }
}

// MARK: - Package Detail View (Available)

struct AvailablePackageDetailView: View {
    let package: AvailablePackage
    @ObservedObject var viewModel: PackagesViewModel
    let onDismiss: () -> Void

    @State private var packageInfo: PackageInfo?
    @State private var isLoadingInfo = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(package.name)
                        .font(.title2)
                        .bold()

                    Label(package.version, systemImage: "number")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.green.opacity(0.05))

            Divider()

            if isLoadingInfo {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading package details...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let info = packageInfo {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Description
                        if !info.description.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Description")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(info.description)
                                    .font(.body)
                            }
                        } else if !info.comment.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Description")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(info.comment)
                                    .font(.body)
                            }
                        }

                        Divider()

                        // Details Grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                            if !info.flatSize.isEmpty {
                                DetailItem(label: "Size", value: info.flatSize)
                            }
                            if !info.origin.isEmpty {
                                DetailItem(label: "Origin", value: info.origin)
                            }
                            if !info.license.isEmpty {
                                DetailItem(label: "License", value: info.license)
                            }
                        }

                        if !info.website.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Website")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Link(info.website, destination: URL(string: info.website) ?? URL(string: "https://freshports.org")!)
                                    .font(.body)
                            }
                        }

                        // Dependencies
                        if !info.dependencies.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Will install dependencies (\(info.dependencies.count))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                ForEach(info.dependencies.prefix(10), id: \.self) { dep in
                                    Text(dep)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.primary)
                                }
                                if info.dependencies.count > 10 {
                                    Text("... and \(info.dependencies.count - 10) more")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding()
                }
            } else {
                // Fallback to basic info from AvailablePackage
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !package.description.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Description")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(package.description)
                                    .font(.body)
                            }
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Action buttons
            HStack {
                Spacer()

                Button(action: {
                    Task {
                        let success = await viewModel.installPackage(name: package.name)
                        if success {
                            onDismiss()
                        }
                    }
                }) {
                    Label("Install", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(viewModel.isLoading)
            }
            .padding()
            .background(Color.green.opacity(0.05))
        }
        .frame(minWidth: 350)
        .onAppear {
            Task {
                packageInfo = await viewModel.getAvailablePackageInfo(name: package.name)
                isLoadingInfo = false
            }
        }
    }
}

// MARK: - Detail Item Helper

struct DetailItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.callout)
                .lineLimit(2)
        }
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
    @Published var upgradeComplete = false
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
        upgradeComplete = false
        upgradeOutput = ""
        error = nil

        do {
            try await sshManager.upgradePackagesStreaming { [weak self] output in
                self?.upgradeOutput += output
            }
            upgradeComplete = true
            isUpgrading = false
        } catch {
            upgradeOutput += "\n\nError: \(error.localizedDescription)"
            upgradeComplete = true
            isUpgrading = false
        }
    }

    func upgradeSelectedPackages(names: [String]) async {
        guard !names.isEmpty else { return }

        // Confirm upgrade
        let alert = NSAlert()
        alert.messageText = "Upgrade Selected Packages?"
        alert.informativeText = "This will upgrade \(names.count) package(s) to their latest versions. This may take several minutes."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Upgrade")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        isUpgrading = true
        upgradeComplete = false
        upgradeOutput = ""
        error = nil

        do {
            try await sshManager.upgradeSelectedPackagesStreaming(names: names) { [weak self] output in
                self?.upgradeOutput += output
            }
            upgradeComplete = true
            isUpgrading = false
        } catch {
            upgradeOutput += "\n\nError: \(error.localizedDescription)"
            upgradeComplete = true
            isUpgrading = false
        }
    }

    func dismissUpgradeConsole() async {
        upgradeComplete = false
        upgradeOutput = ""
        // Reload packages to reflect the changes
        await loadPackages()
        updatesAvailable = 0
        upgradablePackages = []
        // Reload upgradable packages to check if any remain
        await loadUpgradablePackages()
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
            // Always check for updates when switching to this tab
            await loadUpgradablePackages()

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
            updatesAvailable = upgradablePackages.count
        } catch {
            self.error = "Failed to load upgradable packages: \(error.localizedDescription)"
            upgradablePackages = []
            updatesAvailable = 0
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

    // MARK: - Package Details and Operations

    func getPackageInfo(name: String) async -> PackageInfo? {
        do {
            return try await sshManager.getPackageInfo(name: name)
        } catch {
            self.error = "Failed to get package info: \(error.localizedDescription)"
            return nil
        }
    }

    func getAvailablePackageInfo(name: String) async -> PackageInfo? {
        do {
            return try await sshManager.getAvailablePackageInfo(name: name)
        } catch {
            self.error = "Failed to get package info: \(error.localizedDescription)"
            return nil
        }
    }

    func removePackage(name: String, force: Bool = false) async -> Bool {
        // First check if the package is vital or locked
        if let info = await getPackageInfo(name: name) {
            if info.isVital {
                let alert = NSAlert()
                alert.messageText = "Cannot Remove Package"
                alert.informativeText = "'\(name)' is a vital system package and cannot be removed."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return false
            }
            if info.isLocked {
                let alert = NSAlert()
                alert.messageText = "Cannot Remove Package"
                alert.informativeText = "'\(name)' is locked and cannot be removed. Use 'pkg unlock \(name)' to unlock it first."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return false
            }
        }

        // Confirm removal
        let alert = NSAlert()
        alert.messageText = "Remove Package?"
        alert.informativeText = "Are you sure you want to remove '\(name)'? This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return false
        }

        isLoading = true
        error = nil

        do {
            let output = try await sshManager.removePackage(name: name, force: force)

            // Check for vital package error in output
            if output.contains("vital") || output.contains("Cannot delete") {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Cannot Remove Package"
                errorAlert.informativeText = "'\(name)' is a vital system package and cannot be removed."
                errorAlert.alertStyle = .warning
                errorAlert.addButton(withTitle: "OK")
                errorAlert.runModal()
                isLoading = false
                return false
            }

            // Check if removal was successful
            if output.contains("Deinstalling") || output.contains("Deleting") {
                let successAlert = NSAlert()
                successAlert.messageText = "Package Removed"
                successAlert.informativeText = "'\(name)' has been successfully removed."
                successAlert.alertStyle = .informational
                successAlert.addButton(withTitle: "OK")
                successAlert.runModal()

                // Reload packages
                await loadPackages()
                isLoading = false
                return true
            } else {
                self.error = "Package removal may have failed: \(output)"
                isLoading = false
                return false
            }
        } catch {
            self.error = "Failed to remove package: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }

    func installPackage(name: String) async -> Bool {
        // Confirm installation
        let alert = NSAlert()
        alert.messageText = "Install Package?"
        alert.informativeText = "Do you want to install '\(name)'?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return false
        }

        isLoading = true
        error = nil

        do {
            let output = try await sshManager.installPackage(name: name)

            // Check if installation was successful
            if output.contains("Installing") || output.contains("already installed") || output.contains("Extracting") {
                let successAlert = NSAlert()
                successAlert.messageText = "Package Installed"
                successAlert.informativeText = "'\(name)' has been successfully installed."
                successAlert.alertStyle = .informational
                successAlert.addButton(withTitle: "OK")
                successAlert.runModal()

                // Reload packages
                await loadPackages()
                isLoading = false
                return true
            } else {
                self.error = "Package installation may have failed: \(output)"
                isLoading = false
                return false
            }
        } catch {
            self.error = "Failed to install package: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }
}
