//
//  NetworkView.swift
//  HexBSD
//
//  Network interface management for ethernet, wireless, and bridges
//

import SwiftUI
import AppKit

// MARK: - Data Models

enum InterfaceType: String, CaseIterable {
    case ethernet = "Ethernet"
    case wireless = "Wireless"
    case bridge = "Bridge"
    case tap = "TAP"
    case epair = "Epair"
    case loopback = "Loopback"
    case vlan = "VLAN"
    case lagg = "LAGG"
    case other = "Other"

    var icon: String {
        switch self {
        case .ethernet: return "cable.connector"
        case .wireless: return "wifi"
        case .bridge: return "point.3.connected.trianglepath.dotted"
        case .tap: return "arrow.up.arrow.down.circle"
        case .epair: return "arrow.left.arrow.right.circle"
        case .loopback: return "arrow.triangle.2.circlepath"
        case .vlan: return "tag"
        case .lagg: return "link"
        case .other: return "network"
        }
    }

    var color: Color {
        switch self {
        case .ethernet: return .blue
        case .wireless: return .green
        case .bridge: return .purple
        case .tap: return .pink
        case .epair: return .indigo
        case .loopback: return .gray
        case .vlan: return .orange
        case .lagg: return .cyan
        case .other: return .secondary
        }
    }

    /// Returns true if this interface type can be destroyed with ifconfig destroy
    var isDestroyable: Bool {
        switch self {
        case .bridge, .tap, .epair, .vlan, .lagg:
            return true
        default:
            return false
        }
    }
}

enum InterfaceStatus: String {
    case up = "Up"
    case down = "Down"
    case noCarrier = "No Carrier"
    case unknown = "Unknown"

    var color: Color {
        switch self {
        case .up: return .green
        case .down: return .red
        case .noCarrier: return .orange
        case .unknown: return .secondary
        }
    }

    var icon: String {
        switch self {
        case .up: return "circle.fill"
        case .down: return "circle"
        case .noCarrier: return "exclamationmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct NetworkInterfaceInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let type: InterfaceType
    var status: InterfaceStatus
    let macAddress: String
    var ipv4Address: String
    var ipv4Netmask: String
    var ipv6Address: String
    var ipv6Prefix: String
    let mtu: Int
    var dhcp: Bool
    let mediaType: String      // e.g., "Ethernet autoselect (1000baseT <full-duplex>)"
    let mediaOptions: String
    var rxBytes: UInt64
    var txBytes: UInt64
    var rxPackets: UInt64
    var txPackets: UInt64
    var rxErrors: UInt64
    var txErrors: UInt64
    let flags: [String]        // UP, BROADCAST, RUNNING, SIMPLEX, MULTICAST, etc.
    let description: String    // Optional interface description

    var displayName: String {
        if !description.isEmpty {
            return "\(name) (\(description))"
        }
        return name
    }

    var hasIPv4: Bool {
        !ipv4Address.isEmpty && ipv4Address != "N/A"
    }

    var hasIPv6: Bool {
        !ipv6Address.isEmpty && ipv6Address != "N/A"
    }

    var rxBytesFormatted: String {
        formatBytes(rxBytes)
    }

    var txBytesFormatted: String {
        formatBytes(txBytes)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024

        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        } else if mb >= 1 {
            return String(format: "%.2f MB", mb)
        } else if kb >= 1 {
            return String(format: "%.2f KB", kb)
        } else {
            return "\(bytes) B"
        }
    }
}

// MARK: - Wireless Models

struct WirelessNetwork: Identifiable, Hashable {
    let id = UUID()
    let ssid: String
    let bssid: String
    let channel: Int
    let rssi: Int           // Signal strength in dBm
    let noiseFloor: Int     // Noise in dBm
    let rate: String        // e.g., "54M"
    let security: String    // WPA2, WPA3, OPEN, etc.
    let isConnected: Bool

    var signalQuality: Int {
        // Convert RSSI to percentage (typical range -30 to -90 dBm)
        let minRSSI = -90
        let maxRSSI = -30
        let clamped = max(minRSSI, min(maxRSSI, rssi))
        return Int(Double(clamped - minRSSI) / Double(maxRSSI - minRSSI) * 100)
    }

    var signalIcon: String {
        let quality = signalQuality
        if quality >= 75 {
            return "wifi"
        } else if quality >= 50 {
            return "wifi"
        } else if quality >= 25 {
            return "wifi"
        } else {
            return "wifi.exclamationmark"
        }
    }

    var signalColor: Color {
        let quality = signalQuality
        if quality >= 75 {
            return .green
        } else if quality >= 50 {
            return .yellow
        } else if quality >= 25 {
            return .orange
        } else {
            return .red
        }
    }
}

struct WirelessStatus {
    let interfaceName: String
    let ssid: String
    let bssid: String
    let channel: Int
    let rssi: Int
    let rate: String
    let authMode: String
}

// MARK: - Bridge Models

struct BridgeInterface: Identifiable, Hashable {
    let id = UUID()
    let name: String
    var members: [String]       // Member interfaces
    var ipv4Address: String
    var ipv4Netmask: String
    var status: InterfaceStatus
    let stp: Bool               // Spanning Tree Protocol enabled

    var memberCount: Int {
        members.count
    }
}

// MARK: - VM Switch Models

/// Represents a vm-bhyve virtual switch
struct VMSwitch: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let type: String           // standard, vale, etc.
    let iface: String          // bridge interface (e.g., vm-public)
    let address: String        // IP address if configured
    let isPrivate: Bool
    let mtu: String
    let vlan: String
    let ports: [String]        // Physical interfaces attached

    var hasInterface: Bool {
        !iface.isEmpty && iface != "-"
    }

    var hasPorts: Bool {
        !ports.isEmpty
    }
}

// MARK: - Network Tab Enum

enum NetworkTab: String, CaseIterable {
    case interfaces = "Interfaces"
    case wireless = "Wireless"
    case bridges = "Bridges"
    case switches = "Switches"
    case routing = "Routing"

    var icon: String {
        switch self {
        case .interfaces: return "network"
        case .wireless: return "wifi"
        case .bridges: return "point.3.connected.trianglepath.dotted"
        case .switches: return "arrow.left.arrow.right.square"
        case .routing: return "arrow.triangle.branch"
        }
    }
}

// MARK: - Filter Options

enum InterfaceTypeFilter: String, CaseIterable {
    case all = "All"
    case ethernet = "Ethernet"
    case wireless = "Wireless"
    case vlan = "VLAN"
    case other = "Other"

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .ethernet: return "cable.connector"
        case .wireless: return "wifi"
        case .vlan: return "tag"
        case .other: return "network"
        }
    }
}

enum InterfaceStatusFilter: String, CaseIterable {
    case all = "All"
    case up = "Up"
    case down = "Down"

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .up: return "checkmark.circle"
        case .down: return "xmark.circle"
        }
    }
}

// MARK: - Routing Models

struct RouteEntry: Identifiable, Hashable {
    let id = UUID()
    let destination: String
    let gateway: String
    let flags: String
    let netif: String
    let expire: String

    var isDefault: Bool {
        destination == "default"
    }

    var flagDescriptions: [String] {
        var descriptions: [String] = []
        if flags.contains("U") { descriptions.append("Up") }
        if flags.contains("G") { descriptions.append("Gateway") }
        if flags.contains("H") { descriptions.append("Host") }
        if flags.contains("S") { descriptions.append("Static") }
        if flags.contains("C") { descriptions.append("Cloning") }
        if flags.contains("L") { descriptions.append("Link") }
        if flags.contains("B") { descriptions.append("Broadcast") }
        return descriptions
    }
}

// MARK: - Main Network Content View

struct NetworkContentView: View {
    @State private var selectedTab: NetworkTab = .interfaces

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(NetworkTab.allCases, id: \.self) { tab in
                    Button(action: {
                        selectedTab = tab
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                            Text(tab.rawValue)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
                        .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Tab content
            switch selectedTab {
            case .interfaces:
                InterfacesTabView()
            case .wireless:
                WirelessTabView()
            case .bridges:
                BridgesTabView()
            case .switches:
                SwitchesTabView()
            case .routing:
                RoutingTabView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToNetworkBridges)) { _ in
            // Switch to bridges tab when requested from VMs or Jails
            selectedTab = .bridges
        }
    }
}

// MARK: - Interfaces Tab View

struct InterfacesTabView: View {
    @StateObject private var viewModel = InterfacesViewModel()
    @State private var typeFilter: InterfaceTypeFilter = .all
    @State private var statusFilter: InterfaceStatusFilter = .all
    @State private var searchText = ""
    @State private var selectedInterface: NetworkInterfaceInfo?
    @State private var showConfigureSheet = false
    @State private var showError = false

    var filteredInterfaces: [NetworkInterfaceInfo] {
        var interfaces = viewModel.interfaces

        // Exclude bridges - they have their own Bridges tab
        // Also exclude vm-* interfaces as they are managed through the Switches tab
        interfaces = interfaces.filter { $0.type != .bridge }

        // Apply type filter
        switch typeFilter {
        case .all:
            break
        case .ethernet:
            interfaces = interfaces.filter { $0.type == .ethernet }
        case .wireless:
            interfaces = interfaces.filter { $0.type == .wireless }
        case .vlan:
            interfaces = interfaces.filter { $0.type == .vlan }
        case .other:
            interfaces = interfaces.filter { $0.type == .other || $0.type == .loopback || $0.type == .lagg }
        }

        // Apply status filter
        switch statusFilter {
        case .all:
            break
        case .up:
            interfaces = interfaces.filter { $0.status == .up }
        case .down:
            interfaces = interfaces.filter { $0.status == .down || $0.status == .noCarrier }
        }

        // Apply search
        if !searchText.isEmpty {
            interfaces = interfaces.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.ipv4Address.localizedCaseInsensitiveContains(searchText) ||
                $0.macAddress.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText)
            }
        }

        return interfaces
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Network Interfaces")
                        .font(.headline)
                    Text("\(filteredInterfaces.count) of \(viewModel.interfaces.count) interface\(viewModel.interfaces.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Type filter
                Picker("Type", selection: $typeFilter) {
                    ForEach(InterfaceTypeFilter.allCases, id: \.self) { filter in
                        Label(filter.rawValue, systemImage: filter.icon)
                            .tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)

                // Status filter
                Picker("Status", selection: $statusFilter) {
                    ForEach(InterfaceStatusFilter.allCases, id: \.self) { filter in
                        Label(filter.rawValue, systemImage: filter.icon)
                            .tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 100)

                // Search field
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)

                Button(action: {
                    Task {
                        await viewModel.refresh()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // Content
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading network interfaces...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.interfaces.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "network.slash")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Network Interfaces Found")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Unable to retrieve network interface information from the server")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredInterfaces.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Matching Interfaces")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Try adjusting your filter or search terms")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    // Interface list
                    List(filteredInterfaces, selection: $selectedInterface) { iface in
                        InterfaceRowView(interface: iface)
                            .tag(iface)
                    }
                    .frame(minWidth: 300, maxWidth: 400)

                    // Detail view
                    Group {
                        if let iface = selectedInterface {
                            InterfaceDetailView(
                                interface: iface,
                                viewModel: viewModel,
                                onConfigure: {
                                    showConfigureSheet = true
                                },
                                onDestroy: {
                                    selectedInterface = nil
                                }
                            )
                        } else {
                            VStack(spacing: 20) {
                                Image(systemName: "network")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("Select an interface to view details")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 400, maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $showConfigureSheet) {
            if let iface = selectedInterface {
                ConfigureInterfaceSheet(interface: iface, viewModel: viewModel)
            }
        }
        .alert("Error", isPresented: $showError) {
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
                await viewModel.loadInterfaces()
            }
        }
    }
}

// MARK: - Interface Row View

struct InterfaceRowView: View {
    let interface: NetworkInterfaceInfo

    var body: some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: interface.type.icon)
                .font(.system(size: 24))
                .foregroundColor(interface.type.color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(interface.name)
                        .font(.headline)

                    // Status indicator
                    HStack(spacing: 4) {
                        Image(systemName: interface.status.icon)
                            .font(.system(size: 8))
                        Text(interface.status.rawValue)
                            .font(.caption2)
                    }
                    .foregroundColor(interface.status.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(interface.status.color.opacity(0.15))
                    .cornerRadius(4)
                }

                if interface.hasIPv4 {
                    Text(interface.ipv4Address)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if interface.status == .up {
                    Text("No IP address")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !interface.description.isEmpty {
                    Text(interface.description)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Traffic indicators
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 8))
                        .foregroundColor(.green)
                    Text(interface.rxBytesFormatted)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8))
                        .foregroundColor(.blue)
                    Text(interface.txBytesFormatted)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Interface Detail View

struct InterfaceDetailView: View {
    let interface: NetworkInterfaceInfo
    @ObservedObject var viewModel: InterfacesViewModel
    let onConfigure: () -> Void
    let onDestroy: (() -> Void)?

    @State private var showDestroyConfirmation = false

    init(interface: NetworkInterfaceInfo, viewModel: InterfacesViewModel, onConfigure: @escaping () -> Void, onDestroy: (() -> Void)? = nil) {
        self.interface = interface
        self.viewModel = viewModel
        self.onConfigure = onConfigure
        self.onDestroy = onDestroy
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    Image(systemName: interface.type.icon)
                        .font(.system(size: 36))
                        .foregroundColor(interface.type.color)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(interface.name)
                            .font(.title)
                        Text(interface.type.rawValue)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Status badge
                    HStack(spacing: 6) {
                        Image(systemName: interface.status.icon)
                        Text(interface.status.rawValue)
                    }
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(interface.status.color.opacity(0.2))
                    .foregroundColor(interface.status.color)
                    .cornerRadius(8)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)

                // Action buttons
                HStack(spacing: 12) {
                    if interface.status == .up {
                        Button(action: {
                            Task {
                                await viewModel.setInterfaceDown(interface.name)
                            }
                        }) {
                            Label("Bring Down", systemImage: "power")
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    } else {
                        Button(action: {
                            Task {
                                await viewModel.setInterfaceUp(interface.name)
                            }
                        }) {
                            Label("Bring Up", systemImage: "power")
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                    }

                    Button(action: onConfigure) {
                        Label("Configure", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)

                    if interface.dhcp {
                        Button(action: {
                            Task {
                                await viewModel.renewDHCP(interface.name)
                            }
                        }) {
                            Label("Renew DHCP", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }

                    if interface.type.isDestroyable {
                        Button(action: {
                            showDestroyConfirmation = true
                        }) {
                            Label("Destroy", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }

                    Spacer()
                }

                // Address Information
                GroupBox("Addresses") {
                    VStack(alignment: .leading, spacing: 12) {
                        NetworkDetailRow(label: "MAC Address", value: interface.macAddress)

                        if interface.hasIPv4 {
                            NetworkDetailRow(label: "IPv4 Address", value: interface.ipv4Address)
                            NetworkDetailRow(label: "Netmask", value: interface.ipv4Netmask)
                        }

                        if interface.hasIPv6 {
                            NetworkDetailRow(label: "IPv6 Address", value: interface.ipv6Address)
                            NetworkDetailRow(label: "Prefix Length", value: interface.ipv6Prefix)
                        }

                        NetworkDetailRow(label: "DHCP", value: interface.dhcp ? "Enabled" : "Static")
                    }
                    .padding(.vertical, 8)
                }

                // Media Information
                GroupBox("Media") {
                    VStack(alignment: .leading, spacing: 12) {
                        NetworkDetailRow(label: "Media Type", value: interface.mediaType.isEmpty ? "N/A" : interface.mediaType)
                        if !interface.mediaOptions.isEmpty {
                            NetworkDetailRow(label: "Media Options", value: interface.mediaOptions)
                        }
                        NetworkDetailRow(label: "MTU", value: "\(interface.mtu)")
                    }
                    .padding(.vertical, 8)
                }

                // Statistics
                GroupBox("Statistics") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Received")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                NetworkDetailRow(label: "Bytes", value: interface.rxBytesFormatted)
                                NetworkDetailRow(label: "Packets", value: "\(interface.rxPackets)")
                                NetworkDetailRow(label: "Errors", value: "\(interface.rxErrors)")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Transmitted")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                NetworkDetailRow(label: "Bytes", value: interface.txBytesFormatted)
                                NetworkDetailRow(label: "Packets", value: "\(interface.txPackets)")
                                NetworkDetailRow(label: "Errors", value: "\(interface.txErrors)")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 8)
                }

                // Flags
                if !interface.flags.isEmpty {
                    GroupBox("Flags") {
                        NetworkFlowLayout(spacing: 8) {
                            ForEach(interface.flags, id: \.self) { flag in
                                Text(flag)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding()
        }
        .alert("Destroy Interface", isPresented: $showDestroyConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Destroy", role: .destructive) {
                Task {
                    await viewModel.destroyInterface(interface.name)
                    onDestroy?()
                }
            }
        } message: {
            Text("Are you sure you want to destroy \(interface.name)? This will remove the interface from the system.")
        }
    }
}

// MARK: - Network Detail Row Helper

struct NetworkDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
        .font(.system(.body, design: .monospaced))
    }
}

// MARK: - Network Flow Layout for Flags

struct NetworkFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }

                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing

                self.size.width = max(self.size.width, x - spacing)
            }

            self.size.height = y + rowHeight
        }
    }
}

// MARK: - Configure Interface Sheet

struct ConfigureInterfaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let interface: NetworkInterfaceInfo
    @ObservedObject var viewModel: InterfacesViewModel

    @State private var useDHCP = true
    @State private var ipAddress = ""
    @State private var netmask = ""
    @State private var gateway = ""
    @State private var mtu = ""
    @State private var description = ""
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configure \(interface.name)")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(interface.type.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()

                // Status badge
                HStack(spacing: 4) {
                    Image(systemName: interface.status.icon)
                    Text(interface.status.rawValue)
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(interface.status.color.opacity(0.2))
                .foregroundColor(interface.status.color)
                .cornerRadius(8)
            }
            .padding()

            Divider()

            // Configuration form
            Form {
                Section("IP Configuration") {
                    Toggle("Use DHCP", isOn: $useDHCP)

                    if !useDHCP {
                        TextField("IP Address", text: $ipAddress)
                            .textFieldStyle(.roundedBorder)
                        TextField("Netmask", text: $netmask)
                            .textFieldStyle(.roundedBorder)
                        TextField("Default Gateway", text: $gateway)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section("Advanced") {
                    TextField("MTU", text: $mtu)
                        .textFieldStyle(.roundedBorder)
                    TextField("Description", text: $description)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)
            .padding()

            // Error message
            if let error = saveError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
            }

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isSaving ? "Saving..." : "Apply") {
                    Task {
                        await applyConfiguration()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 450)
        .onAppear {
            useDHCP = interface.dhcp
            ipAddress = interface.ipv4Address == "N/A" ? "" : interface.ipv4Address
            netmask = interface.ipv4Netmask == "N/A" ? "" : interface.ipv4Netmask
            mtu = "\(interface.mtu)"
            description = interface.description
        }
    }

    private func applyConfiguration() async {
        isSaving = true
        saveError = nil

        do {
            if useDHCP {
                try await viewModel.configureInterfaceDHCP(interface.name)
            } else {
                try await viewModel.configureInterfaceStatic(
                    interface.name,
                    ipAddress: ipAddress,
                    netmask: netmask,
                    gateway: gateway.isEmpty ? nil : gateway
                )
            }

            if !mtu.isEmpty, let mtuValue = Int(mtu), mtuValue != interface.mtu {
                try await viewModel.setMTU(interface.name, mtu: mtuValue)
            }

            if description != interface.description {
                try await viewModel.setDescription(interface.name, description: description)
            }

            await viewModel.refresh()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }

        isSaving = false
    }
}

// MARK: - Wireless Tab View

struct WirelessTabView: View {
    @StateObject private var viewModel = WirelessViewModel()
    @State private var selectedNetwork: WirelessNetwork?
    @State private var showConnectSheet = false
    @State private var showError = false
    @State private var searchText = ""

    var filteredNetworks: [WirelessNetwork] {
        if searchText.isEmpty {
            return viewModel.networks
        }
        return viewModel.networks.filter {
            $0.ssid.localizedCaseInsensitiveContains(searchText) ||
            $0.bssid.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wireless Networks")
                        .font(.headline)

                    if let status = viewModel.wirelessStatus {
                        HStack(spacing: 4) {
                            Image(systemName: "wifi")
                                .foregroundColor(.green)
                            Text("Connected to \(status.ssid)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if viewModel.wirelessInterface != nil {
                        Text("Not connected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("No wireless interface found")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Search
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)

                Button(action: {
                    Task {
                        await viewModel.scanNetworks()
                    }
                }) {
                    Label("Scan", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.wirelessInterface == nil || viewModel.isScanning)

                Button(action: {
                    Task {
                        await viewModel.refresh()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // Content
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading wireless information...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.wirelessInterface == nil {
                VStack(spacing: 20) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Wireless Interface")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("No wireless network interface was detected on this system")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isScanning {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Scanning for wireless networks...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.networks.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Networks Found")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Click Scan to search for available wireless networks")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: {
                        Task {
                            await viewModel.scanNetworks()
                        }
                    }) {
                        Label("Scan for Networks", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredNetworks, selection: $selectedNetwork) { network in
                    WirelessNetworkRow(network: network)
                        .tag(network)
                        .contextMenu {
                            if network.isConnected {
                                Button("Disconnect") {
                                    Task {
                                        await viewModel.disconnect()
                                    }
                                }
                            } else {
                                Button("Connect") {
                                    selectedNetwork = network
                                    showConnectSheet = true
                                }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showConnectSheet) {
            if let network = selectedNetwork {
                ConnectToNetworkSheet(network: network, viewModel: viewModel)
            }
        }
        .alert("Error", isPresented: $showError) {
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
                await viewModel.loadWirelessInfo()
            }
        }
    }
}

// MARK: - Wireless Network Row

struct WirelessNetworkRow: View {
    let network: WirelessNetwork

    var body: some View {
        HStack(spacing: 12) {
            // Signal strength icon
            Image(systemName: network.signalIcon)
                .font(.system(size: 20))
                .foregroundColor(network.signalColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(network.ssid.isEmpty ? "(Hidden Network)" : network.ssid)
                        .font(.headline)

                    if network.isConnected {
                        Text("Connected")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    }
                }

                HStack(spacing: 12) {
                    Text(network.security)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Ch \(network.channel)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(network.rate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Signal quality percentage
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(network.signalQuality)%")
                    .font(.headline)
                    .foregroundColor(network.signalColor)
                Text("\(network.rssi) dBm")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Connect to Network Sheet

struct ConnectToNetworkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let network: WirelessNetwork
    @ObservedObject var viewModel: WirelessViewModel

    @State private var password = ""
    @State private var isConnecting = false
    @State private var connectError: String?

    var requiresPassword: Bool {
        network.security != "OPEN" && network.security != "open"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: network.signalIcon)
                    .font(.system(size: 32))
                    .foregroundColor(network.signalColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect to Network")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(network.ssid)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(network.security)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(8)
            }
            .padding()

            Divider()

            // Password field
            VStack(alignment: .leading, spacing: 12) {
                if requiresPassword {
                    Text("Password")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("Enter network password", text: $password)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text("This network is open and does not require a password.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()

            // Error message
            if let error = connectError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
            }

            Spacer()

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isConnecting ? "Connecting..." : "Connect") {
                    Task {
                        await connect()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting || (requiresPassword && password.isEmpty))
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 280)
    }

    private func connect() async {
        isConnecting = true
        connectError = nil

        do {
            try await viewModel.connect(to: network, password: requiresPassword ? password : nil)
            dismiss()
        } catch {
            connectError = error.localizedDescription
        }

        isConnecting = false
    }
}

// MARK: - Bridges Tab View

struct BridgesTabView: View {
    @StateObject private var viewModel = BridgesViewModel()
    @State private var selectedBridge: BridgeInterface?
    @State private var showCreateSheet = false
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Network Bridges")
                        .font(.headline)
                    Text("\(viewModel.bridges.count) bridge\(viewModel.bridges.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    showCreateSheet = true
                }) {
                    Label("Create Bridge", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button(action: {
                    Task {
                        await viewModel.refresh()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // Content
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading bridges...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.bridges.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Bridges Configured")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Create a bridge to connect multiple network interfaces")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: {
                        showCreateSheet = true
                    }) {
                        Label("Create Bridge", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    // Bridge list
                    List(viewModel.bridges, selection: $selectedBridge) { bridge in
                        BridgeRowView(bridge: bridge)
                            .tag(bridge)
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task {
                                        await viewModel.deleteBridge(bridge.name)
                                        if selectedBridge?.name == bridge.name {
                                            selectedBridge = nil
                                        }
                                    }
                                } label: {
                                    Label("Delete Bridge", systemImage: "trash")
                                }
                            }
                    }
                    .frame(minWidth: 250, maxWidth: 350)

                    // Detail view
                    Group {
                        if let bridge = selectedBridge {
                            BridgeDetailView(bridge: bridge, viewModel: viewModel)
                        } else {
                            VStack(spacing: 20) {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("Select a bridge to view details")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 400, maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateBridgeSheet(viewModel: viewModel)
        }
        .alert("Error", isPresented: $showError) {
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
                await viewModel.loadBridges()
            }
        }
    }
}

// MARK: - Bridge Row View

struct BridgeRowView: View {
    let bridge: BridgeInterface

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 24))
                .foregroundColor(.purple)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(bridge.name)
                        .font(.headline)

                    HStack(spacing: 4) {
                        Image(systemName: bridge.status.icon)
                            .font(.system(size: 8))
                        Text(bridge.status.rawValue)
                            .font(.caption2)
                    }
                    .foregroundColor(bridge.status.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(bridge.status.color.opacity(0.15))
                    .cornerRadius(4)
                }

                Text("\(bridge.memberCount) member\(bridge.memberCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Bridge Detail View

struct BridgeDetailView: View {
    let bridge: BridgeInterface
    @ObservedObject var viewModel: BridgesViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 36))
                        .foregroundColor(.purple)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(bridge.name)
                            .font(.title)
                        Text("Network Bridge")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Image(systemName: bridge.status.icon)
                        Text(bridge.status.rawValue)
                    }
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(bridge.status.color.opacity(0.2))
                    .foregroundColor(bridge.status.color)
                    .cornerRadius(8)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)

                // Action buttons
                HStack(spacing: 12) {
                    Button(action: {
                        Task {
                            await viewModel.deleteBridge(bridge.name)
                        }
                    }) {
                        Label("Delete Bridge", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Spacer()
                }

                // Address Information
                GroupBox("Configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        NetworkDetailRow(label: "IPv4 Address", value: bridge.ipv4Address.isEmpty ? "Not configured" : bridge.ipv4Address)
                        NetworkDetailRow(label: "Netmask", value: bridge.ipv4Netmask.isEmpty ? "N/A" : bridge.ipv4Netmask)
                        NetworkDetailRow(label: "STP", value: bridge.stp ? "Enabled" : "Disabled")
                    }
                    .padding(.vertical, 8)
                }

                // Member interfaces
                GroupBox("Member Interfaces") {
                    if bridge.members.isEmpty {
                        Text("No member interfaces")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(bridge.members, id: \.self) { member in
                                HStack {
                                    Image(systemName: "cable.connector")
                                        .foregroundColor(.blue)
                                    Text(member)
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                    Button(action: {
                                        Task {
                                            await viewModel.removeMember(bridge.name, member: member)
                                        }
                                    }) {
                                        Image(systemName: "minus.circle")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Create Bridge Sheet

struct CreateBridgeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: BridgesViewModel

    @State private var bridgeName = ""
    @State private var selectedMembers: Set<String> = []
    @State private var useStaticIP = false
    @State private var ipAddress = ""
    @State private var netmask = "255.255.255.0"
    @State private var enableSTP = false
    @State private var isCreating = false
    @State private var createError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Create Network Bridge")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding()

            Divider()

            // Form
            Form {
                Section("Bridge Name") {
                    TextField("e.g., bridge0", text: $bridgeName)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Member Interfaces") {
                    if viewModel.availableInterfaces.isEmpty {
                        Text("No available interfaces")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.availableInterfaces, id: \.self) { iface in
                            Toggle(iface, isOn: Binding(
                                get: { selectedMembers.contains(iface) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedMembers.insert(iface)
                                    } else {
                                        selectedMembers.remove(iface)
                                    }
                                }
                            ))
                        }
                    }
                }

                Section("IP Configuration") {
                    Toggle("Configure static IP", isOn: $useStaticIP)

                    if useStaticIP {
                        TextField("IP Address", text: $ipAddress)
                            .textFieldStyle(.roundedBorder)
                        TextField("Netmask", text: $netmask)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section("Options") {
                    Toggle("Enable Spanning Tree Protocol (STP)", isOn: $enableSTP)
                }
            }
            .formStyle(.grouped)
            .padding()

            // Error message
            if let error = createError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
            }

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isCreating ? "Creating..." : "Create") {
                    Task {
                        await createBridge()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating || bridgeName.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 550)
    }

    private func createBridge() async {
        isCreating = true
        createError = nil

        do {
            try await viewModel.createBridge(
                name: bridgeName,
                members: Array(selectedMembers),
                ipAddress: useStaticIP ? ipAddress : nil,
                netmask: useStaticIP ? netmask : nil,
                stp: enableSTP
            )
            dismiss()
        } catch {
            createError = error.localizedDescription
        }

        isCreating = false
    }
}

// MARK: - Routing Tab View

struct RoutingTabView: View {
    @StateObject private var viewModel = RoutingViewModel()
    @State private var showAddRoute = false
    @State private var showError = false
    @State private var searchText = ""
    @State private var showIPv6 = false

    var filteredRoutes: [RouteEntry] {
        var routes = showIPv6 ? viewModel.routes6 : viewModel.routes4

        if !searchText.isEmpty {
            routes = routes.filter {
                $0.destination.localizedCaseInsensitiveContains(searchText) ||
                $0.gateway.localizedCaseInsensitiveContains(searchText) ||
                $0.netif.localizedCaseInsensitiveContains(searchText)
            }
        }

        return routes
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Routing Table")
                        .font(.headline)
                    Text("\(filteredRoutes.count) route\(filteredRoutes.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // IPv4/IPv6 toggle
                Picker("Protocol", selection: $showIPv6) {
                    Text("IPv4").tag(false)
                    Text("IPv6").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)

                // Search
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)

                Button(action: {
                    showAddRoute = true
                }) {
                    Label("Add Route", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button(action: {
                    Task {
                        await viewModel.refresh()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // Content
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading routing table...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRoutes.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Routes Found")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filteredRoutes) {
                    TableColumn("Destination") { route in
                        HStack(spacing: 4) {
                            if route.isDefault {
                                Image(systemName: "star.fill")
                                    .foregroundColor(.yellow)
                                    .font(.system(size: 10))
                            }
                            Text(route.destination)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Gateway") { route in
                        Text(route.gateway)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 150, ideal: 200)

                    TableColumn("Flags") { route in
                        Text(route.flags)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Interface") { route in
                        Text(route.netif)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("Actions") { route in
                        if !route.isDefault {
                            Button(action: {
                                Task {
                                    await viewModel.deleteRoute(route)
                                }
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .width(60)
                }
            }
        }
        .sheet(isPresented: $showAddRoute) {
            AddRouteSheet(viewModel: viewModel)
        }
        .alert("Error", isPresented: $showError) {
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
                await viewModel.loadRoutes()
            }
        }
    }
}

// MARK: - Add Route Sheet

struct AddRouteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: RoutingViewModel

    @State private var destination = ""
    @State private var gateway = ""
    @State private var netif = ""
    @State private var isAdding = false
    @State private var addError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Route")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding()

            Divider()

            // Form
            Form {
                Section("Route") {
                    TextField("Destination (e.g., 10.0.0.0/24)", text: $destination)
                        .textFieldStyle(.roundedBorder)
                    TextField("Gateway (e.g., 192.168.1.1)", text: $gateway)
                        .textFieldStyle(.roundedBorder)
                    TextField("Interface (optional)", text: $netif)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)
            .padding()

            // Error message
            if let error = addError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
            }

            Spacer()

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isAdding ? "Adding..." : "Add Route") {
                    Task {
                        await addRoute()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAdding || destination.isEmpty || gateway.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 450, height: 350)
    }

    private func addRoute() async {
        isAdding = true
        addError = nil

        do {
            try await viewModel.addRoute(destination: destination, gateway: gateway, netif: netif.isEmpty ? nil : netif)
            dismiss()
        } catch {
            addError = error.localizedDescription
        }

        isAdding = false
    }
}

// MARK: - Switches Tab View

struct SwitchesTabView: View {
    @StateObject private var viewModel = SwitchesViewModel()
    @State private var selectedSwitch: VMSwitch?
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VM Switches")
                        .font(.headline)
                    Text("\(viewModel.switches.count) switch\(viewModel.switches.count == 1 ? "" : "es")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    Task {
                        await viewModel.refresh()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // Content
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading switches...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.switches.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "arrow.left.arrow.right.square")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No VM Switches Found")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("VM switches are created through the VMs feature setup wizard")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    // Switch list
                    List(viewModel.switches, selection: $selectedSwitch) { vmSwitch in
                        SwitchRowView(vmSwitch: vmSwitch)
                            .tag(vmSwitch)
                            .contextMenu {
                                Button(role: .destructive) {
                                    Task {
                                        await viewModel.deleteSwitch(vmSwitch.name)
                                        if selectedSwitch?.name == vmSwitch.name {
                                            selectedSwitch = nil
                                        }
                                    }
                                } label: {
                                    Label("Delete Switch", systemImage: "trash")
                                }
                            }
                    }
                    .frame(minWidth: 250, maxWidth: 350)

                    // Detail view
                    Group {
                        if let vmSwitch = selectedSwitch {
                            SwitchDetailView(vmSwitch: vmSwitch, viewModel: viewModel)
                        } else {
                            VStack(spacing: 20) {
                                Image(systemName: "arrow.left.arrow.right.square")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("Select a switch to view details")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 400, maxWidth: .infinity)
                }
            }
        }
        .alert("Error", isPresented: $showError) {
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
                await viewModel.loadSwitches()
            }
        }
    }
}

// MARK: - Switch Row View

struct SwitchRowView: View {
    let vmSwitch: VMSwitch

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right.square")
                .font(.system(size: 24))
                .foregroundColor(.cyan)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(vmSwitch.name)
                        .font(.headline)

                    Text(vmSwitch.type)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.cyan.opacity(0.15))
                        .foregroundColor(.cyan)
                        .cornerRadius(4)
                }

                if vmSwitch.hasInterface {
                    Text(vmSwitch.iface)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if vmSwitch.hasPorts {
                    Text("Ports: \(vmSwitch.ports.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Switch Detail View

struct SwitchDetailView: View {
    let vmSwitch: VMSwitch
    @ObservedObject var viewModel: SwitchesViewModel
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    Image(systemName: "arrow.left.arrow.right.square")
                        .font(.system(size: 36))
                        .foregroundColor(.cyan)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(vmSwitch.name)
                            .font(.title)
                        Text("VM Switch")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Text(vmSwitch.type)
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.cyan.opacity(0.2))
                        .foregroundColor(.cyan)
                        .cornerRadius(8)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(12)

                // Action buttons
                HStack(spacing: 12) {
                    Button(action: {
                        showDeleteConfirmation = true
                    }) {
                        Label("Delete Switch", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Spacer()
                }

                // Configuration
                GroupBox("Configuration") {
                    VStack(alignment: .leading, spacing: 12) {
                        NetworkDetailRow(label: "Bridge Interface", value: vmSwitch.hasInterface ? vmSwitch.iface : "Not configured")
                        NetworkDetailRow(label: "Address", value: vmSwitch.address == "-" ? "Not configured" : vmSwitch.address)
                        NetworkDetailRow(label: "Private", value: vmSwitch.isPrivate ? "Yes" : "No")
                        NetworkDetailRow(label: "MTU", value: vmSwitch.mtu == "-" ? "Default" : vmSwitch.mtu)
                        NetworkDetailRow(label: "VLAN", value: vmSwitch.vlan == "-" ? "None" : vmSwitch.vlan)
                    }
                    .padding(.vertical, 8)
                }

                // Only show Physical Interfaces section for standard switches (not manual switches which use existing bridges)
                if vmSwitch.type != "manual" {
                    GroupBox("Physical Interfaces") {
                        if vmSwitch.ports.isEmpty {
                            Text("No physical interfaces attached")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 8)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(vmSwitch.ports, id: \.self) { port in
                                    HStack {
                                        Image(systemName: "cable.connector")
                                            .foregroundColor(.blue)
                                        Text(port)
                                            .font(.system(.body, design: .monospaced))
                                        Spacer()
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
            .padding()
        }
        .alert("Delete Switch", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteSwitch(vmSwitch.name)
                }
            }
        } message: {
            if vmSwitch.type == "manual" {
                Text("Are you sure you want to delete the '\(vmSwitch.name)' switch? The underlying bridge interface will not be affected.")
            } else {
                Text("Are you sure you want to delete the '\(vmSwitch.name)' switch? This will also remove the associated bridge interface.")
            }
        }
    }
}

// MARK: - View Models

@MainActor
class InterfacesViewModel: ObservableObject {
    @Published var interfaces: [NetworkInterfaceInfo] = []
    @Published var isLoading = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadInterfaces() async {
        isLoading = true
        error = nil

        do {
            interfaces = try await sshManager.listNetworkInterfaces()
        } catch {
            self.error = "Failed to load interfaces: \(error.localizedDescription)"
            interfaces = []
        }

        isLoading = false
    }

    func refresh() async {
        await loadInterfaces()
    }

    func setInterfaceUp(_ name: String) async {
        error = nil
        do {
            try await sshManager.setNetworkInterfaceUp(name)
            await refresh()
        } catch {
            self.error = "Failed to bring up \(name): \(error.localizedDescription)"
        }
    }

    func setInterfaceDown(_ name: String) async {
        error = nil
        do {
            try await sshManager.setNetworkInterfaceDown(name)
            await refresh()
        } catch {
            self.error = "Failed to bring down \(name): \(error.localizedDescription)"
        }
    }

    func renewDHCP(_ name: String) async {
        error = nil
        do {
            try await sshManager.renewDHCP(name)
            await refresh()
        } catch {
            self.error = "Failed to renew DHCP for \(name): \(error.localizedDescription)"
        }
    }

    func configureInterfaceDHCP(_ name: String) async throws {
        try await sshManager.configureInterfaceDHCP(name)
    }

    func configureInterfaceStatic(_ name: String, ipAddress: String, netmask: String, gateway: String?) async throws {
        try await sshManager.configureInterfaceStatic(name, ipAddress: ipAddress, netmask: netmask, gateway: gateway)
    }

    func setMTU(_ name: String, mtu: Int) async throws {
        try await sshManager.setInterfaceMTU(name, mtu: mtu)
    }

    func setDescription(_ name: String, description: String) async throws {
        try await sshManager.setInterfaceDescription(name, description: description)
    }

    func destroyInterface(_ name: String) async {
        error = nil
        do {
            try await sshManager.destroyClonedInterface(name)
            await refresh()
        } catch {
            self.error = "Failed to destroy \(name): \(error.localizedDescription)"
        }
    }
}

@MainActor
class WirelessViewModel: ObservableObject {
    @Published var wirelessInterface: String?
    @Published var wirelessStatus: WirelessStatus?
    @Published var networks: [WirelessNetwork] = []
    @Published var isLoading = false
    @Published var isScanning = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadWirelessInfo() async {
        isLoading = true
        error = nil

        do {
            wirelessInterface = try await sshManager.getWirelessInterface()
            if wirelessInterface != nil {
                wirelessStatus = try await sshManager.getWirelessStatus()
            }
        } catch {
            self.error = "Failed to load wireless info: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func refresh() async {
        await loadWirelessInfo()
    }

    func scanNetworks() async {
        guard wirelessInterface != nil else { return }

        isScanning = true
        error = nil

        do {
            networks = try await sshManager.scanWirelessNetworks()
        } catch {
            self.error = "Failed to scan networks: \(error.localizedDescription)"
        }

        isScanning = false
    }

    func connect(to network: WirelessNetwork, password: String?) async throws {
        try await sshManager.connectToWirelessNetwork(ssid: network.ssid, password: password)
        await refresh()
    }

    func disconnect() async {
        error = nil
        do {
            try await sshManager.disconnectWireless()
            await refresh()
        } catch {
            self.error = "Failed to disconnect: \(error.localizedDescription)"
        }
    }
}

@MainActor
class BridgesViewModel: ObservableObject {
    @Published var bridges: [BridgeInterface] = []
    @Published var availableInterfaces: [String] = []
    @Published var isLoading = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadBridges() async {
        isLoading = true
        error = nil

        do {
            bridges = try await sshManager.listBridges()
            availableInterfaces = try await sshManager.listBridgeableInterfaces()
        } catch {
            self.error = "Failed to load bridges: \(error.localizedDescription)"
            bridges = []
        }

        isLoading = false
    }

    func refresh() async {
        await loadBridges()
    }

    func createBridge(name: String, members: [String], ipAddress: String?, netmask: String?, stp: Bool) async throws {
        try await sshManager.createBridge(name: name, members: members, ipAddress: ipAddress, netmask: netmask, stp: stp)
        await refresh()
    }

    func deleteBridge(_ name: String) async {
        error = nil
        do {
            try await sshManager.deleteBridge(name)
            await refresh()
        } catch {
            self.error = "Failed to delete bridge: \(error.localizedDescription)"
        }
    }

    func removeMember(_ bridgeName: String, member: String) async {
        error = nil
        do {
            try await sshManager.removeBridgeMember(bridgeName, member: member)
            await refresh()
        } catch {
            self.error = "Failed to remove member: \(error.localizedDescription)"
        }
    }
}

@MainActor
class RoutingViewModel: ObservableObject {
    @Published var routes4: [RouteEntry] = []
    @Published var routes6: [RouteEntry] = []
    @Published var isLoading = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadRoutes() async {
        isLoading = true
        error = nil

        do {
            routes4 = try await sshManager.listRoutes(ipv6: false)
            routes6 = try await sshManager.listRoutes(ipv6: true)
        } catch {
            self.error = "Failed to load routes: \(error.localizedDescription)"
            routes4 = []
            routes6 = []
        }

        isLoading = false
    }

    func refresh() async {
        await loadRoutes()
    }

    func addRoute(destination: String, gateway: String, netif: String?) async throws {
        try await sshManager.addRoute(destination: destination, gateway: gateway, netif: netif)
        await refresh()
    }

    func deleteRoute(_ route: RouteEntry) async {
        error = nil
        do {
            try await sshManager.deleteRoute(destination: route.destination, gateway: route.gateway)
            await refresh()
        } catch {
            self.error = "Failed to delete route: \(error.localizedDescription)"
        }
    }
}

@MainActor
class SwitchesViewModel: ObservableObject {
    @Published var switches: [VMSwitch] = []
    @Published var isLoading = false
    @Published var error: String?

    private let sshManager = SSHConnectionManager.shared

    func loadSwitches() async {
        isLoading = true
        error = nil

        do {
            switches = try await sshManager.listVMSwitches()
        } catch {
            self.error = "Failed to load switches: \(error.localizedDescription)"
            switches = []
        }

        isLoading = false
    }

    func refresh() async {
        await loadSwitches()
    }

    func deleteSwitch(_ name: String) async {
        error = nil
        do {
            try await sshManager.deleteVMSwitch(name)
            await refresh()
        } catch {
            self.error = "Failed to delete switch: \(error.localizedDescription)"
        }
    }
}
