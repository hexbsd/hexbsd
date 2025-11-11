//
//  PortsView.swift
//  HexBSD
//
//  FreeBSD Ports tree browser and search
//

import SwiftUI

// MARK: - Port Models

struct Port: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let category: String
    let version: String
    let comment: String
    let maintainer: String
    let path: String

    var fullName: String {
        "\(category)/\(name)"
    }
}

struct PortsInfo: Equatable {
    let isInstalled: Bool
    let portsPath: String
    let indexPath: String
}

// MARK: - Ports Content View

struct PortsContentView: View {
    @StateObject private var viewModel = PortsViewModel()
    @State private var showError = false
    @State private var searchText = ""
    @State private var selectedCategory = "all"
    @State private var selectedPort: Port?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                if viewModel.isInstalled {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Ports tree installed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if !viewModel.portsPath.isEmpty {
                            Text("(\(viewModel.portsPath))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text("Ports tree not found")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if viewModel.isInstalled {
                    Button(action: {
                        Task {
                            await viewModel.refresh()
                        }
                    }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding()

            Divider()

            // Search and filters
            if viewModel.isInstalled && viewModel.hasIndex {
                HStack {
                    // Search field
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search ports (name, description)...", text: $searchText)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                Task {
                                    await viewModel.searchPorts(query: searchText, category: selectedCategory)
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
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)

                    // Category picker
                    Picker("Category", selection: $selectedCategory) {
                        Text("All Categories").tag("all")
                        ForEach(viewModel.categories, id: \.self) { category in
                            Text(category).tag(category)
                        }
                    }
                    .frame(width: 200)
                    .onChange(of: selectedCategory) { oldValue, newValue in
                        if !searchText.isEmpty {
                            Task {
                                await viewModel.searchPorts(query: searchText, category: newValue)
                            }
                        }
                    }

                    Button("Search") {
                        Task {
                            await viewModel.searchPorts(query: searchText, category: selectedCategory)
                        }
                    }
                    .disabled(searchText.isEmpty)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()
            }

            // Content area
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text(viewModel.loadingMessage)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.isInstalled {
                ScrollView {
                    VStack(spacing: 20) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 72))
                            .foregroundColor(.secondary)
                        Text("Ports Tree Not Found")
                            .font(.title)
                            .foregroundColor(.secondary)
                        Text("Follow these steps to install and configure the FreeBSD ports tree")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 10)

                        VStack(alignment: .leading, spacing: 16) {
                            // Step 1
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("1.")
                                        .font(.headline)
                                        .foregroundColor(.blue)
                                        .frame(width: 24)
                                    Text("Install Git and clone the ports tree")
                                        .font(.headline)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("pkg install git")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.blue)
                                    Text("git clone https://git.FreeBSD.org/ports.git /usr/ports --depth=1")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.blue)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(6)
                                .textSelection(.enabled)
                            }

                            // Step 2
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("2.")
                                        .font(.headline)
                                        .foregroundColor(.blue)
                                        .frame(width: 24)
                                    Text("Generate the INDEX file")
                                        .font(.headline)
                                }

                                Text("This creates a searchable database of all ports (takes a few minutes)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("cd /usr/ports")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.blue)
                                    Text("make index")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.blue)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(6)
                                .textSelection(.enabled)
                            }

                            // Step 3
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("3.")
                                        .font(.headline)
                                        .foregroundColor(.blue)
                                        .frame(width: 24)
                                    Text("Refresh this page")
                                        .font(.headline)
                                }

                                Text("Click the Refresh button above once the INDEX is generated")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                        .frame(maxWidth: 600)
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.searchResults.isEmpty && !searchText.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No ports found")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Try a different search term or category")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isInstalled && !viewModel.hasIndex {
                // Ports installed but no INDEX file
                VStack(spacing: 20) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 72))
                        .foregroundColor(.orange)
                    Text("INDEX File Missing")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text("The ports tree is installed but the INDEX file needs to be generated")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("cd /usr/ports")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.blue)
                        Text("make index")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.blue)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .textSelection(.enabled)

                    Text("Note: This may take several minutes to complete")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.searchResults.isEmpty {
                HSplitView {
                    // Results list
                    VStack(spacing: 0) {
                        HStack {
                            Text("\(viewModel.searchResults.count) port\(viewModel.searchResults.count == 1 ? "" : "s") found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                        Divider()

                        List(viewModel.searchResults, selection: $selectedPort) { port in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "shippingbox")
                                        .foregroundColor(.blue)
                                        .font(.caption)
                                    Text(port.name)
                                        .font(.headline)
                                }
                                Text(port.category)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(port.comment)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                            .tag(port)
                        }
                    }
                    .frame(minWidth: 300, idealWidth: 400)

                    // Detail view
                    if let port = selectedPort {
                        PortDetailView(port: port)
                    } else {
                        VStack(spacing: 20) {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text("Select a port to view details")
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("Search FreeBSD Ports")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text("Enter a search term to find ports")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !viewModel.totalPorts.isEmpty {
                        Text(viewModel.totalPorts)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Ports Error", isPresented: $showError) {
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
                await viewModel.loadPorts()
            }
        }
    }
}

// MARK: - Port Detail View

struct PortDetailView: View {
    let port: Port
    @StateObject private var viewModel = PortDetailViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text(port.name)
                                .font(.title)
                            Text(port.fullName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if !port.version.isEmpty {
                        HStack {
                            Text("Version:")
                                .fontWeight(.semibold)
                            Text(port.version)
                                .textSelection(.enabled)
                        }
                        .font(.subheadline)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)

                // Description
                VStack(alignment: .leading, spacing: 8) {
                    Text("Description")
                        .font(.headline)
                    Text(port.comment)
                        .textSelection(.enabled)
                }

                // Maintainer
                if !port.maintainer.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Maintainer")
                            .font(.headline)
                        Text(port.maintainer)
                            .textSelection(.enabled)
                            .foregroundColor(.blue)
                    }
                }

                // Port path
                VStack(alignment: .leading, spacing: 8) {
                    Text("Port Location")
                        .font(.headline)
                    Text(port.path)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                // Additional details (loaded asynchronously)
                if viewModel.isLoading {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading details...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let details = viewModel.details {
                    if !details.www.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Website")
                                .font(.headline)
                            Text(details.www)
                                .foregroundColor(.blue)
                                .textSelection(.enabled)
                        }
                    }

                    if !details.buildDepends.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Build Dependencies")
                                .font(.headline)
                            ForEach(details.buildDepends, id: \.self) { dep in
                                Text("• \(dep)")
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    if !details.runDepends.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Runtime Dependencies")
                                .font(.headline)
                            ForEach(details.runDepends, id: \.self) { dep in
                                Text("• \(dep)")
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    if !details.options.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Port Options")
                                .font(.headline)
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(details.options) { option in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: option.isEnabled ? "checkmark.square.fill" : "square")
                                            .foregroundColor(option.isEnabled ? .green : .secondary)
                                            .font(.caption)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(option.name)
                                                .font(.system(.caption, design: .monospaced))
                                                .fontWeight(.semibold)
                                            if !option.description.isEmpty {
                                                Text(option.description)
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }

                    if !details.plistFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Package Files (\(details.plistFiles.count))")
                                .font(.headline)
                            DisclosureGroup("Show files") {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(details.plistFiles, id: \.self) { file in
                                            Text(file)
                                                .font(.system(.caption, design: .monospaced))
                                                .textSelection(.enabled)
                                        }
                                    }
                                    .padding(8)
                                }
                                .frame(maxHeight: 300)
                            }
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                }

                Spacer()
            }
            .padding()
        }
        .onAppear {
            Task {
                await viewModel.loadDetails(for: port)
            }
        }
    }
}

// MARK: - Port Details Model

struct PortOption: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let description: String
    let isEnabled: Bool
}

struct PortDetails {
    let www: String
    let buildDepends: [String]
    let runDepends: [String]
    let options: [PortOption]
    let plistFiles: [String]
}

// MARK: - Port Detail View Model

@MainActor
class PortDetailViewModel: ObservableObject {
    @Published var details: PortDetails?
    @Published var isLoading = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadDetails(for port: Port) async {
        print("DEBUG: Loading details for port: \(port.name) at \(port.path)")
        isLoading = true
        error = nil

        do {
            details = try await sshManager.getPortDetails(path: port.path)
            print("DEBUG: Successfully loaded details")
        } catch {
            print("DEBUG: Failed to load details: \(error)")
            self.error = "Failed to load port details: \(error.localizedDescription)"
        }

        isLoading = false
    }
}

// MARK: - Ports View Model

@MainActor
class PortsViewModel: ObservableObject {
    @Published var isInstalled = false
    @Published var portsPath = ""
    @Published var hasIndex = false
    @Published var isLoading = false
    @Published var loadingMessage = "Loading..."
    @Published var error: String?
    @Published var searchResults: [Port] = []
    @Published var categories: [String] = []
    @Published var totalPorts = ""

    private let sshManager = SSHConnectionManager.shared

    func loadPorts() async {
        isLoading = true
        loadingMessage = "Checking ports tree..."
        error = nil

        do {
            let info = try await sshManager.checkPorts()
            isInstalled = info.isInstalled
            portsPath = info.portsPath
            hasIndex = !info.indexPath.isEmpty

            if isInstalled && hasIndex {
                loadingMessage = "Loading categories..."
                categories = try await sshManager.listPortsCategories()

                // Get total port count
                let count = try await sshManager.getPortsCount()
                totalPorts = "\(count) ports available"
            }
        } catch {
            self.error = "Failed to load ports: \(error.localizedDescription)"
            isInstalled = false
            hasIndex = false
        }

        isLoading = false
    }

    func searchPorts(query: String, category: String) async {
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        isLoading = true
        loadingMessage = "Searching ports..."
        error = nil

        do {
            searchResults = try await sshManager.searchPorts(query: query, category: category)
        } catch {
            self.error = "Failed to search ports: \(error.localizedDescription)"
            searchResults = []
        }

        isLoading = false
    }

    func refresh() async {
        searchResults = []
        await loadPorts()
    }
}
