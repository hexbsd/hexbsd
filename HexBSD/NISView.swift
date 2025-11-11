//
//  NISView.swift
//  HexBSD
//
//  Network Information Service (NIS) management - both client and server
//

import SwiftUI
import AppKit

// MARK: - Data Models

struct NISStatus: Identifiable {
    let id = UUID()
    let isClientEnabled: Bool
    let isServerEnabled: Bool
    let domain: String
    let boundServer: String?
    let serverType: ServerType?  // master, slave, or nil if not a server

    enum ServerType: String {
        case master = "Master"
        case slave = "Slave"
    }
}

struct NISMap: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let nickname: String
    let entries: Int
    let lastModified: String?

    var displayName: String {
        if !nickname.isEmpty && nickname != name {
            return "\(nickname) (\(name))"
        }
        return name
    }
}

struct NISMapEntry: Identifiable, Hashable {
    let id = UUID()
    let key: String
    let value: String
}

struct NISSlaveServer: Identifiable, Hashable {
    let id = UUID()
    let hostname: String
    let status: String  // "active", "inactive", "unknown"

    var statusColor: Color {
        switch status.lowercased() {
        case "active": return .green
        case "inactive": return .red
        default: return .secondary
        }
    }
}

// MARK: - Main View

struct NISContentView: View {
    @StateObject private var viewModel = NISViewModel()
    @State private var selectedView: NISViewType = .client
    @State private var showError = false

    enum NISViewType: String, CaseIterable {
        case client = "Client"
        case server = "Server"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segmented control for view selection
            Picker("View", selection: $selectedView) {
                ForEach(NISViewType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // Content based on selected view
            Group {
                switch selectedView {
                case .client:
                    NISClientView(viewModel: viewModel)
                case .server:
                    NISServerView(viewModel: viewModel)
                }
            }
        }
        .alert("NIS Error", isPresented: $showError) {
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
                await viewModel.loadStatus()
            }
        }
    }
}

// MARK: - Client View

struct NISClientView: View {
    @ObservedObject var viewModel: NISViewModel
    @State private var showSetDomain = false
    @State private var newDomain = ""
    @State private var selectedMap: NISMap?
    @State private var mapEntries: [NISMapEntry] = []
    @State private var isLoadingEntries = false

    var body: some View {
        VStack(spacing: 0) {
            // Status section
            VStack(spacing: 16) {
                HStack {
                    Text("Client Status")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    Circle()
                        .fill(viewModel.status?.isClientEnabled == true ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(viewModel.status?.isClientEnabled == true ? "Enabled" : "Disabled")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Domain info
                if let status = viewModel.status {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("NIS Domain:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(status.domain.isEmpty ? "Not set" : status.domain)
                                .font(.body)
                                .fontWeight(.medium)
                        }

                        if let server = status.boundServer {
                            HStack {
                                Text("Bound Server:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(server)
                                    .font(.body)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }

                // Actions
                HStack(spacing: 12) {
                    Button(action: {
                        showSetDomain = true
                    }) {
                        Label("Set Domain", systemImage: "network")
                    }
                    .buttonStyle(.bordered)

                    if viewModel.status?.isClientEnabled == true {
                        Button(action: {
                            Task {
                                await viewModel.stopClient()
                            }
                        }) {
                            Label("Stop Client", systemImage: "stop.circle")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            Task {
                                await viewModel.restartClient()
                            }
                        }) {
                            Label("Restart", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(action: {
                            Task {
                                await viewModel.startClient()
                            }
                        }) {
                            Label("Start Client", systemImage: "play.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()

            Divider()

            // Maps section
            HStack {
                Text("NIS Maps")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer()

                Button(action: {
                    Task {
                        await viewModel.refreshMaps()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.status?.isClientEnabled != true)
            }
            .padding()

            Divider()

            // Maps list
            if viewModel.isLoadingMaps {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading maps...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.status?.isClientEnabled != true {
                VStack(spacing: 20) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("NIS Client Not Running")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Start the NIS client to browse maps")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.maps.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No NIS Maps Found")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    // Maps list
                    VStack(spacing: 0) {
                        List(viewModel.maps, selection: $selectedMap) { map in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(map.displayName)
                                    .font(.body)
                                HStack {
                                    Text("\(map.entries) entries")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    if let modified = map.lastModified {
                                        Text("• \(modified)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(minWidth: 200)

                    // Map contents
                    VStack(spacing: 0) {
                        if let map = selectedMap {
                            HStack {
                                Text("Contents of \(map.displayName)")
                                    .font(.headline)

                                Spacer()

                                Button(action: {
                                    Task {
                                        await loadMapEntries(map)
                                    }
                                }) {
                                    Label("Load", systemImage: "arrow.down.circle")
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding()

                            Divider()

                            if isLoadingEntries {
                                VStack(spacing: 20) {
                                    ProgressView()
                                    Text("Loading map entries...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else if mapEntries.isEmpty {
                                VStack(spacing: 20) {
                                    Image(systemName: "doc")
                                        .font(.system(size: 48))
                                        .foregroundColor(.secondary)
                                    Text("Click Load to view map contents")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                Table(mapEntries) {
                                    TableColumn("Key", value: \.key)
                                        .width(min: 100, ideal: 200)
                                    TableColumn("Value", value: \.value)
                                }
                            }
                        } else {
                            VStack(spacing: 20) {
                                Image(systemName: "sidebar.left")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("Select a map to view its contents")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showSetDomain) {
            SetDomainSheet(
                currentDomain: viewModel.status?.domain ?? "",
                newDomain: $newDomain,
                onSet: {
                    Task {
                        await viewModel.setDomain(newDomain)
                        showSetDomain = false
                    }
                },
                onCancel: {
                    showSetDomain = false
                }
            )
        }
        .onChange(of: selectedMap) { oldValue, newValue in
            mapEntries = []
        }
    }

    private func loadMapEntries(_ map: NISMap) async {
        isLoadingEntries = true
        mapEntries = await viewModel.getMapEntries(mapName: map.name)
        isLoadingEntries = false
    }
}

// MARK: - Server View

struct NISServerView: View {
    @ObservedObject var viewModel: NISViewModel
    @State private var showInitServer = false
    @State private var serverType: ServerType = .master
    @State private var masterServer = ""

    enum ServerType: String, CaseIterable {
        case master = "Master"
        case slave = "Slave"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Status section
            VStack(spacing: 16) {
                HStack {
                    Text("Server Status")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    Circle()
                        .fill(viewModel.status?.isServerEnabled == true ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(viewModel.status?.isServerEnabled == true ? "Running" : "Stopped")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Server info
                if let status = viewModel.status, status.isServerEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Domain:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(status.domain.isEmpty ? "Not set" : status.domain)
                                .font(.body)
                                .fontWeight(.medium)
                        }

                        if let serverType = status.serverType {
                            HStack {
                                Text("Type:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(serverType.rawValue)
                                    .font(.body)
                                    .fontWeight(.medium)
                            }
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }

                // Actions
                HStack(spacing: 12) {
                    if viewModel.status?.isServerEnabled != true {
                        Button(action: {
                            showInitServer = true
                        }) {
                            Label("Initialize Server", systemImage: "server.rack")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if viewModel.status?.isServerEnabled == true {
                        Button(action: {
                            Task {
                                await viewModel.rebuildMaps()
                            }
                        }) {
                            Label("Rebuild Maps", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)

                        if viewModel.status?.serverType == .master {
                            Button(action: {
                                Task {
                                    await viewModel.pushMaps()
                                }
                            }) {
                                Label("Push to Slaves", systemImage: "arrow.right.circle")
                            }
                            .buttonStyle(.bordered)
                        }

                        Button(action: {
                            Task {
                                await viewModel.stopServer()
                            }
                        }) {
                            Label("Stop Server", systemImage: "stop.circle")
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            Task {
                                await viewModel.restartServer()
                            }
                        }) {
                            Label("Restart", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()

            Divider()

            // Maps or Slaves section based on server status
            if viewModel.status?.isServerEnabled == true {
                if viewModel.status?.serverType == .master {
                    // Show slave servers for master
                    VStack(spacing: 0) {
                        HStack {
                            Text("Slave Servers")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            Spacer()

                            Button(action: {
                                Task {
                                    await viewModel.refreshSlaves()
                                }
                            }) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()

                        Divider()

                        if viewModel.isLoadingSlaves {
                            VStack(spacing: 20) {
                                ProgressView()
                                Text("Loading slave servers...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if viewModel.slaveServers.isEmpty {
                            VStack(spacing: 20) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("No Slave Servers")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                                Text("Configure slave servers in /var/yp/ypservers")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List(viewModel.slaveServers) { slave in
                                HStack {
                                    Image(systemName: "server.rack")
                                        .foregroundColor(.blue)

                                    Text(slave.hostname)
                                        .font(.body)

                                    Spacer()

                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(slave.statusColor)
                                            .frame(width: 8, height: 8)
                                        Text(slave.status)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                } else {
                    // Show server maps
                    VStack(spacing: 0) {
                        HStack {
                            Text("Server Maps")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            Spacer()

                            Button(action: {
                                Task {
                                    await viewModel.refreshServerMaps()
                                }
                            }) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()

                        Divider()

                        if viewModel.isLoadingServerMaps {
                            VStack(spacing: 20) {
                                ProgressView()
                                Text("Loading server maps...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if viewModel.serverMaps.isEmpty {
                            VStack(spacing: 20) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("No Maps")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List(viewModel.serverMaps) { map in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(map.displayName)
                                        .font(.body)
                                    HStack {
                                        Text("\(map.entries) entries")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        if let modified = map.lastModified {
                                            Text("• \(modified)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("NIS Server Not Running")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Initialize the server to begin serving NIS maps")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showInitServer) {
            InitServerSheet(
                domain: viewModel.status?.domain ?? "",
                serverType: $serverType,
                masterServer: $masterServer,
                onInit: {
                    Task {
                        await viewModel.initializeServer(type: serverType, masterServer: masterServer.isEmpty ? nil : masterServer)
                        showInitServer = false
                    }
                },
                onCancel: {
                    showInitServer = false
                }
            )
        }
    }
}

// MARK: - Set Domain Sheet

struct SetDomainSheet: View {
    let currentDomain: String
    @Binding var newDomain: String
    let onSet: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Set NIS Domain")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                if !currentDomain.isEmpty {
                    Text("Current Domain")
                        .font(.caption)
                    Text(currentDomain)
                        .font(.body)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)
                }

                Text("New Domain")
                    .font(.caption)
                TextField("e.g., example.com", text: $newDomain)
                    .textFieldStyle(.roundedBorder)

                Text("This will set the NIS domain name for the system")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Set Domain") {
                    onSet()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newDomain.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            newDomain = currentDomain
        }
    }
}

// MARK: - Initialize Server Sheet

struct InitServerSheet: View {
    let domain: String
    @Binding var serverType: NISServerView.ServerType
    @Binding var masterServer: String
    let onInit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Initialize NIS Server")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Text("Domain: \(domain.isEmpty ? "Not set" : domain)")
                    .font(.body)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)

                if domain.isEmpty {
                    Text("Set the NIS domain in the Client tab first")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Text("Server Type")
                    .font(.caption)
                Picker("Type", selection: $serverType) {
                    ForEach(NISServerView.ServerType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                if serverType == .slave {
                    Text("Master Server")
                        .font(.caption)
                    TextField("e.g., master.example.com", text: $masterServer)
                        .textFieldStyle(.roundedBorder)

                    Text("Hostname or IP of the master NIS server")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Text(serverType == .master ? "This will initialize this system as a master NIS server" : "This will initialize this system as a slave NIS server")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Initialize") {
                    onInit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(domain.isEmpty || (serverType == .slave && masterServer.isEmpty))
            }
        }
        .padding()
        .frame(width: 450)
    }
}

// MARK: - View Model

@MainActor
class NISViewModel: ObservableObject {
    @Published var status: NISStatus?
    @Published var maps: [NISMap] = []
    @Published var serverMaps: [NISMap] = []
    @Published var slaveServers: [NISSlaveServer] = []
    @Published var isLoadingMaps = false
    @Published var isLoadingServerMaps = false
    @Published var isLoadingSlaves = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadStatus() async {
        do {
            status = try await sshManager.getNISStatus()

            // Auto-load maps if client is enabled
            if status?.isClientEnabled == true {
                await refreshMaps()
            }

            // Auto-load server data if server is enabled
            if status?.isServerEnabled == true {
                if status?.serverType == .master {
                    await refreshSlaves()
                } else {
                    await refreshServerMaps()
                }
            }
        } catch {
            self.error = "Failed to load NIS status: \(error.localizedDescription)"
        }
    }

    func setDomain(_ domain: String) async {
        error = nil

        do {
            try await sshManager.setNISDomain(domain)
            await loadStatus()
        } catch {
            self.error = "Failed to set domain: \(error.localizedDescription)"
        }
    }

    func startClient() async {
        error = nil

        do {
            try await sshManager.startNISClient()
            await loadStatus()
        } catch {
            self.error = "Failed to start client: \(error.localizedDescription)"
        }
    }

    func stopClient() async {
        error = nil

        do {
            try await sshManager.stopNISClient()
            await loadStatus()
        } catch {
            self.error = "Failed to stop client: \(error.localizedDescription)"
        }
    }

    func restartClient() async {
        error = nil

        do {
            try await sshManager.restartNISClient()
            await loadStatus()
        } catch {
            self.error = "Failed to restart client: \(error.localizedDescription)"
        }
    }

    func refreshMaps() async {
        isLoadingMaps = true
        error = nil

        do {
            maps = try await sshManager.listNISMaps()
        } catch {
            self.error = "Failed to load maps: \(error.localizedDescription)"
            maps = []
        }

        isLoadingMaps = false
    }

    func getMapEntries(mapName: String) async -> [NISMapEntry] {
        do {
            return try await sshManager.getNISMapEntries(mapName: mapName)
        } catch {
            self.error = "Failed to load map entries: \(error.localizedDescription)"
            return []
        }
    }

    func initializeServer(type: NISServerView.ServerType, masterServer: String?) async {
        error = nil

        do {
            try await sshManager.initializeNISServer(isMaster: type == .master, masterServer: masterServer)
            await loadStatus()
        } catch {
            self.error = "Failed to initialize server: \(error.localizedDescription)"
        }
    }

    func startServer() async {
        error = nil

        do {
            try await sshManager.startNISServer()
            await loadStatus()
        } catch {
            self.error = "Failed to start server: \(error.localizedDescription)"
        }
    }

    func stopServer() async {
        error = nil

        do {
            try await sshManager.stopNISServer()
            await loadStatus()
        } catch {
            self.error = "Failed to stop server: \(error.localizedDescription)"
        }
    }

    func restartServer() async {
        error = nil

        do {
            try await sshManager.restartNISServer()
            await loadStatus()
        } catch {
            self.error = "Failed to restart server: \(error.localizedDescription)"
        }
    }

    func rebuildMaps() async {
        error = nil

        do {
            try await sshManager.rebuildNISMaps()
            await refreshServerMaps()
        } catch {
            self.error = "Failed to rebuild maps: \(error.localizedDescription)"
        }
    }

    func pushMaps() async {
        error = nil

        do {
            try await sshManager.pushNISMaps()
        } catch {
            self.error = "Failed to push maps: \(error.localizedDescription)"
        }
    }

    func refreshServerMaps() async {
        isLoadingServerMaps = true
        error = nil

        do {
            serverMaps = try await sshManager.listNISServerMaps()
        } catch {
            self.error = "Failed to load server maps: \(error.localizedDescription)"
            serverMaps = []
        }

        isLoadingServerMaps = false
    }

    func refreshSlaves() async {
        isLoadingSlaves = true
        error = nil

        do {
            slaveServers = try await sshManager.listNISSlaveServers()
        } catch {
            self.error = "Failed to load slave servers: \(error.localizedDescription)"
            slaveServers = []
        }

        isLoadingSlaves = false
    }
}
