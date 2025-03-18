//
//  ContentView.swift
//  SwiftBSD
//
//  Created by Joseph Maloney on 3/17/25.
//

import SwiftUI

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

struct DetailView: View {
    let section: SidebarSection
    let serverAddress: String

    var body: some View {
        VStack {
            if section == .network {
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
