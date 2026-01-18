//
//  HelpView.swift
//  HexBSD
//
//  Help documentation for HexBSD
//

import SwiftUI

// MARK: - Help Topic Model

struct HelpTopic: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let icon: String
    let sections: [HelpSection]
}

struct HelpSection: Identifiable, Hashable {
    let id = UUID()
    let title: String?
    let content: [HelpContent]
}

enum HelpContent: Identifiable, Hashable {
    case paragraph(String)
    case bullet(String)
    case numbered(Int, String)
    case bold(String)
    case tip(String)
    case warning(String)

    var id: String {
        switch self {
        case .paragraph(let s): return "p-\(s.prefix(20))"
        case .bullet(let s): return "b-\(s.prefix(20))"
        case .numbered(let n, let s): return "n-\(n)-\(s.prefix(20))"
        case .bold(let s): return "bold-\(s.prefix(20))"
        case .tip(let s): return "tip-\(s.prefix(20))"
        case .warning(let s): return "warn-\(s.prefix(20))"
        }
    }
}

// MARK: - Help Data

struct HelpData {
    static let topics: [HelpTopic] = [
        gettingStarted,
        dashboard,
        files,
        jails,
        logs,
        network,
        packages,
        poudriere,
        security,
        services,
        tasks,
        terminal,
        usersAndGroups,
        zfs,
        troubleshooting
    ]

    static let gettingStarted = HelpTopic(
        title: "Getting Started",
        icon: "play.circle",
        sections: [
            HelpSection(title: "Connecting to a Server", content: [
                .numbered(1, "Launch HexBSD - you'll see your saved servers list (or an empty state if none configured)"),
                .numbered(2, "Click the + button in the bottom-right corner"),
                .numbered(3, "Enter your connection details:"),
                .bullet("Server Name: A friendly name for the server (optional)"),
                .bullet("Server Address: Hostname or IP address"),
                .bullet("Port: SSH port (default: 22)"),
                .bullet("Username: SSH user account (root recommended for full functionality)"),
                .bullet("SSH Private Key: Click to select your private key file"),
                .numbered(4, "Click Connect"),
                .numbered(5, "On successful connection, you'll be prompted to save the server for quick access")
            ]),
            HelpSection(title: "Supported Key Types", content: [
                .bullet("Ed25519 (recommended)"),
                .bullet("RSA (PKCS#1 or OpenSSH format)"),
                .bullet("ECDSA P256"),
                .warning("Password authentication is not supported - only SSH key-based authentication.")
            ]),
            HelpSection(title: "Saved Servers", content: [
                .paragraph("Saved servers appear in the main list with online/offline status indicators."),
                .bullet("Green dot = Online"),
                .bullet("Red dot = Offline"),
                .bullet("Click Connect to quickly connect to a saved server"),
                .bullet("Click Remove to delete a saved server configuration")
            ])
        ]
    )

    static let dashboard = HelpTopic(
        title: "Dashboard",
        icon: "chart.bar",
        sections: [
            HelpSection(title: nil, content: [
                .paragraph("The Dashboard provides real-time system monitoring with auto-refresh every 5 seconds:"),
                .bullet("CPU Usage: Per-core usage visualization with circular progress indicators"),
                .bullet("Memory: Combined memory and ZFS ARC cache usage"),
                .bullet("Disk I/O: Per-disk activity monitoring with read/write rates"),
                .bullet("Swap Usage: System swap statistics"),
                .bullet("Network I/O: Per-interface traffic rates (inbound/outbound)"),
                .bullet("Storage: Root filesystem usage")
            ])
        ]
    )

    static let files = HelpTopic(
        title: "Files",
        icon: "folder",
        sections: [
            HelpSection(title: nil, content: [
                .paragraph("A dual-pane file manager for transferring files between your Mac and the remote server.")
            ]),
            HelpSection(title: "Navigation", content: [
                .bullet("Left pane: Local filesystem (your Mac)"),
                .bullet("Right pane: Remote filesystem (FreeBSD server)"),
                .bullet("Use the Up button or breadcrumb path to navigate"),
                .bullet("Click Home to return to home directory")
            ]),
            HelpSection(title: "File Operations", content: [
                .bullet("Transfer files: Drag and drop between panes, or select and click transfer button"),
                .bullet("Create directory: Click the folder+ icon"),
                .bullet("Rename: Right-click and select Rename"),
                .bullet("Delete: Right-click and select Delete (with confirmation)")
            ]),
            HelpSection(title: "Transfer Progress", content: [
                .paragraph("Progress bar shows transfer status with percentage and speed."),
                .tip("Click Cancel to stop an in-progress transfer.")
            ])
        ]
    )

    static let jails = HelpTopic(
        title: "Jails",
        icon: "building.2",
        sections: [
            HelpSection(title: nil, content: [
                .paragraph("Manage FreeBSD jails (lightweight containers) with full vNET networking support.")
            ]),
            HelpSection(title: "Prerequisites", content: [
                .paragraph("Before creating jails, you need:"),
                .numbered(1, "Network Bridge: At least one bridge must exist (create in Network section)"),
                .numbered(2, "Jail Directory: ZFS dataset or UFS directory for jail storage"),
                .numbered(3, "Templates: For thin jails, at least one FreeBSD template with snapshot")
            ]),
            HelpSection(title: "Creating a Jail", content: [
                .bold("Step 1 - Basic Information:"),
                .bullet("Enter jail name and hostname"),
                .bullet("Choose jail type:"),
                .bullet("  Thin (ZFS Clone): Fast, space-efficient, uses template"),
                .bullet("  Thick (ZFS Dataset): Full base system, independent updates"),
                .bullet("Select template (thin) or FreeBSD version (thick)"),
                .bold("Step 2 - Network:"),
                .bullet("Choose IP mode: DHCP or Static"),
                .bullet("Select network bridge"),
                .bullet("Enter static IP if applicable (e.g., 192.168.1.100/24)"),
                .bold("Step 3 - Review:"),
                .bullet("Verify configuration and create jail")
            ]),
            HelpSection(title: "Managing Jails", content: [
                .bullet("Start/Stop/Restart: Use action buttons for running state control"),
                .bullet("Console: Open terminal shell into running jail"),
                .bullet("Configure: Edit jail.conf for advanced settings"),
                .bullet("Delete: Remove jail (must be stopped first)")
            ]),
            HelpSection(title: "Templates", content: [
                .paragraph("Create templates by downloading FreeBSD base system. Templates enable fast thin jail creation."),
                .paragraph("Available versions are fetched automatically from FreeBSD release servers.")
            ])
        ]
    )

    static let logs = HelpTopic(
        title: "Logs",
        icon: "doc.text",
        sections: [
            HelpSection(title: nil, content: [
                .paragraph("View and search system log files in real-time.")
            ]),
            HelpSection(title: "Features", content: [
                .bullet("Log List: Shows all files in /var/log with icons by type"),
                .bullet("Live Streaming: Tail -f style real-time updates"),
                .bullet("Line Count: View last 100, 500, 1000, or all lines"),
                .bullet("Search: Search across all logs or within current log"),
                .bullet("Export: Save log contents to local file")
            ]),
            HelpSection(title: "Search", content: [
                .bullet("Enter search term to filter log entries"),
                .bullet("Matching lines highlighted in orange"),
                .bullet("Match count displayed per file"),
                .bullet("Click a file to view matching content")
            ])
        ]
    )

    static let network = HelpTopic(
        title: "Network",
        icon: "network",
        sections: [
            HelpSection(title: nil, content: [
                .paragraph("Comprehensive network management across three tabs.")
            ]),
            HelpSection(title: "Interfaces Tab", content: [
                .bullet("View all network interfaces with status (Up/Down/No Carrier)"),
                .bullet("See IP addresses, MAC addresses, and traffic statistics"),
                .bullet("Configure: Set static IP or enable DHCP"),
                .bullet("Bring Up/Down: Enable or disable interfaces"),
                .bullet("Destroy: Remove virtual interfaces (bridges, TAP, etc.)")
            ]),
            HelpSection(title: "Bridges Tab", content: [
                .bullet("Create Bridge: Combine multiple interfaces into a bridge"),
                .bullet("  - Select member interfaces"),
                .bullet("  - Configure IP (static or inherit from member)"),
                .bullet("  - Enable/disable Spanning Tree Protocol (STP)"),
                .bullet("Manage Members: Add or remove interfaces from bridges"),
                .bullet("Delete Bridge: Remove bridge configuration")
            ]),
            HelpSection(title: "Routing Tab", content: [
                .bullet("View IPv4 and IPv6 routing tables"),
                .bullet("Add Route: Create static routes with destination CIDR and gateway"),
                .bullet("Delete Route: Remove custom routes (default routes protected)"),
                .paragraph("Route flags: U=Up, G=Gateway, H=Host, S=Static")
            ])
        ]
    )

    static let packages = HelpTopic(
        title: "Packages",
        icon: "shippingbox.fill",
        sections: [
            HelpSection(title: nil, content: [
                .paragraph("Full package management for FreeBSD pkg system.")
            ]),
            HelpSection(title: "Tabs", content: [
                .bullet("Installed: All currently installed packages"),
                .bullet("Upgradable: Packages with available updates"),
                .bullet("Available: Search and install new packages")
            ]),
            HelpSection(title: "Operations", content: [
                .bullet("Install: Select from Available tab and click Install"),
                .bullet("Remove: Select installed package and click Remove (with safety checks)"),
                .bullet("Upgrade: Update individual packages or all at once")
            ]),
            HelpSection(title: "Repository Management", content: [
                .bullet("Switch Repo: Change between Quarterly (stable) and Latest (bleeding edge)"),
                .bullet("Custom Repository: Use your own package server (e.g., Poudriere builds)"),
                .bullet("Mirror Selection: Choose from available FreeBSD mirrors")
            ]),
            HelpSection(title: "Package Information", content: [
                .bullet("View description, size, license, maintainer, website"),
                .bullet("See dependencies and reverse dependencies"),
                .bullet("Repository source with color-coded badges")
            ]),
            HelpSection(title: "Cache Management", content: [
                .bullet("View cache size and package count"),
                .bullet("Clean Cache: Remove cached package files to free disk space")
            ])
        ]
    )

    static let poudriere = HelpTopic(
        title: "Poudriere",
        icon: "shippingbox",
        sections: [
            HelpSection(title: nil, content: [
                .paragraph("Build custom FreeBSD packages from ports.")
            ]),
            HelpSection(title: "Setup", content: [
                .numbered(1, "Click Install Poudriere (also installs Git)"),
                .numbered(2, "Configure storage settings (ZFS or UFS mode)"),
                .numbered(3, "Create at least one jail and ports tree")
            ]),
            HelpSection(title: "Jails", content: [
                .paragraph("Build jails are isolated environments for compiling packages:"),
                .bullet("Create: Select FreeBSD version and architecture"),
                .bullet("Update: Refresh base system in existing jails"),
                .bullet("Delete: Remove jail configuration")
            ]),
            HelpSection(title: "Ports Trees", content: [
                .paragraph("Source code repositories for building packages:"),
                .bullet("Create: Clone from Git with branch selection (main, quarterly)"),
                .bullet("Update: Pull latest changes"),
                .bullet("Delete: Remove ports tree")
            ]),
            HelpSection(title: "Building Packages", content: [
                .bullet("Build All: Compile entire ports tree"),
                .bullet("From File: Build packages listed in a file"),
                .bullet("Specific Packages: Enter package names to build"),
                .bold("Options:"),
                .bullet("Select target jail and ports tree"),
                .bullet("Enable Clean build to force rebuild"),
                .bullet("Enable Test build to build without committing")
            ]),
            HelpSection(title: "Configuration", content: [
                .bullet("Storage mode (ZFS/UFS) and pool selection"),
                .bullet("FreeBSD mirror for downloads"),
                .bullet("Build parallelism (make jobs)"),
                .bullet("Cache paths for distfiles")
            ]),
            HelpSection(title: "Build Status", content: [
                .bullet("Web-based dashboard shows build progress"),
                .bullet("View success/failure statistics"),
                .bullet("Monitor running builds")
            ])
        ]
    )

    static let security = HelpTopic(
        title: "Security",
        icon: "shield.lefthalf.filled",
        sections: [
            HelpSection(title: nil, content: [
                .paragraph("Three integrated security management areas.")
            ]),
            HelpSection(title: "Audit Tab", content: [
                .bullet("Scan for known vulnerabilities using VuXML database"),
                .bullet("View CVE IDs with severity levels (Critical, High, Medium, Low)"),
                .bullet("Color-coded severity indicators"),
                .bullet("Detailed vulnerability information and remediation steps"),
                .bullet("Export audit results")
            ]),
            HelpSection(title: "Connections Tab", content: [
                .paragraph("Live network connection monitoring showing user, command, PID, protocol, addresses, and ports."),
                .paragraph("Connection state with color coding:"),
                .bullet("Green = ESTABLISHED"),
                .bullet("Blue = LISTEN"),
                .bullet("Orange = Waiting states"),
                .bullet("Red = Closed states"),
                .paragraph("Filter by protocol (TCP, UDP, IPv4, IPv6). Auto-refresh every 3 seconds.")
            ]),
            HelpSection(title: "Firewall Tab (ipfw)", content: [
                .bullet("Enable/disable firewall"),
                .bullet("Common service templates (SSH, HTTP, HTTPS, databases, etc.)"),
                .bullet("Add custom port rules"),
                .bullet("Protected ports (SSH always protected)"),
                .bullet("Rule management with numbering system")
            ])
        ]
    )

    static let services = HelpTopic(
        title: "Services",
        icon: "gearshape.2",
        sections: [
            HelpSection(title: nil, content: [
                .paragraph("Manage FreeBSD services (rc.d scripts).")
            ]),
            HelpSection(title: "Viewing Services", content: [
                .bullet("Base System: Services from /etc/rc.d"),
                .bullet("Ports: Services from /usr/local/etc/rc.d"),
                .bullet("Filter by source, status, or search by name")
            ]),
            HelpSection(title: "Service Control", content: [
                .bullet("Start/Stop/Restart: Runtime control buttons"),
                .bullet("Enable/Disable: Configure boot-time behavior"),
                .paragraph("Status indicators: Running (green), Stopped (gray), Unknown (orange)")
            ]),
            HelpSection(title: "Configuration", content: [
                .bullet("Configure: Edit service configuration files"),
                .bullet("Save: Save changes to config file"),
                .bullet("Save & Restart: Save and apply changes immediately")
            ])
        ]
    )

    static let tasks = HelpTopic(
        title: "Tasks",
        icon: "clock",
        sections: [
            HelpSection(title: nil, content: [
                .paragraph("Manage scheduled tasks (cron jobs).")
            ]),
            HelpSection(title: "Creating Tasks", content: [
                .numbered(1, "Click Add Task"),
                .numbered(2, "Select frequency:"),
                .bullet("Every X minutes"),
                .bullet("Hourly (at specific minute)"),
                .bullet("Daily (at specific time)"),
                .bullet("Weekly (on specific day)"),
                .bullet("Monthly (on specific day)"),
                .numbered(3, "Enter command to execute"),
                .numbered(4, "Select user to run as"),
                .numbered(5, "Click Add Task")
            ]),
            HelpSection(title: "Managing Tasks", content: [
                .bullet("Edit: Modify existing task schedule or command"),
                .bullet("Enable/Disable: Toggle task without deleting"),
                .bullet("Delete: Remove task permanently")
            ]),
            HelpSection(title: "ZFS Replication Tasks", content: [
                .paragraph("Tasks created from ZFS replication are displayed with friendly details:"),
                .bullet("Source dataset and target server"),
                .bullet("Retention period (1 Hour, 1 Day, 1 Week, etc.)"),
                .bullet("Blue replication icon for easy identification")
            ])
        ]
    )

    static let terminal = HelpTopic(
        title: "Terminal",
        icon: "terminal",
        sections: [
            HelpSection(title: nil, content: [
                .paragraph("Full interactive SSH terminal with VT100/xterm-256color emulation."),
                .bullet("80x24 character terminal grid"),
                .bullet("Bidirectional I/O for interactive commands"),
                .bullet("Proper line handling and terminal modes")
            ])
        ]
    )

    static let usersAndGroups = HelpTopic(
        title: "Users & Groups",
        icon: "person.2",
        sections: [
            HelpSection(title: nil, content: [
                .paragraph("Manage local users, groups, and network domains.")
            ]),
            HelpSection(title: "Users Tab", content: [
                .bullet("View all users with UID, home directory, and shell"),
                .bullet("System users (UID < 1000) shown separately"),
                .bullet("Create new users with home directory and shell selection"),
                .bullet("Configure sudo access via wheel group")
            ]),
            HelpSection(title: "Groups Tab", content: [
                .bullet("View all groups with GID and member count"),
                .bullet("Create new groups"),
                .bullet("Manage group membership")
            ]),
            HelpSection(title: "Setup Tab", content: [
                .paragraph("Configure user environment:"),
                .bullet("Install and configure Zsh shell"),
                .bullet("Add Zsh autosuggestions and completions"),
                .bullet("Install and configure sudo"),
                .bullet("Set up shell prompts with Git information")
            ]),
            HelpSection(title: "Network Tab", content: [
                .paragraph("Configure NIS/NFS for network users:"),
                .bullet("Set domain role (Server, Client, None)"),
                .bullet("Configure NIS domain name"),
                .bullet("Manage network users and netgroups"),
                .bullet("Enable NFS (v3 or v4)")
            ]),
            HelpSection(title: "Sessions Tab", content: [
                .paragraph("Monitor active user sessions:"),
                .bullet("See logged-in users with TTY and login time"),
                .bullet("Track idle time"),
                .bullet("Identify remote vs local logins")
            ])
        ]
    )

    static let zfs = HelpTopic(
        title: "ZFS",
        icon: "cylinder.split.1x2",
        sections: [
            HelpSection(title: nil, content: [
                .paragraph("Comprehensive ZFS pool, dataset, and replication management.")
            ]),
            HelpSection(title: "Pools", content: [
                .bullet("Create Pool: Select disks and RAID level (Stripe, RAID-Z1/Z2/Z3)"),
                .bullet("Export/Destroy: Remove pools with confirmation"),
                .bullet("Scrub: Start/stop data integrity checks"),
                .bullet("Monitor health, capacity, and fragmentation")
            ]),
            HelpSection(title: "Datasets", content: [
                .bullet("Create Dataset: Set compression, quota, recordsize, mountpoint"),
                .bullet("Create ZVOL: Block devices for VMs with size and block size options"),
                .bullet("Properties: View and modify dataset settings"),
                .bullet("Delete: Remove datasets (protected datasets cannot be deleted)"),
                .tip("Protected Datasets: Root filesystem, boot environments, and critical system paths are protected from accidental deletion.")
            ]),
            HelpSection(title: "Snapshots", content: [
                .bullet("Create: Take point-in-time snapshots"),
                .bullet("Delete: Remove single or multiple snapshots"),
                .bullet("Rollback: Restore dataset to snapshot state"),
                .bullet("Clone: Create writable copy from snapshot")
            ]),
            HelpSection(title: "Replication", content: [
                .paragraph("Replicate datasets to remote servers:"),
                .bold("One-Time Replication:"),
                .bullet("Select source dataset and target server"),
                .bullet("Immediate snapshot and transfer"),
                .bold("Scheduled Replication:"),
                .numbered(1, "Select dataset and click Replicate To"),
                .numbered(2, "Choose target server and dataset"),
                .numbered(3, "Click Schedule to set up recurring replication"),
                .numbered(4, "Configure frequency (minutes, hourly, daily, weekly, monthly)"),
                .numbered(5, "Set retention period: Forever, 1 Hour, 1 Day, 1 Week, 1 Month, 3 Months, 1 Year"),
                .numbered(6, "Old snapshots automatically pruned based on retention"),
                .bold("SSH Key Setup:"),
                .bullet("Replication uses dedicated SSH key (id_replication)"),
                .bullet("Key automatically generated if not present"),
                .bullet("Public key must be added to target server")
            ]),
            HelpSection(title: "Boot Environments", content: [
                .bullet("View all boot environments"),
                .bullet("Create: New BE from existing"),
                .bullet("Activate: Set as next boot target"),
                .bullet("Rename: Change BE name (inactive only)"),
                .bullet("Delete: Remove BE (inactive only)")
            ])
        ]
    )

    static let troubleshooting = HelpTopic(
        title: "Troubleshooting",
        icon: "wrench.and.screwdriver",
        sections: [
            HelpSection(title: "Connection Issues", content: [
                .bullet("Verify server is reachable (ping test)"),
                .bullet("Check SSH key permissions (should be 600)"),
                .bullet("Ensure SSH key type is supported (Ed25519, RSA, ECDSA)"),
                .bullet("Verify username has SSH access")
            ]),
            HelpSection(title: "Permission Errors", content: [
                .bullet("Many operations require root access"),
                .bullet("Consider connecting as root or user with sudo privileges")
            ]),
            HelpSection(title: "Replication Not Working", content: [
                .bullet("Verify SSH key (id_replication) exists on source server"),
                .bullet("Ensure public key is in target's authorized_keys"),
                .bullet("Check target dataset exists and is writable"),
                .bullet("Verify network connectivity between servers")
            ]),
            HelpSection(title: "Services Won't Start", content: [
                .bullet("Check service configuration file for errors"),
                .bullet("View service logs for detailed error messages"),
                .bullet("Ensure dependencies are running")
            ])
        ]
    )
}

// MARK: - Help Content View

struct HelpContentView: View {
    let content: HelpContent

    var body: some View {
        switch content {
        case .paragraph(let text):
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .foregroundColor(.secondary)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 8)
        case .numbered(let num, let text):
            HStack(alignment: .top, spacing: 8) {
                Text("\(num).")
                    .foregroundColor(.secondary)
                    .frame(width: 20, alignment: .trailing)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 8)
        case .bold(let text):
            Text(text)
                .fontWeight(.semibold)
                .padding(.top, 4)
        case .tip(let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb")
                    .foregroundColor(.yellow)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.yellow.opacity(0.1))
            .cornerRadius(6)
        case .warning(let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(6)
        }
    }
}

// MARK: - Help Section View

struct HelpSectionView: View {
    let section: HelpSection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = section.title {
                Text(title)
                    .font(.headline)
                    .padding(.top, 8)
            }

            ForEach(section.content) { content in
                HelpContentView(content: content)
            }
        }
    }
}

// MARK: - Help Topic Detail View

struct HelpTopicDetailView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: topic.icon)
                        .font(.system(size: 32))
                        .foregroundColor(.accentColor)
                    Text(topic.title)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                }
                .padding(.bottom, 8)

                Divider()

                // Sections
                ForEach(topic.sections) { section in
                    HelpSectionView(section: section)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Main Help View

struct HelpView: View {
    @State private var selectedTopic: HelpTopic? = HelpData.topics.first
    @State private var searchText = ""

    var filteredTopics: [HelpTopic] {
        if searchText.isEmpty {
            return HelpData.topics
        }
        return HelpData.topics.filter { topic in
            topic.title.localizedCaseInsensitiveContains(searchText) ||
            topic.sections.contains { section in
                section.content.contains { content in
                    switch content {
                    case .paragraph(let text), .bullet(let text), .numbered(_, let text),
                         .bold(let text), .tip(let text), .warning(let text):
                        return text.localizedCaseInsensitiveContains(searchText)
                    }
                }
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filteredTopics, selection: $selectedTopic) { topic in
                Label(topic.title, systemImage: topic.icon)
                    .tag(topic)
            }
            .listStyle(.sidebar)
            .navigationTitle("Help")
            .searchable(text: $searchText, prompt: "Search Help")
        } detail: {
            if let topic = selectedTopic {
                HelpTopicDetailView(topic: topic)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    Text("Select a topic")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}

// MARK: - Help Window Command

struct HelpWindowCommand: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("HexBSD Help") {
                openHelpWindow()
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }

    private func openHelpWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "HexBSD Help"
        window.contentView = NSHostingView(rootView: HelpView())
        window.makeKeyAndOrderFront(nil)
    }
}

#Preview {
    HelpView()
}
