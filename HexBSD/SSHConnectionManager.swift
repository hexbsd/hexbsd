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

    // Network rate tracking per interface
    private var lastInterfaceStats: [String: (inBytes: UInt64, outBytes: UInt64)] = [:]
    private var lastNetworkTime: Date?

    // CPU tracking for per-core usage
    private var lastCPUSnapshot: [UInt64] = []
    private var lastCPUTime: Date?

    // Initializer - can create multiple instances for replication
    init() {}

    /// Validate that the connected server is running FreeBSD
    func validateFreeBSD() async throws {
        do {
            let output = try await executeCommand("uname -s")
            let osName = output.trimmingCharacters(in: .whitespacesAndNewlines)

            if osName != "FreeBSD" {
                throw NSError(
                    domain: "SSHConnectionManager",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Unsupported Operating System",
                        NSLocalizedRecoverySuggestionErrorKey: "HexBSD only supports FreeBSD servers. Detected OS: \(osName)"
                    ]
                )
            }
        } catch let error as NSError where error.domain == "SSHConnectionManager" && error.code == 2 {
            // Re-throw our OS validation error
            throw error
        } catch {
            // If we can't determine the OS, throw a generic error
            throw NSError(
                domain: "SSHConnectionManager",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Unable to validate operating system",
                    NSLocalizedRecoverySuggestionErrorKey: "Could not verify that the server is running FreeBSD."
                ]
            )
        }
    }

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

    // MARK: - SFTP File Operations

    /// List files in a remote directory
    func listDirectory(path: String) async throws -> [RemoteFile] {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Use ls command with detailed output
        let command = "ls -la '\(path)' 2>/dev/null || ls -la ~"
        let output = try await executeCommand(command)

        return parseLsOutput(output, basePath: path)
    }

    /// Download a file from the remote server
    func downloadFile(remotePath: String, localURL: URL) async throws {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Use cat to read the file and save locally
        let output = try await executeCommand("cat '\(remotePath)'")
        guard let data = output.data(using: .utf8) else {
            throw NSError(domain: "SSHConnectionManager", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to convert file data"])
        }

        try data.write(to: localURL)
    }

    /// Upload a file to the remote server
    func uploadFile(localURL: URL, remotePath: String) async throws {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Read local file
        let data = try Data(contentsOf: localURL)
        let base64 = data.base64EncodedString()

        // Upload using base64 encoding to handle binary files
        let command = "echo '\(base64)' | base64 -d > '\(remotePath)'"
        _ = try await executeCommand(command)
    }

    /// Delete a file or directory on the remote server
    func deleteFile(path: String, isDirectory: Bool) async throws {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Use rm -rf for directories, rm for files
        let command = isDirectory ? "rm -rf '\(path)'" : "rm '\(path)'"
        _ = try await executeCommand(command)
    }

    private func parseLsOutput(_ output: String, basePath: String) -> [RemoteFile] {
        var files: [RemoteFile] = []
        let lines = output.components(separatedBy: .newlines)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "MMM d HH:mm"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")

        let yearFormatter = DateFormatter()
        yearFormatter.dateFormat = "MMM d yyyy"
        yearFormatter.locale = Locale(identifier: "en_US_POSIX")

        for line in lines {
            // Skip empty lines and total line
            if line.isEmpty || line.starts(with: "total") {
                continue
            }

            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            // Format: permissions links owner group size month day time/year name
            // Example: drwxr-xr-x 2 root wheel 512 Jan 10 15:30 Documents
            // Or:      -rw-r--r-- 1 root wheel 512 Jan 10  2023 oldfile.txt
            guard components.count >= 9 else { continue }

            let permissions = components[0]
            let isDirectory = permissions.starts(with: "d")
            let sizeStr = components[4]
            let month = components[5]
            let day = components[6]
            let timeOrYear = components[7]
            let name = components[8...].joined(separator: " ")

            // Skip . and ..
            if name == "." || name == ".." {
                continue
            }

            // Parse size
            let size = Int64(sizeStr) ?? 0

            // Parse date - check if timeOrYear is a time (contains :) or year (4 digits)
            var date: Date?
            if timeOrYear.contains(":") {
                // It's a time - file modified this year
                let dateStr = "\(month) \(day) \(timeOrYear)"
                if let parsedDate = timeFormatter.date(from: dateStr) {
                    // Set to current year
                    var calendar = Calendar.current
                    calendar.timeZone = TimeZone.current
                    let currentYear = calendar.component(.year, from: Date())
                    var components = calendar.dateComponents([.month, .day, .hour, .minute], from: parsedDate)
                    components.year = currentYear
                    date = calendar.date(from: components)
                }
            } else {
                // It's a year - file modified in previous year
                let dateStr = "\(month) \(day) \(timeOrYear)"
                date = yearFormatter.date(from: dateStr)
            }

            // Build full path
            let fullPath: String
            if basePath == "~" || basePath.isEmpty {
                fullPath = name
            } else if basePath.hasSuffix("/") {
                fullPath = basePath + name
            } else {
                fullPath = basePath + "/" + name
            }

            files.append(RemoteFile(
                name: name,
                path: fullPath,
                isDirectory: isDirectory,
                size: size,
                permissions: String(permissions.dropFirst()),
                modifiedDate: date
            ))
        }

        // Sort: directories first, then alphabetically
        return files.sorted { first, second in
            if first.isDirectory != second.isDirectory {
                return first.isDirectory
            }
            return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
        }
    }
}

// MARK: - Log File Operations

extension SSHConnectionManager {
    /// List log files in /var/log directory
    func listLogFiles() async throws -> [LogFile] {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // List only readable files, excluding directories and compressed archives
        let command = """
        for f in /var/log/*; do
            if [ -f "$f" ] && [ -r "$f" ]; then
                case "$f" in
                    *.bz2|*.gz|*.xz) ;;
                    *) ls -lh "$f" ;;
                esac
            fi
        done
        """
        let output = try await executeCommand(command)

        return parseLogFiles(output)
    }

    /// Read log file content (last N lines)
    func readLogFile(path: String, lines: Int) async throws -> String {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Use tail to get last N lines
        let command = "tail -n \(lines) '\(path)'"
        return try await executeCommand(command)
    }

    private func parseLogFiles(_ output: String) -> [LogFile] {
        var files: [LogFile] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            // Skip empty lines
            if line.isEmpty {
                continue
            }

            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            // Format: permissions links owner group size month day time path
            // Example: -rw-r--r-- 1 root wheel 1.2K Jan 10 15:30 /var/log/messages
            guard components.count >= 9 else { continue }

            let size = components[4]
            let fullPath = components[8...].joined(separator: " ")

            // Skip if it's a directory marker
            if components[0].starts(with: "d") {
                continue
            }

            // Extract just the filename from the full path for display
            let name = (fullPath as NSString).lastPathComponent

            files.append(LogFile(
                name: name,
                path: fullPath,
                size: size
            ))
        }

        // Sort alphabetically
        return files.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Sysctl Operations

extension SSHConnectionManager {
    /// List available sysctl categories
    func listSysctlCategories() async throws -> [String] {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Get just the sysctl names (fast) - using -a to be safe, but only extracting first level
        let command = "sysctl -Na 2>/dev/null | cut -d. -f1 | sort -u"
        let output = try await executeCommand(command)

        var categories = output.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }

        return categories
    }

    /// List sysctls for a specific category
    func listSysctlsForCategory(_ category: String) async throws -> [SysctlEntry] {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Get sysctls for specific category only (much faster than -a)
        let command = "sysctl \(category)"
        let output = try await executeCommand(command)

        return parseSysctlOutput(output)
    }

    private func parseSysctlOutput(_ output: String) -> [SysctlEntry] {
        var sysctls: [SysctlEntry] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            // Skip empty lines
            if line.isEmpty {
                continue
            }

            // Format: name: value or name = value
            let separators = [":", "="]
            var name = ""
            var value = ""

            for separator in separators {
                if let separatorIndex = line.firstIndex(of: Character(separator)) {
                    name = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
                    value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }

            // Skip if we couldn't parse
            if name.isEmpty {
                continue
            }

            // For now, assume all sysctls are read-only
            // We could potentially check writability with `sysctl -d` but that's expensive
            let writable = false

            sysctls.append(SysctlEntry(
                name: name,
                value: value,
                writable: writable
            ))
        }

        return sysctls
    }
}

// MARK: - Network Connection Operations

extension SSHConnectionManager {
    /// List all network connections using sockstat
    func listNetworkConnections() async throws -> [NetworkConnection] {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Use sockstat to show all network connections with protocol info
        // -4 = IPv4, -6 = IPv6, -l = listening sockets, -c = connected sockets
        let command = "sockstat -46"
        let output = try await executeCommand(command)

        return parseSockstatOutput(output)
    }

    private func parseSockstatOutput(_ output: String) -> [NetworkConnection] {
        var connections: [NetworkConnection] = []
        let lines = output.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            // Skip header line and empty lines
            if index == 0 || line.isEmpty {
                continue
            }

            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            // Format: USER COMMAND PID FD PROTO LOCAL ADDRESS FOREIGN ADDRESS
            // Example: root sshd 1234 3 tcp4 192.168.1.100:22 192.168.1.50:54321
            // Example: nobody httpd 5678 4 tcp6 *:80 *:*
            guard components.count >= 7 else { continue }

            let user = components[0]
            let command = components[1]
            let pid = components[2]
            // Skip FD (file descriptor) at index 3
            let proto = components[4]
            let localAddress = components[5]
            let foreignAddress = components[6]

            // Determine state (TCP connections may have state info)
            var state = ""
            if proto.lowercased().contains("tcp") {
                // Check if there's additional state info
                if components.count > 7 {
                    state = components[7]
                } else {
                    // Infer state from addresses
                    if foreignAddress == "*:*" {
                        state = "LISTEN"
                    } else {
                        state = "ESTABLISHED"
                    }
                }
            }

            connections.append(NetworkConnection(
                user: user,
                command: command,
                pid: pid,
                proto: proto,
                localAddress: localAddress,
                foreignAddress: foreignAddress,
                state: state
            ))
        }

        return connections
    }
}

// MARK: - User Session Operations

extension SSHConnectionManager {
    /// List all active user sessions using w command
    func listUserSessions() async throws -> [UserSession] {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Use w command to show logged in users with details
        let command = "w -h"
        let output = try await executeCommand(command)

        return parseWOutput(output)
    }

    private func parseWOutput(_ output: String) -> [UserSession] {
        var sessions: [UserSession] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            // Skip empty lines
            if line.isEmpty {
                continue
            }

            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            // Format: USER TTY FROM LOGIN@ IDLE WHAT
            // Example: root pts/0 192.168.1.100 3:21PM - w
            // Example: user1 pts/1 - 2:15PM 1:05 -bash
            guard components.count >= 4 else { continue }

            let user = components[0]
            let tty = components[1]
            let from = components[2]
            let loginTime = components[3]

            // IDLE and WHAT can vary - idle might be missing
            var idle = "-"
            var what = ""

            if components.count >= 5 {
                idle = components[4]
            }

            if components.count >= 6 {
                what = components[5...].joined(separator: " ")
            }

            sessions.append(UserSession(
                user: user,
                tty: tty,
                from: from == "-" ? "" : from,
                loginTime: loginTime,
                idle: idle,
                what: what
            ))
        }

        return sessions
    }
}

// MARK: - Poudriere Operations

extension SSHConnectionManager {
    /// Detect custom poudriere config path from running processes
    private func detectPoudriereConfigPath() async throws -> String? {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Find running poudriere bulk processes and extract config path from open files
        let command = """
        # Find poudriere bulk.sh processes
        BULK_PID=$(ps -auwx | grep 'poudriere.*bulk.sh' | grep -v grep | head -1 | awk '{print $2}')

        if [ -n "$BULK_PID" ]; then
            # Extract config path from open files using procstat
            # Data path pattern: /some/base/poudriere/data/...
            # Config path: /some/base/etc/poudriere.conf
            procstat files "$BULK_PID" 2>/dev/null | awk '{print $NF}' \
             | sed -n 's#^\\(.*\\)/poudriere/data/.*#\\1/etc/poudriere.conf#p' | head -1
        fi
        """

        let output = try await executeCommand(command)
        let configPath = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if !configPath.isEmpty {
            print("DEBUG: Detected custom poudriere config from running process: \(configPath)")
            return configPath
        }

        return nil
    }

    /// Check for running poudriere bulk builds
    func getRunningPoudriereBulk() async throws -> [String] {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Extract jail-ports combinations from running bulk processes
        let command = """
        ps -auwx | grep 'sh: poudriere\\[' | grep -v grep | sed -n 's/.*poudriere\\[\\([^]]*\\)\\].*/\\1/p' | sort -u
        """

        let output = try await executeCommand(command)
        let builds = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        print("DEBUG: Running poudriere builds: \(builds)")
        return builds
    }

    /// Check if poudriere is installed and get config
    func checkPoudriere() async throws -> PoudriereInfo {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Check if poudriere is installed
        let checkCommand = "command -v poudriere >/dev/null 2>&1 && echo 'installed' || echo 'not-installed'"
        let checkOutput = try await executeCommand(checkCommand)

        if checkOutput.trimmingCharacters(in: .whitespacesAndNewlines) != "installed" {
            return PoudriereInfo(isInstalled: false, htmlPath: "", dataPath: "", configPath: nil, runningBuilds: [])
        }

        // Try to detect custom poudriere config path from running processes
        let customConfigPath = try? await detectPoudriereConfigPath()

        // Read poudriere.conf to get paths - use custom path if detected
        let confCommand: String
        if let customPath = customConfigPath, !customPath.isEmpty {
            print("DEBUG: Using custom poudriere config: \(customPath)")
            confCommand = """
            if [ -f '\(customPath)' ]; then
                cat '\(customPath)'
            else
                echo ""
            fi
            """
        } else {
            confCommand = """
            if [ -f /usr/local/etc/poudriere.conf ]; then
                cat /usr/local/etc/poudriere.conf
            elif [ -f /etc/poudriere.conf ]; then
                cat /etc/poudriere.conf
            else
                echo ""
            fi
            """
        }
        let confOutput = try await executeCommand(confCommand)

        // Use shell to evaluate poudriere config and get actual paths
        // This sources the config file and uses poudriere's own logic
        let pathDetectionCommand: String
        if let customPath = customConfigPath, !customPath.isEmpty {
            pathDetectionCommand = """
            # Use custom poudriere config path
            if [ -f '\(customPath)' ]; then
                # Source the config file directly to preserve variable expansion
                . '\(customPath)'

                # Output diagnostic info with DIAG: prefix
                echo "DIAG:Sourced config: \(customPath)"
                echo "DIAG:BASEFS='${BASEFS}'"
                echo "DIAG:POUDRIERE_DATA='${POUDRIERE_DATA}'"
            else
                # Config not found, use defaults
                echo "DIAG:Config file not found: \(customPath)"
                echo "DATA:/usr/local/poudriere/data"
                echo "HTML:/usr/local/share/poudriere/html"
                exit 0
            fi

            # Get POUDRIERE_DATA (with default fallback to BASEFS/data)
            if [ -z "$POUDRIERE_DATA" ]; then
                if [ -n "$BASEFS" ]; then
                    POUDRIERE_DATA="${BASEFS}/data"
                    echo "DIAG:Computed POUDRIERE_DATA from BASEFS: '${POUDRIERE_DATA}'"
                else
                    POUDRIERE_DATA="/usr/local/poudriere/data"
                    echo "DIAG:Using default POUDRIERE_DATA (BASEFS empty): '${POUDRIERE_DATA}'"
                fi
            else
                echo "DIAG:POUDRIERE_DATA already set: '${POUDRIERE_DATA}'"
            fi

            # Output the paths
            echo "DATA:${POUDRIERE_DATA}"

            # Determine HTML path - HTML templates are typically in standard location
            # even with custom POUDRIERE_DATA paths
            # Check standard HTML template location first
            if [ -f "/usr/local/share/poudriere/html/index.html" ]; then
                echo "HTML:/usr/local/share/poudriere/html"
                echo "DIAG:Using standard HTML templates"
            elif [ -f "${POUDRIERE_DATA}/logs/bulk/index.html" ]; then
                echo "HTML:${POUDRIERE_DATA}/logs/bulk"
                echo "DIAG:Using HTML from data directory"
            elif [ -d "${POUDRIERE_DATA}/logs/bulk" ]; then
                # Data dir exists but no HTML yet, use standard templates
                echo "HTML:/usr/local/share/poudriere/html"
                echo "DIAG:Data dir exists, using standard HTML templates"
            else
                echo "HTML:/usr/local/share/poudriere/html"
                echo "DIAG:Fallback to standard HTML templates"
            fi
            """
        } else {
            pathDetectionCommand = """
            # Source poudriere functions to get actual configured paths
            if [ -f /usr/local/etc/poudriere.conf ]; then
                POUDRIERE_ETC=/usr/local/etc
            elif [ -f /etc/poudriere.conf ]; then
                POUDRIERE_ETC=/etc
            else
                # No config found, use defaults
                echo "DATA:/usr/local/poudriere/data"
                echo "HTML:/usr/local/share/poudriere/html"
                exit 0
            fi

            # Source the config (safely - just extract variables)
            eval $(grep -E '^[A-Z_]+=' ${POUDRIERE_ETC}/poudriere.conf 2>/dev/null)

            # Get POUDRIERE_DATA (with default)
            POUDRIERE_DATA=${POUDRIERE_DATA:-${BASEFS}/data}
            POUDRIERE_DATA=${POUDRIERE_DATA:-/usr/local/poudriere/data}

            # Output the paths
            echo "DATA:${POUDRIERE_DATA}"

            # Determine HTML path - check where index.html actually exists
            if [ -f "${POUDRIERE_DATA}/logs/bulk/index.html" ]; then
                echo "HTML:${POUDRIERE_DATA}/logs/bulk"
            elif [ -f "/usr/local/share/poudriere/html/index.html" ]; then
                echo "HTML:/usr/local/share/poudriere/html"
            elif [ -d "${POUDRIERE_DATA}/logs/bulk" ]; then
                echo "HTML:${POUDRIERE_DATA}/logs/bulk"
            elif [ -d "/usr/local/share/poudriere/html" ]; then
                echo "HTML:/usr/local/share/poudriere/html"
            else
                echo "HTML:/usr/local/share/poudriere/html"
            fi
            """
        }

        let pathOutput = try await executeCommand(pathDetectionCommand)
        print("DEBUG: Path detection output:\n\(pathOutput)")

        // Parse the output
        var dataPath = "/usr/local/poudriere/data"
        var htmlPath = "/usr/local/share/poudriere/html"

        for line in pathOutput.components(separatedBy: .newlines) {
            if line.hasPrefix("DATA:") {
                dataPath = String(line.dropFirst(5))
            } else if line.hasPrefix("HTML:") {
                htmlPath = String(line.dropFirst(5))
            }
        }

        print("DEBUG: Poudriere Configuration Summary:")
        print("  - Config Path: \(customConfigPath ?? "standard")")
        print("  - DATA Path: \(dataPath)")
        print("  - HTML Path: \(htmlPath)")

        // Get running builds
        let runningBuilds = (try? await getRunningPoudriereBulk()) ?? []
        print("  - Running Builds: \(runningBuilds.joined(separator: ", "))")

        return PoudriereInfo(
            isInstalled: true,
            htmlPath: htmlPath,
            dataPath: dataPath,
            configPath: customConfigPath,
            runningBuilds: runningBuilds
        )
    }

    /// Load HTML content from poudriere
    func loadPoudriereHTML(path: String) async throws -> String {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Read the HTML file
        let command = "cat '\(path)' 2>/dev/null || echo ''"
        let content = try await executeCommand(command)

        return content
    }
}

// MARK: - Ports Operations

extension SSHConnectionManager {
    /// Check if ports tree is installed
    func checkPorts() async throws -> PortsInfo {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Check common ports locations
        let checkCommand = """
        if [ -d /usr/ports ] && [ -f /usr/ports/Mk/bsd.port.mk ]; then
            echo "INSTALLED:/usr/ports"
        elif [ -d /usr/local/ports ] && [ -f /usr/local/ports/Mk/bsd.port.mk ]; then
            echo "INSTALLED:/usr/local/ports"
        else
            echo "NOT_INSTALLED"
        fi
        """

        print("DEBUG: Checking for ports tree...")
        let output = try await executeCommand(checkCommand)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        print("DEBUG: Ports check result: \(trimmed)")

        if trimmed.hasPrefix("INSTALLED:") {
            let portsPath = String(trimmed.dropFirst(10))

            // Find INDEX file - use simpler command
            let indexCommand = "ls '\(portsPath)'/INDEX-* 2>&1 | grep -v 'No such file' | head -1"
            print("DEBUG: Looking for INDEX file in \(portsPath)...")

            do {
                let indexFile = try await executeCommand(indexCommand).trimmingCharacters(in: .whitespacesAndNewlines)
                print("DEBUG: INDEX file found: \(indexFile)")
                let indexPath = indexFile.isEmpty ? "" : indexFile
                return PortsInfo(isInstalled: true, portsPath: portsPath, indexPath: indexPath)
            } catch {
                // INDEX file not found - this is OK, can be generated later
                print("DEBUG: INDEX file not found (this is normal for fresh Git clone)")
                return PortsInfo(isInstalled: true, portsPath: portsPath, indexPath: "")
            }
        } else {
            return PortsInfo(isInstalled: false, portsPath: "", indexPath: "")
        }
    }

    /// List all ports categories
    func listPortsCategories() async throws -> [String] {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let info = try await checkPorts()
        guard info.isInstalled else {
            return []
        }

        // Get categories from directory names - simpler approach
        let command = """
        cd '\(info.portsPath)' 2>/dev/null && ls -1 -d */ 2>/dev/null | sed 's|/||' | grep -v -E '^(distfiles|packages|Templates|\\.)'  | sort || echo ''
        """
        print("DEBUG: Listing categories from \(info.portsPath)...")
        let output = try await executeCommand(command)
        print("DEBUG: Found categories: \(output.components(separatedBy: .newlines).count) items")

        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Get total ports count
    func getPortsCount() async throws -> Int {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let info = try await checkPorts()
        guard info.isInstalled, !info.indexPath.isEmpty else {
            print("DEBUG: Ports not installed or INDEX not found, returning 0")
            return 0
        }

        let command = "wc -l < '\(info.indexPath)' 2>/dev/null || echo '0'"
        print("DEBUG: Counting ports in INDEX file: \(info.indexPath)...")
        let output = try await executeCommand(command)
        let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        print("DEBUG: Total ports count: \(count)")
        return count
    }

    /// Search ports by name or description
    func searchPorts(query: String, category: String) async throws -> [Port] {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let info = try await checkPorts()
        guard info.isInstalled, !info.indexPath.isEmpty else {
            return []
        }

        // Escape query for grep
        let escapedQuery = query.replacingOccurrences(of: "'", with: "'\\''")

        // Search INDEX file
        // INDEX format: portname|path|prefix|comment|descr|maintainer|categories|build-deps|run-deps|www|...
        var command: String
        if category != "all" {
            // Filter by category and search
            command = """
            grep -i '\(escapedQuery)' '\(info.indexPath)' | grep -E '\\|\(category)[ |]' | head -100
            """
        } else {
            command = """
            grep -i '\(escapedQuery)' '\(info.indexPath)' | head -100
            """
        }

        let output = try await executeCommand(command)
        return parseIndexEntries(output, portsPath: info.portsPath)
    }

    /// Get detailed port information
    func getPortDetails(path: String) async throws -> PortDetails {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Read Makefile variables, options, and plist
        let command = """
        cd '\(path)' 2>/dev/null && {
            make -V WWW -V BUILD_DEPENDS -V RUN_DEPENDS 2>/dev/null || echo ''
            echo "---OPTIONS---"
            make -V OPTIONS_DEFINE -V OPTIONS_DEFAULT 2>/dev/null || echo ''
            echo "---OPTIONS_DESC---"
            make -V OPTIONS_DEFINE 2>/dev/null | tr ' ' '\\n' | while read opt; do
                [ -n "$opt" ] && make -V ${opt}_DESC 2>/dev/null | sed "s/^/${opt}:/"
            done
            echo "---PLIST---"
            if [ -f pkg-plist ]; then cat pkg-plist | grep -v '^@' | head -100; fi
        } 2>/dev/null || echo ''
        """
        print("DEBUG: Getting port details for: \(path)")
        let output = try await executeCommand(command)
        print("DEBUG: Port details output length: \(output.count)")

        // Split output into sections
        let sections = output.components(separatedBy: "---OPTIONS---")
        let basicInfo = sections[0]
        let optionsAndRest = sections.count > 1 ? sections[1] : ""

        let descSections = optionsAndRest.components(separatedBy: "---OPTIONS_DESC---")
        let optionsDefaults = descSections[0]
        let descAndPlist = descSections.count > 1 ? descSections[1] : ""

        let plistSections = descAndPlist.components(separatedBy: "---PLIST---")
        let optionsDesc = plistSections[0]
        let plistText = plistSections.count > 1 ? plistSections[1] : ""

        // Parse basic info
        let lines = basicInfo.components(separatedBy: .newlines)
        let www = lines.count > 0 ? lines[0].trimmingCharacters(in: .whitespaces) : ""
        let buildDepends = lines.count > 1 ? parseDependencies(lines[1]) : []
        let runDepends = lines.count > 2 ? parseDependencies(lines[2]) : []

        // Parse options
        print("DEBUG: Options defaults length: \(optionsDefaults.count)")
        print("DEBUG: Options defaults preview: \(String(optionsDefaults.prefix(200)))")
        print("DEBUG: Options desc length: \(optionsDesc.count)")
        print("DEBUG: Options desc preview: \(String(optionsDesc.prefix(200)))")
        let options = parsePortOptionsNew(optionsDefaults: optionsDefaults, optionsDesc: optionsDesc)

        // Parse plist
        let plistFiles = plistText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        print("DEBUG: WWW: \(www), BuildDeps: \(buildDepends.count), RunDeps: \(runDepends.count), Options: \(options.count), Files: \(plistFiles.count)")

        return PortDetails(www: www, buildDepends: buildDepends, runDepends: runDepends, options: options, plistFiles: plistFiles)
    }

    // MARK: - Helpers

    private func parseIndexEntries(_ output: String, portsPath: String) -> [Port] {
        var ports: [Port] = []

        for line in output.components(separatedBy: .newlines) {
            guard !line.isEmpty else { continue }

            let fields = line.components(separatedBy: "|")
            guard fields.count >= 7 else { continue }

            let portName = fields[0]
            let path = fields[1]
            let comment = fields[3]
            let maintainer = fields[5]
            let categories = fields[6]

            // Extract category (first category) and version
            let categoryList = categories.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let category = categoryList.first ?? "misc"

            // Extract version from port name (usually portname-version)
            let nameParts = portName.components(separatedBy: "-")
            let version = nameParts.count > 1 ? nameParts.last ?? "" : ""
            let name = nameParts.count > 1 ? nameParts.dropLast().joined(separator: "-") : portName

            ports.append(Port(
                name: name,
                category: category,
                version: version,
                comment: comment,
                maintainer: maintainer,
                path: path
            ))
        }

        return ports
    }

    private func parseDependencies(_ depString: String) -> [String] {
        guard !depString.isEmpty else { return [] }

        return depString.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .compactMap { dep in
                // Dependencies are in format: path:target or just path
                let parts = dep.components(separatedBy: ":")
                return parts.first
            }
    }

    private func parsePortOptionsNew(optionsDefaults: String, optionsDesc: String) -> [PortOption] {
        var options: [PortOption] = []

        // Parse OPTIONS_DEFINE and OPTIONS_DEFAULT
        // Filter out empty lines first
        let lines = optionsDefaults.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let optionsDefineStr = lines.count > 0 ? lines[0] : ""
        let optionsDefaultStr = lines.count > 1 ? lines[1] : ""

        let optionsDefine = optionsDefineStr.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let optionsDefault = Set(optionsDefaultStr.components(separatedBy: .whitespaces).filter { !$0.isEmpty })

        print("DEBUG: OPTIONS_DEFINE: \(optionsDefine)")
        print("DEBUG: OPTIONS_DEFAULT: \(optionsDefault)")

        // Parse descriptions
        var descriptions: [String: String] = [:]
        for line in optionsDesc.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let colonIndex = trimmed.firstIndex(of: ":") {
                let optName = String(trimmed[..<colonIndex])
                let desc = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                descriptions[optName] = desc
            }
        }

        print("DEBUG: Descriptions found: \(descriptions.count)")

        // Build options list
        for optName in optionsDefine {
            let isEnabled = optionsDefault.contains(optName)
            let description = descriptions[optName] ?? ""

            options.append(PortOption(
                name: optName,
                description: description,
                isEnabled: isEnabled
            ))
        }

        return options
    }
}

// MARK: - Security Operations

extension SSHConnectionManager {
    /// Audit packages for security vulnerabilities using pkg audit
    func auditPackageVulnerabilities() async throws -> [Vulnerability] {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Run pkg audit with -F to fetch latest VuXML database
        // Output format:
        // package-version is vulnerable:
        // CVE-XXXX-YYYY -- description
        // WWW: url
        // Note: pkg audit returns exit code 1 when vulnerabilities are found,
        // so we wrap it to always succeed
        let command = "pkg audit -F 2>&1; true"
        print("DEBUG: Running pkg audit...")
        let output = try await executeCommand(command)
        print("DEBUG: pkg audit output length: \(output.count)")
        print("DEBUG: pkg audit output preview: \(String(output.prefix(500)))")

        return parseVulnerabilities(output)
    }

    private func parseVulnerabilities(_ output: String) -> [Vulnerability] {
        var vulnerabilities: [Vulnerability] = []
        let lines = output.components(separatedBy: .newlines)

        var currentPackage = ""
        var currentVersion = ""
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            // Look for package line: "package-version is vulnerable:"
            if line.hasSuffix("is vulnerable:") {
                // Extract package name and version
                let parts = line.replacingOccurrences(of: " is vulnerable:", with: "")
                    .components(separatedBy: "-")

                // Version is usually the last part
                if !parts.isEmpty {
                    currentVersion = parts.last ?? ""
                    currentPackage = parts.dropLast().joined(separator: "-")
                }

                i += 1
                continue
            }

            // Look for CVE/vulnerability line
            if !currentPackage.isEmpty && line.contains("--") {
                let vulnParts = line.components(separatedBy: " -- ")
                if vulnParts.count >= 2 {
                    let vulnId = vulnParts[0].trimmingCharacters(in: .whitespaces)
                    let description = vulnParts[1].trimmingCharacters(in: .whitespaces)

                    // Look ahead for WWW line
                    var url = ""
                    if i + 1 < lines.count {
                        let nextLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
                        if nextLine.hasPrefix("WWW:") {
                            url = nextLine.replacingOccurrences(of: "WWW:", with: "")
                                .trimmingCharacters(in: .whitespaces)
                            i += 1 // Skip the WWW line
                        }
                    }

                    vulnerabilities.append(Vulnerability(
                        packageName: currentPackage,
                        version: currentVersion,
                        vuln: vulnId,
                        description: description,
                        url: url
                    ))
                }
            }

            i += 1
        }

        print("DEBUG: Parsed \(vulnerabilities.count) vulnerabilities")
        return vulnerabilities
    }
}

// MARK: - Jails Operations

extension SSHConnectionManager {
    /// Check if user is root
    func hasElevatedPrivileges() async throws -> Bool {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Check if user is root (UID = 0)
        let uidCommand = "id -u"
        let uid = try await executeCommand(uidCommand).trimmingCharacters(in: .whitespacesAndNewlines)

        let isRoot = uid == "0"
        print("DEBUG: User UID: \(uid), is root: \(isRoot)")
        return isRoot
    }

    /// List all jails (running and configured)
    func listJails() async throws -> [Jail] {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Use jls to get running jails
        // Format: JID IP Hostname Path
        let command = "jls -n jid name host.hostname path ip4.addr 2>/dev/null || echo ''"
        print("DEBUG: Listing jails...")
        let output = try await executeCommand(command)
        print("DEBUG: jls output: \(output)")

        // Get list of jails configured in rc.conf
        let rcConfJails = try await getManagedJails()

        return parseJails(output, managedJails: rcConfJails)
    }

    /// Get list of jails configured in /etc/jail.conf and /etc/jail.conf.d/
    private func getManagedJails() async throws -> Set<String> {
        // Check jail.conf and jail.conf.d for jail definitions
        let command = """
        {
            # Check main jail.conf
            if [ -f /etc/jail.conf ]; then
                awk '/^[[:space:]]*[a-zA-Z0-9_-]+[[:space:]]*{/ {gsub(/[[:space:]]*{.*/, ""); print}' /etc/jail.conf
            fi
            # Check jail.conf.d directory
            if [ -d /etc/jail.conf.d ]; then
                find /etc/jail.conf.d -type f \\( -name "*.conf" -o -name "*" ! -name ".*" \\) -exec awk '/^[[:space:]]*[a-zA-Z0-9_-]+[[:space:]]*{/ {gsub(/[[:space:]]*{.*/, ""); print}' {} \\;
            fi
        } | sort -u
        """
        let output = try await executeCommand(command).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !output.isEmpty else {
            print("DEBUG: No jails configured in /etc/jail.conf or /etc/jail.conf.d/")
            return Set()
        }

        // Parse list of jail names (one per line)
        let jailNames = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        print("DEBUG: Managed jails from jail.conf: \(jailNames)")
        return Set(jailNames)
    }

    /// Start a jail
    func startJail(name: String) async throws {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Try multiple methods to start jail
        let command = """
        if [ -f /etc/rc.d/jail ]; then
            service jail start \(name)
        elif [ -x /usr/local/bin/ezjail-admin ]; then
            ezjail-admin start \(name)
        elif [ -x /usr/local/bin/iocage ]; then
            iocage start \(name)
        else
            jail -c \(name)
        fi
        """
        print("DEBUG: Starting jail: \(name)")
        _ = try await executeCommand(command)
    }

    /// Stop a jail
    func stopJail(name: String) async throws {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Try multiple methods to stop jail
        let command = """
        if [ -f /etc/rc.d/jail ]; then
            service jail stop \(name)
        elif [ -x /usr/local/bin/ezjail-admin ]; then
            ezjail-admin stop \(name)
        elif [ -x /usr/local/bin/iocage ]; then
            iocage stop \(name)
        else
            jail -r \(name)
        fi
        """
        print("DEBUG: Stopping jail: \(name)")
        _ = try await executeCommand(command)
    }

    /// Restart a jail
    func restartJail(name: String) async throws {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Try multiple methods to restart jail
        let command = """
        if [ -f /etc/rc.d/jail ]; then
            service jail restart \(name)
        elif [ -x /usr/local/bin/ezjail-admin ]; then
            ezjail-admin restart \(name)
        elif [ -x /usr/local/bin/iocage ]; then
            iocage restart \(name)
        else
            jail -rc \(name)
        fi
        """
        print("DEBUG: Restarting jail: \(name)")
        _ = try await executeCommand(command)
    }

    /// Get jail configuration from /etc/jail.conf or /etc/jail.conf.d/
    func getJailConfig(name: String) async throws -> JailConfig {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Check both /etc/jail.conf and /etc/jail.conf.d/ for jail configuration
        // Only extract the specific jail's configuration block
        let command = """
        {
            # Check main jail.conf
            if [ -f /etc/jail.conf ]; then
                awk '
                    /^[[:space:]]*\(name)[[:space:]]*\\{/ { found=1; print; next }
                    found && /^[[:space:]]*\\}/ { print; found=0; exit }
                    found { print }
                ' /etc/jail.conf 2>/dev/null
            fi

            # Check jail.conf.d directory
            if [ -d /etc/jail.conf.d ]; then
                find /etc/jail.conf.d -type f \\( -name "*.conf" -o -name "*" ! -name ".*" \\) -exec awk '
                    /^[[:space:]]*\(name)[[:space:]]*\\{/ { found=1; print; next }
                    found && /^[[:space:]]*\\}/ { print; found=0; exit }
                    found { print }
                ' {} \\; 2>/dev/null
            fi
        } | head -1000
        """
        let output = try await executeCommand(command)

        return parseJailConfig(name: name, output: output)
    }

    /// Get jail resource usage
    func getJailResourceUsage(name: String) async throws -> JailResourceUsage {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Get process count and CPU usage via jexec
        let psCommand = "jexec \(name) ps aux 2>/dev/null | wc -l"
        let procCount = try await executeCommand(psCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Get memory usage from jls
        let memCommand = "jls -j \(name) -h name memoryuse 2>/dev/null | tail -1 | awk '{print $2}'"
        let memUsed = try await executeCommand(memCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // CPU percentage is harder to get, use a placeholder for now
        let cpuPercent = 0.0

        return JailResourceUsage(
            cpuPercent: cpuPercent,
            memoryUsed: formatBytes(memUsed),
            memoryLimit: "",
            processCount: Int(procCount) ?? 0
        )
    }

    // MARK: - Helpers

    private func parseJails(_ output: String, managedJails: Set<String>) -> [Jail] {
        var jails: [Jail] = []
        var runningJailNames: Set<String> = []

        // Parse running jails from jls output
        for line in output.components(separatedBy: .newlines) {
            guard !line.isEmpty else { continue }

            // Parse jls -n output format: key=value key=value
            var jid = ""
            var name = ""
            var hostname = ""
            var path = ""
            var ip = ""

            let parts = line.components(separatedBy: .whitespaces)
            for part in parts {
                let keyValue = part.components(separatedBy: "=")
                guard keyValue.count == 2 else { continue }

                let key = keyValue[0]
                let value = keyValue[1]

                switch key {
                case "jid": jid = value
                case "name": name = value
                case "host.hostname": hostname = value
                case "path": path = value
                case "ip4.addr": ip = value
                default: break
                }
            }

            if !jid.isEmpty && !name.isEmpty {
                let isManaged = managedJails.contains(name)
                print("DEBUG: Running jail \(name) isManaged: \(isManaged)")
                runningJailNames.insert(name)

                jails.append(Jail(
                    id: name,
                    jid: jid,
                    name: name,
                    hostname: hostname,
                    path: path,
                    ip: ip,
                    status: .running,
                    isManaged: isManaged
                ))
            }
        }

        // Add stopped jails from configuration
        for managedJailName in managedJails {
            if !runningJailNames.contains(managedJailName) {
                print("DEBUG: Adding stopped jail: \(managedJailName)")
                jails.append(Jail(
                    id: managedJailName,
                    jid: "",  // No JID for stopped jails
                    name: managedJailName,
                    hostname: "",
                    path: "",
                    ip: "",
                    status: .stopped,
                    isManaged: true  // By definition, it's from the config
                ))
            }
        }

        print("DEBUG: Parsed \(jails.count) total jails (\(runningJailNames.count) running, \(jails.count - runningJailNames.count) stopped)")
        return jails
    }

    private func parseJailConfig(name: String, output: String) -> JailConfig {
        var parameters: [String: String] = [:]
        var path = ""
        var hostname = ""
        var ip = ""

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { continue }

            // Parse "key = value;" format
            if let equalsIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
                var value = String(trimmed[trimmed.index(after: equalsIndex)...])
                    .trimmingCharacters(in: .whitespaces)

                // Remove trailing semicolon
                if value.hasSuffix(";") {
                    value = String(value.dropLast())
                        .trimmingCharacters(in: .whitespaces)
                }

                // Remove quotes
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }

                parameters[key] = value

                // Extract common fields
                switch key {
                case "path": path = value
                case "host.hostname": hostname = value
                case "ip4.addr": ip = value
                default: break
                }
            }
        }

        return JailConfig(
            name: name,
            path: path,
            hostname: hostname,
            ip: ip,
            parameters: parameters
        )
    }

    private func formatBytes(_ bytesStr: String) -> String {
        guard let bytes = Int(bytesStr) else { return bytesStr }

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

// MARK: - FreeBSD Data Fetchers

extension SSHConnectionManager {
    /// Fetch system status information
    func fetchSystemStatus() async throws -> SystemStatus {
        // Get uptime
        let uptimeOutput = try await executeCommand("uptime")
        let uptime = parseUptime(uptimeOutput)

        // Get active network connections count
        let connectionsOutput = try await executeCommand("netstat -an | grep ESTABLISHED | wc -l")
        let connectionCount = connectionsOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Get memory usage - use vm.stats.vm for accurate memory reporting
        let memInfo = try await executeCommand("sysctl -n hw.physmem vm.stats.vm.v_page_count vm.stats.vm.v_free_count vm.stats.vm.v_inactive_count hw.pagesize")
        let (totalMem, usedMem) = parseMemory(memInfo)

        // Get CPU usage (via top for overall)
        let topOutput = try await executeCommand("top -b -n 1 | head -3")
        let cpuUsage = parseCPUUsage(topOutput)

        // Get per-core CPU usage
        print("DEBUG: About to call parsePerCoreCPU()")
        var cpuCores: [Double] = []
        do {
            cpuCores = try await parsePerCoreCPU()
            print("DEBUG: parsePerCoreCPU returned \(cpuCores.count) cores")
        } catch {
            print("DEBUG: ERROR - parsePerCoreCPU failed: \(error)")
            // Continue with empty array
        }

        // Get ZFS ARC stats
        let arcStats = try await executeCommand("sysctl -n kstat.zfs.misc.arcstats.size kstat.zfs.misc.arcstats.c_max")
        let (arcUsed, arcMax) = parseARCStats(arcStats)

        // Get swap usage
        let swapOutput = try await executeCommand("swapinfo -k | tail -1")
        let (swapUsed, swapTotal) = parseSwapUsage(swapOutput)

        // Get storage usage
        let dfOutput = try await executeCommand("df -h /")
        let (storageUsed, storageTotal) = parseStorageUsage(dfOutput)

        // Get per-interface network statistics
        var networkInterfaces: [NetworkInterface] = []

        do {
            // Get raw netstat output per interface
            let netstatOutput = try await executeCommand("netstat -ibn | grep -v lo0 | grep Link")
            let currentInterfaceStats = parseNetstatByInterface(netstatOutput)

            print("DEBUG: Current interface stats: \(currentInterfaceStats)")

            // Calculate rates if we have a previous measurement
            let now = Date()
            if let lastTime = lastNetworkTime, !lastInterfaceStats.isEmpty {
                let timeInterval = now.timeIntervalSince(lastTime)
                if timeInterval > 0 {
                    for (interface, currentStats) in currentInterfaceStats.sorted(by: { $0.key < $1.key }) {
                        if let lastStats = lastInterfaceStats[interface] {
                            let inDelta = currentStats.inBytes > lastStats.inBytes ? currentStats.inBytes - lastStats.inBytes : 0
                            let outDelta = currentStats.outBytes > lastStats.outBytes ? currentStats.outBytes - lastStats.outBytes : 0

                            let inRate = Double(inDelta) / timeInterval
                            let outRate = Double(outDelta) / timeInterval

                            networkInterfaces.append(NetworkInterface(
                                name: interface,
                                inRate: formatBytesPerSecond(inRate),
                                outRate: formatBytesPerSecond(outRate)
                            ))

                            print("DEBUG: \(interface) - In: \(formatBytesPerSecond(inRate)), Out: \(formatBytesPerSecond(outRate))")
                        }
                    }
                }
            } else {
                // First call - return interfaces with 0 rates so they appear immediately
                print("DEBUG: First network stats call, returning interfaces with 0 rates")
                for interface in currentInterfaceStats.keys.sorted() {
                    networkInterfaces.append(NetworkInterface(
                        name: interface,
                        inRate: "0 B/s",
                        outRate: "0 B/s"
                    ))
                }
            }

            // Store current values for next calculation
            lastInterfaceStats = currentInterfaceStats
            lastNetworkTime = now
        } catch {
            print("DEBUG: Network stats error: \(error)")
            // Continue with empty interfaces
        }

        // Get per-disk I/O stats
        var disks: [DiskIO] = []
        do {
            let iostatOutput = try await executeCommand("iostat -x")
            let diskStats = parseDiskIO(iostatOutput)
            for stat in diskStats {
                disks.append(DiskIO(
                    name: stat.name,
                    readMBps: stat.readMBps,
                    writeMBps: stat.writeMBps,
                    totalMBps: stat.readMBps + stat.writeMBps
                ))
            }
        } catch {
            print("DEBUG: Disk I/O stats error: \(error)")
        }

        return SystemStatus(
            cpuUsage: String(format: "%.1f%%", cpuUsage),
            cpuCores: cpuCores,
            memoryUsage: String(format: "%.1f GB / %.1f GB", usedMem, totalMem),
            zfsArcUsage: String(format: "%.1f GB / %.1f GB", arcUsed, arcMax),
            swapUsage: String(format: "%.1f GB / %.1f GB", swapUsed, swapTotal),
            storageUsage: String(format: "%.1f GB / %.1f GB", storageUsed, storageTotal),
            uptime: uptime,
            disks: disks,
            networkInterfaces: networkInterfaces
        )
    }

}

// MARK: - Output Parsers

extension SSHConnectionManager {
    private func parseUptime(_ output: String) -> String {
        // Parse uptime output
        // Example: "10:30AM up 5 days, 3:24, 2 users, load averages: 0.52, 0.58, 0.59"
        // or: "10:30AM up 3:24, 2 users, load averages: 0.52, 0.58, 0.59"
        let components = output.components(separatedBy: "up ")
        if components.count > 1 {
            let uptimePart = components[1].components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces)

            var days = 0
            var hours = 0
            var minutes = 0

            // Check for "X days" or "X day"
            if uptimePart.contains("day") {
                let dayComponents = uptimePart.components(separatedBy: " ")
                if let dayValue = Int(dayComponents[0]) {
                    days = dayValue
                }

                // Check if there's also hours:minutes after "days"
                if uptimePart.contains(":") {
                    let timeComponents = uptimePart.components(separatedBy: ", ")
                    if timeComponents.count > 1 {
                        let timePart = timeComponents[1]
                        let hm = timePart.split(separator: ":")
                        if hm.count == 2 {
                            hours = Int(hm[0]) ?? 0
                            minutes = Int(hm[1]) ?? 0
                        }
                    }
                }
            } else if uptimePart.contains(":") {
                // Format: "3:24" (hours:minutes only, less than a day)
                let hm = uptimePart.split(separator: ":")
                if hm.count == 2 {
                    hours = Int(hm[0]) ?? 0
                    minutes = Int(hm[1]) ?? 0
                }
            }

            // Build friendly string
            var parts: [String] = []
            if days > 0 {
                parts.append("\(days) day\(days == 1 ? "" : "s")")
            }
            if hours > 0 {
                parts.append("\(hours) hour\(hours == 1 ? "" : "s")")
            }
            if minutes > 0 {
                parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")")
            }

            if parts.isEmpty {
                return "Just started"
            }

            return parts.joined(separator: " ")
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
        // Expected: hw.physmem, v_page_count, v_free_count, v_inactive_count, hw.pagesize
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }

        if lines.count >= 5 {
            let physmem = Double(lines[0]) ?? 0
            let pageCount = Double(lines[1]) ?? 0
            let freeCount = Double(lines[2]) ?? 0
            let inactiveCount = Double(lines[3]) ?? 0
            let pageSize = Double(lines[4]) ?? 0

            // Calculate memory in bytes
            // Total memory from physmem
            let totalBytes = physmem

            // Used memory = total pages - (free + inactive) pages
            // Free and inactive pages are available for use
            let availablePages = freeCount + inactiveCount
            let usedPages = pageCount - availablePages
            let usedBytes = usedPages * pageSize

            print("DEBUG: Memory calc - totalBytes=\(totalBytes), pageCount=\(pageCount), freeCount=\(freeCount), inactiveCount=\(inactiveCount), pageSize=\(pageSize)")
            print("DEBUG: Memory calc - usedPages=\(usedPages), usedBytes=\(usedBytes)")

            return (total: totalBytes / 1_073_741_824, used: usedBytes / 1_073_741_824) // Convert to GB
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

    private func parsePerCoreCPU() async throws -> [Double] {
        print("DEBUG: Starting parsePerCoreCPU()")

        // Get actual CPU count from system
        let cpuCountOutput = try await executeCommand("sysctl -n hw.ncpu")
        let actualCPUCount = Int(cpuCountOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        print("DEBUG: System reports hw.ncpu = \(actualCPUCount) CPUs")

        // Get per-core CPU usage using kern.cp_times
        // Format: user, nice, system, interrupt, idle (5 values per core, repeated for each core)

        // Get current snapshot
        print("DEBUG: Getting current CPU snapshot...")
        let snapshotOutput = try await executeCommand("sysctl -n kern.cp_times")
        print("DEBUG: Snapshot length: \(snapshotOutput.count), preview: \(snapshotOutput.prefix(200))")

        // Parse the current snapshot - trim to remove trailing newlines
        let trimmedOutput = snapshotOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let allComponents = trimmedOutput.components(separatedBy: .whitespaces)
        print("DEBUG: Total components before filtering: \(allComponents.count)")

        let filtered = allComponents.filter { !$0.isEmpty }
        print("DEBUG: After filtering empty: \(filtered.count) components")

        let currentValues = filtered.compactMap { UInt64($0) }

        print("DEBUG: Parsed current values count: \(currentValues.count)")
        if currentValues.count != filtered.count {
            print("DEBUG: WARNING - Some components failed to parse as UInt64!")
            print("DEBUG: Failed components: \(filtered.enumerated().filter { UInt64($0.element) == nil }.map { "[\($0.offset)]: '\($0.element)'" })")
        }
        print("DEBUG: Expected values for \(actualCPUCount) CPUs: \(actualCPUCount * 5)")
        print("DEBUG: Difference: \(currentValues.count - actualCPUCount * 5)")

        // Check if we have a previous snapshot
        let now = Date()
        guard !lastCPUSnapshot.isEmpty,
              lastCPUSnapshot.count == currentValues.count,
              let lastTime = lastCPUTime else {
            // First call - store snapshot and return placeholder data with 0% usage
            print("DEBUG: First CPU snapshot, storing for next call")
            lastCPUSnapshot = currentValues
            lastCPUTime = now

            // Return 0% usage for all cores so circles appear immediately
            print("DEBUG: Returning \(actualCPUCount) cores with 0% usage as placeholder")
            return Array(repeating: 0.0, count: actualCPUCount)
        }

        // Calculate time delta
        let timeDelta = now.timeIntervalSince(lastTime)
        print("DEBUG: Time delta: \(String(format: "%.2f", timeDelta)) seconds")

        // Use previous and current snapshots
        let values1 = lastCPUSnapshot
        let values2 = currentValues

        // Store current snapshot for next call
        lastCPUSnapshot = currentValues
        lastCPUTime = now

        print("DEBUG: Parsed values1 count: \(values1.count), values2 count: \(values2.count)")

        // Ensure we have valid data and same number of values
        guard !values1.isEmpty, values1.count == values2.count else {
            print("DEBUG: ERROR - Invalid kern.cp_times data: values1=\(values1.count), values2=\(values2.count)")
            print("DEBUG: values1 sample: \(values1.prefix(10))")
            print("DEBUG: values2 sample: \(values2.prefix(10))")
            // Return empty array to signal failure
            return []
        }

        // Use actual CPU count from hw.ncpu if available and reasonable
        var numCores = actualCPUCount

        // Validate we have enough data for the reported CPU count
        let expectedValues = actualCPUCount * 5
        if actualCPUCount > 0 && values1.count >= expectedValues {
            // We have at least enough data for all CPUs
            print("DEBUG: Using actual CPU count from hw.ncpu: \(actualCPUCount) cores")
            numCores = actualCPUCount
        } else {
            // Fall back to calculating from data
            numCores = values1.count / 5
            print("DEBUG: Falling back to calculated cores from data: \(numCores) cores")

            if values1.count % 5 != 0 {
                print("DEBUG: WARNING - Extra values detected: \(values1.count % 5) values beyond complete cores")
            }
        }

        guard numCores > 0 else {
            print("DEBUG: ERROR - No cores detected")
            return []
        }

        print("DEBUG: Processing \(numCores) CPU cores")
        var coreUsages: [Double] = []

        for core in 0..<numCores {
            let baseIdx = core * 5

            // Safety check to ensure we don't go out of bounds
            guard baseIdx + 4 < values1.count && baseIdx + 4 < values2.count else {
                print("DEBUG: WARNING - Skipping core \(core) due to insufficient data")
                continue
            }

            // Extract values for this core (user, nice, system, interrupt, idle)
            let user1 = values1[baseIdx]
            let nice1 = values1[baseIdx + 1]
            let system1 = values1[baseIdx + 2]
            let interrupt1 = values1[baseIdx + 3]
            let idle1 = values1[baseIdx + 4]

            let user2 = values2[baseIdx]
            let nice2 = values2[baseIdx + 1]
            let system2 = values2[baseIdx + 2]
            let interrupt2 = values2[baseIdx + 3]
            let idle2 = values2[baseIdx + 4]

            // Calculate deltas
            let userDelta = user2 > user1 ? user2 - user1 : 0
            let niceDelta = nice2 > nice1 ? nice2 - nice1 : 0
            let systemDelta = system2 > system1 ? system2 - system1 : 0
            let interruptDelta = interrupt2 > interrupt1 ? interrupt2 - interrupt1 : 0
            let idleDelta = idle2 > idle1 ? idle2 - idle1 : 0

            // Total ticks in this period
            let totalDelta = userDelta + niceDelta + systemDelta + interruptDelta + idleDelta

            // Debug first core to see what's happening
            if core == 0 {
                print("DEBUG: Core 0 - user:\(userDelta) nice:\(niceDelta) sys:\(systemDelta) int:\(interruptDelta) idle:\(idleDelta) total:\(totalDelta)")
            }

            // Calculate CPU usage percentage
            if totalDelta > 0 {
                let activeDelta = userDelta + niceDelta + systemDelta + interruptDelta
                let usage = (Double(activeDelta) / Double(totalDelta)) * 100.0
                coreUsages.append(usage)
            } else {
                // No ticks recorded, assume 0% usage
                coreUsages.append(0.0)
            }
        }

        print("DEBUG: Successfully parsed \(numCores) CPU cores: \(coreUsages.map { String(format: "%.1f%%", $0) }.joined(separator: ", "))")
        return coreUsages
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

    private func parseSwapUsage(_ output: String) -> (used: Double, total: Double) {
        // Parse swapinfo output
        // Format: Device 1K-blocks Used Avail Capacity
        // Example: /dev/ada0p3 4194304 0 4194304 0%
        let components = output.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        if components.count >= 3 {
            let totalKB = Double(components[1]) ?? 0
            let usedKB = Double(components[2]) ?? 0

            // Convert from KB to GB
            return (used: usedKB / 1_048_576, total: totalKB / 1_048_576)
        }

        return (used: 0, total: 0)
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

    private func parseNetstatByInterface(_ output: String) -> [String: (inBytes: UInt64, outBytes: UInt64)] {
        // Parse netstat -ibn for per-interface cumulative bytes
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var interfaceStats: [String: (inBytes: UInt64, outBytes: UInt64)] = [:]

        for line in lines {
            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            // FreeBSD netstat -ibn format with Link:
            // Name Mtu Network Address Ibytes Ierrs Idrop Obytes Oerrs Ocoll
            // em0  1500 <Link#1> 12:34:56:78:9a:bc 12345678 0 0 87654321 0 0

            guard components.count >= 8 else { continue }

            let interfaceName = components[0]

            // Skip if it contains angle brackets (Link addresses)
            if interfaceName.contains("<") || interfaceName.contains(">") {
                continue
            }

            // Ibytes is typically at index 4, Obytes at index 7
            if let inBytes = UInt64(components[4]),
               let outBytes = UInt64(components[7]) {
                interfaceStats[interfaceName] = (inBytes: inBytes, outBytes: outBytes)
            }
        }

        return interfaceStats
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

    private func parseDiskIO(_ output: String) -> [(name: String, readMBps: Double, writeMBps: Double)] {
        // Parse iostat -x output to get per-disk read/write rates
        // iostat -x format:
        // device     r/s   w/s    kr/s    kw/s  qlen  svc_t  %b
        // ada0      10.5   5.2   150.3    75.1     0    0.5   2

        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var disks: [(name: String, readMBps: Double, writeMBps: Double)] = []

        for line in lines {
            // Skip header lines
            if line.contains("device") || line.contains("r/s") || line.contains("KB/t") {
                continue
            }

            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            // iostat -x format on FreeBSD:
            // device   r/s   w/s    kr/s    kw/s  qlen  svc_t  %b
            //   0      1     2       3       4     5     6      7

            if components.count >= 5 {
                let deviceName = components[0]

                // Skip if device name contains special characters (might be garbage)
                if deviceName.contains("<") || deviceName.contains(">") {
                    continue
                }

                // Skip passthrough devices (pass0, pass1, etc.)
                if deviceName.hasPrefix("pass") {
                    continue
                }

                // kr/s is at index 3, kw/s is at index 4
                if let readKBps = Double(components[3]),
                   let writeKBps = Double(components[4]) {
                    // Convert KB/s to MB/s
                    disks.append((
                        name: deviceName,
                        readMBps: readKBps / 1024,
                        writeMBps: writeKBps / 1024
                    ))
                }
            }
        }

        return disks
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

    // MARK: - ZFS Management

    /// List all ZFS pools with their properties
    func listZFSPools() async throws -> [ZFSPool] {
        // Execute zpool list to get pool information
        let output = try await executeCommand("zpool list -H -o name,size,alloc,free,frag,cap,health,altroot")

        var pools: [ZFSPool] = []

        for line in output.split(separator: "\n") {
            let components = line.split(separator: "\t").map { String($0) }
            guard components.count >= 8 else { continue }

            let pool = ZFSPool(
                name: components[0],
                size: components[1],
                allocated: components[2],
                free: components[3],
                fragmentation: components[4],
                capacity: components[5],
                health: components[6],
                altroot: components[7]
            )
            pools.append(pool)
        }

        return pools
    }

    /// List all ZFS datasets with their properties
    func listZFSDatasets() async throws -> [ZFSDataset] {
        // Execute zfs list to get dataset information with all properties we need
        let output = try await executeCommand("zfs list -H -o name,used,avail,refer,mountpoint,compression,compressratio,quota,reservation,type")

        var datasets: [ZFSDataset] = []

        for line in output.split(separator: "\n") {
            let components = line.split(separator: "\t").map { String($0) }
            guard components.count >= 10 else { continue }

            let dataset = ZFSDataset(
                name: components[0],
                used: components[1],
                available: components[2],
                referenced: components[3],
                mountpoint: components[4],
                compression: components[5],
                compressRatio: components[6],
                quota: components[7],
                reservation: components[8],
                type: components[9]
            )
            datasets.append(dataset)
        }

        return datasets
    }

    /// Create a ZFS snapshot
    func createZFSSnapshot(dataset: String, snapshotName: String) async throws {
        let fullName = "\(dataset)@\(snapshotName)"
        _ = try await executeCommand("zfs snapshot \(fullName)")
    }

    /// Delete a ZFS snapshot
    func deleteZFSSnapshot(snapshot: String) async throws {
        _ = try await executeCommand("zfs destroy \(snapshot)")
    }

    /// Rollback a ZFS dataset to a snapshot
    func rollbackZFSSnapshot(snapshot: String) async throws {
        _ = try await executeCommand("zfs rollback -r \(snapshot)")
    }

    /// Clone a ZFS dataset from a snapshot
    func cloneZFSDataset(snapshot: String, destination: String) async throws {
        _ = try await executeCommand("zfs clone \(snapshot) \(destination)")
    }

    /// Get ZFS scrub status for all pools
    func getZFSScrubStatus() async throws -> [ZFSScrubStatus] {
        // Get list of all pools first
        let poolsOutput = try await executeCommand("zpool list -H -o name")
        let poolNames = poolsOutput.split(separator: "\n").map { String($0) }

        var statuses: [ZFSScrubStatus] = []

        for poolName in poolNames {
            // Get detailed status for each pool
            let statusOutput = try await executeCommand("zpool status \(poolName)")

            // Parse the scrub status from the output
            var state = "none"
            var progress: Double?
            var scanned: String?
            var issued: String?
            var duration: String?
            var errors = 0

            // Look for scrub information in the output
            let lines = statusOutput.split(separator: "\n")
            for (index, line) in lines.enumerated() {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)

                // Look for scrub status line
                if trimmedLine.hasPrefix("scan:") || trimmedLine.hasPrefix("scrub:") {
                    if trimmedLine.contains("in progress") || trimmedLine.contains("scrub in progress") {
                        state = "in progress"

                        // Try to extract progress percentage
                        if let percentRange = trimmedLine.range(of: #"(\d+\.?\d*)%"#, options: .regularExpression) {
                            let percentStr = String(trimmedLine[percentRange]).replacingOccurrences(of: "%", with: "")
                            progress = Double(percentStr)
                        }

                        // Extract scanned amount
                        if let scannedRange = trimmedLine.range(of: #"(\d+\.?\d*[KMGT]?) scanned"#, options: .regularExpression) {
                            scanned = String(trimmedLine[scannedRange]).replacingOccurrences(of: " scanned", with: "")
                        }
                    } else if trimmedLine.contains("completed") {
                        state = "completed"

                        // Extract completion time
                        if let dateRange = trimmedLine.range(of: #"on \w+ \w+ +\d+ \d+:\d+:\d+ \d+"#, options: .regularExpression) {
                            duration = String(trimmedLine[dateRange]).replacingOccurrences(of: "on ", with: "")
                        }
                    } else if trimmedLine.contains("none requested") {
                        state = "none requested"
                    }
                }

                // Look for errors
                if trimmedLine.hasPrefix("errors:") {
                    let errorStr = trimmedLine.replacingOccurrences(of: "errors:", with: "").trimmingCharacters(in: .whitespaces)
                    if errorStr.lowercased() != "no known data errors" {
                        // Try to extract error count
                        if let count = Int(errorStr) {
                            errors = count
                        }
                    }
                }
            }

            let status = ZFSScrubStatus(
                poolName: poolName,
                state: state,
                progress: progress,
                scanned: scanned,
                issued: issued,
                duration: duration,
                errors: errors
            )
            statuses.append(status)
        }

        return statuses
    }

    /// Start a scrub on a ZFS pool
    func startZFSScrub(pool: String) async throws {
        _ = try await executeCommand("zpool scrub \(pool)")
    }

    /// Stop a scrub on a ZFS pool
    func stopZFSScrub(pool: String) async throws {
        _ = try await executeCommand("zpool scrub -s \(pool)")
    }

    /// Replicate a ZFS dataset/snapshot to another server using ZFS send/receive
    func replicateDataset(dataset: String, targetHost: String, targetManager: SSHConnectionManager) async throws {
        // If it's a snapshot, replicate it directly
        // If it's a dataset, create a snapshot first, then replicate
        let snapshotToSend: String

        if dataset.contains("@") {
            // It's already a snapshot
            snapshotToSend = dataset
        } else {
            // Create a temporary snapshot for replication
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let snapshotName = "replication-\(timestamp)"
            try await createZFSSnapshot(dataset: dataset, snapshotName: snapshotName)
            snapshotToSend = "\(dataset)@\(snapshotName)"
        }

        // Use zfs send | zfs receive pattern
        // Note: This is a simplified version. In production, you'd want to:
        // 1. Check if the dataset exists on target
        // 2. Use incremental send if possible
        // 3. Handle resumable send/receive
        // 4. Show progress

        // For now, we'll execute the send on source and pipe to receive on target
        // This requires SSH access from source to target or using an intermediate method

        // Create the receive command on target
        let receiveCommand = "zfs receive -F \(snapshotToSend.split(separator: "@")[0])"

        // Execute send on source and capture output
        let sendCommand = "zfs send \(snapshotToSend)"

        // For now, we'll use a temporary file approach
        let tempFile = "/tmp/zfs-replication-\(UUID().uuidString).zfs"

        // Save send output to temp file on source
        _ = try await executeCommand("zfs send \(snapshotToSend) > \(tempFile)")

        // Copy to target using SCP-like functionality (through SSH)
        // Get the data
        let data = try await executeCommand("cat \(tempFile)")

        // Write to target
        _ = try await targetManager.executeCommand("cat > \(tempFile) << 'ZFSDATA'\n\(data)\nZFSDATA")

        // Execute receive on target
        _ = try await targetManager.executeCommand("cat \(tempFile) | \(receiveCommand)")

        // Cleanup
        _ = try await executeCommand("rm -f \(tempFile)")
        _ = try await targetManager.executeCommand("rm -f \(tempFile)")
    }

    // MARK: - Boot Environment Management

    /// List all boot environments using bectl
    func listBootEnvironments() async throws -> [BootEnvironment] {
        // Execute bectl list to get boot environment information
        let output = try await executeCommand("bectl list -H")

        var bootEnvironments: [BootEnvironment] = []

        for line in output.split(separator: "\n") {
            let components = line.split(separator: "\t").map { String($0) }
            guard components.count >= 5 else { continue }

            // Parse bectl list output format:
            // name active mountpoint space created
            let name = components[0]
            let activeFlags = components[1]  // Can be N, NR, R, or -
            let mountpoint = components[2]
            let space = components[3]
            let created = components[4]

            // Parse active flags
            // N = active now
            // R = active on reboot
            // NR = active now and on reboot
            let active = activeFlags.contains("N")
            let activeOnReboot = activeFlags.contains("R")

            let be = BootEnvironment(
                name: name,
                active: active,
                mountpoint: mountpoint,
                space: space,
                created: created,
                activeOnReboot: activeOnReboot
            )
            bootEnvironments.append(be)
        }

        return bootEnvironments
    }

    /// Create a new boot environment
    func createBootEnvironment(name: String, source: String?) async throws {
        if let source = source {
            // Clone from existing BE
            _ = try await executeCommand("bectl create -e \(source) \(name)")
        } else {
            // Create from current
            _ = try await executeCommand("bectl create \(name)")
        }
    }

    /// Activate a boot environment (set for next boot)
    func activateBootEnvironment(name: String) async throws {
        _ = try await executeCommand("bectl activate \(name)")
    }

    /// Delete a boot environment
    func deleteBootEnvironment(name: String) async throws {
        _ = try await executeCommand("bectl destroy -F \(name)")
    }

    /// Rename a boot environment
    func renameBootEnvironment(oldName: String, newName: String) async throws {
        _ = try await executeCommand("bectl rename \(oldName) \(newName)")
    }

    /// Mount a boot environment
    func mountBootEnvironment(name: String) async throws {
        _ = try await executeCommand("bectl mount \(name)")
    }

    /// Unmount a boot environment
    func unmountBootEnvironment(name: String) async throws {
        _ = try await executeCommand("bectl unmount \(name)")
    }

    // MARK: - NIS (Network Information Service) Methods

    /// Get NIS status (client and server)
    func getNISStatus() async throws -> NISStatus {
        // Check domain
        let domainOutput = try await executeCommand("domainname 2>/dev/null || echo ''")
        let domain = domainOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if ypbind (client) is running
        let ypbindCheck = try await executeCommand("ps aux | grep -v grep | grep ypbind | wc -l")
        let isClientEnabled = (Int(ypbindCheck.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0

        // Check if ypserv (server) is running
        let ypservCheck = try await executeCommand("ps aux | grep -v grep | grep ypserv | wc -l")
        let isServerEnabled = (Int(ypservCheck.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0

        // Try to get bound server if client is running
        var boundServer: String?
        if isClientEnabled {
            do {
                let serverOutput = try await executeCommand("ypwhich 2>/dev/null || echo ''")
                let server = serverOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !server.isEmpty && server != "ypwhich: not running ypbind" {
                    boundServer = server
                }
            } catch {
                // Ignore errors for ypwhich
            }
        }

        // Determine server type if server is running
        var serverType: NISStatus.ServerType?
        if isServerEnabled {
            // Check if this is a master or slave by looking for ypxfrd (typically only on master)
            let ypxfrdCheck = try await executeCommand("ps aux | grep -v grep | grep ypxfrd | wc -l")
            let hasYpxfrd = (Int(ypxfrdCheck.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0

            // Also check for /var/yp/Makefile which is typically only on master
            let makefileCheck = try await executeCommand("test -f /var/yp/Makefile && echo 'yes' || echo 'no'")
            let hasMakefile = makefileCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"

            serverType = (hasYpxfrd || hasMakefile) ? .master : .slave
        }

        return NISStatus(
            isClientEnabled: isClientEnabled,
            isServerEnabled: isServerEnabled,
            domain: domain,
            boundServer: boundServer,
            serverType: serverType
        )
    }

    /// Set NIS domain
    func setNISDomain(_ domain: String) async throws {
        // Set domain for current session
        _ = try await executeCommand("domainname \(domain)")

        // Enable in rc.conf for persistence
        _ = try await executeCommand("sysrc nisdomainname='\(domain)'")
    }

    /// Start NIS client
    func startNISClient() async throws {
        // Enable in rc.conf
        _ = try await executeCommand("sysrc nis_client_enable='YES'")

        // Start ypbind
        _ = try await executeCommand("service ypbind start")
    }

    /// Stop NIS client
    func stopNISClient() async throws {
        // Stop ypbind
        _ = try await executeCommand("service ypbind stop")

        // Disable in rc.conf
        _ = try await executeCommand("sysrc nis_client_enable='NO'")
    }

    /// Restart NIS client
    func restartNISClient() async throws {
        _ = try await executeCommand("service ypbind restart")
    }

    /// List available NIS maps
    func listNISMaps() async throws -> [NISMap] {
        // Get list of maps with their nicknames
        let output = try await executeCommand("ypcat -x 2>/dev/null || echo ''")

        var maps: [NISMap] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\"").map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
                let nickname = parts[0]
                let mapName = parts[1]

                // Try to get entry count
                var entries = 0
                do {
                    let countOutput = try await executeCommand("ypcat \(mapName) 2>/dev/null | wc -l")
                    entries = Int(countOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                } catch {
                    // If ypcat fails, continue with 0 entries
                }

                let map = NISMap(
                    name: mapName,
                    nickname: nickname,
                    entries: entries,
                    lastModified: nil
                )
                maps.append(map)
            }
        }

        return maps
    }

    /// Get entries from a specific NIS map
    func getNISMapEntries(mapName: String) async throws -> [NISMapEntry] {
        let output = try await executeCommand("ypcat \(mapName) 2>/dev/null || echo ''")

        var entries: [NISMapEntry] = []
        for line in output.split(separator: "\n") {
            let line = String(line)
            if let colonIndex = line.firstIndex(of: ":") ?? line.firstIndex(of: " ") {
                let key = String(line[..<colonIndex])
                let value = String(line[line.index(after: colonIndex)...])

                entries.append(NISMapEntry(
                    key: key.trimmingCharacters(in: .whitespaces),
                    value: value.trimmingCharacters(in: .whitespaces)
                ))
            }
        }

        return entries
    }

    /// Initialize NIS server
    func initializeNISServer(isMaster: Bool, masterServer: String?) async throws {
        if isMaster {
            // Initialize as master
            _ = try await executeCommand("cd /var/yp && ypinit -m <<EOF\n\nEOF")
        } else {
            // Initialize as slave
            guard let master = masterServer else {
                throw NSError(domain: "NIS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Master server required for slave initialization"])
            }
            _ = try await executeCommand("ypinit -s \(master)")
        }

        // Enable services in rc.conf
        _ = try await executeCommand("sysrc nis_server_enable='YES'")
        if isMaster {
            _ = try await executeCommand("sysrc nis_yppasswdd_enable='YES'")
            _ = try await executeCommand("sysrc nis_ypxfrd_enable='YES'")
        }
    }

    /// Start NIS server
    func startNISServer() async throws {
        // Start ypserv
        _ = try await executeCommand("service ypserv start")

        // Start yppasswdd if master
        _ = try await executeCommand("service yppasswdd start 2>/dev/null || true")

        // Start ypxfrd if master
        _ = try await executeCommand("service ypxfrd start 2>/dev/null || true")
    }

    /// Stop NIS server
    func stopNISServer() async throws {
        _ = try await executeCommand("service ypserv stop")
        _ = try await executeCommand("service yppasswdd stop 2>/dev/null || true")
        _ = try await executeCommand("service ypxfrd stop 2>/dev/null || true")
    }

    /// Restart NIS server
    func restartNISServer() async throws {
        _ = try await executeCommand("service ypserv restart")
        _ = try await executeCommand("service yppasswdd restart 2>/dev/null || true")
        _ = try await executeCommand("service ypxfrd restart 2>/dev/null || true")
    }

    /// Rebuild NIS maps
    func rebuildNISMaps() async throws {
        _ = try await executeCommand("cd /var/yp && make")
    }

    /// Push NIS maps to slave servers
    func pushNISMaps() async throws {
        _ = try await executeCommand("cd /var/yp && yppush -d $(domainname) passwd.byname")
        _ = try await executeCommand("cd /var/yp && yppush -d $(domainname) group.byname")
        _ = try await executeCommand("cd /var/yp && yppush -d $(domainname) hosts.byname")
    }

    /// List NIS server maps (from /var/yp/<domain>)
    func listNISServerMaps() async throws -> [NISMap] {
        let domain = try await executeCommand("domainname")
        let domainName = domain.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !domainName.isEmpty else {
            return []
        }

        let output = try await executeCommand("ls -la /var/yp/\(domainName)/*.db 2>/dev/null || echo ''")

        var maps: [NISMap] = []
        for line in output.split(separator: "\n") {
            let components = line.split(separator: " ").map { String($0) }
            if components.count >= 9 {
                // Extract filename from path
                let fullPath = components[8]
                if let filename = fullPath.split(separator: "/").last {
                    let mapName = String(filename).replacingOccurrences(of: ".db", with: "")

                    // Get size
                    let size = components[4]

                    // Get modification date
                    let dateStr = "\(components[5]) \(components[6]) \(components[7])"

                    maps.append(NISMap(
                        name: mapName,
                        nickname: "",
                        entries: 0,  // Would need to parse the db file
                        lastModified: dateStr
                    ))
                }
            }
        }

        return maps
    }

    /// List NIS slave servers
    func listNISSlaveServers() async throws -> [NISSlaveServer] {
        let domain = try await executeCommand("domainname")
        let domainName = domain.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !domainName.isEmpty else {
            return []
        }

        // Read ypservers map
        let output = try await executeCommand("cat /var/yp/\(domainName)/ypservers 2>/dev/null || echo ''")

        var slaves: [NISSlaveServer] = []
        for line in output.split(separator: "\n") {
            let hostname = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if !hostname.isEmpty {
                // Try to ping the server to check status
                let pingOutput = try await executeCommand("ping -c 1 -t 1 \(hostname) >/dev/null 2>&1 && echo 'active' || echo 'inactive'")
                let status = pingOutput.trimmingCharacters(in: .whitespacesAndNewlines)

                slaves.append(NISSlaveServer(
                    hostname: hostname,
                    status: status
                ))
            }
        }

        return slaves
    }

    // MARK: - NFS (Network File System) Methods

    /// Get NFS status (client and server)
    func getNFSStatus() async throws -> NFSStatus {
        // Check if rpcbind is running
        let rpcbindCheck = try await executeCommand("ps aux | grep -v grep | grep rpcbind | wc -l")
        let rpcbindRunning = (Int(rpcbindCheck.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0

        // Check if nfsd (server) is running
        let nfsdCheck = try await executeCommand("ps aux | grep -v grep | grep nfsd | wc -l")
        let isServerEnabled = (Int(nfsdCheck.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0

        // Check if there are any NFS mounts (client)
        let mountCheck = try await executeCommand("mount -t nfs,nfs4 2>/dev/null | wc -l")
        let hasMounts = (Int(mountCheck.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
        let isClientEnabled = rpcbindRunning && hasMounts

        // Get number of nfsd threads if server is running
        var nfsdThreads = 0
        if isServerEnabled {
            let threadsOutput = try await executeCommand("sysctl vfs.nfsd.server_max_nfsvers 2>/dev/null || echo '0'")
            nfsdThreads = Int(threadsOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        return NFSStatus(
            isClientEnabled: isClientEnabled,
            isServerEnabled: isServerEnabled,
            nfsdThreads: nfsdThreads,
            rpcbindRunning: rpcbindRunning
        )
    }

    /// List mounted NFS shares
    func listNFSMounts() async throws -> [NFSMount] {
        let output = try await executeCommand("mount -t nfs,nfs4 2>/dev/null || echo ''")

        var mounts: [NFSMount] = []
        for line in output.split(separator: "\n") {
            let line = String(line)
            // Parse: server:/path on /mountpoint (nfs, options)
            if let onIndex = line.range(of: " on "),
               let parenIndex = line.range(of: " (") {
                let serverPath = String(line[..<onIndex.lowerBound])
                let mountPoint = String(line[onIndex.upperBound..<parenIndex.lowerBound])
                let remainder = String(line[parenIndex.upperBound...])

                // Split server and path
                let serverParts = serverPath.split(separator: ":", maxSplits: 1)
                guard serverParts.count == 2 else { continue }

                let server = String(serverParts[0])
                let remotePath = String(serverParts[1])

                // Parse type and options
                let typeAndOptions = remainder.replacingOccurrences(of: ")", with: "").split(separator: ",", maxSplits: 1)
                let type = typeAndOptions.first.map(String.init) ?? "nfs"
                let options = typeAndOptions.count > 1 ? String(typeAndOptions[1]).trimmingCharacters(in: .whitespaces) : ""

                mounts.append(NFSMount(
                    server: server,
                    remotePath: remotePath,
                    mountPoint: mountPoint,
                    type: type.trimmingCharacters(in: .whitespaces),
                    options: options,
                    status: .mounted
                ))
            }
        }

        return mounts
    }

    /// Mount an NFS share
    func mountNFSShare(server: String, remotePath: String, mountPoint: String, options: String, addToFstab: Bool) async throws {
        // Create mount point if it doesn't exist
        _ = try await executeCommand("mkdir -p \(mountPoint)")

        // Build mount command
        var mountCmd = "mount -t nfs"
        if !options.isEmpty {
            mountCmd += " -o \(options)"
        }
        mountCmd += " \(server):\(remotePath) \(mountPoint)"

        _ = try await executeCommand(mountCmd)

        // Add to fstab if requested
        if addToFstab {
            let fstabEntry = "\(server):\(remotePath) \(mountPoint) nfs \(options.isEmpty ? "rw" : options) 0 0"
            _ = try await executeCommand("echo '\(fstabEntry)' >> /etc/fstab")
        }
    }

    /// Unmount an NFS share
    func unmountNFS(mountPoint: String) async throws {
        _ = try await executeCommand("umount \(mountPoint)")
    }

    /// Get NFS client statistics
    func getNFSClientStats() async throws -> NFSStats {
        let output = try await executeCommand("nfsstat -c 2>/dev/null || echo ''")

        // Parse nfsstat output for key metrics
        var getattr = "0"
        var lookup = "0"
        var read = "0"
        var write = "0"
        var total = "0"

        for line in output.split(separator: "\n") {
            let line = String(line).trimmingCharacters(in: .whitespaces)
            if line.contains("Getattr") {
                let parts = line.split(separator: " ")
                getattr = parts.last.map(String.init) ?? "0"
            } else if line.contains("Lookup") {
                let parts = line.split(separator: " ")
                lookup = parts.last.map(String.init) ?? "0"
            } else if line.contains("Read") {
                let parts = line.split(separator: " ")
                read = parts.last.map(String.init) ?? "0"
            } else if line.contains("Write") {
                let parts = line.split(separator: " ")
                write = parts.last.map(String.init) ?? "0"
            }
        }

        // Calculate total
        if let g = Int(getattr), let l = Int(lookup), let r = Int(read), let w = Int(write) {
            total = String(g + l + r + w)
        }

        return NFSStats(
            getattr: getattr,
            lookup: lookup,
            read: read,
            write: write,
            total: total
        )
    }

    /// Start NFS server
    func startNFSServer() async throws {
        // Enable services in rc.conf
        _ = try await executeCommand("sysrc rpcbind_enable='YES'")
        _ = try await executeCommand("sysrc nfs_server_enable='YES'")
        _ = try await executeCommand("sysrc mountd_enable='YES'")

        // Start services
        _ = try await executeCommand("service rpcbind start 2>/dev/null || service rpcbind restart")
        _ = try await executeCommand("service nfsd start")
        _ = try await executeCommand("service mountd start")
    }

    /// Stop NFS server
    func stopNFSServer() async throws {
        _ = try await executeCommand("service mountd stop")
        _ = try await executeCommand("service nfsd stop")

        // Disable in rc.conf
        _ = try await executeCommand("sysrc nfs_server_enable='NO'")
        _ = try await executeCommand("sysrc mountd_enable='NO'")
    }

    /// List NFS exports
    func listNFSExports() async throws -> [NFSExport] {
        // Read /etc/exports
        let output = try await executeCommand("cat /etc/exports 2>/dev/null || echo ''")

        var exports: [NFSExport] = []
        for line in output.split(separator: "\n") {
            let line = String(line).trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            // Parse: /path -options host1 host2
            let parts = line.split(separator: " ", maxSplits: 1)
            guard !parts.isEmpty else { continue }

            let path = String(parts[0])
            var clients = ""
            var options = ""

            if parts.count > 1 {
                let remainder = String(parts[1]).trimmingCharacters(in: .whitespaces)
                // Options start with - or are empty
                if remainder.hasPrefix("-") {
                    let optParts = remainder.split(separator: " ", maxSplits: 1)
                    options = String(optParts[0]).replacingOccurrences(of: "-", with: "")
                    if optParts.count > 1 {
                        clients = String(optParts[1])
                    }
                } else {
                    clients = remainder
                }
            }

            // Check if export is active (listed in exportfs output)
            let isActiveCheck = try await executeCommand("showmount -e localhost 2>/dev/null | grep '\(path)' | wc -l")
            let isActive = (Int(isActiveCheck.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0

            exports.append(NFSExport(
                path: path,
                clients: clients,
                options: options,
                isActive: isActive
            ))
        }

        return exports
    }

    /// Add NFS export
    func addNFSExport(path: String, clients: String, options: String) async throws {
        // Build export line
        var exportLine = path
        if !options.isEmpty {
            exportLine += " -\(options)"
        }
        if !clients.isEmpty {
            exportLine += " \(clients)"
        }

        // Add to /etc/exports
        _ = try await executeCommand("echo '\(exportLine)' >> /etc/exports")

        // Reload exports
        try await reloadNFSExports()
    }

    /// Remove NFS export
    func removeNFSExport(path: String) async throws {
        // Remove line from /etc/exports
        _ = try await executeCommand("sed -i '' '/^\(path.replacingOccurrences(of: "/", with: "\\/"))/d' /etc/exports")

        // Reload exports
        try await reloadNFSExports()
    }

    /// Reload NFS exports
    func reloadNFSExports() async throws {
        // Signal mountd to reload exports
        _ = try await executeCommand("service mountd reload 2>/dev/null || kill -HUP $(cat /var/run/mountd.pid 2>/dev/null) 2>/dev/null || true")
    }

    /// List connected NFS clients
    func listNFSClients() async throws -> [NFSClient] {
        let output = try await executeCommand("showmount -a 2>/dev/null || echo ''")

        var clients: [NFSClient] = []
        for line in output.split(separator: "\n") {
            let line = String(line).trimmingCharacters(in: .whitespaces)

            // Skip header lines
            if line.contains("All mounts") || line.isEmpty {
                continue
            }

            // Parse: hostname:/path
            if let colonIndex = line.firstIndex(of: ":") {
                let hostname = String(line[..<colonIndex])
                let path = String(line[line.index(after: colonIndex)...])

                clients.append(NFSClient(
                    hostname: hostname,
                    mountedPath: path
                ))
            }
        }

        return clients
    }

    /// Get NFS server statistics
    func getNFSServerStats() async throws -> NFSStats {
        let output = try await executeCommand("nfsstat -s 2>/dev/null || echo ''")

        // Parse nfsstat output for key metrics
        var getattr = "0"
        var lookup = "0"
        var read = "0"
        var write = "0"
        var total = "0"

        for line in output.split(separator: "\n") {
            let line = String(line).trimmingCharacters(in: .whitespaces)
            if line.contains("Getattr") {
                let parts = line.split(separator: " ")
                getattr = parts.last.map(String.init) ?? "0"
            } else if line.contains("Lookup") {
                let parts = line.split(separator: " ")
                lookup = parts.last.map(String.init) ?? "0"
            } else if line.contains("Read") {
                let parts = line.split(separator: " ")
                read = parts.last.map(String.init) ?? "0"
            } else if line.contains("Write") {
                let parts = line.split(separator: " ")
                write = parts.last.map(String.init) ?? "0"
            }
        }

        // Calculate total
        if let g = Int(getattr), let l = Int(lookup), let r = Int(read), let w = Int(write) {
            total = String(g + l + r + w)
        }

        return NFSStats(
            getattr: getattr,
            lookup: lookup,
            read: read,
            write: write,
            total: total
        )
    }

    // MARK: - Bhyve Virtual Machine Methods

    /// List bhyve virtual machines
    func listBhyveVMs() async throws -> [BhyveVM] {
        let output = try await executeCommand("vm list 2>/dev/null || echo ''")

        var vms: [BhyveVM] = []
        for line in output.split(separator: "\n") {
            let line = String(line).trimmingCharacters(in: .whitespaces)

            // Skip header lines
            if line.contains("NAME") || line.isEmpty {
                continue
            }

            // Parse: NAME  DATASTORE  LOADER  CPU  MEMORY  VNC  AUTOSTART  STATE
            let components = line.split(separator: " ").compactMap { part -> String? in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }

            guard components.count >= 8 else { continue }

            let name = components[0]
            let cpu = components[3]
            let memory = components[4]
            let vncStr = components[5]
            let autostartStr = components[6]
            let stateStr = components[7]

            // Parse VNC port
            var vncPort: Int?
            if vncStr != "-" && vncStr.contains(":") {
                let parts = vncStr.split(separator: ":")
                if let portStr = parts.last {
                    vncPort = Int(portStr)
                }
            }

            // Parse status
            let status: BhyveVM.VMStatus
            switch stateStr.lowercased() {
            case "running":
                status = .running
            case "stopped":
                status = .stopped
            default:
                status = .unknown
            }

            vms.append(BhyveVM(
                name: name,
                status: status,
                cpu: cpu,
                memory: memory,
                autostart: autostartStr == "Yes" || autostartStr == "1",
                vncPort: vncPort,
                serialPort: "/dev/nmdm-\(name).1A"  // Default serial port pattern
            ))
        }

        return vms
    }

    /// Start a bhyve VM
    func startBhyveVM(name: String) async throws {
        _ = try await executeCommand("vm start \(name)")
    }

    /// Stop a bhyve VM
    func stopBhyveVM(name: String) async throws {
        _ = try await executeCommand("vm stop \(name)")
    }

    /// Restart a bhyve VM
    func restartBhyveVM(name: String) async throws {
        _ = try await executeCommand("vm restart \(name)")
    }

    /// Delete a bhyve VM
    func deleteBhyveVM(name: String) async throws {
        _ = try await executeCommand("vm destroy -f \(name)")
    }

    /// Get detailed VM information
    func getBhyveVMInfo(name: String) async throws -> VMInfo {
        let output = try await executeCommand("vm info \(name) 2>/dev/null || echo ''")

        var cpu = "1"
        var memory = "512M"
        var disks: [String] = []
        var networks: [String] = []
        var bootrom = "default"
        var autostart = false

        for line in output.split(separator: "\n") {
            let line = String(line).trimmingCharacters(in: .whitespaces)

            if line.contains("cpu:") {
                cpu = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "1"
            } else if line.contains("memory:") {
                memory = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "512M"
            } else if line.contains("disk") {
                disks.append(line)
            } else if line.contains("network") {
                networks.append(line)
            } else if line.contains("loader:") {
                bootrom = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "default"
            } else if line.contains("autostart:") {
                let value = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "no"
                autostart = value.lowercased() == "yes" || value == "1"
            }
        }

        return VMInfo(
            name: name,
            cpu: cpu,
            memory: memory,
            disks: disks,
            networks: networks,
            bootrom: bootrom,
            autostart: autostart
        )
    }

    /// Create a new bhyve VM
    func createBhyveVM(name: String, cpu: String, memory: String, disk: String) async throws {
        // Create VM with basic configuration
        var createCmd = "vm create"
        createCmd += " -t generic"  // Generic template
        createCmd += " -c \(cpu)"
        createCmd += " -m \(memory)"
        createCmd += " -s \(disk)"
        createCmd += " \(name)"

        _ = try await executeCommand(createCmd)
    }

    // MARK: - IPFW Firewall Management

    func getFirewallStatus() async throws -> FirewallStatus {
        // Check if ipfw is enabled
        let enableCheck = try await executeCommand("sysctl net.inet.ip.fw.enable 2>/dev/null || echo '0'")
        let enabled = enableCheck.trimmingCharacters(in: .whitespacesAndNewlines).contains("1")

        // Count rules
        let rulesOutput = try await executeCommand("ipfw list 2>/dev/null | wc -l")
        let ruleCount = Int(rulesOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        // Count dynamic states
        let statesOutput = try await executeCommand("ipfw -d list 2>/dev/null | grep -c dynamic || echo '0'")
        let stateCount = Int(statesOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        return FirewallStatus(
            enabled: enabled,
            ruleCount: ruleCount,
            stateCount: stateCount
        )
    }

    func getFirewallRules() async throws -> [FirewallRule] {
        var rules: [FirewallRule] = []

        // Get ipfw rules with packet/byte counters
        let output = try await executeCommand("ipfw -a list 2>/dev/null")
        let lines = output.split(separator: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Parse ipfw rule format: 00100 12345 1234567 allow ip from any to any
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }

            let ruleNumber = String(parts[0])
            let packets = String(parts[1])
            let bytes = String(parts[2])
            let ruleLine = parts.count > 3 ? String(parts[3]) : ""

            // Parse action, proto, source, dest from rule line
            let ruleComponents = ruleLine.split(separator: " ", omittingEmptySubsequences: true)
            let action = ruleComponents.first.map(String.init) ?? "unknown"
            let proto = ruleComponents.count > 1 ? String(ruleComponents[1]) : "ip"

            // Find "from" and "to" keywords
            var source = "any"
            var destination = "any"
            var options = ""

            if let fromIndex = ruleComponents.firstIndex(of: "from"),
               fromIndex + 1 < ruleComponents.count {
                source = String(ruleComponents[fromIndex + 1])

                if let toIndex = ruleComponents.firstIndex(of: "to"),
                   toIndex + 1 < ruleComponents.count {
                    destination = String(ruleComponents[toIndex + 1])

                    // Everything after destination is options
                    if toIndex + 2 < ruleComponents.count {
                        options = ruleComponents[(toIndex + 2)...].joined(separator: " ")
                    }
                }
            }

            rules.append(FirewallRule(
                number: ruleNumber,
                action: action,
                proto: proto,
                source: source,
                destination: destination,
                options: options,
                packets: packets,
                bytes: bytes
            ))
        }

        return rules
    }

    func getFirewallStates() async throws -> [FirewallState] {
        var states: [FirewallState] = []

        // Get ipfw dynamic rules/states
        let output = try await executeCommand("ipfw -d list 2>/dev/null")
        let lines = output.split(separator: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("dynamic") else { continue }

            // Parse dynamic rule format
            // Example: ## 00001 (T 10, slot 3) tcp 192.168.1.100:12345 192.168.1.1:80 ESTABLISHED

            var proto = "tcp"
            var source = "unknown"
            var destination = "unknown"
            var state = "ACTIVE"

            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)

            // Find protocol
            if let protoIndex = parts.firstIndex(where: { $0 == "tcp" || $0 == "udp" || $0 == "icmp" }) {
                proto = String(parts[protoIndex])

                if protoIndex + 2 < parts.count {
                    source = String(parts[protoIndex + 1])
                    destination = String(parts[protoIndex + 2])

                    if protoIndex + 3 < parts.count {
                        state = String(parts[protoIndex + 3])
                    }
                }
            }

            states.append(FirewallState(
                proto: proto,
                source: source,
                destination: destination,
                state: state
            ))
        }

        return states
    }

    func getFirewallStats() async throws -> FirewallStats {
        // Get ipfw statistics from sysctl
        let packetsIn = try await executeCommand("sysctl -n net.inet.ip.fw.packets_in 2>/dev/null || echo '0'")
        let packetsOut = try await executeCommand("sysctl -n net.inet.ip.fw.packets_out 2>/dev/null || echo '0'")
        let bytesIn = try await executeCommand("sysctl -n net.inet.ip.fw.bytes_in 2>/dev/null || echo '0'")
        let bytesOut = try await executeCommand("sysctl -n net.inet.ip.fw.bytes_out 2>/dev/null || echo '0'")

        // Calculate blocked and passed from rules
        let rulesOutput = try await executeCommand("ipfw -a list 2>/dev/null")
        var blocked = 0
        var passed = 0

        for line in rulesOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("deny") || trimmed.contains("reject") {
                let parts = trimmed.split(separator: " ", maxSplits: 2)
                if parts.count >= 2, let count = Int(parts[1]) {
                    blocked += count
                }
            } else if trimmed.contains("allow") || trimmed.contains("pass") {
                let parts = trimmed.split(separator: " ", maxSplits: 2)
                if parts.count >= 2, let count = Int(parts[1]) {
                    passed += count
                }
            }
        }

        return FirewallStats(
            packetsIn: packetsIn.trimmingCharacters(in: .whitespacesAndNewlines),
            packetsOut: packetsOut.trimmingCharacters(in: .whitespacesAndNewlines),
            bytesIn: formatBytes(bytesIn.trimmingCharacters(in: .whitespacesAndNewlines)),
            bytesOut: formatBytes(bytesOut.trimmingCharacters(in: .whitespacesAndNewlines)),
            blocked: String(blocked),
            passed: String(passed)
        )
    }

    func reloadFirewallRules() async throws {
        // Reload IPFW rules
        _ = try await executeCommand("service ipfw reload 2>&1")
    }
}
