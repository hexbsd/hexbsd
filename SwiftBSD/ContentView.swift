//
//  ContentView.swift
//  SwiftBSD
//
//  Created by Joseph Maloney on 3/17/25.
//

import SwiftUI

struct SystemStatus {
    let cpuUsage: String
    let memoryUsage: String
    let zfsArcUsage: String
    let storageUsage: String
    let uptime: String
    let loadAverage: String
}

let mockSystemStatus = SystemStatus(
    cpuUsage: "15%",
    memoryUsage: "8 GB / 16 GB",
    zfsArcUsage: "4 GB / 8 GB",
    storageUsage: "120 GB / 500 GB",
    uptime: "5 days, 12 hours",
    loadAverage: "0.85, 0.76, 0.72"
)

enum SidebarSection: String, CaseIterable, Identifiable {
    case accounts = "Accounts"
    case jails = "Jails"
    case network = "Network"
    case packages = "Packages"
    case security = "Security"
    case services = "Services"
    case sharing = "Sharing"
    case status = "Status"
    case storage = "Storage"
    case system = "System"
    case updates = "Updates"
    case virtualMachines = "Virtual Machines"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .accounts: return "person.2"
        case .jails: return "lock"
        case .network: return "network"
        case .packages: return "shippingbox"
        case .security: return "shield.lefthalf.filled"
        case .services: return "gear"
        case .sharing: return "square.and.arrow.up"
        case .storage: return "externaldrive"
        case .status: return "chart.bar"
        case .system: return "cpu"
        case .updates: return "arrow.triangle.2.circlepath"
        case .virtualMachines: return "desktopcomputer"
        }
    }
}

struct UserAccount: Identifiable {
    let id = UUID()
    let username: String
    let uid: Int
    let primaryGroup: String
    let additionalGroups: [String]
    let shell: String
    let homeDirectory: String
}

let mockAccounts: [UserAccount] = [
    UserAccount(username: "rhendricks", uid: 1001, primaryGroup: "engineers", additionalGroups: ["wheel", "ssh", "staff"], shell: "/bin/sh", homeDirectory: "/home/rhendricks"),
    UserAccount(username: "dgilfoyle", uid: 1002, primaryGroup: "engineers", additionalGroups: ["wheel", "security"], shell: "/bin/bash", homeDirectory: "/home/dgilfoyle"),
    UserAccount(username: "bertram", uid: 1003, primaryGroup: "engineers", additionalGroups: ["games"], shell: "/usr/local/bin/fish", homeDirectory: "/home/bertram"),
    UserAccount(username: "cbradley", uid: 1004, primaryGroup: "engineers", additionalGroups: ["dev"], shell: "/bin/csh", homeDirectory: "/home/cbradley"),
    UserAccount(username: "jpmcmillan", uid: 1005, primaryGroup: "engineers", additionalGroups: ["qa"], shell: "/bin/sh", homeDirectory: "/home/jpmcmillan"),
    UserAccount(username: "rtrung", uid: 1006, primaryGroup: "engineers", additionalGroups: ["devops"], shell: "/usr/bin/zsh", homeDirectory: "/home/rtrung"),
    UserAccount(username: "nelsonbighetti", uid: 1007, primaryGroup: "engineers", additionalGroups: ["marketing"], shell: "/bin/sh", homeDirectory: "/home/nelsonbighetti"),
    UserAccount(username: "ian", uid: 1008, primaryGroup: "engineers", additionalGroups: ["game-dev"], shell: "/bin/zsh", homeDirectory: "/home/ian"),
    UserAccount(username: "poppy", uid: 1009, primaryGroup: "engineers", additionalGroups: ["game-dev", "qa"], shell: "/bin/fish", homeDirectory: "/home/poppy"),
    UserAccount(username: "jo", uid: 1010, primaryGroup: "engineers", additionalGroups: ["executive"], shell: "/bin/sh", homeDirectory: "/home/jo"),
    UserAccount(username: "brad", uid: 1011, primaryGroup: "engineers", additionalGroups: ["finance"], shell: "/bin/bash", homeDirectory: "/home/brad")
]

struct NFSExport: Identifiable {
    let id = UUID()
    let path: String
    let clients: String
    let options: String
}

let mockNFSExports: [NFSExport] = [
    NFSExport(path: "/mnt/storage", clients: "192.168.1.0/24", options: "rw,sync,no_root_squash"),
    NFSExport(path: "/home", clients: "10.0.0.0/16", options: "ro,sync,all_squash"),
    NFSExport(path: "/usr/ports", clients: "192.168.2.0/24", options: "rw,no_subtree_check"),
    NFSExport(path: "/var/backups", clients: "backup.local", options: "rw,sync,no_root_squash"),
    NFSExport(path: "/exports/media", clients: "192.168.3.100", options: "ro,async")
]

struct Jail: Identifiable {
    let id = UUID()
    let name: String
    let ipAddress: String
    let status: String
    let services: [String]
}

let mockJails: [Jail] = [
    Jail(name: "nginx", ipAddress: "192.168.1.10", status: "Running", services: ["Web Server"]),
    Jail(name: "squid", ipAddress: "192.168.1.11", status: "Running", services: ["Proxy Server"]),
    Jail(name: "postgresql", ipAddress: "192.168.1.12", status: "Stopped", services: ["Database Server"]),
    Jail(name: "redis", ipAddress: "192.168.1.13", status: "Running", services: ["Caching Server"]),
    Jail(name: "unbound", ipAddress: "192.168.1.14", status: "Running", services: ["DNS Resolver"]),
    Jail(name: "openvpn", ipAddress: "192.168.1.15", status: "Stopped", services: ["VPN Server"]),
    Jail(name: "mailserver", ipAddress: "192.168.1.16", status: "Running", services: ["Email Server"]),
    Jail(name: "gitlab", ipAddress: "192.168.1.17", status: "Running", services: ["Git Hosting"]),
    Jail(name: "nextcloud", ipAddress: "192.168.1.18", status: "Stopped", services: ["Cloud Storage"]),
    Jail(name: "plex", ipAddress: "192.168.1.19", status: "Running", services: ["Media Server"])
]

struct NetworkInterface: Identifiable {
    let id = UUID()
    let name: String
    let type: String
    let ipAddress: String
    let status: String
}

let mockNetworkInterfaces: [NetworkInterface] = [
    NetworkInterface(name: "em0", type: "Intel 10G", ipAddress: "192.168.1.100", status: "Active"),
    NetworkInterface(name: "em1", type: "Intel 10G", ipAddress: "192.168.1.101", status: "Active"),
    NetworkInterface(name: "re0", type: "Realtek 1G", ipAddress: "192.168.1.102", status: "Inactive"),
    NetworkInterface(name: "bridge0", type: "Bridge", ipAddress: "192.168.1.1", status: "Active"),
    NetworkInterface(name: "vlan10", type: "VLAN", ipAddress: "192.168.10.1", status: "Active"),
    NetworkInterface(name: "lo0", type: "Loopback", ipAddress: "127.0.0.1", status: "Active")
]

struct Package: Identifiable {
    let id = UUID()
    let name: String
    let version: String
    let description: String
}

let mockPackages: [Package] = [
    Package(name: "pkg", version: "1.18.4", description: "Package management tool for FreeBSD"),
    Package(name: "poudriere", version: "3.3.7", description: "Port building and testing system"),
    Package(name: "nginx", version: "1.24.0", description: "High-performance HTTP server and reverse proxy"),
    Package(name: "openssl", version: "3.0.8", description: "Cryptography and SSL/TLS toolkit"),
    Package(name: "python", version: "3.9.16", description: "Interpreted, interactive, object-oriented programming language"),
    Package(name: "git", version: "2.41.0", description: "Distributed version control system"),
    Package(name: "zfs", version: "2.1.9", description: "OpenZFS filesystem and volume manager"),
    Package(name: "vim", version: "9.0.1500", description: "Improved version of the vi editor"),
    Package(name: "bash", version: "5.2.15", description: "GNU Bourne Again Shell"),
    Package(name: "tmux", version: "3.3a", description: "Terminal multiplexer"),
    Package(name: "sudo", version: "1.9.14p3", description: "Allow users to run commands as root")
]

struct FirewallRule: Identifiable {
    let id = UUID()
    let ruleNumber: Int
    let action: String
    let protocolType: String
    let source: String
    let destination: String
    let port: String
}

let mockFirewallRules: [FirewallRule] = [
    FirewallRule(ruleNumber: 100, action: "Allow", protocolType: "TCP", source: "192.168.1.0/24", destination: "Any", port: "22 (SSH)"),
    FirewallRule(ruleNumber: 200, action: "Allow", protocolType: "TCP", source: "Any", destination: "192.168.1.100", port: "80 (HTTP)"),
    FirewallRule(ruleNumber: 300, action: "Allow", protocolType: "TCP", source: "Any", destination: "192.168.1.100", port: "443 (HTTPS)"),
    FirewallRule(ruleNumber: 400, action: "Allow", protocolType: "UDP", source: "Any", destination: "192.168.1.255", port: "53 (DNS)"),
    FirewallRule(ruleNumber: 500, action: "Deny", protocolType: "Any", source: "Any", destination: "Any", port: "Any"),
]

struct Service: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let status: String
}

let mockServices: [Service] = [
    Service(name: "sshd", description: "OpenSSH Daemon", status: "Running"),
    Service(name: "cron", description: "Daemon to execute scheduled commands", status: "Running"),
    Service(name: "sendmail", description: "Mail Transfer Agent", status: "Stopped"),
    Service(name: "syslogd", description: "System Logging Daemon", status: "Running"),
    Service(name: "dhclient", description: "DHCP Client", status: "Running"),
    Service(name: "ntpd", description: "Network Time Protocol Daemon", status: "Stopped"),
    Service(name: "devd", description: "Device State Change Daemon", status: "Running"),
    Service(name: "local_unbound", description: "Local DNS Resolver", status: "Stopped"),
    Service(name: "zfsd", description: "ZFS Automatic Device Management Daemon", status: "Running"),
    Service(name: "bgpd", description: "BGP Routing Daemon", status: "Stopped")
]

struct ContentView: View {
    @State private var selectedSection: SidebarSection?
    @State private var showConnectSheet = false
    @State private var isConnected = false
    @State private var serverAddress = "Not Connected"

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selectedSection) { section in
                NavigationLink(value: section) {
                    Label(section.rawValue, systemImage: section.icon)
                }
                .disabled(!isConnected)
            }
            .navigationTitle("\(isConnected ? serverAddress : "SwiftBSD")")

#if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
        } detail: {
            if let section = selectedSection {
                DetailView(section: section, serverAddress: serverAddress)
            } else {
                VStack {
                    Text("Welcome to SwiftBSD")
                        .font(.largeTitle)
                        .bold()
                        .padding(.bottom, 10)

                    Button("Connect") {
                        showConnectSheet.toggle()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Documentation") {
                        if let url = URL(string: "https://swiftbsd.example.com/help") {
                            #if os(macOS)
                            NSWorkspace.shared.open(url)
                            #endif
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Support") {
                        if let url = URL(string: "https://swiftbsd.example.com/support") {
                            #if os(macOS)
                            NSWorkspace.shared.open(url)
                            #endif
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .sheet(isPresented: $showConnectSheet) {
            ConnectView(isConnected: $isConnected, serverAddress: $serverAddress)
        }
    }
}

// MARK: - ZFS Storage Models
struct ZFSPool: Identifiable {
    let id = UUID()
    let name: String
    let size: String
    let used: String
    let available: String
    let status: String
}

struct ZFSDataset: Identifiable {
    let id = UUID()
    let name: String
    let pool: String
    let used: String
    let mountpoint: String
}

let mockZFSPools: [ZFSPool] = [
    ZFSPool(name: "zroot", size: "500 GB", used: "120 GB", available: "380 GB", status: "ONLINE"),
    ZFSPool(name: "tank", size: "2 TB", used: "1.5 TB", available: "500 GB", status: "DEGRADED")
]

let mockZFSDatasets: [ZFSDataset] = [
    ZFSDataset(name: "zroot/ROOT", pool: "zroot", used: "5 GB", mountpoint: "/"),
    ZFSDataset(name: "zroot/usr", pool: "zroot", used: "50 GB", mountpoint: "/usr"),
    ZFSDataset(name: "zroot/var", pool: "zroot", used: "20 GB", mountpoint: "/var"),
    ZFSDataset(name: "tank/media", pool: "tank", used: "1 TB", mountpoint: "/mnt/media"),
    ZFSDataset(name: "tank/backups", pool: "tank", used: "500 GB", mountpoint: "/mnt/backups")
]

struct SystemSettings {
    let hostname: String
    let timezone: String
    let defaultShell: String
    let availableTimezones: [String]
    let availableShells: [String]
}

let mockSystemSettings = SystemSettings(
    hostname: "freebsd-server",
    timezone: "US/Eastern",
    defaultShell: "/bin/sh",
    availableTimezones: [
        "US/Pacific", "US/Mountain", "US/Central", "US/Eastern",
        "UTC", "Europe/London", "Europe/Paris", "Asia/Tokyo"
    ],
    availableShells: [
        "/bin/sh", "/bin/csh", "/usr/local/bin/zsh",
        "/usr/local/bin/fish", "/bin/bash"
    ]
)

struct SystemUpdate: Identifiable {
    let id = UUID()
    let type: String
    let description: String
    let status: String
}

let mockSystemUpdates: [SystemUpdate] = [
    SystemUpdate(type: "Security", description: "OpenSSL vulnerability fix", status: "Pending"),
    SystemUpdate(type: "Kernel", description: "Kernel update to 13.2-RELEASE-p5", status: "Pending"),
    SystemUpdate(type: "Packages", description: "pkg updated to 1.18.5", status: "Installed"),
    SystemUpdate(type: "Packages", description: "vim updated to 9.0.1600", status: "Pending"),
    SystemUpdate(type: "Base System", description: "Userland utilities update", status: "Pending")
]

struct DetailView: View {
    let section: SidebarSection
    let serverAddress: String

    var body: some View {
        VStack {
            if section == .services {
                Text("System Services")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                Table(mockServices) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Description", value: \.description)
                    TableColumn("Status", value: \.status)
                }
            } else if section == .security {
                Text("Firewall Manager")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                Table(mockFirewallRules) {
                    TableColumn("Rule #") { Text("\($0.ruleNumber)") }
                    TableColumn("Action", value: \.action)
                    TableColumn("Protocol", value: \.protocolType)
                    TableColumn("Source", value: \.source)
                    TableColumn("Destination", value: \.destination)
                    TableColumn("Port", value: \.port)
                }
            } else if section == .packages {
                Text("Installed Packages")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                Table(mockPackages) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Version", value: \.version)
                    TableColumn("Description", value: \.description)
                }
            } else if section == .network {
                Text("Network Interfaces")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                Table(mockNetworkInterfaces) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Type", value: \.type)
                    TableColumn("IP Address", value: \.ipAddress)
                    TableColumn("Status", value: \.status)
                }
            } else if section == .accounts {
                Text("User Accounts")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                Table(mockAccounts.filter { $0.username != "root" }) {
                    TableColumn("Username", value: \.username)
                    TableColumn("UID") { Text("\($0.uid)") }
                    TableColumn("Primary Group", value: \.primaryGroup)
                    TableColumn("Additional Groups") { Text($0.additionalGroups.joined(separator: ", ")) }
                    TableColumn("Shell", value: \.shell)
                    TableColumn("Home Directory", value: \.homeDirectory)
                }

                HStack {
                    Button("Add") {
                        // UI-only mockup, does nothing
                    }
                    Button("Edit") {
                        // UI-only mockup, does nothing
                    }
                    .disabled(true) // Always disabled in mockup

                    Button("Remove") {
                        // UI-only mockup, does nothing
                    }
                    .disabled(true) // Always disabled in mockup
                }
                .padding(.top, 10)
            } else if section == .jails {
                Text("Jails")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                Table(mockJails) {
                    TableColumn("Name", value: \.name)
                    TableColumn("IP Address", value: \.ipAddress)
                    TableColumn("Status") { Text($0.status) }
                    TableColumn("Services") { Text($0.services.joined(separator: ", ")) }
                }

                HStack {
                    Button("Add") {
                        // UI-only mockup, does nothing
                    }
                    Button("Edit") {
                        // UI-only mockup, does nothing
                    }
                    .disabled(true) // Always disabled in mockup

                    Button("Remove") {
                        // UI-only mockup, does nothing
                    }
                    .disabled(true) // Always disabled in mockup
                }
                .padding(.top, 10)
            } else if section == .sharing {
                Text("NFS Exports")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                Table(mockNFSExports) {
                    TableColumn("Path", value: \.path)
                    TableColumn("Clients", value: \.clients)
                    TableColumn("Options", value: \.options)
                }
            } else if section == .storage {
                Text("ZFS Storage")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                Text("ZFS Pools")
                    .font(.title2)
                    .bold()
                    .padding(.top, 10)

                Table(mockZFSPools) {
                    TableColumn("Pool Name", value: \.name)
                    TableColumn("Size", value: \.size)
                    TableColumn("Used", value: \.used)
                    TableColumn("Available", value: \.available)
                    TableColumn("Status", value: \.status)
                }
                .padding(.bottom, 20)

                Text("ZFS Datasets")
                    .font(.title2)
                    .bold()
                    .padding(.top, 10)

                Table(mockZFSDatasets) {
                    TableColumn("Dataset Name", value: \.name)
                    TableColumn("Pool", value: \.pool)
                    TableColumn("Used", value: \.used)
                    TableColumn("Mountpoint", value: \.mountpoint)
                }
            } else if section == .system {
                Text("System Settings")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Hostname: \(mockSystemSettings.hostname)")
                        .font(.title2)
                        .bold()

                    Text("Current Timezone: \(mockSystemSettings.timezone)")
                        .font(.title2)
                        .bold()

                    Picker("Select Timezone", selection: .constant(mockSystemSettings.timezone)) {
                        ForEach(mockSystemSettings.availableTimezones, id: \.self) { timezone in
                            Text(timezone)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .padding(.top, 10)

                    Text("Default Shell: \(mockSystemSettings.defaultShell)")
                        .font(.title2)
                        .bold()

                    Picker("Select Shell", selection: .constant(mockSystemSettings.defaultShell)) {
                        ForEach(mockSystemSettings.availableShells, id: \.self) { shell in
                            Text(shell)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .padding(.top, 10)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.2)))
                .padding()
            } else if section == .status {
                Text("System Status Dashboard")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)
 
                VStack(alignment: .leading, spacing: 10) {
                    Text("CPU Usage: \(mockSystemStatus.cpuUsage)")
                    Text("Memory Usage: \(mockSystemStatus.memoryUsage)")
                    Text("ZFS ARC Usage: \(mockSystemStatus.zfsArcUsage)")
                    Text("Storage Usage: \(mockSystemStatus.storageUsage)")
                    Text("Uptime: \(mockSystemStatus.uptime)")
                    Text("Load Average: \(mockSystemStatus.loadAverage)")
                }
                .font(.title2)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.2)))
                .padding()
            } else if section == .updates {
                Text("System Updates")
                    .font(.largeTitle)
                    .bold()
                    .padding(.bottom, 10)

                Table(mockSystemUpdates) {
                    TableColumn("Type", value: \.type)
                    TableColumn("Description", value: \.description)
                    TableColumn("Status", value: \.status)
                }

                HStack {
                    Button("Check for Updates") {
                        // UI-only mockup, does nothing
                    }
                    Button("Apply Updates") {
                        // UI-only mockup, does nothing
                    }
                    .disabled(true) // Always disabled in mockup
                }
                .padding(.top, 10)
            } else {
                Text(section.rawValue)
                    .font(.largeTitle)
                    .bold()
            }
            Spacer()
        }
        .padding()
        .navigationTitle("\(serverAddress) - \(section.rawValue)")
    }
}

// MARK: - Connect View
struct ConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var isConnected: Bool
    @Binding var serverAddress: String
    @State private var inputAddress = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Connect to Server")
                .font(.title2)
                .bold()
            TextField("Server Address", text: $inputAddress)
                .textFieldStyle(.roundedBorder)
                .padding()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Connect") {
                    serverAddress = inputAddress.isEmpty ? "Unknown Server" : inputAddress
                    isConnected = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

#Preview {
    ContentView()
        .navigationTitle("SwiftBSD")
}
