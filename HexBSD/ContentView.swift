//
//  ContentView.swift
//  HexBSD
//
//  Created by Joseph Maloney on 3/17/25.
//

import SwiftUI
import Foundation
import Combine
import Network
#if os(macOS)
import AppKit
#endif

/// Thread-safe helper for resuming a continuation only once
private final class HostReachabilityResumeState: @unchecked Sendable {
    private var hasResumed = false
    private let lock = NSLock()

    func resumeOnce(with result: Bool, continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if !hasResumed {
            hasResumed = true
            continuation.resume(returning: result)
        }
    }
}

struct NetworkInterface {
    let name: String
    let inRate: String
    let outRate: String
}

struct DiskIO {
    let name: String
    let readMBps: Double
    let writeMBps: Double
    let totalMBps: Double  // Combined for visualization
}

struct SystemStatus {
    let cpuUsage: String
    let cpuCores: [Double]  // Per-core CPU usage percentages
    let memoryUsage: String
    let zfsArcUsage: String
    let swapUsage: String
    let storageUsage: String
    let uptime: String
    let disks: [DiskIO]  // Per-disk I/O stats
    let networkInterfaces: [NetworkInterface]

    // Helper to extract percentage from cpuUsage string
    var cpuPercentage: Double {
        let cleaned = cpuUsage.replacingOccurrences(of: "%", with: "")
        return Double(cleaned) ?? 0
    }

    // Helper to extract memory usage percentage
    var memoryPercentage: Double {
        let parts = memoryUsage.split(separator: "/")
        guard parts.count == 2,
              let used = Double(parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: "")),
              let total = Double(parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: ""))
        else { return 0 }
        return total > 0 ? (used / total) * 100 : 0
    }

    // Helper to extract storage usage percentage
    var storagePercentage: Double {
        let parts = storageUsage.split(separator: "/")
        guard parts.count == 2,
              let used = Double(parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: "")),
              let total = Double(parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: ""))
        else { return 0 }
        return total > 0 ? (used / total) * 100 : 0
    }

    // Helper to extract ZFS ARC usage percentage
    var arcPercentage: Double {
        let parts = zfsArcUsage.split(separator: "/")
        guard parts.count == 2,
              let used = Double(parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: "")),
              let total = Double(parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: ""))
        else { return 0 }
        return total > 0 ? (used / total) * 100 : 0
    }

    // Helper to extract swap usage percentage
    var swapPercentage: Double {
        let parts = swapUsage.split(separator: "/")
        guard parts.count == 2,
              let used = Double(parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: "")),
              let total = Double(parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: ""))
        else { return 0 }
        return total > 0 ? (used / total) * 100 : 0
    }
}

// MARK: - Dashboard Components

struct CircularProgressView: View {
    let progress: Double // 0-100
    let color: Color
    let lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)

            // Progress circle
            Circle()
                .trim(from: 0, to: min(progress / 100, 1.0))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: progress)

            // Percentage text
            Text(String(format: "%.0f%%", progress))
                .font(.system(size: 24, weight: .bold))
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let progress: Double?
    let color: Color
    let systemImage: String

    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundColor(color)
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }

            if let progress = progress {
                CircularProgressView(progress: progress, color: color)
                    .frame(width: 120, height: 120)

                Text(value)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(value)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            Spacer(minLength: 0) // Push content to top
        }
        .frame(height: 200) // Fixed height to match all cards
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
        )
    }
}

struct MemoryARCCard: View {
    let memoryUsage: String
    let memoryPercentage: Double
    let arcUsage: String
    let arcPercentage: Double
    let color: Color

    // Calculate ARC as percentage of total system memory
    private var arcPercentageOfTotal: Double {
        // Parse the usage strings to get values
        let memParts = memoryUsage.split(separator: "/")
        let arcParts = arcUsage.split(separator: "/")

        guard memParts.count == 2, arcParts.count == 2,
              let memTotal = Double(memParts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: "")),
              let arcUsed = Double(arcParts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " GB", with: ""))
        else {
            print("DEBUG: Failed to parse memory/ARC strings")
            print("DEBUG: memoryUsage = '\(memoryUsage)'")
            print("DEBUG: arcUsage = '\(arcUsage)'")
            return 0
        }

        let arcPct = memTotal > 0 ? (arcUsed / memTotal) * 100 : 0
        print("DEBUG: memTotal=\(memTotal) GB, arcUsed=\(arcUsed) GB, arcPct=\(arcPct)%")
        return arcPct
    }

    // Non-ARC memory is the total memory percentage minus ARC portion
    private var memoryOnlyPercentage: Double {
        let result = max(0, memoryPercentage - arcPercentageOfTotal)
        print("DEBUG: memoryPercentage=\(memoryPercentage)%, arcPercentageOfTotal=\(arcPercentageOfTotal)%, memoryOnly=\(result)%")
        return result
    }

    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Image(systemName: "memorychip")
                    .font(.title2)
                    .foregroundColor(color)
                Text("Memory")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }

            // Single circle showing stacked memory usage
            ZStack {
                // Background circle
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 12)

                // Non-ARC memory (green) - starts at 0
                Circle()
                    .trim(from: 0, to: min(memoryOnlyPercentage / 100, 1.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: memoryOnlyPercentage)

                // ARC memory (purple) - stacks on top of green
                Circle()
                    .trim(from: memoryOnlyPercentage / 100, to: min((memoryOnlyPercentage + arcPercentageOfTotal) / 100, 1.0))
                    .stroke(Color.purple, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: arcPercentageOfTotal)

                // Center text showing total percentage
                VStack(spacing: 2) {
                    Text(String(format: "%.0f%%", memoryPercentage))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.primary)
                    Text("used")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 120, height: 120)

            // ARC usage label
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.purple)
                    .frame(width: 8, height: 8)
                Text("ARC: \(arcUsage)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0) // Push content to top
        }
        .frame(height: 200) // Fixed height to match all cards
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
        )
    }
}

struct DiskIOCard: View {
    let disks: [DiskIO]
    let color: Color

    // Calculate optimal grid layout to maximize horizontal space usage
    private func calculateGridLayout(availableWidth: CGFloat) -> (columns: Int, circleSize: CGFloat, spacing: CGFloat) {
        let diskCount = disks.count
        let maxHeight: CGFloat = 120 // Fixed height to match other cards

        guard diskCount > 0 else {
            return (1, 120, 0)
        }

        // Special case: single disk - use full size
        if diskCount == 1 {
            return (1, 120, 0)
        }

        // Try different column counts and find the one that maximizes circle size
        var bestLayout: (columns: Int, circleSize: CGFloat, spacing: CGFloat) = (1, 0, 0)
        var bestCircleSize: CGFloat = 0

        let maxColumns = min(diskCount, 12)

        for cols in 1...maxColumns {
            let rows = Int(ceil(Double(diskCount) / Double(cols)))
            let spacing: CGFloat = cols <= 4 ? 8 : (cols <= 8 ? 5 : 3)

            let circleFromHeight = (maxHeight - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            let circleFromWidth = (availableWidth - CGFloat(cols - 1) * spacing) / CGFloat(cols)
            let circleSize = min(circleFromHeight, circleFromWidth)

            if circleSize >= 10 && circleSize > bestCircleSize {
                bestCircleSize = circleSize
                bestLayout = (cols, circleSize, spacing)
            }
        }

        return bestLayout
    }

    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Image(systemName: "internaldrive")
                    .font(.title2)
                    .foregroundColor(color)
                Text("Disk I/O")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }

            if disks.isEmpty {
                Text("No disks detected")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(height: 120)
            } else {
                GeometryReader { geometry in
                    let layout = calculateGridLayout(availableWidth: geometry.size.width)

                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.circleSize), spacing: layout.spacing), count: layout.columns), spacing: layout.spacing) {
                        ForEach(disks.indices, id: \.self) { index in
                            let disk = disks[index]
                            DiskCircle(disk: disk, size: layout.circleSize, color: color)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(height: 120)
            }

            Spacer(minLength: 0) // Push content to top
        }
        .frame(height: 200) // Fixed height to match all cards
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
        )
    }
}

struct DiskCircle: View {
    let disk: DiskIO
    let size: CGFloat
    let color: Color

    // Normalize activity to a 0-100 scale for visualization
    // Using a logarithmic scale since disk I/O can vary widely
    private var activityLevel: Double {
        let totalIO = disk.totalMBps
        // Scale: 0 MB/s = 0%, 100 MB/s = ~100%
        // Using log scale to better represent wide range of values
        if totalIO <= 0 { return 0 }
        let normalized = min(100, (log10(totalIO + 1) / log10(101)) * 100)
        return normalized
    }

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .stroke(color.opacity(0.2), lineWidth: max(2, size / 12))

            // Activity level circle
            Circle()
                .trim(from: 0, to: activityLevel / 100)
                .stroke(color, style: StrokeStyle(lineWidth: max(2, size / 12), lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: activityLevel)

            // Disk name (if space allows)
            if size > 40 {
                VStack(spacing: 2) {
                    Text(disk.name)
                        .font(.system(size: min(10, size / 6), weight: .medium))
                        .foregroundColor(.primary)
                    if size > 60 {
                        Text(String(format: "%.1f MB/s", disk.totalMBps))
                            .font(.system(size: min(8, size / 8)))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct NetworkInterfaceCard: View {
    let title: String
    let interfaces: [NetworkInterface]
    let color: Color
    let systemImage: String
    let direction: String // "in" or "out"

    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundColor(color)
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }

            if interfaces.isEmpty {
                Text("No interfaces")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(height: 120)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(interfaces, id: \.name) { interface in
                        HStack {
                            Text(interface.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                                .frame(width: 80, alignment: .leading)

                            Spacer()

                            Text(direction == "in" ? interface.inRate : interface.outRate)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(color)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(color.opacity(0.1))
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
        )
    }
}

struct CPUCoresCard: View {
    let cpuCores: [Double]
    let color: Color

    // Calculate optimal grid layout to maximize horizontal space usage
    private func calculateGridLayout(availableWidth: CGFloat) -> (columns: Int, circleSize: CGFloat, spacing: CGFloat) {
        let coreCount = cpuCores.count
        let maxHeight: CGFloat = 120 // Fixed height to match memory card

        guard coreCount > 0 else {
            return (1, 120, 0)
        }

        // Special case: single core - use full size like memory card
        if coreCount == 1 {
            return (1, 120, 0)
        }

        // Try different column counts and find the one that maximizes circle size
        var bestLayout: (columns: Int, circleSize: CGFloat, spacing: CGFloat) = (1, 0, 0)
        var bestCircleSize: CGFloat = 0

        // Try column counts from 1 to coreCount (or reasonable max)
        let maxColumns = min(coreCount, 12)

        for cols in 1...maxColumns {
            let rows = Int(ceil(Double(coreCount) / Double(cols)))

            // Calculate spacing based on density
            let spacing: CGFloat = cols <= 4 ? 8 : (cols <= 8 ? 5 : 3)

            // Calculate circle size based on height constraint
            let circleFromHeight = (maxHeight - CGFloat(rows - 1) * spacing) / CGFloat(rows)

            // Calculate circle size based on width constraint
            let circleFromWidth = (availableWidth - CGFloat(cols - 1) * spacing) / CGFloat(cols)

            // Use the smaller of the two to ensure it fits
            let circleSize = min(circleFromHeight, circleFromWidth)

            // Only consider if circles are reasonable size (at least 10px)
            if circleSize >= 10 && circleSize > bestCircleSize {
                bestCircleSize = circleSize
                bestLayout = (cols, circleSize, spacing)
            }
        }

        return bestLayout
    }

    var body: some View {
        VStack(spacing: 15) {
            HStack {
                Image(systemName: "cpu")
                    .font(.title2)
                    .foregroundColor(color)
                Text("CPU Usage")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }

            if cpuCores.isEmpty {
                // Show loading state - same size as when loaded
                CircularProgressView(progress: 0, color: color)
                    .frame(width: 120, height: 120)
                    .opacity(0.3)

                Text("Loading...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                // Use GeometryReader to get available width and calculate optimal layout
                GeometryReader { geometry in
                    let availableWidth = geometry.size.width
                    let layout = calculateGridLayout(availableWidth: availableWidth)
                    let columns = Array(repeating: GridItem(.fixed(layout.circleSize), spacing: layout.spacing), count: layout.columns)

                    VStack(spacing: 0) {
                        LazyVGrid(columns: columns, spacing: layout.spacing) {
                            ForEach(Array(cpuCores.enumerated()), id: \.offset) { index, usage in
                                ZStack {
                                    // Background circle
                                    Circle()
                                        .stroke(color.opacity(0.2), lineWidth: max(2, layout.circleSize / 10))

                                    // Progress circle
                                    Circle()
                                        .trim(from: 0, to: min(usage / 100, 1.0))
                                        .stroke(color, style: StrokeStyle(lineWidth: max(2, layout.circleSize / 10), lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                        .animation(.easeInOut(duration: 0.3), value: usage)

                                    // Core number (scale font based on circle size)
                                    if layout.circleSize >= 16 {
                                        Text("\(index)")
                                            .font(.system(size: max(6, layout.circleSize / 3.5), weight: .medium))
                                            .foregroundColor(.primary)
                                    }
                                }
                                .frame(width: layout.circleSize, height: layout.circleSize)
                                .help("Core \(index): \(String(format: "%.1f%%", usage))") // Tooltip on hover
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .frame(height: 120) // Match CircularProgressView height
                }
                .frame(height: 120)

                // Add matching caption space like MetricCard has
                Text("\(cpuCores.count) cores")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0) // Push content to top
        }
        .frame(height: 200) // Fixed height to match all cards
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
        )
    }
}

struct SavedServer: Identifiable, Codable {
    var id = UUID()
    let name: String
    let host: String
    let port: Int
    let username: String
    let keyPath: String  // Store the actual path instead of bookmark

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, keyPath
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case files = "Files"
    case jails = "Jails"
    case logs = "Logs"
    case network = "Network"
    case packages = "Packages"
    case poudriere = "Poudriere"
    case security = "Security"
    case services = "Services"
    case tasks = "Tasks"
    case terminal = "Terminal"
    case usersAndGroups = "Users & Groups"
    case zfs = "ZFS"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "chart.bar"
        case .files: return "folder"
        case .jails: return "building.2"
        case .logs: return "doc.text"
        case .network: return "network"
        case .packages: return "shippingbox.fill"
        case .poudriere: return "shippingbox"
        case .security: return "shield.lefthalf.filled"
        case .services: return "gearshape.2"
        case .tasks: return "clock"
        case .terminal: return "terminal"
        case .usersAndGroups: return "person.2"
        case .zfs: return "cylinder.split.1x2"
        }
    }
}

struct ContentView: View {
    @State private var selectedSection: SidebarSection?
    @State private var showConnectSheet = false
    @State private var showAbout = false
    @State private var savedServers: [SavedServer] = []
    @State private var selectedServer: SavedServer?
    @State private var isNavigationLocked = false  // Locks sidebar during long-running operations
    @State private var onlineServers: Set<String> = []  // Server IDs that are online
    @State private var hasCheckedServers = false  // True after initial check completes
    @State private var serverCheckTimer: Timer?

    // Unique ID for this window instance - used to scope notifications
    @State private var windowId = UUID()

    // Per-window SSH connection manager for independent server connections
    @State private var sshManager = SSHConnectionManager()

    // Real data from SSH
    @State private var systemStatus: SystemStatus?

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selectedSection) { section in
                NavigationLink(value: section) {
                    Label(section.rawValue, systemImage: section.icon)
                }
                .disabled(!sshManager.isConnected || isNavigationLocked)
            }
            .navigationTitle("\(sshManager.isConnected ? sshManager.serverName : "HexBSD")")

#if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
#endif
        } detail: {
            if let section = selectedSection, sshManager.isConnected {
                DetailView(
                    section: section,
                    serverName: sshManager.serverName,
                    systemStatus: systemStatus
                )
                .environment(\.windowID, windowId)
            } else {
                ZStack(alignment: .bottomTrailing) {
                    if savedServers.isEmpty {
                        VStack {
                            Spacer()
                            Text("No servers configured")
                                .foregroundColor(.secondary)
                            Text("Click + to add a server")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                            Spacer()
                        }
                    } else {
                        List(savedServers) { server in
                            let isOnline = onlineServers.contains(server.id.uuidString)
                            HStack {
                                // Online/offline indicator
                                if !hasCheckedServers {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 12, height: 12)
                                } else {
                                    Circle()
                                        .fill(isOnline ? Color.green : Color.red)
                                        .frame(width: 10, height: 10)
                                }

                                VStack(alignment: .leading) {
                                    Text(server.name)
                                        .font(.headline)
                                    HStack(spacing: 4) {
                                        Text("\(server.username)@\(server.host):\(server.port)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        if hasCheckedServers && !isOnline {
                                            Text("• offline")
                                                .font(.caption)
                                                .foregroundColor(.red)
                                        }
                                    }
                                }

                                Spacer()

                                Button("Connect") {
                                    connectToServer(server)
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Remove") {
                                    removeServer(server)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                        }
                        .onAppear {
                            Task {
                                await checkServersOnline()
                            }
                            // Recheck servers every 5 seconds
                            serverCheckTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                                Task {
                                    await checkServersOnline()
                                }
                            }
                        }
                        .onDisappear {
                            serverCheckTimer?.invalidate()
                            serverCheckTimer = nil
                        }
                    }

                    // Floating Add button in bottom-right corner
                    Button(action: {
                        selectedServer = nil
                        showConnectSheet.toggle()
                    }) {
                        Image(systemName: "plus")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.accentColor)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(20)
                }
            }
        }
        .sheet(isPresented: $showConnectSheet) {
            ConnectView(
                onConnected: {
                    loadDataFromServer()
                    // Navigate to status screen after connection
                    selectedSection = .dashboard
                },
                onServerSaved: { server in
                    savedServers.append(server)
                    saveServers()
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowAboutWindow"))) { _ in
            showAbout = true
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        .environment(\.sshManager, sshManager)
        .onAppear {
            loadSavedServers()
            // New windows always show the server list so users can connect to new servers
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            // Auto-refresh dashboard every 5 seconds if connected and viewing dashboard
            if sshManager.isConnected && selectedSection == .dashboard {
                loadDataFromServer()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTerminalWithCommand)) { notification in
            // Switch to terminal tab when jail console is requested
            print("DEBUG: ContentView received openTerminalWithCommand notification")
            if sshManager.isConnected {
                let wasNotOnTerminal = selectedSection != .terminal
                print("DEBUG: Switching to terminal section (was on terminal: \(!wasNotOnTerminal))")
                selectedSection = .terminal

                // Only re-post if we just switched to terminal tab (so TerminalContentView gets created)
                if wasNotOnTerminal, let command = notification.userInfo?["command"] as? String {
                    print("DEBUG: Will re-post command after terminal loads: \(command)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        print("DEBUG: Re-posting command notification")
                        NotificationCenter.default.post(
                            name: .openTerminalWithCommand,
                            object: nil,
                            userInfo: ["command": command]
                        )
                    }
                }
            } else {
                print("DEBUG: Not connected, cannot switch to terminal")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToNetworkBridges)) { _ in
            // Switch to network section when bridge creation is requested
            if sshManager.isConnected {
                let wasNotOnNetwork = selectedSection != .network
                selectedSection = .network

                // Re-post notification after NetworkContentView loads so it can switch to Bridges tab
                if wasNotOnNetwork {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(name: .navigateToNetworkBridges, object: nil)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sidebarNavigationLock)) { notification in
            // Lock/unlock sidebar navigation during long-running operations
            if let locked = notification.userInfo?["locked"] as? Bool {
                isNavigationLocked = locked
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTasks)) { _ in
            // Switch to tasks section after scheduling a task
            if sshManager.isConnected {
                selectedSection = .tasks
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToZFS)) { notification in
            // Only handle if this notification is for this window
            if let notificationWindowId = notification.userInfo?["windowId"] as? UUID,
               notificationWindowId != windowId {
                return
            }

            // Switch to ZFS section for pool setup
            if sshManager.isConnected {
                let wasNotOnZFS = selectedSection != .zfs
                selectedSection = .zfs

                // Re-post notification after ZFSContentView loads so it can open the pools sheet
                if wasNotOnZFS {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(name: .navigateToZFS, object: nil, userInfo: ["windowId": self.windowId])
                    }
                }
            }
        }
    }

    func loadSavedServers() {
        if let data = UserDefaults.standard.data(forKey: "savedServers"),
           let servers = try? JSONDecoder().decode([SavedServer].self, from: data) {
            savedServers = servers
        }
    }

    func saveServers() {
        if let data = try? JSONEncoder().encode(savedServers) {
            UserDefaults.standard.set(data, forKey: "savedServers")
        }
    }

    func removeServer(_ server: SavedServer) {
        savedServers.removeAll { $0.id == server.id }
        saveServers()
    }

    // Check connectivity to each saved server (quick TCP check)
    private func checkServersOnline() async {
        var online: Set<String> = []

        await withTaskGroup(of: (String, Bool).self) { group in
            for server in savedServers {
                group.addTask {
                    let isOnline = await self.checkHostReachable(host: server.host, port: server.port)
                    return (server.id.uuidString, isOnline)
                }
            }

            for await (serverId, isOnline) in group {
                if isOnline {
                    online.insert(serverId)
                }
            }
        }

        await MainActor.run {
            onlineServers = online
            hasCheckedServers = true
        }
    }

    private func checkHostReachable(host: String, port: Int) async -> Bool {
        return await withCheckedContinuation { continuation in
            let state = HostReachabilityResumeState()

            let socket = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )

            socket.stateUpdateHandler = { socketState in
                switch socketState {
                case .ready:
                    socket.cancel()
                    state.resumeOnce(with: true, continuation: continuation)
                case .failed, .cancelled:
                    state.resumeOnce(with: false, continuation: continuation)
                default:
                    break
                }
            }

            socket.start(queue: .global())

            // Timeout after 2 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                socket.cancel()
                state.resumeOnce(with: false, continuation: continuation)
            }
        }
    }

    func connectToServer(_ server: SavedServer) {
        Task {
            do {
                // Use the saved key path directly (relying on entitlements for access)
                let keyURL = URL(fileURLWithPath: server.keyPath)

                // Verify the key file still exists
                guard FileManager.default.fileExists(atPath: server.keyPath) else {
                    print("SSH key file not found at: \(server.keyPath)")
                    return
                }

                let authMethod = SSHAuthMethod(username: server.username, privateKeyURL: keyURL)

                try await sshManager.connect(host: server.host, port: server.port, authMethod: authMethod)

                // Validate that server is running FreeBSD
                try await sshManager.validateFreeBSD()

                // Set the server name for display in window titles
                // Use host as fallback for older saved servers that might have empty names
                await MainActor.run {
                    sshManager.serverName = server.name.isEmpty ? server.host : server.name
                }

                await MainActor.run {
                    loadDataFromServer()
                    // Navigate to status screen after successful connection
                    selectedSection = .dashboard
                }
            } catch {
                // Disconnect if connection or validation failed
                await sshManager.disconnect()
                print("Connection failed: \(error.localizedDescription)")
            }
        }
    }

    func loadDataFromServer() {
        Task {
            do {
                let status = try await sshManager.fetchSystemStatus()
                await MainActor.run {
                    self.systemStatus = status
                }
            } catch {
                print("Error loading system status: \(error.localizedDescription)")
            }
        }
    }
}

struct DetailView: View {
    let section: SidebarSection
    let serverName: String
    let systemStatus: SystemStatus?

    var body: some View {
        VStack {
            if section == .dashboard {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let systemStatus = systemStatus {
                            // Row 1: CPU and Memory/ARC
                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: 20),
                                GridItem(.flexible(), spacing: 20)
                            ], spacing: 20) {
                                // Always use CPUCoresCard for per-core display
                                CPUCoresCard(
                                    cpuCores: systemStatus.cpuCores,
                                    color: .blue
                                )

                                MemoryARCCard(
                                    memoryUsage: systemStatus.memoryUsage,
                                    memoryPercentage: systemStatus.memoryPercentage,
                                    arcUsage: systemStatus.zfsArcUsage,
                                    arcPercentage: systemStatus.arcPercentage,
                                    color: .green
                                )
                            }

                            // Row 2: Disk I/O and Swap
                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: 20),
                                GridItem(.flexible(), spacing: 20)
                            ], spacing: 20) {
                                DiskIOCard(
                                    disks: systemStatus.disks,
                                    color: .orange
                                )

                                MetricCard(
                                    title: "Swap",
                                    value: systemStatus.swapUsage,
                                    progress: systemStatus.swapPercentage,
                                    color: .red,
                                    systemImage: "arrow.left.arrow.right"
                                )
                            }

                            // Row 3: Network Traffic by Interface
                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: 20),
                                GridItem(.flexible(), spacing: 20)
                            ], spacing: 20) {
                                NetworkInterfaceCard(
                                    title: "Network In",
                                    interfaces: systemStatus.networkInterfaces,
                                    color: .teal,
                                    systemImage: "arrow.down.circle",
                                    direction: "in"
                                )

                                NetworkInterfaceCard(
                                    title: "Network Out",
                                    interfaces: systemStatus.networkInterfaces,
                                    color: .indigo,
                                    systemImage: "arrow.up.circle",
                                    direction: "out"
                                )
                            }

                        } else {
                            VStack(spacing: 20) {
                                ProgressView()
                                    .scaleEffect(1.5)
                                Text("Loading system status...")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(100)
                        }
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if section == .files {
                // Files browser view
                FilesContentView()
            } else if section == .usersAndGroups {
                // Users and Groups management
                UsersAndGroupsView()
            } else if section == .jails {
                // Jails management
                JailsContentView()
            } else if section == .logs {
                // Logs viewer
                LogsContentView()
            } else if section == .packages {
                // Package management
                PackagesContentView()
            } else if section == .poudriere {
                // Poudriere build status viewer
                PoudriereContentView()
            } else if section == .network {
                // Network interface management
                NetworkContentView()
            } else if section == .security {
                // Security vulnerability scanner
                SecurityContentView()
            } else if section == .services {
                // FreeBSD service management
                ServicesContentView()
            } else if section == .tasks {
                // Cron task scheduler and viewer
                TasksContentView()
            } else if section == .terminal {
                // Terminal view handled separately with its own coordinator
                TerminalContentView()
            } else if section == .zfs {
                // ZFS pool and dataset management
                ZFSContentView()
            } else {
                Text(section.rawValue)
                    .font(.largeTitle)
                    .bold()
            }
            Spacer()
        }
        .padding()
        .navigationTitle("\(serverName) - \(section.rawValue)")
    }
}

// MARK: - Connect View
struct ConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sshManager) private var sshManager
    let onConnected: () -> Void
    let onServerSaved: (SavedServer) -> Void

    @State private var serverName = ""
    @State private var inputAddress = ""
    @State private var username = ""
    @State private var port = "22"
    @State private var selectedKeyURL: URL?
    @State private var selectedKeyPath: String = "No key selected"
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showSavePrompt = false
    @State private var pendingServer: SavedServer?

    var body: some View {
        VStack(spacing: 16) {
            Text("Connect to FreeBSD Server")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 8) {
                Text("Server Name")
                    .font(.caption)
                TextField("My FreeBSD Server", text: $serverName)
                    .textFieldStyle(.roundedBorder)

                Text("Server Address")
                    .font(.caption)
                TextField("hostname or IP", text: $inputAddress)
                    .textFieldStyle(.roundedBorder)

                Text("Port")
                    .font(.caption)
                TextField("22", text: $port)
                    .textFieldStyle(.roundedBorder)

                Text("Username")
                    .font(.caption)
                TextField("username", text: $username)
                    .textFieldStyle(.roundedBorder)

                // Warning for non-root users
                if !username.isEmpty && username.lowercased() != "root" {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Not using root account")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.orange)
                            Text("Some features and content that require elevated privileges will not be available. See Help for details.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

                Text("SSH Private Key")
                    .font(.caption)
                HStack {
                    Text(selectedKeyPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button("Choose...") {
                        openFilePicker()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isConnecting)

                Button(isConnecting ? "Connecting..." : "Connect") {
                    connectToServer()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isConnecting || serverName.isEmpty || inputAddress.isEmpty || username.isEmpty || selectedKeyURL == nil)
            }
        }
        .padding()
        .frame(width: 450)
        .alert("Save Server?", isPresented: $showSavePrompt) {
            Button("Save") {
                if let server = pendingServer {
                    onServerSaved(server)
                }
                onConnected()
                dismiss()
            }
            Button("Don't Save") {
                onConnected()
                dismiss()
            }
        } message: {
            Text("Would you like to save this server configuration for quick access next time?")
        }
    }

    private func openFilePicker() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.message = "Select your SSH private key"

        // Start in the .ssh directory if it exists
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let sshURL = homeURL.appendingPathComponent(".ssh")
        if FileManager.default.fileExists(atPath: sshURL.path) {
            panel.directoryURL = sshURL
        }

        panel.begin { response in
            if response == .OK, let url = panel.url {
                selectedKeyURL = url
                selectedKeyPath = url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            }
        }
        #endif
    }

    private func resolveHostname(_ hostname: String) async -> String? {
        // Try to resolve hostname to IP address to work around sandbox DNS issues
        // If it's already an IP, this will return it unchanged
        return await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_INET  // IPv4
            hints.ai_socktype = SOCK_STREAM

            var result: UnsafeMutablePointer<addrinfo>?

            guard getaddrinfo(hostname, nil, &hints, &result) == 0,
                  let addrInfo = result else {
                return nil
            }

            defer { freeaddrinfo(result) }

            var addr = addrInfo.pointee.ai_addr.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

            if getnameinfo(&addr, addrInfo.pointee.ai_addrlen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: hostname)
            }

            return nil
        }.value
    }

    private func connectToServer() {
        guard let keyURL = selectedKeyURL else {
            errorMessage = "Please select an SSH private key"
            return
        }

        isConnecting = true
        errorMessage = nil

        Task {
            do {
                let portInt = Int(port) ?? 22

                // Try to resolve hostname to IP to work around sandbox DNS issues
                var hostToConnect = inputAddress
                if let resolvedIP = await resolveHostname(inputAddress) {
                    print("DEBUG: Resolved \(inputAddress) to \(resolvedIP)")
                    hostToConnect = resolvedIP
                }

                let authMethod = SSHAuthMethod(username: username, privateKeyURL: keyURL)

                try await sshManager.connect(host: hostToConnect, port: portInt, authMethod: authMethod)

                // Validate that server is running FreeBSD
                try await sshManager.validateFreeBSD()

                // Set the server name for display in window titles
                await MainActor.run {
                    sshManager.serverName = serverName
                }

                // Connection successful - prompt to save server
                await MainActor.run {
                    // Create pending server for save prompt
                    if let keyURL = selectedKeyURL {
                        pendingServer = SavedServer(
                            name: serverName,
                            host: inputAddress,
                            port: portInt,
                            username: username,
                            keyPath: keyURL.path
                        )
                        showSavePrompt = true
                    } else {
                        // No key selected, just connect without saving
                        onConnected()
                        dismiss()
                    }
                }
            } catch {
                // Disconnect if connection or validation failed
                await sshManager.disconnect()

                await MainActor.run {
                    errorMessage = "Connection failed: \(error.localizedDescription)"
                    isConnecting = false
                }
            }
        }
    }
}

// MARK: - About View
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("HexBSD")
                .font(.largeTitle)
                .bold()

            Text("Version 1.0")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Open Source Acknowledgments")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Citadel")
                            .font(.headline)

                        Text("Swift SSH Client")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("Copyright (c) Orlandos Technologies")
                            .font(.caption)

                        Link("https://github.com/orlandos-nl/Citadel", destination: URL(string: "https://github.com/orlandos-nl/Citadel")!)
                            .font(.caption)

                        Divider()

                        Text("MIT License")
                            .font(.caption)
                            .bold()

                        Text("""
                        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

                        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

                        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
                        """)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.1)))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("SwiftTerm")
                            .font(.headline)

                        Text("VT100/Xterm Terminal Emulator")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("Copyright (c) Miguel de Icaza")
                            .font(.caption)

                        Link("https://github.com/migueldeicaza/SwiftTerm", destination: URL(string: "https://github.com/migueldeicaza/SwiftTerm")!)
                            .font(.caption)

                        Divider()

                        Text("MIT License")
                            .font(.caption)
                            .bold()

                        Text("""
                        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

                        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

                        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
                        """)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.1)))
                }
                .padding()
            }

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 600, height: 500)
    }
}

#Preview {
    ContentView()
        .navigationTitle("HexBSD")
}
