//
//  SSHConnectionManager.swift
//  HexBSD
//
//  SSH connection management for FreeBSD systems
//

import Foundation
import Citadel
import Crypto
import _CryptoExtras
import NIOCore
import NIOSSH

/// SSH key type
enum SSHKeyType {
    case rsa
    case ed25519
    case ecdsa
}

/// Authentication method for SSH connection (SSH keys only)
struct SSHAuthMethod {
    let username: String
    let privateKeyURL: URL
}

/// SSH connection manager for FreeBSD systems
@Observable
class SSHConnectionManager {
    // Singleton instance shared across all windows
    static let shared = SSHConnectionManager()

    // Connection state
    var isConnected: Bool = false
    var serverAddress: String = ""
    var lastError: String?

    // SSH client
    private var client: SSHClient?

    // Network rate tracking
    private var lastNetworkIn: UInt64 = 0
    private var lastNetworkOut: UInt64 = 0
    private var lastNetworkTime: Date?

    // Private initializer to enforce singleton
    private init() {}

    /// Connect to a FreeBSD server via SSH using key-based authentication
    func connect(host: String, port: Int = 22, authMethod: SSHAuthMethod) async throws {
        print("DEBUG: Attempting SSH key auth to \(authMethod.username)@\(host):\(port)")
        print("DEBUG: Key file: \(authMethod.privateKeyURL.path)")

        // Load private key from file
        let keyString = try String(contentsOf: authMethod.privateKeyURL, encoding: .utf8)

        // Detect key type and create appropriate authentication
        let sshAuth: SSHAuthenticationMethod

        if keyString.contains("BEGIN OPENSSH PRIVATE KEY") || keyString.contains("ssh-ed25519") {
            print("DEBUG: Detected Ed25519 key")
            let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: keyString)
            sshAuth = .ed25519(username: authMethod.username, privateKey: privateKey)
        } else if keyString.contains("BEGIN RSA PRIVATE KEY") || keyString.contains("BEGIN PRIVATE KEY") {
            print("DEBUG: Detected RSA key")
            // Try to load as Insecure RSA key directly
            let privateKey = try Insecure.RSA.PrivateKey(sshRsa: keyString)
            sshAuth = .rsa(username: authMethod.username, privateKey: privateKey)
        } else if keyString.contains("BEGIN EC PRIVATE KEY") {
            print("DEBUG: Detected ECDSA P256 key")
            let privateKey = try P256.Signing.PrivateKey(pemRepresentation: keyString)
            sshAuth = .p256(username: authMethod.username, privateKey: privateKey)
        } else {
            throw NSError(domain: "SSHConnectionManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Unsupported key format. Please use RSA, Ed25519, or ECDSA P256 keys."])
        }

        // Create connection settings
        let settings = SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: {
                print("DEBUG: Authentication method closure called")
                return sshAuth
            },
            hostKeyValidator: .acceptAnything()
        )

        // Connect
        do {
            print("DEBUG: Connecting to SSH server...")
            self.client = try await SSHClient.connect(to: settings)
            print("DEBUG: Connection successful!")
            self.isConnected = true
            self.serverAddress = host
            self.lastError = nil
        } catch let error as NSError {
            print("DEBUG: Connection failed - Domain: \(error.domain), Code: \(error.code)")
            print("DEBUG: Error description: \(error.localizedDescription)")
            print("DEBUG: Full error: \(error)")
            print("DEBUG: Error userInfo: \(error.userInfo)")
            if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? Error {
                print("DEBUG: Underlying error: \(underlyingError)")
            }
            self.isConnected = false

            // Provide more specific error messages
            var errorMsg = "Connection failed: "

            // Check for NIOCore.IOError first
            if error.domain == "NIOCore.IOError" || String(describing: error).contains("Connection reset by peer") {
                errorMsg += "Server closed connection. Possible causes:\n"
                errorMsg += "• Incorrect username or password\n"
                errorMsg += "• SSH server configured to reject password auth\n"
                errorMsg += "• User account locked or disabled\n"
                errorMsg += "• SSH server security policy blocking connection\n"
                errorMsg += "\nTry: ssh \(error.userInfo["username"] as? String ?? "user")@\(host) from Terminal to test"
            } else if error.domain == NSPOSIXErrorDomain {
                switch error.code {
                case 4: // EINTR
                    errorMsg += "Interrupted system call. This might be a library issue."
                case 54: // ECONNRESET
                    errorMsg += "Connection reset by server. Check credentials and SSH server logs."
                case 60: // ETIMEDOUT
                    errorMsg += "Connection timed out. Check firewall settings."
                case 61: // ECONNREFUSED
                    errorMsg += "Connection refused. Check if SSH server is running on port \(port)."
                case 64: // EHOSTDOWN
                    errorMsg += "Host is down or unreachable."
                case 65: // EHOSTUNREACH
                    errorMsg += "No route to host. Check network connectivity."
                default:
                    errorMsg += "Network error (POSIX code \(error.code))"
                }
            } else if error.domain == "NIOSSHError" || error.domain.contains("SSH") {
                errorMsg += "SSH protocol error: \(error.localizedDescription) (code \(error.code))"
            } else if error.domain == "Citadel.SSHClientError" {
                switch error.code {
                case 4: // allAuthenticationOptionsFailed
                    errorMsg += "Authentication failed. Please check:\n"
                    errorMsg += "• Username and password are correct\n"
                    errorMsg += "• SSH server allows password authentication\n"
                    errorMsg += "• User account is not locked"
                default:
                    errorMsg += "SSH client error: \(error.localizedDescription) (code \(error.code))"
                }
            } else {
                errorMsg += "\(error.localizedDescription) (domain: \(error.domain), code: \(error.code))"
            }

            self.lastError = errorMsg
            throw NSError(domain: "SSHConnectionManager", code: error.code,
                         userInfo: [NSLocalizedDescriptionKey: errorMsg])
        } catch {
            print("DEBUG: Unknown error type: \(type(of: error))")
            print("DEBUG: Error details: \(error)")
            if let localizedError = error as? LocalizedError {
                print("DEBUG: Failure reason: \(localizedError.failureReason ?? "none")")
                print("DEBUG: Recovery suggestion: \(localizedError.recoverySuggestion ?? "none")")
            }
            self.isConnected = false
            self.lastError = "Connection failed: \(error.localizedDescription)"
            throw error
        }
    }

    /// Disconnect from the server
    func disconnect() async {
        if let client = client {
            try? await client.close()
        }
        self.client = nil
        self.isConnected = false
        self.serverAddress = ""
    }

    /// Execute a command on the remote server
    func executeCommand(_ command: String) async throws -> String {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let output = try await client.executeCommand(command)
        return String(buffer: output)
    }

    /// Execute a command and return stdout/stderr separately
    func executeCommandDetailed(_ command: String) async throws -> (stdout: String, stderr: String) {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let streams = try await client.executeCommandStream(command)

        var stdout = ""
        var stderr = ""

        for try await event in streams {
            switch event {
            case .stdout(let data):
                stdout += String(buffer: data)
            case .stderr(let data):
                stderr += String(buffer: data)
            }
        }

        return (stdout: stdout, stderr: stderr)
    }

    /// Start an interactive shell session with PTY
    @available(macOS 15.0, *)
    func startInteractiveShell(delegate: TerminalCoordinator) async throws {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Configure PTY request
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([
                .ECHO: 1,
                .ICRNL: 1,
                .OPOST: 1,
                .ONLCR: 1
            ])
        )

        // Start PTY session
        try await client.withPTY(ptyRequest) { ttyOutput, ttyStdinWriter in
            // Provide stdin writer to delegate
            await MainActor.run {
                delegate.setStdinWriter { buffer in
                    try await ttyStdinWriter.write(buffer)
                }
            }

            // Stream output to delegate
            for try await output in ttyOutput {
                switch output {
                case .stdout(let buffer), .stderr(let buffer):
                    // Convert ByteBuffer to Data
                    let data = Data(buffer: buffer)
                    await MainActor.run {
                        delegate.receiveOutput(data)
                    }
                }
            }
        }
    }
}

// MARK: - FreeBSD Data Fetchers

extension SSHConnectionManager {
    /// Fetch system status information
    func fetchSystemStatus() async throws -> SystemStatus {
        // Get uptime
        let uptimeOutput = try await executeCommand("uptime")
        let uptime = parseUptime(uptimeOutput)

        // Get load average
        let loadAvg = try await executeCommand("sysctl -n vm.loadavg")
        let loads = parseLoadAverage(loadAvg)

        // Get memory usage
        let memInfo = try await executeCommand("sysctl -n hw.physmem hw.usermem")
        let (totalMem, usedMem) = parseMemory(memInfo)

        // Get CPU usage (via top)
        let topOutput = try await executeCommand("top -b -n 1 | head -3")
        let cpuUsage = parseCPUUsage(topOutput)

        // Get ZFS ARC stats
        let arcStats = try await executeCommand("sysctl -n kstat.zfs.misc.arcstats.size kstat.zfs.misc.arcstats.c_max")
        let (arcUsed, arcMax) = parseARCStats(arcStats)

        // Get storage usage
        let dfOutput = try await executeCommand("df -h /")
        let (storageUsed, storageTotal) = parseStorageUsage(dfOutput)

        // Get network statistics and calculate rates
        var networkIn = "0 KB/s"
        var networkOut = "0 KB/s"

        do {
            // Get raw netstat output
            let netstatOutput = try await executeCommand("netstat -ib | grep -v lo0")
            let (currentIn, currentOut) = parseNetstatBytes(netstatOutput)

            print("DEBUG: Current bytes - In: \(currentIn), Out: \(currentOut)")

            // Calculate rate if we have a previous measurement
            let now = Date()
            if let lastTime = lastNetworkTime {
                let timeInterval = now.timeIntervalSince(lastTime)
                if timeInterval > 0 {
                    let inRate = Double(currentIn - lastNetworkIn) / timeInterval
                    let outRate = Double(currentOut - lastNetworkOut) / timeInterval

                    networkIn = formatBytesPerSecond(inRate)
                    networkOut = formatBytesPerSecond(outRate)

                    print("DEBUG: Network rates - In: \(networkIn), Out: \(networkOut) (over \(String(format: "%.1f", timeInterval))s)")
                }
            }

            // Store current values for next calculation
            lastNetworkIn = currentIn
            lastNetworkOut = currentOut
            lastNetworkTime = now
        } catch {
            print("DEBUG: Network stats error: \(error)")
            // Continue with defaults
        }

        return SystemStatus(
            cpuUsage: String(format: "%.1f%%", cpuUsage),
            memoryUsage: String(format: "%.1f GB / %.1f GB", usedMem, totalMem),
            zfsArcUsage: String(format: "%.1f GB / %.1f GB", arcUsed, arcMax),
            storageUsage: String(format: "%.1f GB / %.1f GB", storageUsed, storageTotal),
            uptime: uptime,
            loadAverage: String(format: "%.2f, %.2f, %.2f", loads.0, loads.1, loads.2),
            networkIn: networkIn,
            networkOut: networkOut
        )
    }

}

// MARK: - Output Parsers

extension SSHConnectionManager {
    private func parseUptime(_ output: String) -> String {
        // Parse uptime output
        // Example: "10:30AM up 5 days, 3:24, 2 users, load averages: 0.52, 0.58, 0.59"
        let components = output.components(separatedBy: "up ")
        if components.count > 1 {
            let uptimePart = components[1].components(separatedBy: ",")
            if !uptimePart.isEmpty {
                return uptimePart[0].trimmingCharacters(in: .whitespaces)
            }
        }
        return "Unknown"
    }

    private func parseLoadAverage(_ output: String) -> (Double, Double, Double) {
        // Parse load average output: "{ 0.52 0.58 0.59 }"
        let cleaned = output.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            .trimmingCharacters(in: .whitespaces)
        let components = cleaned.components(separatedBy: .whitespaces)
        let loads = components.compactMap { Double($0) }
        if loads.count >= 3 {
            return (loads[0], loads[1], loads[2])
        }
        return (0, 0, 0)
    }

    private func parseMemory(_ output: String) -> (total: Double, used: Double) {
        // Parse memory info from sysctl
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if lines.count >= 2 {
            let physmem = Double(lines[0]) ?? 0
            let usermem = Double(lines[1]) ?? 0
            let used = physmem - usermem
            return (total: physmem / 1_073_741_824, used: used / 1_073_741_824) // Convert to GB
        }
        return (total: 0, used: 0)
    }

    private func parseCPUUsage(_ output: String) -> Double {
        // Parse CPU usage from top output
        // Look for "CPU:" line
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("CPU:") {
                // Extract percentage
                let components = line.components(separatedBy: .whitespaces)
                for (i, comp) in components.enumerated() {
                    if comp.hasSuffix("%") && i > 0 {
                        let percentage = comp.replacingOccurrences(of: "%", with: "")
                        return Double(percentage) ?? 0
                    }
                }
            }
        }
        return 0
    }

    private func parseARCStats(_ output: String) -> (used: Double, max: Double) {
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if lines.count >= 2 {
            let used = Double(lines[0]) ?? 0
            let max = Double(lines[1]) ?? 0
            return (used: used / 1_073_741_824, max: max / 1_073_741_824) // Convert to GB
        }
        return (used: 0, max: 0)
    }

    private func parseStorageUsage(_ output: String) -> (used: Double, total: Double) {
        // Parse df output
        let lines = output.components(separatedBy: .newlines)
        if lines.count > 1 {
            let dataLine = lines[1]
            let components = dataLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if components.count >= 4 {
                // Convert from human readable format
                let used = parseStorageSize(components[2])
                let total = parseStorageSize(components[1])
                return (used: used, total: total)
            }
        }
        return (used: 0, total: 0)
    }

    private func parseStorageSize(_ sizeStr: String) -> Double {
        let number = Double(sizeStr.filter { $0.isNumber || $0 == "." }) ?? 0
        if sizeStr.hasSuffix("T") {
            return number * 1024
        } else if sizeStr.hasSuffix("G") {
            return number
        } else if sizeStr.hasSuffix("M") {
            return number / 1024
        }
        return number
    }

    private func parseSystatOutput(_ output: String) -> (inbound: String, outbound: String) {
        // Parse systat -ifstat output
        // Look for lines with interface data showing KB/s or MB/s
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }

        var totalInKB: Double = 0
        var totalOutKB: Double = 0

        for line in lines {
            // Skip header lines
            if line.contains("Interface") || line.contains("---") {
                continue
            }

            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // Typical systat format has KB/s in specific columns
            if components.count >= 5 {
                // Try to extract rates (format varies, but typically has In and Out columns)
                if let inRate = Double(components[components.count - 2]) {
                    totalInKB += inRate
                }
                if let outRate = Double(components[components.count - 1]) {
                    totalOutKB += outRate
                }
            }
        }

        return (
            inbound: formatBytesPerSecond(totalInKB * 1024),
            outbound: formatBytesPerSecond(totalOutKB * 1024)
        )
    }

    private func parseNetstatBytes(_ output: String) -> (inbound: UInt64, outbound: UInt64) {
        // Parse netstat -ib for cumulative bytes
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        for (index, line) in lines.enumerated() {
            // Skip header lines
            if line.contains("Name") || line.contains("Mtu") || line.contains("<Link#") {
                continue
            }

            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            // FreeBSD netstat -ib format:
            // Name Mtu Network Address Ipkts Ierrs Idrop Ibytes Opkts Oerrs Obytes Coll
            // Look for lines with numeric data (should have Ibytes and Obytes)

            // Try to find Ibytes and Obytes by looking for large numbers
            if components.count >= 7 {
                // Scan from right to left looking for byte counts
                for i in (0..<components.count).reversed() {
                    if let value = UInt64(components[i]), value > 1000 {
                        // This might be Obytes or Ibytes
                        // Look for two large numbers
                        if i >= 3 {
                            if let ibytes = UInt64(components[i-3]), ibytes > 1000,
                               let obytes = UInt64(components[i]), obytes > 1000 {
                                totalIn += ibytes
                                totalOut += obytes
                                break
                            }
                        }
                    }
                }
            }
        }

        return (inbound: totalIn, outbound: totalOut)
    }

    private func formatBytesPerSecond(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_073_741_824 {
            return String(format: "%.2f GB/s", bytesPerSec / 1_073_741_824)
        } else if bytesPerSec >= 1_048_576 {
            return String(format: "%.2f MB/s", bytesPerSec / 1_048_576)
        } else if bytesPerSec >= 1024 {
            return String(format: "%.2f KB/s", bytesPerSec / 1024)
        } else {
            return String(format: "%.0f B/s", bytesPerSec)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        let mb = Double(bytes) / 1_048_576
        let kb = Double(bytes) / 1024

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
