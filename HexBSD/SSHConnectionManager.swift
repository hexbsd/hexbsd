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

    // CPU tracking for per-core usage
    private var lastCPUSnapshot: [UInt64] = []
    private var lastCPUTime: Date?

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

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d HH:mm"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        for line in lines {
            // Skip empty lines and total line
            if line.isEmpty || line.starts(with: "total") {
                continue
            }

            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

            // Format: permissions links owner group size month day time name
            // Example: drwxr-xr-x 2 root wheel 512 Jan 10 15:30 Documents
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

            // Parse date
            let dateStr = "\(month) \(day) \(timeOrYear)"
            let date = dateFormatter.date(from: dateStr)

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

        // Get load average
        let loadAvg = try await executeCommand("sysctl -n vm.loadavg")
        let loads = parseLoadAverage(loadAvg)

        // Get memory usage
        let memInfo = try await executeCommand("sysctl -n hw.physmem hw.usermem")
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
            cpuCores: cpuCores,
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
            // First call - store snapshot and return empty
            print("DEBUG: First CPU snapshot, storing for next call")
            lastCPUSnapshot = currentValues
            lastCPUTime = now
            return []
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
