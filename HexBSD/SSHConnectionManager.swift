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

/// Async semaphore to limit concurrent operations
actor AsyncSemaphore {
    private let limit: Int
    private var count: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if count < limit {
            count += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            count -= 1
        }
    }
}

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

    // Connection parameters (stored for SCP)
    private var connectedHost: String?
    private var connectedPort: Int?
    private var connectedUsername: String?
    private var connectedKeyPath: String?

    // Network rate tracking per interface
    private var lastInterfaceStats: [String: (inBytes: UInt64, outBytes: UInt64)] = [:]
    private var lastNetworkTime: Date?

    // CPU tracking for per-core usage
    private var lastCPUSnapshot: [UInt64] = []
    private var lastCPUTime: Date?

    // Semaphore to limit concurrent SSH commands (SSH servers typically limit to ~10 channels)
    private let commandSemaphore = AsyncSemaphore(limit: 6)

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
            // Test raw socket connectivity first
            print("DEBUG: Testing raw socket connectivity to \(host):\(port)...")
            let socketTestResult = await testSocketConnectivity(host: host, port: port)
            print("DEBUG: Socket test result: \(socketTestResult)")

            print("DEBUG: Connecting to SSH server...")
            self.client = try await SSHClient.connect(to: settings)
            print("DEBUG: Connection successful!")
            self.isConnected = true
            self.serverAddress = host
            self.lastError = nil

            // Store connection parameters for SCP
            self.connectedHost = host
            self.connectedPort = port
            self.connectedUsername = authMethod.username
            self.connectedKeyPath = authMethod.privateKeyURL.path
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

    /// Test raw socket connectivity to diagnose connection issues
    private func testSocketConnectivity(host: String, port: Int) async -> String {
        return await Task.detached {
            var result = ""

            // Get address info
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC  // Allow both IPv4 and IPv6
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP

            var addrInfoPtr: UnsafeMutablePointer<addrinfo>?
            let portStr = String(port)

            let gaiResult = getaddrinfo(host, portStr, &hints, &addrInfoPtr)
            if gaiResult != 0 {
                if let errorStr = gai_strerror(gaiResult) {
                    result += "getaddrinfo failed: \(String(cString: errorStr))"
                } else {
                    result += "getaddrinfo failed with code \(gaiResult)"
                }
                return result
            }

            guard let addrInfo = addrInfoPtr else {
                return "No address info returned"
            }
            defer { freeaddrinfo(addrInfo) }

            // Try each address
            var current: UnsafeMutablePointer<addrinfo>? = addrInfo
            var addressIndex = 0

            while let addr = current {
                addressIndex += 1
                let family = addr.pointee.ai_family == AF_INET ? "IPv4" : "IPv6"

                // Get the IP string
                var ipStr = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if addr.pointee.ai_family == AF_INET {
                    var addr4 = addr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    inet_ntop(AF_INET, &addr4.sin_addr, &ipStr, socklen_t(INET_ADDRSTRLEN))
                } else {
                    var addr6 = addr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                    inet_ntop(AF_INET6, &addr6.sin6_addr, &ipStr, socklen_t(INET6_ADDRSTRLEN))
                }
                let ipString = String(cString: ipStr)

                result += "[\(addressIndex)] \(family) \(ipString):\(port) - "

                // Create socket
                let sock = Darwin.socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
                if sock < 0 {
                    result += "socket() failed: errno \(errno)\n"
                    current = addr.pointee.ai_next
                    continue
                }

                // Set non-blocking for timeout
                let flags = fcntl(sock, F_GETFL, 0)
                _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

                // Try to connect
                let connectResult = Darwin.connect(sock, addr.pointee.ai_addr, addr.pointee.ai_addrlen)

                if connectResult == 0 {
                    result += "SUCCESS (immediate)\n"
                    Darwin.close(sock)
                    current = addr.pointee.ai_next
                    continue
                }

                if errno == EINPROGRESS {
                    // Connection in progress, wait with poll instead of select (simpler in Swift)
                    var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
                    let pollResult = poll(&pfd, 1, 5000)  // 5 second timeout

                    if pollResult > 0 {
                        // Check if connection succeeded
                        var optval: Int32 = 0
                        var optlen = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(sock, SOL_SOCKET, SO_ERROR, &optval, &optlen)

                        if optval == 0 {
                            result += "SUCCESS\n"
                        } else {
                            result += "connect failed: errno \(optval) (\(String(cString: strerror(optval))))\n"
                        }
                    } else if pollResult == 0 {
                        result += "TIMEOUT\n"
                    } else {
                        result += "poll failed: errno \(errno)\n"
                    }
                } else {
                    result += "connect failed: errno \(errno) (\(String(cString: strerror(errno))))\n"
                }

                Darwin.close(sock)
                current = addr.pointee.ai_next
            }

            return result.isEmpty ? "No addresses to test" : result
        }.value
    }

    /// Execute a command on the remote server
    func executeCommand(_ command: String) async throws -> String {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Throttle concurrent SSH commands to avoid channel exhaustion
        await commandSemaphore.acquire()
        defer {
            Task { await commandSemaphore.release() }
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

        // Throttle concurrent SSH commands to avoid channel exhaustion
        await commandSemaphore.acquire()
        defer {
            Task { await commandSemaphore.release() }
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

    /// Execute a command with streaming output via a callback
    /// The callback is called for each chunk of output received
    /// Returns the exit code when the command completes
    func executeCommandStreaming(_ command: String, onOutput: @escaping (String) -> Void) async throws -> Int {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Throttle concurrent SSH commands to avoid channel exhaustion
        // Note: This holds the semaphore for the duration of the streaming command
        await commandSemaphore.acquire()
        defer {
            Task { await commandSemaphore.release() }
        }

        print("DEBUG: executeCommandStreaming starting with command: \(command)")

        // Wrap command to get exit code at the end, use script command to force line buffering
        // The script command creates a pseudo-terminal which forces programs to use line buffering
        let wrappedCommand = "script -q /dev/null sh -c '\(command.replacingOccurrences(of: "'", with: "'\\''")) 2>&1; echo EXIT_CODE:$?'"
        print("DEBUG: Wrapped command: \(wrappedCommand)")

        let streams = try await client.executeCommandStream(wrappedCommand)
        print("DEBUG: Got command streams, starting to read output")

        var allOutput = ""
        var outputCount = 0

        for try await event in streams {
            // Check for task cancellation
            try Task.checkCancellation()

            switch event {
            case .stdout(let data), .stderr(let data):
                let text = String(buffer: data)
                allOutput += text
                outputCount += 1
                print("DEBUG: Stream event #\(outputCount), received \(text.count) chars: \(text.prefix(100))...")

                // Don't output the exit code marker
                if !text.contains("EXIT_CODE:") {
                    await MainActor.run {
                        onOutput(text)
                    }
                }
            }
        }

        print("DEBUG: Stream finished, total output: \(allOutput.count) chars")

        // Parse exit code from the end
        if let range = allOutput.range(of: "EXIT_CODE:") {
            let exitCodeStr = allOutput[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            let exitCode = Int(exitCodeStr) ?? 1
            print("DEBUG: Parsed exit code: \(exitCode)")
            return exitCode
        }

        print("DEBUG: No exit code found, returning 0")
        return 0
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
        guard client != nil else {
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
        try await downloadFile(remotePath: remotePath, localURL: localURL, progressCallback: nil, cancelCheck: nil)
    }

    /// Download a file from the remote server with progress reporting
    func downloadFile(
        remotePath: String,
        localURL: URL,
        progressCallback: ((Int64, Int64, String) -> Void)?,
        cancelCheck: (() -> Bool)?
    ) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Get file size first
        let sizeOutput = try await executeCommand("stat -f %z '\(remotePath)' 2>/dev/null || ls -l '\(remotePath)' | awk '{print $5}'")
        let fileSize = Int64(sizeOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        print("DEBUG: Downloading file of size: \(fileSize) bytes")

        // Always use SCP for reliable binary transfers
        print("DEBUG: Using SCP for file download")
        return try await downloadWithSCP(remotePath: remotePath, localURL: localURL, fileSize: fileSize, progressCallback: progressCallback, cancelCheck: cancelCheck)
    }

    private func downloadWithSCP(
        remotePath: String,
        localURL: URL,
        fileSize: Int64,
        progressCallback: ((Int64, Int64, String) -> Void)?,
        cancelCheck: (() -> Bool)?
    ) async throws {
        guard let keyPath = connectedKeyPath else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No SSH key configured"])
        }

        guard let host = connectedHost else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }

        let user = connectedUsername ?? "root"
        let portNum = connectedPort ?? 22

        print("DEBUG: Starting SCP download from \(user)@\(host):\(remotePath)")

        let scpCommand = [
            "/usr/bin/scp",
            "-i", keyPath,
            "-P", "\(portNum)",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "\(user)@\(host):\(remotePath)",
            localURL.path
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: scpCommand[0])
        process.arguments = Array(scpCommand.dropFirst())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let startTime = Date()
        try process.run()

        // Monitor progress by checking local file size
        var lastReportedBytes: Int64 = 0
        while process.isRunning {
            // Check for cancellation
            if cancelCheck?() == true {
                process.terminate()
                try? FileManager.default.removeItem(at: localURL)
                throw NSError(domain: "SSHConnectionManager", code: 100,
                             userInfo: [NSLocalizedDescriptionKey: "Transfer cancelled"])
            }

            // Check file size for progress
            if let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path),
               let currentSize = attrs[.size] as? Int64 {
                if currentSize != lastReportedBytes {
                    let elapsed = Date().timeIntervalSince(startTime)
                    let rate = elapsed > 0 ? Double(currentSize) / elapsed : 0
                    let rateStr = formatTransferRate(rate)
                    progressCallback?(currentSize, fileSize, rateStr)
                    lastReportedBytes = currentSize
                }
            }

            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "SSHConnectionManager", code: Int(process.terminationStatus),
                         userInfo: [NSLocalizedDescriptionKey: "SCP failed: \(errorStr)"])
        }

        // Final progress update
        if let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path),
           let finalSize = attrs[.size] as? Int64 {
            progressCallback?(finalSize, fileSize, "")
        }
    }

    /// Download a directory recursively from the remote server
    func downloadDirectory(
        remotePath: String,
        localURL: URL,
        progressCallback: ((String) -> Void)?
    ) async throws {
        guard let keyPath = connectedKeyPath else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No SSH key configured"])
        }

        guard let host = connectedHost else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }

        let user = connectedUsername ?? "root"
        let portNum = connectedPort ?? 22

        print("DEBUG: Starting recursive SCP download from \(user)@\(host):\(remotePath)")
        progressCallback?("Downloading directory...")

        // Create local directory if it doesn't exist
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true, attributes: nil)

        // Check if remote directory is empty
        let listOutput = try await executeCommand("ls -A \"\(remotePath)\" 2>/dev/null | head -1")
        if listOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Directory is empty, just create the local directory (already done above)
            print("DEBUG: Remote directory is empty, created empty local directory")
            progressCallback?("Download complete (empty directory)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = [
            "-r",  // Recursive
            "-P", String(portNum),
            "-i", keyPath,
            "-o", "StrictHostKeyChecking=no",
            "-o", "BatchMode=yes",
            "\(user)@\(host):\(remotePath)/*",  // Copy contents of directory
            localURL.path
        ]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "SSHConnectionManager", code: Int(process.terminationStatus),
                         userInfo: [NSLocalizedDescriptionKey: "SCP failed: \(errorStr)"])
        }

        progressCallback?("Download complete")
    }

    /// Upload a directory recursively to the remote server
    func uploadDirectory(
        localURL: URL,
        remotePath: String,
        progressCallback: ((String) -> Void)?
    ) async throws {
        guard let keyPath = connectedKeyPath else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No SSH key configured"])
        }

        guard let host = connectedHost else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }

        let user = connectedUsername ?? "root"
        let portNum = connectedPort ?? 22

        print("DEBUG: Starting recursive SCP upload from \(localURL.path) to \(user)@\(host):\(remotePath)")
        progressCallback?("Uploading directory...")

        // Create remote directory first
        _ = try await executeCommand("mkdir -p \"\(remotePath)\"")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = [
            "-r",  // Recursive
            "-P", String(portNum),
            "-i", keyPath,
            "-o", "StrictHostKeyChecking=no",
            "-o", "BatchMode=yes",
            localURL.path,  // Source directory
            "\(user)@\(host):\(remotePath)"  // Destination path
        ]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "SSHConnectionManager", code: Int(process.terminationStatus),
                         userInfo: [NSLocalizedDescriptionKey: "SCP failed: \(errorStr)"])
        }

        progressCallback?("Upload complete")
    }

    private func formatTransferRate(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        let mb = kb / 1024

        if mb >= 1 {
            return String(format: "%.1f MB/s", mb)
        } else if kb >= 1 {
            return String(format: "%.0f KB/s", kb)
        } else {
            return String(format: "%.0f B/s", bytesPerSecond)
        }
    }

    /// Upload a file to the remote server
    func uploadFile(localURL: URL, remotePath: String, progressCallback: ((Double) -> Void)? = nil) async throws {
        try await uploadFile(localURL: localURL, remotePath: remotePath, detailedProgressCallback: nil, cancelCheck: nil)
    }

    /// Upload a file to the remote server with detailed progress reporting
    func uploadFile(
        localURL: URL,
        remotePath: String,
        detailedProgressCallback: ((Int64, Int64, String) -> Void)?,
        cancelCheck: (() -> Bool)?
    ) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Get file size
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        guard let fileSize = fileAttributes[.size] as? Int64 else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Could not determine file size"])
        }

        print("DEBUG: Uploading file of size: \(fileSize) bytes (\(Double(fileSize) / 1_000_000_000.0) GB)")

        // For large files (> 5MB), use scp which is much faster
        if fileSize > 5_000_000 {
            print("DEBUG: Using SCP for large file upload")
            return try await uploadWithSCPProgress(localURL: localURL, remotePath: remotePath, fileSize: fileSize, progressCallback: detailedProgressCallback, cancelCheck: cancelCheck)
        }

        // For small files (< 5MB), use single command method
        print("DEBUG: Using single-command upload for small file")
        detailedProgressCallback?(0, fileSize, "")

        // Check for cancellation
        if cancelCheck?() == true {
            throw NSError(domain: "SSHConnectionManager", code: 100,
                         userInfo: [NSLocalizedDescriptionKey: "Transfer cancelled"])
        }

        let data = try Data(contentsOf: localURL)
        let base64 = data.base64EncodedString()
        let command = "echo '\(base64)' | base64 -d > '\(remotePath)'"
        _ = try await executeCommand(command)
        detailedProgressCallback?(fileSize, fileSize, "")
    }

    private func uploadWithSCPProgress(
        localURL: URL,
        remotePath: String,
        fileSize: Int64,
        progressCallback: ((Int64, Int64, String) -> Void)?,
        cancelCheck: (() -> Bool)?
    ) async throws {
        guard let keyPath = connectedKeyPath else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No SSH key configured"])
        }

        guard let host = connectedHost else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }

        let user = connectedUsername ?? "root"
        let portNum = connectedPort ?? 22

        print("DEBUG: Starting SSH upload to \(user)@\(host):\(remotePath)")

        // Use SSH with cat to stream data - we can track bytes written to stdin
        let sshArgs = [
            "-i", keyPath,
            "-p", "\(portNum)",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "\(user)@\(host)",
            "cat > '\(remotePath)'"
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArgs

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        let startTime = Date()
        try process.run()

        // Read file and write to stdin in chunks, tracking progress
        let fileHandle = try FileHandle(forReadingFrom: localURL)
        defer { try? fileHandle.close() }

        let chunkSize = 64 * 1024 // 64KB chunks
        var totalBytesWritten: Int64 = 0
        var lastReportTime = startTime

        while true {
            // Check for cancellation
            if cancelCheck?() == true {
                process.terminate()
                throw NSError(domain: "SSHConnectionManager", code: 100,
                             userInfo: [NSLocalizedDescriptionKey: "Transfer cancelled"])
            }

            guard let chunk = try fileHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }

            stdinPipe.fileHandleForWriting.write(chunk)
            totalBytesWritten += Int64(chunk.count)

            // Report progress
            let now = Date()
            let elapsed = now.timeIntervalSince(startTime)
            let rate = elapsed > 0 ? Double(totalBytesWritten) / elapsed : 0
            let rateStr = formatTransferRate(rate)

            progressCallback?(totalBytesWritten, fileSize, rateStr)

            // Throttle progress updates to avoid flooding
            if now.timeIntervalSince(lastReportTime) > 0.1 {
                print("DEBUG: Upload progress: \(totalBytesWritten)/\(fileSize) bytes (\(rateStr))")
                lastReportTime = now
            }
        }

        // Close stdin to signal end of data
        try stdinPipe.fileHandleForWriting.close()

        // Wait for process to complete
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "SSHConnectionManager", code: Int(process.terminationStatus),
                         userInfo: [NSLocalizedDescriptionKey: "SSH upload failed: \(errorStr)"])
        }

        // Final progress update
        let elapsed = Date().timeIntervalSince(startTime)
        let rate = elapsed > 0 ? Double(fileSize) / elapsed : 0
        progressCallback?(fileSize, fileSize, formatTransferRate(rate))
    }

    private func uploadWithSCP(localURL: URL, remotePath: String, progressCallback: ((Double) -> Void)? = nil) async throws {
        // Use scp command for fast, reliable large file uploads
        // Format: scp -i keyfile localfile user@host:remotepath

        guard let keyPath = connectedKeyPath else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No SSH key configured"])
        }

        guard let host = connectedHost else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }

        let user = connectedUsername ?? "root"
        let portNum = connectedPort ?? 22

        print("DEBUG: Starting SCP upload to \(user)@\(host):\(remotePath)")

        // Build scp command
        let scpCommand = [
            "/usr/bin/scp",
            "-i", keyPath,
            "-P", "\(portNum)",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            localURL.path,
            "\(user)@\(host):\(remotePath)"
        ]

        print("DEBUG: SCP command: \(scpCommand.joined(separator: " "))")

        // Execute scp using Process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = Array(scpCommand.dropFirst())

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        // Report progress periodically while process runs
        let progressTask = Task {
            while process.isRunning {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                // SCP doesn't provide real-time progress, so we just show indeterminate
                progressCallback?(0.5)
            }
        }

        process.waitUntilExit()

        // Cancel the progress task to stop sending 0.5 updates
        progressTask.cancel()

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            print("DEBUG: SCP failed with status \(process.terminationStatus)")
            print("DEBUG: SCP error output: \(errorOutput)")
            throw NSError(domain: "SSHConnectionManager", code: Int(process.terminationStatus),
                         userInfo: [NSLocalizedDescriptionKey: "SCP upload failed: \(errorOutput)"])
        }

        print("DEBUG: SCP upload completed successfully")
        progressCallback?(1.0)
    }

    /// Delete a file or directory on the remote server
    func deleteFile(path: String, isDirectory: Bool) async throws {
        guard client != nil else {
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
        guard client != nil else {
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
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Use tail to get last N lines
        let command = "tail -n \(lines) '\(path)'"
        return try await executeCommand(command)
    }

    /// Stream log file updates using tail -f
    func streamLogFile(path: String, onNewLine: @escaping (String) -> Void) async throws {
        guard let client = client else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Use tail -f to follow log file updates
        // Using -F to also handle log rotation
        let command = "tail -F '\(path)' 2>/dev/null"

        let streams = try await client.executeCommandStream(command)

        for try await event in streams {
            // Check for task cancellation
            try Task.checkCancellation()

            switch event {
            case .stdout(let data), .stderr(let data):
                let text = String(buffer: data)
                // Split into lines and call callback for each
                let lines = text.components(separatedBy: "\n")
                for line in lines where !line.isEmpty {
                    onNewLine(line)
                }
            }
        }
    }

    /// Search all log files for a pattern, returns files with match counts
    func searchAllLogs(pattern: String) async throws -> [LogSearchResult] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Escape single quotes in the pattern for shell safety
        let escapedPattern = pattern.replacingOccurrences(of: "'", with: "'\\''")

        // Use grep -c to count matches per file, -i for case insensitive
        // Only search readable non-compressed files
        // Wrap in a subshell that always exits 0 to avoid TTY errors
        let command = """
        (for f in /var/log/*; do
            if [ -f "$f" ] && [ -r "$f" ]; then
                case "$f" in
                    *.bz2|*.gz|*.xz) ;;
                    *)
                        count=$(grep -ci '\(escapedPattern)' "$f" 2>/dev/null) || count=0
                        if [ "$count" -gt 0 ] 2>/dev/null; then
                            size=$(ls -lh "$f" 2>/dev/null | awk '{print $5}')
                            echo "$count|$size|$f"
                        fi
                        ;;
                esac
            fi
        done) 2>/dev/null; true
        """
        let output = try await executeCommand(command)

        return parseLogSearchResults(output)
    }

    private func parseLogSearchResults(_ output: String) -> [LogSearchResult] {
        var results: [LogSearchResult] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines where !line.isEmpty {
            let parts = line.components(separatedBy: "|")
            guard parts.count == 3,
                  let count = Int(parts[0]) else { continue }

            let size = parts[1]
            let path = parts[2]
            let name = (path as NSString).lastPathComponent

            results.append(LogSearchResult(
                name: name,
                path: path,
                size: size,
                matchCount: count
            ))
        }

        // Sort by match count descending
        return results.sorted { $0.matchCount > $1.matchCount }
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

// MARK: - Network Connection Operations

extension SSHConnectionManager {
    /// List all network connections using sockstat
    func listNetworkConnections() async throws -> [NetworkConnection] {
        guard client != nil else {
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
        guard client != nil else {
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
        guard client != nil else {
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
        guard client != nil else {
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
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Check if poudriere is installed
        let checkCommand = "command -v poudriere >/dev/null 2>&1 && echo 'installed' || echo 'not-installed'"
        let checkOutput = try await executeCommand(checkCommand)

        if checkOutput.trimmingCharacters(in: .whitespacesAndNewlines) != "installed" {
            return PoudriereInfo(isInstalled: false, htmlPath: "", dataPath: "", configPath: nil, runningBuilds: [], hasBuilds: false)
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
        _ = try await executeCommand(confCommand)

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

            # Validate that POUDRIERE_DATA actually exists
            # If configured path doesn't exist, try standard fallbacks
            if [ ! -d "$POUDRIERE_DATA" ]; then
                echo "DIAG:Configured POUDRIERE_DATA '$POUDRIERE_DATA' does not exist"
                # Try common fallback locations
                if [ -d "/usr/local/poudriere/data" ]; then
                    POUDRIERE_DATA="/usr/local/poudriere/data"
                    echo "DIAG:Using fallback: /usr/local/poudriere/data"
                elif [ -n "$BASEFS" ] && [ -d "${BASEFS}/data" ]; then
                    POUDRIERE_DATA="${BASEFS}/data"
                    echo "DIAG:Using fallback: ${BASEFS}/data"
                else
                    echo "DIAG:No valid data directory found, using default"
                    POUDRIERE_DATA="/usr/local/poudriere/data"
                fi
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

            # Validate that POUDRIERE_DATA actually exists
            # If configured path doesn't exist, try standard fallbacks
            if [ ! -d "$POUDRIERE_DATA" ]; then
                # Try common fallback locations
                if [ -d "/usr/local/poudriere/data" ]; then
                    POUDRIERE_DATA="/usr/local/poudriere/data"
                elif [ -n "$BASEFS" ] && [ -d "${BASEFS}/data" ]; then
                    POUDRIERE_DATA="${BASEFS}/data"
                fi
            fi

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

        // Check if any builds have been run by looking for build directories in logs/bulk
        // Find where build logs are stored - check multiple possible locations
        print("DEBUG: Looking for build logs, dataPath: \(dataPath)")
        let findLogsCommand = """
        echo "=== Searching for poudriere logs ==="
        echo "Checking \(dataPath):"
        ls -la '\(dataPath)' 2>&1 | head -10
        echo ""
        echo "Checking for logs directory:"
        find '\(dataPath)' -maxdepth 3 -type d -name 'logs' 2>/dev/null | head -5
        echo ""
        echo "Checking for bulk directory:"
        find '\(dataPath)' -maxdepth 4 -type d -name 'bulk' 2>/dev/null | head -5
        echo ""
        echo "Looking for .html files (build results):"
        find '\(dataPath)' -maxdepth 5 -name '*.html' 2>/dev/null | head -5
        echo ""
        echo "Checking /usr/local/poudriere:"
        ls -la /usr/local/poudriere 2>&1 | head -10
        echo ""
        echo "Checking if any builds exist anywhere:"
        if find '\(dataPath)' -maxdepth 5 -type f -name '*.html' 2>/dev/null | head -1 | grep -q .; then
            echo 'has-builds'
        elif find /usr/local/poudriere -maxdepth 5 -type d -name 'bulk' 2>/dev/null | head -1 | grep -q .; then
            echo 'has-builds'
        else
            echo 'no-builds'
        fi
        """
        let buildCheckOutput = try await executeCommand(findLogsCommand)
        print("DEBUG: Build check output:\n\(buildCheckOutput)")
        let hasBuilds = buildCheckOutput.contains("has-builds")
        print("  - Has Builds: \(hasBuilds)")

        return PoudriereInfo(
            isInstalled: true,
            htmlPath: htmlPath,
            dataPath: dataPath,
            configPath: customConfigPath,
            runningBuilds: runningBuilds,
            hasBuilds: hasBuilds
        )
    }

    /// Load HTML content from poudriere
    func loadPoudriereHTML(path: String) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Read the HTML file
        let command = "cat '\(path)' 2>/dev/null || echo ''"
        let content = try await executeCommand(command)

        return content
    }

    /// List all poudriere jails
    func listPoudriereJails() async throws -> [PoudriereJail] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // poudriere jail -l outputs: NAME VERSION ARCH METHOD TIMESTAMP PATH
        let command = "poudriere jail -l -q 2>/dev/null || echo ''"
        let output = try await executeCommand(command)

        var jails: [PoudriereJail] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Split by whitespace, handling variable spacing
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if parts.count >= 6 {
                let jail = PoudriereJail(
                    id: parts[0],
                    name: parts[0],
                    version: parts[1],
                    arch: parts[2],
                    method: parts[3],
                    timestamp: parts[4],
                    path: parts[5]
                )
                jails.append(jail)
            }
        }

        return jails
    }

    /// Create a new poudriere jail (kept for backwards compatibility, but streaming version is preferred)
    func createPoudriereJail(name: String, version: String, arch: String, method: String) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let command = "poudriere jail -c -j '\(name)' -v '\(version)' -a '\(arch)' -m '\(method)'"
        print("DEBUG: Creating poudriere jail with command: \(command)")

        // Wrap command to capture exit code and output even on failure
        let wrappedCommand = """
        \(command) 2>&1; echo "EXIT_CODE:$?"
        """

        let output = try await executeCommand(wrappedCommand)
        print("DEBUG: Jail creation raw output: \(output)")

        // Parse exit code from output
        let lines = output.components(separatedBy: .newlines)
        var exitCode = 0
        var resultOutput = ""

        for line in lines {
            if line.hasPrefix("EXIT_CODE:") {
                exitCode = Int(line.replacingOccurrences(of: "EXIT_CODE:", with: "")) ?? 0
            } else {
                resultOutput += line + "\n"
            }
        }

        resultOutput = resultOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        print("DEBUG: Jail creation output: \(resultOutput)")
        print("DEBUG: Jail creation exit code: \(exitCode)")

        if exitCode != 0 {
            throw NSError(domain: "SSHConnectionManager", code: exitCode,
                         userInfo: [NSLocalizedDescriptionKey: "Jail creation failed: \(resultOutput)"])
        }

        return resultOutput
    }

    /// Delete a poudriere jail
    func deletePoudriereJail(name: String) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let command = "poudriere jail -d -j '\(name)'"
        let output = try await executeCommand(command)
        return output
    }

    /// Update a poudriere jail
    func updatePoudriereJail(name: String) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let command = "poudriere jail -u -j '\(name)'"
        let output = try await executeCommand(command)
        return output
    }

    /// List all poudriere ports trees
    func listPoudrierePortsTrees() async throws -> [PoudrierePortsTree] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // poudriere ports -l outputs: PORTSTREE METHOD TIMESTAMP PATH
        // Timestamp can contain spaces (e.g., "2024-01-15 13:55:26")
        // The path is always last and starts with /
        let command = "poudriere ports -l -q 2>/dev/null || echo ''"
        let output = try await executeCommand(command)

        var trees: [PoudrierePortsTree] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            // Need at least: name, method, and path (path starts with /)
            if parts.count >= 3 {
                let name = parts[0]
                let method = parts[1]

                // Find the path - it's the last element that starts with /
                var path = ""
                var timestampParts: [String] = []

                for i in 2..<parts.count {
                    if parts[i].hasPrefix("/") {
                        path = parts[i]
                    } else if path.isEmpty {
                        // Everything between method and path is timestamp
                        timestampParts.append(parts[i])
                    }
                }

                let timestamp = timestampParts.joined(separator: " ")

                let tree = PoudrierePortsTree(
                    id: name,
                    name: name,
                    method: method,
                    timestamp: timestamp,
                    path: path
                )
                trees.append(tree)
                print("DEBUG: Parsed ports tree - name: \(name), method: \(method), timestamp: \(timestamp), path: \(path)")
            }
        }

        return trees
    }

    /// Create a new poudriere ports tree
    func createPoudrierePortsTree(name: String, method: String, branch: String? = nil) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        var command = "poudriere ports -c -p '\(name)' -m '\(method)'"
        if let branch = branch, !branch.isEmpty, method.contains("git") {
            command += " -B '\(branch)'"
        }

        let output = try await executeCommand(command)
        return output
    }

    /// Delete a poudriere ports tree
    func deletePoudrierePortsTree(name: String) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let command = "poudriere ports -d -p '\(name)'"
        let output = try await executeCommand(command)
        return output
    }

    /// Update a poudriere ports tree
    func updatePoudrierePortsTree(name: String) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let command = "poudriere ports -u -p '\(name)'"
        let output = try await executeCommand(command)
        return output
    }

    /// Start a bulk build with all packages
    func startPoudriereBulkAll(jail: String, portsTree: String, clean: Bool = false, test: Bool = false) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        var command = "poudriere bulk -j '\(jail)' -p '\(portsTree)' -a"
        if clean { command += " -c" }
        if test { command += " -t" }

        // Run in background with nohup so it survives SSH disconnection
        command = "nohup \(command) > /tmp/poudriere-bulk-\(jail)-\(portsTree).log 2>&1 &"

        let output = try await executeCommand(command)
        return output
    }

    /// Start a bulk build with specific packages
    func startPoudriereBulkPackages(jail: String, portsTree: String, packages: [String], clean: Bool = false, test: Bool = false) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // First validate that all packages exist in the ports tree
        let trees = try await listPoudrierePortsTrees()
        guard let tree = trees.first(where: { $0.name == portsTree }) else {
            throw NSError(domain: "SSHConnectionManager", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Ports tree not found: \(portsTree)"])
        }

        print("DEBUG: Validating packages in ports tree at: \(tree.path)")
        var invalidPackages: [String] = []
        for pkg in packages {
            let checkCommand = "test -d '\(tree.path)/\(pkg)' && echo 'exists' || echo 'missing'"
            print("DEBUG: Checking package '\(pkg)' with command: \(checkCommand)")
            let result = try await executeCommand(checkCommand)
            let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
            print("DEBUG: Result for '\(pkg)': '\(trimmedResult)'")
            if trimmedResult == "missing" {
                invalidPackages.append(pkg)
            }
        }

        print("DEBUG: Invalid packages: \(invalidPackages)")
        if !invalidPackages.isEmpty {
            throw NSError(domain: "SSHConnectionManager", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "Package(s) not found in ports tree: \(invalidPackages.joined(separator: ", "))"])
        }

        let packageList = packages.joined(separator: " ")
        var command = "poudriere bulk -j '\(jail)' -p '\(portsTree)' \(packageList)"
        if clean { command += " -c" }
        if test { command += " -t" }

        // Run in background with nohup so it survives SSH disconnection
        command = "nohup \(command) > /tmp/poudriere-bulk-\(jail)-\(portsTree).log 2>&1 &"

        let output = try await executeCommand(command)
        return output
    }

    /// Start a bulk build from a package list file
    func startPoudriereBulkFromFile(jail: String, portsTree: String, listFile: String, clean: Bool = false, test: Bool = false) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // First validate that the list file exists
        let checkCommand = "test -f '\(listFile)' && echo 'exists' || echo 'missing'"
        let result = try await executeCommand(checkCommand)
        if result.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
            throw NSError(domain: "SSHConnectionManager", code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "Package list file not found: \(listFile)"])
        }

        var command = "poudriere bulk -j '\(jail)' -p '\(portsTree)' -f '\(listFile)'"
        if clean { command += " -c" }
        if test { command += " -t" }

        // Run in background with nohup so it survives SSH disconnection
        command = "nohup \(command) > /tmp/poudriere-bulk-\(jail)-\(portsTree).log 2>&1 &"

        let output = try await executeCommand(command)
        return output
    }

    /// Search for packages in the ports tree
    func searchPoudrierePorts(query: String, portsTree: String) async throws -> [BuildablePackage] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Get the ports tree path
        let trees = try await listPoudrierePortsTrees()
        guard let tree = trees.first(where: { $0.name == portsTree }) else {
            throw NSError(domain: "SSHConnectionManager", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Ports tree not found: \(portsTree)"])
        }

        // Search in the ports tree using make search
        // This searches the INDEX file for matching ports
        let command = """
        cd '\(tree.path)' && make search name='\(query)' 2>/dev/null | grep -E '^Port:|^Path:|^Info:' | paste - - - | head -50
        """

        let output = try await executeCommand(command)

        var packages: [BuildablePackage] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Parse: Port: name\tPath: /usr/ports/cat/name\tInfo: description
            var origin = ""
            var comment = ""

            let parts = trimmed.components(separatedBy: "\t")
            for part in parts {
                if part.hasPrefix("Path:") {
                    let path = part.replacingOccurrences(of: "Path:", with: "").trimmingCharacters(in: .whitespaces)
                    // Extract category/port from path
                    let pathParts = path.components(separatedBy: "/")
                    if pathParts.count >= 2 {
                        origin = "\(pathParts[pathParts.count - 2])/\(pathParts[pathParts.count - 1])"
                    }
                } else if part.hasPrefix("Info:") {
                    comment = part.replacingOccurrences(of: "Info:", with: "").trimmingCharacters(in: .whitespaces)
                }
            }

            if !origin.isEmpty {
                packages.append(BuildablePackage(origin: origin, comment: comment))
            }
        }

        return packages
    }

    /// Get list of categories from the ports tree
    func getPoudrierePortsCategories(portsTree: String) async throws -> [String] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let trees = try await listPoudrierePortsTrees()
        guard let tree = trees.first(where: { $0.name == portsTree }) else {
            throw NSError(domain: "SSHConnectionManager", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Ports tree not found: \(portsTree)"])
        }

        let command = "ls -d '\(tree.path)'/*/ 2>/dev/null | xargs -I{} basename {} | grep -v '^\\.' | sort"
        let output = try await executeCommand(command)

        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Mk") && !$0.hasPrefix("Tools") && !$0.hasPrefix("Templates") }
    }

    /// Get packages in a specific category
    func getPoudrierePortsInCategory(portsTree: String, category: String) async throws -> [BuildablePackage] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let trees = try await listPoudrierePortsTrees()
        guard let tree = trees.first(where: { $0.name == portsTree }) else {
            throw NSError(domain: "SSHConnectionManager", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Ports tree not found: \(portsTree)"])
        }

        let command = """
        for port in '\(tree.path)/\(category)'/*/; do
            if [ -f "$port/Makefile" ]; then
                name=$(basename "$port")
                comment=$(make -C "$port" -V COMMENT 2>/dev/null | head -1)
                echo "\(category)/$name|$comment"
            fi
        done
        """

        let output = try await executeCommand(command)

        var packages: [BuildablePackage] = []
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let parts = trimmed.components(separatedBy: "|")
            let origin = parts[0]
            let comment = parts.count > 1 ? parts[1] : ""

            packages.append(BuildablePackage(origin: origin, comment: comment))
        }

        return packages
    }

    /// Read poudriere.conf configuration
    func readPoudriereConfig() async throws -> PoudriereConfig {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let command = """
        if [ -f /usr/local/etc/poudriere.conf ]; then
            cat /usr/local/etc/poudriere.conf
        elif [ -f /etc/poudriere.conf ]; then
            cat /etc/poudriere.conf
        else
            echo ""
        fi
        """

        let output = try await executeCommand(command)

        var config = PoudriereConfig.default

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.components(separatedBy: "=")
            if parts.count >= 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                var value = parts.dropFirst().joined(separator: "=")
                    .trimmingCharacters(in: .whitespaces)
                // Remove surrounding quotes (both single and double)
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                   (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }

                switch key {
                case "ZPOOL": config.zpool = value
                case "BASEFS": config.basefs = value
                case "POUDRIERE_DATA": config.poudriereData = value
                case "DISTFILES_CACHE": config.distfilesCache = value
                case "FREEBSD_HOST": config.freebsdHost = value
                case "USE_PORTLINT": config.usePortlint = value.lowercased() == "yes"
                case "USE_TMPFS": config.useTmpfs = value
                case "PARALLEL_JOBS", "MAKE_JOBS": config.makeJobs = Int(value) ?? 4
                case "ALLOW_MAKE_JOBS_PACKAGES": config.allowMakeJobsPackages = value
                case "NO_ZFS": config.noZfs = value.lowercased() == "yes"
                default: break
                }
            }
        }

        return config
    }

    /// Write poudriere.conf configuration
    func writePoudriereConfig(_ config: PoudriereConfig) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Build config content, handling UFS mode (NO_ZFS)
        var configLines = [
            "# Poudriere configuration",
            "# Generated by HexBSD",
            ""
        ]

        if config.noZfs {
            // UFS mode - no ZFS available
            configLines.append("# Running in UFS mode (no ZFS)")
            configLines.append("NO_ZFS=yes")
            configLines.append("")
        } else {
            // ZFS mode
            configLines.append("# The pool where poudriere will create all datasets")
            configLines.append("ZPOOL=\(config.zpool)")
            configLines.append("")
        }

        configLines.append(contentsOf: [
            "# Root of the poudriere filesystem",
            "BASEFS=\(config.basefs)",
            "",
            "# Where poudriere stores data",
            "POUDRIERE_DATA=\(config.poudriereData)",
            "",
            "# Cache for distfiles",
            "DISTFILES_CACHE=\(config.distfilesCache)",
            "",
            "# FreeBSD mirror for jail creation",
            "FREEBSD_HOST=\(config.freebsdHost)",
            "",
            "# Use portlint for QA checks",
            "USE_PORTLINT=\(config.usePortlint ? "yes" : "no")",
            "",
            "# Use tmpfs for work directories",
            "USE_TMPFS=\(config.useTmpfs)",
            "",
            "# Number of parallel jobs",
            "PARALLEL_JOBS=\(config.makeJobs)",
            "",
            "# Packages that can use more jobs",
            "ALLOW_MAKE_JOBS_PACKAGES=\"\(config.allowMakeJobsPackages)\""
        ])

        let configContent = configLines.joined(separator: "\n")

        // Determine config path
        let checkPath = "test -f /usr/local/etc/poudriere.conf && echo '/usr/local/etc/poudriere.conf' || echo '/usr/local/etc/poudriere.conf'"
        let configPath = try await executeCommand(checkPath).trimmingCharacters(in: .whitespacesAndNewlines)

        // Backup existing config
        _ = try? await executeCommand("cp '\(configPath)' '\(configPath).bak' 2>/dev/null")

        // Write new config
        let escapedContent = configContent.replacingOccurrences(of: "'", with: "'\\''")
        let command = "echo '\(escapedContent)' > '\(configPath)'"
        _ = try await executeCommand(command)
    }

    /// Get available ZFS pools for poudriere
    func getAvailableZpools() async throws -> [String] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let command = "zpool list -Ho name 2>/dev/null || echo ''"
        let output = try await executeCommand(command)

        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Fetch available FreeBSD releases from the configured mirror
    /// Releases are organized by architecture, auto-detects host architecture if not specified
    func getAvailableFreeBSDReleases(mirror: String = "https://download.FreeBSD.org", arch: String? = nil) async throws -> [String] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Use provided arch or detect host architecture
        let archPath: String
        if let providedArch = arch {
            // Map architecture names to FreeBSD mirror paths
            switch providedArch {
            case "aarch64", "arm64":
                archPath = "arm64/aarch64"
            case "amd64", "x86_64":
                archPath = "amd64"
            default:
                archPath = providedArch
            }
        } else {
            // Auto-detect host architecture
            let hostArch = try await executeCommand("uname -m").trimmingCharacters(in: .whitespacesAndNewlines)
            switch hostArch {
            case "aarch64", "arm64":
                archPath = "arm64/aarch64"
            case "amd64", "x86_64":
                archPath = "amd64"
            default:
                archPath = hostArch
            }
        }

        // Fetch the releases directory listing from the mirror
        // Releases are at /releases/<arch>/ e.g., /releases/amd64/14.2-RELEASE/
        let command = """
        fetch -qo - '\(mirror)/releases/\(archPath)/' 2>/dev/null | \
        grep -oE 'href="[0-9]+\\.[0-9]+-RELEASE/"' | \
        sed 's/href="//;s/\\/"$//' | \
        sort -t. -k1,1rn -k2,2rn | \
        uniq
        """

        let output = try await executeCommand(command)

        var releases = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.contains("-RELEASE") }

        if releases.isEmpty {
            // Fallback if fetch fails
            releases = ["15.0-RELEASE", "14.3-RELEASE", "14.2-RELEASE", "13.5-RELEASE", "13.4-RELEASE"]
        }

        return releases
    }

    /// Fetch available architectures from the FreeBSD mirror
    func getAvailableArchitectures(mirror: String = "https://download.FreeBSD.org") async throws -> [String] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Fetch the architecture directory listing - architectures are at /releases/
        let command = """
        fetch -qo - '\(mirror)/releases/' 2>/dev/null | \
        grep -oE 'href="(amd64|i386|arm64|arm|powerpc|riscv)/"' | \
        sed 's/href="//;s/\\/"$//' | \
        sort | uniq
        """

        let output = try await executeCommand(command)

        var archs = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if archs.isEmpty {
            // Fallback if fetch fails
            archs = ["amd64", "arm64", "i386"]
        }

        return archs
    }

    /// Get the host system's architecture
    func getHostArchitecture() async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let command = "uname -p"
        let output = try await executeCommand(command)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if QEMU user-static is installed for cross-architecture builds
    func checkQemuInstalled() async throws -> Bool {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let command = "pkg info -e qemu-user-static && echo 'installed' || echo 'not-installed'"
        let output = try await executeCommand(command)
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "installed"
    }

    /// Install QEMU user-static for cross-architecture builds
    func installQemu() async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let command = "pkg install -y qemu-user-static 2>&1"
        let output = try await executeCommand(command)
        return output
    }
}

// MARK: - Security Operations

extension SSHConnectionManager {
    /// Audit packages for security vulnerabilities using pkg audit
    func auditPackageVulnerabilities() async throws -> [Vulnerability] {
        guard client != nil else {
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

        // pkg audit output format:
        // package-version is vulnerable:
        //   title -- Short description
        //   CVE: CVE-xxxx
        //   CVE: CVE-yyyy (possibly multiple)
        //   WWW: url
        //
        //   title -- Another description
        //   CVE: CVE-zzzz
        //   WWW: url

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

            // Look for vulnerability description line: "title -- description"
            if !currentPackage.isEmpty && line.contains(" -- ") {
                let vulnParts = line.components(separatedBy: " -- ")
                if vulnParts.count >= 2 {
                    let title = vulnParts[0].trimmingCharacters(in: .whitespaces)
                    let description = vulnParts[1].trimmingCharacters(in: .whitespaces)

                    // Collect CVEs and URL from following lines
                    var cves: [String] = []
                    var url = ""
                    i += 1

                    while i < lines.count {
                        let nextLine = lines[i].trimmingCharacters(in: .whitespaces)

                        if nextLine.hasPrefix("CVE:") {
                            let cve = nextLine.replacingOccurrences(of: "CVE:", with: "")
                                .trimmingCharacters(in: .whitespaces)
                            cves.append(cve)
                            i += 1
                        } else if nextLine.hasPrefix("WWW:") {
                            url = nextLine.replacingOccurrences(of: "WWW:", with: "")
                                .trimmingCharacters(in: .whitespaces)
                            i += 1
                            break  // WWW marks end of this vulnerability block
                        } else if nextLine.isEmpty {
                            i += 1
                            break  // Empty line marks end of block
                        } else {
                            break  // Something else, stop collecting
                        }
                    }

                    // Create vulnerability ID string from CVEs or use title
                    let vulnId = cves.isEmpty ? title : cves.joined(separator: ", ")

                    vulnerabilities.append(Vulnerability(
                        packageName: currentPackage,
                        version: currentVersion,
                        vuln: vulnId,
                        description: "\(title) -- \(description)",
                        url: url
                    ))
                    continue  // Don't increment i again
                }
            }

            i += 1
        }

        print("DEBUG: Parsed \(vulnerabilities.count) vulnerabilities")
        return vulnerabilities
    }

    // MARK: - Firewall (ipfw) Operations

    /// Get the current firewall status and rules
    func getFirewallStatus() async throws -> (status: FirewallStatus, rules: [FirewallRule]) {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        print("DEBUG: getFirewallStatus - checking if ipfw exists...")

        // Check if ipfw exists
        let whichOutput = try await executeCommand("which ipfw 2>/dev/null || echo 'not found'")
        print("DEBUG: which ipfw output: '\(whichOutput.trimmingCharacters(in: .whitespacesAndNewlines))'")
        if whichOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "not found" {
            print("DEBUG: ipfw not found")
            return (status: .notInstalled, rules: [])
        }

        // Check if firewall is enabled by looking for rules
        // ipfw list returns rules if enabled, or just the default rule 65535
        print("DEBUG: Getting ipfw list...")
        let listOutput = try await executeCommand("ipfw list 2>&1 || echo 'ERROR'")
        print("DEBUG: ipfw list output: '\(listOutput)'")

        // "Protocol not available" means ipfw module is not loaded = firewall disabled
        if listOutput.contains("Protocol not available") {
            print("DEBUG: ipfw module not loaded - firewall disabled")
            return (status: .disabled, rules: [])
        }

        if listOutput.contains("ERROR") || listOutput.contains("Permission denied") {
            print("DEBUG: ipfw list error or permission denied")
            // Need root, try with sudo check
            let sudoCheck = try await executeCommand("id -u")
            if sudoCheck.trimmingCharacters(in: .whitespacesAndNewlines) != "0" {
                throw NSError(domain: "SSHConnectionManager", code: 2,
                             userInfo: [NSLocalizedDescriptionKey: "Root privileges required to manage firewall"])
            }
            return (status: .unknown, rules: [])
        }

        let rules = parseFirewallRules(listOutput)
        print("DEBUG: Parsed \(rules.count) firewall rules")

        // If only the default allow rule exists (65535), firewall is effectively disabled
        // If we have more rules, it's enabled
        if rules.count <= 1 {
            print("DEBUG: Firewall status: disabled (only default rule)")
            return (status: .disabled, rules: rules)
        } else {
            print("DEBUG: Firewall status: enabled (\(rules.count) rules)")
            return (status: .enabled, rules: rules)
        }
    }

    /// Enable firewall with default secure rules (SSH allowed, block all else)
    func enableFirewall() async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        print("DEBUG: enableFirewall - starting...")

        // Write the rules to /etc/ipfw.rules first (before starting firewall)
        print("DEBUG: Writing /etc/ipfw.rules...")
        let rulesContent = """
#!/bin/sh
# HexBSD Firewall Rules
ipfw -q flush
# Allow loopback traffic
ipfw -q add 00100 allow all from any to any via lo0 // loopback
# Check state for return traffic (must be before outbound rule)
ipfw -q add 00150 check-state // check-state
# Allow all outgoing traffic and track state
ipfw -q add 00200 allow all from any to any out keep-state // outbound
# Allow SSH inbound
ipfw -q add 01000 allow tcp from any to any 22 in // SSH
# Deny everything else inbound
ipfw -q add 65534 deny log all from any to any in // deny-all-inbound
"""
        let writeRulesOutput = try await executeCommand("printf '%s' '\(rulesContent.replacingOccurrences(of: "'", with: "'\\''"))' > /etc/ipfw.rules 2>&1")
        print("DEBUG: write rules output: '\(writeRulesOutput)'")

        let chmodOutput = try await executeCommand("chmod +x /etc/ipfw.rules 2>&1")
        print("DEBUG: chmod output: '\(chmodOutput)'")

        // Configure rc.conf
        print("DEBUG: Setting sysrc firewall_enable...")
        let sysrcEnableOutput = try await executeCommand("sysrc firewall_enable=\"YES\" 2>&1")
        print("DEBUG: sysrc enable output: '\(sysrcEnableOutput)'")

        print("DEBUG: Setting sysrc firewall_script...")
        let sysrcScriptOutput = try await executeCommand("sysrc firewall_script=\"/etc/ipfw.rules\" 2>&1")
        print("DEBUG: sysrc script output: '\(sysrcScriptOutput)'")

        print("DEBUG: Setting sysrc firewall_logging...")
        let sysrcLoggingOutput = try await executeCommand("sysrc firewall_logging=\"YES\" 2>&1")
        print("DEBUG: sysrc logging output: '\(sysrcLoggingOutput)'")

        // Remove firewall_type if set (we're using firewall_script instead)
        print("DEBUG: Removing firewall_type if set...")
        let removeTypeOutput = try await executeCommand("sysrc -x firewall_type 2>&1 || true")
        print("DEBUG: remove type output: '\(removeTypeOutput)'")

        // Start/restart the firewall service (this loads the module safely)
        print("DEBUG: Starting ipfw service...")
        let serviceOutput = try await executeCommand("service ipfw restart 2>&1")
        print("DEBUG: service ipfw output: '\(serviceOutput)'")

        print("DEBUG: enableFirewall - complete")
    }

    /// Disable firewall and flush all rules
    func disableFirewall() async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        print("DEBUG: disableFirewall - starting...")

        // Stop the firewall service
        print("DEBUG: Stopping ipfw service...")
        let stopOutput = try await executeCommand("service ipfw stop 2>&1")
        print("DEBUG: service stop output: '\(stopOutput)'")

        // Disable at boot
        print("DEBUG: Setting sysrc firewall_enable=NO...")
        let sysrcOutput = try await executeCommand("sysrc firewall_enable=\"NO\" 2>&1")
        print("DEBUG: sysrc output: '\(sysrcOutput)'")

        // Unload the kernel module
        print("DEBUG: Unloading ipfw module...")
        let kldunloadOutput = try await executeCommand("kldunload ipfw 2>&1 || true")
        print("DEBUG: kldunload output: '\(kldunloadOutput)'")

        print("DEBUG: disableFirewall - complete")
    }

    /// Parse ipfw list output into FirewallRule objects
    private func parseFirewallRules(_ output: String) -> [FirewallRule] {
        var rules: [FirewallRule] = []
        let lines = output.components(separatedBy: .newlines)

        // ipfw list format:
        // 00100 allow ip from any to any via lo0
        // 00200 allow tcp from any to any established
        // 00300 allow tcp from any to any dst-port 22 in
        // 65535 allow ip from any to any

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Extract comment if present (after //)
            var rulePart = trimmed
            var comment = ""
            if let commentIndex = trimmed.range(of: "//") {
                rulePart = String(trimmed[..<commentIndex.lowerBound]).trimmingCharacters(in: .whitespaces)
                comment = String(trimmed[commentIndex.upperBound...]).trimmingCharacters(in: .whitespaces)
            }

            let parts = rulePart.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 4 else { continue }

            // First part should be the rule number
            guard let ruleNumber = Int(parts[0]) else { continue }

            let action = parts[1]
            let proto = parts.count > 2 ? parts[2] : "ip"

            // Parse source and destination
            var source = "any"
            var destination = "any"
            var options = ""

            // Find "from" and "to" keywords
            if let fromIndex = parts.firstIndex(of: "from"),
               fromIndex + 1 < parts.count {
                source = parts[fromIndex + 1]
            }

            if let toIndex = parts.firstIndex(of: "to"),
               toIndex + 1 < parts.count {
                destination = parts[toIndex + 1]
            }

            // Collect remaining options (ports, flags, etc.)
            var optionParts: [String] = []
            if let toIndex = parts.firstIndex(of: "to"),
               toIndex + 2 < parts.count {
                optionParts = Array(parts[(toIndex + 2)...])
            }
            options = optionParts.joined(separator: " ")

            rules.append(FirewallRule(
                ruleNumber: ruleNumber,
                action: action,
                proto: proto,
                source: source,
                destination: destination,
                options: options,
                comment: comment,
                rawRule: trimmed
            ))
        }

        return rules
    }

    /// Add a new firewall rule
    func addFirewallRule(ruleNumber: Int, action: String, proto: String, source: String, destination: String, port: Int?, direction: String?, comment: String?) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        var ruleCmd = "ipfw -q add \(String(format: "%05d", ruleNumber)) \(action) \(proto) from \(source) to \(destination)"

        if let port = port {
            ruleCmd += " \(port)"
        }

        if let direction = direction, !direction.isEmpty {
            ruleCmd += " \(direction)"
        }

        if let comment = comment, !comment.isEmpty {
            ruleCmd += " // \(comment)"
        }

        print("DEBUG: Adding firewall rule: \(ruleCmd)")
        let output = try await executeCommand("\(ruleCmd) 2>&1")
        print("DEBUG: Add rule output: '\(output)'")

        // Also update /etc/ipfw.rules to persist the rule
        try await updateIpfwRulesFile()
    }

    /// Delete a firewall rule by number
    func deleteFirewallRule(ruleNumber: Int) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        print("DEBUG: Deleting firewall rule: \(ruleNumber)")
        let output = try await executeCommand("ipfw -q delete \(ruleNumber) 2>&1")
        print("DEBUG: Delete rule output: '\(output)'")

        // Also update /etc/ipfw.rules to persist the change
        try await updateIpfwRulesFile()
    }

    /// Update /etc/ipfw.rules with current rules for persistence
    private func updateIpfwRulesFile() async throws {
        // Get current rules
        let rulesOutput = try await executeCommand("ipfw list 2>&1")

        // Build the rules file content with proper base rules
        // Note: ipfw list doesn't show check-state/keep-state keywords, so we hardcode the base rules
        var content = """
#!/bin/sh
# HexBSD Firewall Rules
ipfw -q flush
# Allow loopback traffic
ipfw -q add 00100 allow all from any to any via lo0 // loopback
# Check state for return traffic (must be before outbound rule)
ipfw -q add 00150 check-state // check-state
# Allow all outgoing traffic and track state
ipfw -q add 00200 allow all from any to any out keep-state // outbound

"""

        // Add user-defined rules (skip base rules we already added)
        let baseRuleNumbers = Set(["00100", "00150", "00200", "65534", "65535"])

        for line in rulesOutput.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Extract rule number (first component)
            let ruleNumber = String(trimmed.prefix(5))

            // Skip base rules and default deny rules
            if baseRuleNumbers.contains(ruleNumber) { continue }

            // Convert "01000 allow..." to "ipfw -q add 01000 allow..."
            content += "ipfw -q add \(trimmed)\n"
        }

        // Add the final deny rule
        content += "# Deny everything else inbound\nipfw -q add 65534 deny log all from any to any in // deny-all-inbound\n"

        // Write to file
        let escapedContent = content.replacingOccurrences(of: "'", with: "'\\''")
        let _ = try await executeCommand("printf '%s' '\(escapedContent)' > /etc/ipfw.rules 2>&1")
        let _ = try await executeCommand("chmod +x /etc/ipfw.rules 2>&1")
        print("DEBUG: Updated /etc/ipfw.rules")
    }

    /// Enable firewall rules required for NIS/NFS domain services
    /// - Parameter role: "server" for domain server, "client" for domain client
    func enableDomainFirewallRules(role: String) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Check if firewall is enabled
        let (status, rules) = try await getFirewallStatus()
        guard status == .enabled else {
            print("DEBUG: Firewall not enabled, skipping domain firewall rules")
            return
        }

        // Find next available rule number
        let userRules = rules.filter { $0.ruleNumber >= 1000 && $0.ruleNumber < 65000 }
        var nextRuleNum = (userRules.map { $0.ruleNumber }.max() ?? 999) + 1

        // Check which ports already have rules
        let existingPorts = Set(rules.compactMap { $0.port })

        // Ports needed for domain services:
        // - 111 (RPC Portmapper) - required for NIS and NFS service discovery
        // - 2049 (NFS) - Network File System (server only)
        // NIS/YP ports (server only):
        // - 811 (ypserv) - NIS server daemon
        // - 616/649 (ypbind) - NIS binding daemon
        // - 802/709 (yppasswdd) - NIS password daemon

        // Add RPC Portmapper if not already allowed (needed for both server and client)
        if !existingPorts.contains(111) {
            print("DEBUG: Adding RPC Portmapper (111/tcp) firewall rule")
            try await addFirewallRule(ruleNumber: nextRuleNum, action: "allow", proto: "tcp",
                                      source: "any", destination: "any", port: 111,
                                      direction: "in", comment: "RPC-Portmapper-Domain")
            nextRuleNum += 1

            // Also add UDP for portmapper
            try await addFirewallRule(ruleNumber: nextRuleNum, action: "allow", proto: "udp",
                                      source: "any", destination: "any", port: 111,
                                      direction: "in", comment: "RPC-Portmapper-UDP-Domain")
            nextRuleNum += 1
        }

        // Server needs NFS and NIS ports
        if role == "server" {
            // NFS port
            if !existingPorts.contains(2049) {
                print("DEBUG: Adding NFS (2049/tcp) firewall rule")
                try await addFirewallRule(ruleNumber: nextRuleNum, action: "allow", proto: "tcp",
                                          source: "any", destination: "any", port: 2049,
                                          direction: "in", comment: "NFS-Domain")
                nextRuleNum += 1
            }

            // ypserv (NIS server) - port 811 TCP and UDP
            if !existingPorts.contains(811) {
                print("DEBUG: Adding ypserv (811/tcp) firewall rule")
                try await addFirewallRule(ruleNumber: nextRuleNum, action: "allow", proto: "tcp",
                                          source: "any", destination: "any", port: 811,
                                          direction: "in", comment: "NIS-ypserv-Domain")
                nextRuleNum += 1

                try await addFirewallRule(ruleNumber: nextRuleNum, action: "allow", proto: "udp",
                                          source: "any", destination: "any", port: 811,
                                          direction: "in", comment: "NIS-ypserv-UDP-Domain")
                nextRuleNum += 1
            }

            // ypbind - port 616 UDP, 649 TCP
            if !existingPorts.contains(616) {
                print("DEBUG: Adding ypbind (616/udp, 649/tcp) firewall rules")
                try await addFirewallRule(ruleNumber: nextRuleNum, action: "allow", proto: "udp",
                                          source: "any", destination: "any", port: 616,
                                          direction: "in", comment: "NIS-ypbind-UDP-Domain")
                nextRuleNum += 1
            }
            if !existingPorts.contains(649) {
                try await addFirewallRule(ruleNumber: nextRuleNum, action: "allow", proto: "tcp",
                                          source: "any", destination: "any", port: 649,
                                          direction: "in", comment: "NIS-ypbind-TCP-Domain")
                nextRuleNum += 1
            }

            // yppasswdd - port 802 UDP, 709 TCP (for password changes)
            if !existingPorts.contains(802) {
                print("DEBUG: Adding yppasswdd (802/udp, 709/tcp) firewall rules")
                try await addFirewallRule(ruleNumber: nextRuleNum, action: "allow", proto: "udp",
                                          source: "any", destination: "any", port: 802,
                                          direction: "in", comment: "NIS-yppasswdd-UDP-Domain")
                nextRuleNum += 1
            }
            if !existingPorts.contains(709) {
                try await addFirewallRule(ruleNumber: nextRuleNum, action: "allow", proto: "tcp",
                                          source: "any", destination: "any", port: 709,
                                          direction: "in", comment: "NIS-yppasswdd-TCP-Domain")
                nextRuleNum += 1
            }
        }

        print("DEBUG: Domain firewall rules enabled for role: \(role)")
    }

    /// Remove firewall rules added for NIS/NFS domain services
    func disableDomainFirewallRules() async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Check if firewall is enabled
        let (status, rules) = try await getFirewallStatus()
        guard status == .enabled else {
            print("DEBUG: Firewall not enabled, skipping domain firewall rule removal")
            return
        }

        // Find and remove rules with "Domain" in the comment
        let domainRules = rules.filter { $0.comment.contains("Domain") }

        for rule in domainRules {
            print("DEBUG: Removing domain firewall rule \(rule.ruleNumber): \(rule.comment)")
            try await deleteFirewallRule(ruleNumber: rule.ruleNumber)
        }

        print("DEBUG: Domain firewall rules removed")
    }

    /// Check if NIS/NFS domain services are configured and return the role
    /// Returns: "server" if NIS server is enabled, "client" if NIS client is enabled, nil if neither
    func getDomainRole() async throws -> String? {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Check if NIS server is enabled
        let serverEnabled = try await executeCommand("sysrc -n nis_server_enable 2>/dev/null || echo 'NO'")
        if serverEnabled.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "YES" {
            print("DEBUG: NIS server is enabled")
            return "server"
        }

        // Check if NIS client is enabled
        let clientEnabled = try await executeCommand("sysrc -n nis_client_enable 2>/dev/null || echo 'NO'")
        if clientEnabled.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "YES" {
            print("DEBUG: NIS client is enabled")
            return "client"
        }

        print("DEBUG: No domain role configured")
        return nil
    }
}

// MARK: - Jails Operations

extension SSHConnectionManager {
    /// Check if user is root
    func hasElevatedPrivileges() async throws -> Bool {
        guard client != nil else {
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
        guard client != nil else {
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

        // Get managed jail details (path, type) from config files
        let managedJailDetails = try await getManagedJailDetails()

        return parseJails(output, managedJails: rcConfJails, managedJailDetails: managedJailDetails)
    }

    /// Get details for managed jails from config files (path, type, version)
    private func getManagedJailDetails() async throws -> [String: (path: String, jailType: JailType?, version: String?)] {
        let command = """
        {
            # For each jail config file, extract name, path and check if thin/thick
            for conf in /etc/jail.conf.d/*.conf; do
                [ -f "$conf" ] || continue
                name=$(awk '/^[[:space:]]*[a-zA-Z0-9_-]+[[:space:]]*{/ {gsub(/[[:space:]]*{.*/, ""); print; exit}' "$conf")
                [ -z "$name" ] && continue
                path=$(awk -F'=' '/path[[:space:]]*=/ {gsub(/[";[:space:]]/, "", $2); print $2; exit}' "$conf")
                [ -z "$path" ] && continue

                # Determine jail type - check if it's a ZFS clone (thin) or not
                jail_type="thick"
                if zfs list -H -o origin "$path" 2>/dev/null | grep -q '@'; then
                    jail_type="thin"
                fi

                # Get FreeBSD version from the jail
                version="Unknown"
                if [ -x "$path/bin/freebsd-version" ]; then
                    version=$("$path/bin/freebsd-version" -u 2>/dev/null || echo "Unknown")
                fi

                echo "JAIL_DETAIL:$name:$path:$jail_type:$version"
            done
        }
        """
        let output = try await executeCommand(command)
        print("DEBUG: Managed jail details: \(output)")

        var details: [String: (path: String, jailType: JailType?, version: String?)] = [:]

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("JAIL_DETAIL:") else { continue }

            let parts = trimmed.dropFirst(12).components(separatedBy: ":")
            guard parts.count >= 4 else { continue }

            let name = parts[0]
            let path = parts[1]
            let jailType: JailType? = parts[2] == "thin" ? .thin : .thick
            let version = parts[3...].joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)

            details[name] = (path: path, jailType: jailType, version: version.isEmpty ? nil : version)
        }

        return details
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
        guard client != nil else {
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
        guard client != nil else {
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
        guard client != nil else {
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
        guard client != nil else {
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
        guard client != nil else {
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

    private func parseJails(_ output: String, managedJails: Set<String>, managedJailDetails: [String: (path: String, jailType: JailType?, version: String?)]) -> [Jail] {
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

                // Get additional details from config if available
                let details = managedJailDetails[name]

                jails.append(Jail(
                    id: name,
                    jid: jid,
                    name: name,
                    hostname: hostname,
                    path: path,
                    ip: ip,
                    status: .running,
                    isManaged: isManaged,
                    jailType: details?.jailType,
                    version: details?.version
                ))
            }
        }

        // Add stopped jails from configuration
        for managedJailName in managedJails {
            if !runningJailNames.contains(managedJailName) {
                print("DEBUG: Adding stopped jail: \(managedJailName)")
                let details = managedJailDetails[managedJailName]
                jails.append(Jail(
                    id: managedJailName,
                    jid: "",  // No JID for stopped jails
                    name: managedJailName,
                    hostname: "",
                    path: details?.path ?? "",
                    ip: "",
                    status: .stopped,
                    isManaged: true,  // By definition, it's from the config
                    jailType: details?.jailType,
                    version: details?.version
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

// MARK: - Extended Jail Management Operations

extension SSHConnectionManager {

    /// Jail setup status structure
    struct JailSetupStatus {
        var directoriesExist: Bool = false
        var jailEnabled: Bool = false
        var parallelStart: Bool = false
        var hasTemplates: Bool = false
        var basePath: String = "/jails"
        var jailsEnabled: Bool = false
        var jailConfExists: Bool = false
        var jailConfIncludeExists: Bool = false
        var jailConfdExists: Bool = false
        var templatesPath: String = "/jails/templates"
        var hasZFS: Bool = false
        var zfsDataset: String?

        init() {}
    }

    /// List available jail templates
    func listJailTemplates() async throws -> [JailTemplate] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Check jail template location
        let command = """
        {
            # Check for templates in /jails/templates
            if [ -d /jails/templates ]; then
                for template in /jails/templates/*/; do
                    if [ -d "$template" ] && [ -x "$template/bin/sh" ]; then
                        name=$(basename "$template")
                        path="$template"
                        # Get actual FreeBSD version from the template
                        if [ -x "$template/bin/freebsd-version" ]; then
                            version=$("$template/bin/freebsd-version" -u 2>/dev/null || echo "Unknown")
                        else
                            version="Unknown"
                        fi
                        # Check if it's a ZFS dataset
                        zfs_info=$(zfs list -H -o name "$template" 2>/dev/null || echo "")
                        if [ -n "$zfs_info" ]; then
                            # ZFS templates can always create thin jails (snapshots are created on-demand)
                            echo "TEMPLATE:$name:$path:zfs:yes:$version"
                        else
                            echo "TEMPLATE:$name:$path:ufs:no:$version"
                        fi
                    fi
                done
            fi
        }
        """

        let output = try await executeCommand(command)
        print("DEBUG: Template discovery output: \(output)")

        var templates: [JailTemplate] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("TEMPLATE:") else { continue }

            let parts = trimmed.dropFirst(9).components(separatedBy: ":")
            guard parts.count >= 5 else { continue }

            let name = parts[0]
            let path = parts[1]
            let isZFS = parts[2] == "zfs"
            let hasSnapshot = parts[3] == "yes"
            // Version is in parts[4], may contain colons so join remaining parts
            let version = parts[4...].joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)

            templates.append(JailTemplate(
                name: name,
                path: path,
                version: version.isEmpty ? "Unknown" : version,
                isZFS: isZFS,
                hasSnapshot: hasSnapshot
            ))
        }

        return templates
    }

    private func extractVersion(from string: String) -> String? {
        // Match FreeBSD version patterns like 14.0-RELEASE, 13.2-RELEASE
        let pattern = #"(\d+\.\d+)-RELEASE"#
        if let range = string.range(of: pattern, options: .regularExpression) {
            return String(string[range])
        }
        return nil
    }

    /// Check jail setup status
    func checkJailSetup() async throws -> JailSetupStatus {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let command = """
        {
            # Check if jails are enabled in rc.conf
            jail_enable=$(sysrc -n jail_enable 2>/dev/null || echo "NO")
            echo "JAILS_ENABLED:$jail_enable"

            # Check for parallel start
            jail_parallel=$(sysrc -n jail_parallel_start 2>/dev/null || echo "NO")
            echo "PARALLEL_START:$jail_parallel"

            # Check if jail.conf exists
            if [ -f /etc/jail.conf ]; then
                echo "JAIL_CONF:yes"
                if grep -q '.include.*jail.conf.d' /etc/jail.conf 2>/dev/null; then
                    echo "JAIL_CONF_INCLUDE:yes"
                else
                    echo "JAIL_CONF_INCLUDE:no"
                fi
            else
                echo "JAIL_CONF:no"
                echo "JAIL_CONF_INCLUDE:no"
            fi

            # Check if jail.conf.d directory exists
            if [ -d /etc/jail.conf.d ]; then
                echo "JAIL_CONFD:yes"
            else
                echo "JAIL_CONFD:no"
            fi

            # Determine base path and check if directory structure exists
            # Note: templates directory is optional (only for ZFS mode)
            echo "BASE_PATH:/jails"
            if [ -d /jails/containers ] && [ -d /jails/media ]; then
                echo "DIRS_EXIST:yes"
            else
                echo "DIRS_EXIST:no"
            fi

            # Check for templates (must have actual base system content, not just empty directories)
            template_count=0
            if [ -d /jails/templates ]; then
                for tpl in /jails/templates/*/; do
                    # Check if template has base system files (bin/sh is always present)
                    if [ -x "$tpl/bin/sh" ]; then
                        template_count=$((template_count + 1))
                    fi
                done
            fi
            if [ "$template_count" -gt 0 ]; then
                echo "HAS_TEMPLATES:yes"
            else
                echo "HAS_TEMPLATES:no"
            fi

            # Check for ZFS
            if kldstat -q -m zfs 2>/dev/null; then
                echo "HAS_ZFS:yes"
                # Try to find jail-related ZFS dataset
                zfs_dataset=$(zfs list -H -o name 2>/dev/null | grep -E 'jails?$' | head -1 || true)
                if [ -n "$zfs_dataset" ]; then
                    echo "ZFS_DATASET:$zfs_dataset"
                fi
            else
                echo "HAS_ZFS:no"
            fi
        }
        """

        let output = try await executeCommand(command)
        print("DEBUG: Jail setup check output: \(output)")

        var status = JailSetupStatus()

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.components(separatedBy: ":")
            guard parts.count >= 2 else { continue }

            let key = parts[0]
            let value = parts.dropFirst().joined(separator: ":")

            switch key {
            case "JAILS_ENABLED":
                let enabled = value.uppercased() == "YES"
                status.jailsEnabled = enabled
                status.jailEnabled = enabled
            case "PARALLEL_START":
                status.parallelStart = value.uppercased() == "YES"
            case "JAIL_CONF":
                status.jailConfExists = value == "yes"
            case "JAIL_CONF_INCLUDE":
                status.jailConfIncludeExists = value == "yes"
            case "JAIL_CONFD":
                status.jailConfdExists = value == "yes"
            case "DIRS_EXIST":
                status.directoriesExist = value == "yes"
            case "HAS_TEMPLATES":
                status.hasTemplates = value == "yes"
            case "BASE_PATH":
                status.basePath = value
                status.templatesPath = value + "/templates"
            case "HAS_ZFS":
                status.hasZFS = value == "yes"
            case "ZFS_DATASET":
                status.zfsDataset = value
            default:
                break
            }
        }

        return status
    }

    /// Create a new jail (Thick or Thin, ZFS or UFS-based)
    func createJail(
        name: String,
        hostname: String,
        type: JailType,
        ipMode: JailIPMode,
        ipAddress: String,
        bridgeName: String,
        template: JailTemplate?,
        freebsdVersion: String,
        useZFS: Bool = true
    ) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        print("DEBUG: Creating jail '\(name)' of type \(type.rawValue) using \(useZFS ? "ZFS" : "UFS")")

        // Determine jail path
        let basePath = "/jails/containers"
        let path = "\(basePath)/\(name)"

        // Get next available jail ID for epair numbering
        let jailId = try await getNextJailId()
        print("DEBUG: Using jail ID \(jailId) for epair numbering")

        // Generate jail configuration
        let configContent = generateJailConfig(
            name: name,
            hostname: hostname,
            path: path,
            type: type,
            ipMode: ipMode,
            ipAddress: ipAddress,
            bridgeName: bridgeName,
            jailId: jailId
        )

        // Ensure jail.conf.d directory exists
        _ = try await executeCommand("mkdir -p /etc/jail.conf.d")

        // Write the jail configuration file
        let writeConfigCommand = """
        cat > '/etc/jail.conf.d/\(name).conf' << 'JAILCONF'
        \(configContent)
        JAILCONF
        """
        _ = try await executeCommand(writeConfigCommand)
        print("DEBUG: Wrote jail config to /etc/jail.conf.d/\(name).conf")

        // Create jail directory structure based on type and storage backend
        if useZFS {
            switch type {
            case .thick:
                // Thick jail: dedicated ZFS dataset with full copy
                try await createThickZFSJail(name: name, path: path, template: template?.name, freebsdVersion: freebsdVersion)

            case .thin:
                // Thin jail: ZFS clone from template snapshot
                try await createThinZFSJail(name: name, path: path, template: template?.name)
            }
        } else {
            // UFS mode - only thick jails supported
            try await createThickUFSJail(name: name, path: path, freebsdVersion: freebsdVersion)
        }

        print("DEBUG: Jail '\(name)' created successfully")
    }

    /// Create a new jail with streaming output for progress display (Thick jails only - thin jails are instant)
    func createJailStreaming(
        name: String,
        hostname: String,
        type: JailType,
        ipMode: JailIPMode,
        ipAddress: String,
        bridgeName: String,
        template: JailTemplate?,
        freebsdVersion: String,
        useZFS: Bool = true,
        onOutput: @escaping (String) -> Void
    ) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        print("DEBUG: Creating jail '\(name)' of type \(type.rawValue) using \(useZFS ? "ZFS" : "UFS") (streaming)")

        // Determine jail path
        let basePath = "/jails/containers"
        let path = "\(basePath)/\(name)"

        // Get next available jail ID for epair numbering
        let jailId = try await getNextJailId()
        onOutput("Using jail ID \(jailId) for network interface\n")

        // Generate jail configuration
        let configContent = generateJailConfig(
            name: name,
            hostname: hostname,
            path: path,
            type: type,
            ipMode: ipMode,
            ipAddress: ipAddress,
            bridgeName: bridgeName,
            jailId: jailId
        )

        // Ensure jail.conf.d directory exists
        _ = try await executeCommand("mkdir -p /etc/jail.conf.d")

        // Write the jail configuration file
        let writeConfigCommand = """
        cat > '/etc/jail.conf.d/\(name).conf' << 'JAILCONF'
        \(configContent)
        JAILCONF
        """
        _ = try await executeCommand(writeConfigCommand)
        onOutput("Created jail configuration: /etc/jail.conf.d/\(name).conf\n\n")

        // Create jail directory structure based on type and storage backend
        if useZFS {
            switch type {
            case .thick:
                // Thick jail: dedicated ZFS dataset with full copy - use streaming
                try await createThickZFSJailStreaming(name: name, path: path, freebsdVersion: freebsdVersion, onOutput: onOutput)

            case .thin:
                // Thin jail: ZFS clone from template snapshot (instant, no streaming needed)
                onOutput("Creating thin jail from template snapshot...\n")
                try await createThinZFSJail(name: name, path: path, template: template?.name)
                onOutput("Thin jail created successfully!\n")
            }
        } else {
            // UFS mode - only thick jails supported, use streaming
            try await createThickUFSJailStreaming(name: name, path: path, freebsdVersion: freebsdVersion, onOutput: onOutput)
        }

        print("DEBUG: Jail '\(name)' created successfully")
    }

    /// Generate jail.conf content for a jail
    /// Get next available jail ID for epair numbering
    func getNextJailId() async throws -> Int {
        // Check existing jail configs to find used IDs
        let result = try await executeCommand("grep -h '\\$id.*=' /etc/jail.conf.d/*.conf 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1")
        let lastId = Int(result.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return lastId + 1
    }

    private func generateJailConfig(
        name: String,
        hostname: String,
        path: String,
        type: JailType,
        ipMode: JailIPMode,
        ipAddress: String,
        bridgeName: String,
        jailId: Int = 1
    ) -> String {
        // bridgeName is an existing bridge (e.g., bridge0, bridge1)
        let bridge = bridgeName.isEmpty ? "bridge0" : bridgeName

        // Simple vNET config following FreeBSD Handbook pattern
        var config = """
        \(name) {
            path = "\(path)";
            host.hostname = "\(hostname.isEmpty ? name : hostname)";

            # vNET
            vnet;
            vnet.interface = "${epair}b";

            $id = "\(jailId)";
            $epair = "epair${id}";

            # Create epair and add to existing bridge
            exec.prestart  = "/sbin/ifconfig ${epair} create up";
            exec.prestart += "/sbin/ifconfig \(bridge) addm ${epair}a up";

        """

        // Network: DHCP by default, static IP if specified
        switch ipMode {
        case .dhcp:
            config += """
                exec.start     = "/sbin/dhclient ${epair}b";
                exec.start    += "/bin/sh /etc/rc";

            """
        case .staticIP:
            let ip = ipAddress.isEmpty ? "192.168.1.100/24" : ipAddress
            // Extract gateway from IP (assume .1 on same subnet)
            let gateway: String
            if let slashIndex = ip.firstIndex(of: "/"),
               let lastDot = ip[..<slashIndex].lastIndex(of: ".") {
                gateway = String(ip[..<lastDot]) + ".1"
            } else {
                gateway = "192.168.1.1"
            }
            config += """
                exec.start     = "/sbin/ifconfig ${epair}b \(ip) up";
                exec.start    += "/sbin/route add default \(gateway)";
                exec.start    += "/bin/sh /etc/rc";

            """
        }

        config += """
            exec.stop      = "/bin/sh /etc/rc.shutdown jail";
            exec.poststop  = "/sbin/ifconfig ${epair}a destroy";

            exec.clean;
            mount.devfs;
            devfs_ruleset = 11;
        }

        """

        return config
    }

    /// Create a thick jail with dedicated ZFS dataset
    private func createThickZFSJail(name: String, path: String, template: String?, freebsdVersion: String) async throws {
        print("DEBUG: Creating thick ZFS jail '\(name)' at \(path)")

        // Find ZFS pool for jails
        let poolCommand = "zfs list -H -o name 2>/dev/null | grep -E 'jails?$' | head -1 || zpool list -H -o name | head -1"
        let pool = try await executeCommand(poolCommand).trimmingCharacters(in: .whitespacesAndNewlines)
        let jailDataset = "\(pool)/containers/\(name)"

        let version = freebsdVersion.isEmpty ? "14.2-RELEASE" : freebsdVersion

        // Detect host architecture for correct download URL
        let archCommand = "uname -m"
        let hostArch = try await executeCommand(archCommand).trimmingCharacters(in: .whitespacesAndNewlines)
        let archPath: String
        switch hostArch {
        case "aarch64", "arm64":
            archPath = "arm64/aarch64"
        case "amd64", "x86_64":
            archPath = "amd64"
        default:
            archPath = hostArch
        }
        let baseUrl = "https://download.freebsd.org/releases/\(archPath)/\(version)"

        let createCommand = """
        {
            # Create ZFS dataset for jail
            zfs create '\(jailDataset)'
            zfs set mountpoint='\(path)' '\(jailDataset)'

            # Download and extract base if needed
            media_dir="/jails/media/\(version)"
            mkdir -p "$media_dir"

            if [ ! -f "$media_dir/base.txz" ]; then
                echo "Downloading base.txz for \(version)..."
                fetch -o "$media_dir/base.txz" "\(baseUrl)/base.txz" || exit 1
            fi

            echo "Extracting base system to \(path)..."
            tar -xf "$media_dir/base.txz" -C '\(path)'

            # Copy resolv.conf and localtime
            cp /etc/resolv.conf '\(path)/etc/resolv.conf' 2>/dev/null || true
            cp /etc/localtime '\(path)/etc/localtime' 2>/dev/null || true

            echo "Thick ZFS jail '\(name)' created with dataset \(jailDataset)"
        }
        """
        _ = try await executeCommand(createCommand)
    }

    /// Create a thick jail using UFS directories (no ZFS)
    private func createThickUFSJail(name: String, path: String, freebsdVersion: String) async throws {
        print("DEBUG: Creating thick UFS jail '\(name)' at \(path)")

        let version = freebsdVersion.isEmpty ? "14.2-RELEASE" : freebsdVersion

        // Detect host architecture for correct download URL
        let archCommand = "uname -m"
        let hostArch = try await executeCommand(archCommand).trimmingCharacters(in: .whitespacesAndNewlines)
        let archPath: String
        switch hostArch {
        case "aarch64", "arm64":
            archPath = "arm64/aarch64"
        case "amd64", "x86_64":
            archPath = "amd64"
        default:
            archPath = hostArch
        }
        let baseUrl = "https://download.freebsd.org/releases/\(archPath)/\(version)"

        let createCommand = """
        {
            # Create jail directory
            mkdir -p '\(path)'

            # Download and extract base if needed
            media_dir="/jails/media/\(version)"
            mkdir -p "$media_dir"

            if [ ! -f "$media_dir/base.txz" ]; then
                echo "Downloading base.txz for \(version)..."
                fetch -o "$media_dir/base.txz" "\(baseUrl)/base.txz" || exit 1
            fi

            echo "Extracting base system to \(path)..."
            tar -xf "$media_dir/base.txz" -C '\(path)'

            # Copy resolv.conf and localtime
            cp /etc/resolv.conf '\(path)/etc/resolv.conf' 2>/dev/null || true
            cp /etc/localtime '\(path)/etc/localtime' 2>/dev/null || true

            echo "Thick UFS jail '\(name)' created at \(path)"
        }
        """
        _ = try await executeCommand(createCommand)
    }

    /// Create a thick jail using UFS directories (no ZFS) - streaming version with progress
    private func createThickUFSJailStreaming(name: String, path: String, freebsdVersion: String, onOutput: @escaping (String) -> Void) async throws {
        print("DEBUG: Creating thick UFS jail '\(name)' at \(path) (streaming)")

        let version = freebsdVersion.isEmpty ? "14.2-RELEASE" : freebsdVersion

        // Detect host architecture for correct download URL
        let hostArch = try await executeCommand("uname -m").trimmingCharacters(in: .whitespacesAndNewlines)
        let archPath: String
        switch hostArch {
        case "aarch64", "arm64":
            archPath = "arm64/aarch64"
        case "amd64", "x86_64":
            archPath = "amd64"
        default:
            archPath = hostArch
        }
        let baseUrl = "https://download.freebsd.org/releases/\(archPath)/\(version)"

        let createCommand = """
        # Create jail directory
        mkdir -p '\(path)'
        echo "Created jail directory: \(path)"

        # Download and extract base if needed
        media_dir="/jails/media/\(version)"
        mkdir -p "$media_dir"

        if [ ! -f "$media_dir/base.txz" ]; then
            echo ""
            echo "Downloading base.txz from \(baseUrl)..."
            echo ""
            fetch -v -o "$media_dir/base.txz" "\(baseUrl)/base.txz" || exit 1
            echo ""
        else
            echo "Using cached base.txz from $media_dir"
        fi

        echo ""
        echo "Extracting base system to \(path)..."
        count=0
        tar -xvf "$media_dir/base.txz" -C '\(path)' 2>&1 | while read line; do
            count=$((count + 1))
            if [ $((count % 100)) -eq 0 ]; then
                echo "Extracted $count files..."
            fi
        done
        echo "Extraction complete."

        # Copy resolv.conf and localtime
        echo ""
        echo "Configuring jail..."
        cp /etc/resolv.conf '\(path)/etc/resolv.conf' 2>/dev/null || true
        cp /etc/localtime '\(path)/etc/localtime' 2>/dev/null || true

        echo ""
        echo "================================================"
        echo "Thick UFS jail '\(name)' created successfully!"
        echo "Path: \(path)"
        echo "================================================"
        """

        let exitCode = try await executeCommandStreaming(createCommand, onOutput: onOutput)
        if exitCode != 0 {
            throw NSError(domain: "SSHConnectionManager", code: exitCode,
                         userInfo: [NSLocalizedDescriptionKey: "UFS jail creation failed with exit code \(exitCode)"])
        }
    }

    /// Create a thick jail with dedicated ZFS dataset - streaming version with progress
    private func createThickZFSJailStreaming(name: String, path: String, freebsdVersion: String, onOutput: @escaping (String) -> Void) async throws {
        print("DEBUG: Creating thick ZFS jail '\(name)' at \(path) (streaming)")

        // Find ZFS pool for jails
        let poolCommand = "zfs list -H -o name 2>/dev/null | grep -E 'jails?$' | head -1 || zpool list -H -o name | head -1"
        let pool = try await executeCommand(poolCommand).trimmingCharacters(in: .whitespacesAndNewlines)
        let jailDataset = "\(pool)/containers/\(name)"

        let version = freebsdVersion.isEmpty ? "14.2-RELEASE" : freebsdVersion

        // Detect host architecture for correct download URL
        let hostArch = try await executeCommand("uname -m").trimmingCharacters(in: .whitespacesAndNewlines)
        let archPath: String
        switch hostArch {
        case "aarch64", "arm64":
            archPath = "arm64/aarch64"
        case "amd64", "x86_64":
            archPath = "amd64"
        default:
            archPath = hostArch
        }
        let baseUrl = "https://download.freebsd.org/releases/\(archPath)/\(version)"

        let createCommand = """
        # Create ZFS dataset for jail
        echo "Creating ZFS dataset: \(jailDataset)"
        zfs create '\(jailDataset)'
        zfs set mountpoint='\(path)' '\(jailDataset)'
        echo "Dataset mounted at: \(path)"

        # Download and extract base if needed
        media_dir="/jails/media/\(version)"
        mkdir -p "$media_dir"

        if [ ! -f "$media_dir/base.txz" ]; then
            echo ""
            echo "Downloading base.txz from \(baseUrl)..."
            echo ""
            fetch -v -o "$media_dir/base.txz" "\(baseUrl)/base.txz" || exit 1
            echo ""
        else
            echo "Using cached base.txz from $media_dir"
        fi

        echo ""
        echo "Extracting base system to \(path)..."
        count=0
        tar -xvf "$media_dir/base.txz" -C '\(path)' 2>&1 | while read line; do
            count=$((count + 1))
            if [ $((count % 100)) -eq 0 ]; then
                echo "Extracted $count files..."
            fi
        done
        echo "Extraction complete."

        # Copy resolv.conf and localtime
        echo ""
        echo "Configuring jail..."
        cp /etc/resolv.conf '\(path)/etc/resolv.conf' 2>/dev/null || true
        cp /etc/localtime '\(path)/etc/localtime' 2>/dev/null || true

        echo ""
        echo "================================================"
        echo "Thick ZFS jail '\(name)' created successfully!"
        echo "Dataset: \(jailDataset)"
        echo "Path: \(path)"
        echo "================================================"
        """

        let exitCode = try await executeCommandStreaming(createCommand, onOutput: onOutput)
        if exitCode != 0 {
            throw NSError(domain: "SSHConnectionManager", code: exitCode,
                         userInfo: [NSLocalizedDescriptionKey: "ZFS jail creation failed with exit code \(exitCode)"])
        }
    }

    /// Create a thin jail by cloning a ZFS template snapshot
    private func createThinZFSJail(name: String, path: String, template: String?) async throws {
        guard let template = template else {
            throw NSError(domain: "SSHConnectionManager", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Thin ZFS jail requires a template with snapshot"])
        }

        print("DEBUG: Creating thin ZFS jail '\(name)' from template '\(template)'")

        // Find ZFS pool for jails
        let poolCommand = "zfs list -H -o name 2>/dev/null | grep -E 'jails?$' | head -1 || zpool list -H -o name | head -1"
        let pool = try await executeCommand(poolCommand).trimmingCharacters(in: .whitespacesAndNewlines)
        print("DEBUG: Pool detected: '\(pool)'")

        let templateDataset = "\(pool)/templates/\(template)"
        let jailDataset = "\(pool)/containers/\(name)"

        print("DEBUG: Template dataset: \(templateDataset)")
        print("DEBUG: Jail dataset: \(jailDataset)")

        // Clone from template - create a unique snapshot for this jail
        let snapshotName = "clone-\(name)"
        let cloneCommand = """
        {
            # Check if template dataset exists
            if ! zfs list -H '\(templateDataset)' >/dev/null 2>&1; then
                echo "ERROR: Template dataset \(templateDataset) does not exist" >&2
                exit 1
            fi

            # Create a unique snapshot for this jail
            echo "Creating snapshot \(templateDataset)@\(snapshotName)..."
            zfs snapshot '\(templateDataset)@\(snapshotName)' 2>&1

            # Clone the snapshot
            echo "Cloning \(templateDataset)@\(snapshotName) to \(jailDataset)..."
            zfs clone '\(templateDataset)@\(snapshotName)' '\(jailDataset)' 2>&1

            # Set mountpoint
            zfs set mountpoint='\(path)' '\(jailDataset)' 2>&1

            # Copy fresh resolv.conf
            cp /etc/resolv.conf '\(path)/etc/resolv.conf' 2>/dev/null || true

            echo "Thin ZFS jail '\(name)' created from template '\(template)'"
        }
        """
        let output = try await executeCommand(cloneCommand)
        print("DEBUG: Clone command output: \(output)")
    }

    /// Delete a jail
    func deleteJail(name: String, removePath: Bool) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        print("DEBUG: Deleting jail '\(name)', removePath: \(removePath)")

        // Stop jail if running
        _ = try? await executeCommand("service jail stop \(name) 2>/dev/null || jail -r \(name) 2>/dev/null || true")

        // Get jail path from config before removing
        var jailPath = ""
        if removePath {
            let pathCommand = """
            grep -h 'path.*=' /etc/jail.conf.d/\(name).conf 2>/dev/null | head -1 | sed 's/.*=[ ]*"\\{0,1\\}\\([^";]*\\).*/\\1/' || true
            """
            jailPath = try await executeCommand(pathCommand).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Remove config file
        _ = try await executeCommand("rm -f '/etc/jail.conf.d/\(name).conf'")
        print("DEBUG: Removed config /etc/jail.conf.d/\(name).conf")

        // Remove jail path if requested
        if removePath && !jailPath.isEmpty && jailPath != "/" {
            // Check if it's a ZFS dataset
            let zfsCheck = "zfs list -H -o name '\(jailPath)' 2>/dev/null || echo ''"
            let dataset = try await executeCommand(zfsCheck).trimmingCharacters(in: .whitespacesAndNewlines)

            if !dataset.isEmpty {
                // It's a ZFS dataset, destroy it
                print("DEBUG: Destroying ZFS dataset \(dataset)")
                _ = try await executeCommand("zfs destroy -r '\(dataset)' 2>/dev/null || rm -rf '\(jailPath)'")
            } else {
                // Regular directory - need to clear schg flags first (FreeBSD sets these on base system files)
                print("DEBUG: Clearing schg flags on \(jailPath)")
                _ = try await executeCommand("chflags -R noschg '\(jailPath)'")
                print("DEBUG: Removing jail directory \(jailPath)")
                _ = try await executeCommand("rm -rf '\(jailPath)'")
            }
        }

        print("DEBUG: Jail '\(name)' deleted")
    }

    /// Get jail config file content
    func getJailConfigFile(name: String) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Try jail.conf.d first, then main jail.conf
        let command = """
        if [ -f '/etc/jail.conf.d/\(name).conf' ]; then
            cat '/etc/jail.conf.d/\(name).conf'
        elif [ -f /etc/jail.conf ]; then
            # Extract specific jail block from main config
            awk '
                /^[[:space:]]*\(name)[[:space:]]*\\{/ { found=1 }
                found { print }
                found && /^[[:space:]]*\\}/ { exit }
            ' /etc/jail.conf
        else
            echo "# No configuration found for jail: \(name)"
        fi
        """

        return try await executeCommand(command)
    }

    /// Save jail config file content
    func saveJailConfigFile(name: String, content: String) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Ensure directory exists
        _ = try await executeCommand("mkdir -p /etc/jail.conf.d")

        // Write the config
        let writeCommand = """
        cat > '/etc/jail.conf.d/\(name).conf' << 'JAILCONF'
        \(content)
        JAILCONF
        """

        _ = try await executeCommand(writeCommand)
        print("DEBUG: Saved jail config to /etc/jail.conf.d/\(name).conf")
    }

    /// Setup jail directories (ZFS-only)
    func setupJailDirectories(basePath: String, zfsDataset: String) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        print("DEBUG: Setting up ZFS jail directories at \(basePath) with dataset \(zfsDataset)")

        guard !zfsDataset.isEmpty else {
            throw NSError(domain: "SSHConnectionManager", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "ZFS dataset is required"])
        }

        // Create ZFS datasets
        let zfsCommand = """
        {
            # Create base dataset if needed
            zfs list '\(zfsDataset)' >/dev/null 2>&1 || zfs create '\(zfsDataset)'

            # Create subdirectories as datasets
            zfs list '\(zfsDataset)/templates' >/dev/null 2>&1 || zfs create '\(zfsDataset)/templates'
            zfs list '\(zfsDataset)/media' >/dev/null 2>&1 || zfs create '\(zfsDataset)/media'
            zfs list '\(zfsDataset)/containers' >/dev/null 2>&1 || zfs create '\(zfsDataset)/containers'

            # Set mountpoints
            zfs set mountpoint='\(basePath)' '\(zfsDataset)'

            mkdir -p /etc/jail.conf.d

            echo "Created ZFS datasets:"
            echo "  \(zfsDataset) -> \(basePath)"
            echo "  \(zfsDataset)/templates"
            echo "  \(zfsDataset)/media"
            echo "  \(zfsDataset)/containers"
        }
        """
        return try await executeCommand(zfsCommand)
    }

    /// Setup jail directories using regular UFS directories (no ZFS)
    /// Note: Templates are not supported for UFS - only thick jails
    func setupJailDirectoriesUFS(basePath: String) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        print("DEBUG: Setting up UFS jail directories at \(basePath)")

        let command = """
        {
            # Create base directory and subdirectories (no templates for UFS)
            mkdir -p '\(basePath)/media'
            mkdir -p '\(basePath)/containers'
            mkdir -p /etc/jail.conf.d

            echo "Created UFS directories:"
            echo "  \(basePath)"
            echo "  \(basePath)/media"
            echo "  \(basePath)/containers"
        }
        """
        return try await executeCommand(command)
    }

    /// Create a jail template from base system (ZFS-only with snapshot) - streaming version
    func createJailTemplateStreaming(version: String, name: String, basePath: String, zfsDataset: String, onOutput: @escaping (String) -> Void) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        guard !zfsDataset.isEmpty else {
            throw NSError(domain: "SSHConnectionManager", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "ZFS dataset is required"])
        }

        let templatePath = "\(basePath)/templates/\(name)"
        print("DEBUG: Creating ZFS template '\(name)' at \(templatePath)")

        // Detect host architecture for correct download URL
        let hostArch = try await executeCommand("uname -m").trimmingCharacters(in: .whitespacesAndNewlines)
        let archPath: String
        switch hostArch {
        case "aarch64", "arm64":
            archPath = "arm64/aarch64"
        case "amd64", "x86_64":
            archPath = "amd64"
        default:
            archPath = hostArch
        }
        let baseUrl = "https://download.freebsd.org/releases/\(archPath)/\(version)"

        // Create ZFS template with snapshot - use fetch -v for verbose download progress
        let zfsCommand = """
        # Create template dataset
        template_ds="\(zfsDataset)/templates/\(name)"
        zfs list "$template_ds" >/dev/null 2>&1 || zfs create "$template_ds"
        zfs set mountpoint='\(templatePath)' "$template_ds"

        # Download and extract base
        media_dir="\(basePath)/media/\(version)"
        mkdir -p "$media_dir"

        if [ ! -f "$media_dir/base.txz" ]; then
            echo "Downloading base.txz from \(baseUrl)..."
            fetch -v -o "$media_dir/base.txz" "\(baseUrl)/base.txz" || exit 1
            echo ""
        else
            echo "Using cached base.txz from $media_dir"
        fi

        echo "Extracting base system to \(templatePath)..."
        tar -xvf "$media_dir/base.txz" -C '\(templatePath)' 2>&1 | while read line; do
            # Show progress every 100 files
            count=$((count + 1))
            if [ $((count % 100)) -eq 0 ]; then
                echo "Extracted $count files..."
            fi
        done

        # Copy timezone and resolv.conf
        echo "Configuring template..."
        cp /etc/resolv.conf '\(templatePath)/etc/resolv.conf' 2>/dev/null || true
        cp /etc/localtime '\(templatePath)/etc/localtime' 2>/dev/null || true

        echo ""
        echo "Template '\(name)' created successfully:"
        echo "  Dataset: $template_ds"
        echo "  Path: \(templatePath)"
        """

        let exitCode = try await executeCommandStreaming(zfsCommand, onOutput: onOutput)
        if exitCode != 0 {
            throw NSError(domain: "SSHConnectionManager", code: exitCode,
                         userInfo: [NSLocalizedDescriptionKey: "Template creation failed with exit code \(exitCode)"])
        }
    }

    /// Create a jail template from base system (ZFS-only with snapshot)
    func createJailTemplate(version: String, name: String, basePath: String, zfsDataset: String) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        guard !zfsDataset.isEmpty else {
            throw NSError(domain: "SSHConnectionManager", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "ZFS dataset is required"])
        }

        let templatePath = "\(basePath)/templates/\(name)"
        print("DEBUG: Creating ZFS template '\(name)' at \(templatePath)")

        // Detect host architecture for correct download URL
        let hostArch = try await executeCommand("uname -m").trimmingCharacters(in: .whitespacesAndNewlines)
        let archPath: String
        switch hostArch {
        case "aarch64", "arm64":
            archPath = "arm64/aarch64"
        case "amd64", "x86_64":
            archPath = "amd64"
        default:
            archPath = hostArch
        }
        let baseUrl = "https://download.freebsd.org/releases/\(archPath)/\(version)"

        // Create ZFS template with snapshot
        let zfsCommand = """
        {
            # Create template dataset
            template_ds="\(zfsDataset)/templates/\(name)"
            zfs list "$template_ds" >/dev/null 2>&1 || zfs create "$template_ds"
            zfs set mountpoint='\(templatePath)' "$template_ds"

            # Download and extract base
            media_dir="\(basePath)/media/\(version)"
            mkdir -p "$media_dir"

            if [ ! -f "$media_dir/base.txz" ]; then
                echo "Downloading base.txz from \(baseUrl)..."
                fetch -o "$media_dir/base.txz" "\(baseUrl)/base.txz" || exit 1
            fi

            echo "Extracting base system to \(templatePath)..."
            tar -xf "$media_dir/base.txz" -C '\(templatePath)'

            # Copy timezone and resolv.conf
            cp /etc/resolv.conf '\(templatePath)/etc/resolv.conf' 2>/dev/null || true
            cp /etc/localtime '\(templatePath)/etc/localtime' 2>/dev/null || true

            echo ""
            echo "Template '\(name)' created successfully:"
            echo "  Dataset: $template_ds"
            echo "  Path: \(templatePath)"
        }
        """
        return try await executeCommand(zfsCommand)
    }

    /// Delete a jail template
    func deleteJailTemplate(_ template: JailTemplate) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        print("DEBUG: Deleting template '\(template.name)' at \(template.path)")

        // Try to find and destroy the ZFS dataset, then remove the directory
        let templatePathClean = template.path.hasSuffix("/") ? String(template.path.dropLast()) : template.path
        let command = """
        {
            # Try to find ZFS dataset for this template
            template_path="\(templatePathClean)"
            dataset=$(zfs list -H -o name "$template_path" 2>/dev/null)

            if [ -n "$dataset" ]; then
                echo "Found ZFS dataset: $dataset"

                # Get all snapshots and promote any clones (makes thin jails independent)
                snapshots=$(zfs list -H -t snapshot -o name -r "$dataset" 2>/dev/null | grep "^$dataset@")
                if [ -n "$snapshots" ]; then
                    for snap in $snapshots; do
                        clones=$(zfs list -H -o clones "$snap" 2>/dev/null | tr ',' '\\n' | grep -v '^-$' | grep -v '^$')
                        if [ -n "$clones" ]; then
                            echo "Promoting thin jails to independent datasets..."
                            for clone in $clones; do
                                echo "  Promoting: $clone"
                                zfs promote "$clone"
                            done
                        fi
                    done
                fi

                # Destroy the dataset recursively (includes any remaining snapshots)
                echo "Destroying dataset: $dataset"
                zfs destroy -r "$dataset"
                echo "Template deleted successfully."
            elif [ -d '$template_path' ]; then
                # Fallback: just remove the directory (UFS)
                rm -rf '$template_path'
                echo "Removed directory: $template_path"
            else
                echo "Template not found"
                exit 1
            fi
        }
        """
        _ = try await executeCommand(command)
        print("DEBUG: Template deleted")
    }

    /// Update a jail base system using freebsd-update
    func updateJailBaseStreaming(path: String, onOutput: @escaping (String) -> Void) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        print("DEBUG: Running freebsd-update for path: \(path)")

        // Set PAGER=cat to prevent freebsd-update from using interactive pager
        let command = "PAGER=cat freebsd-update -b '\(path)' fetch install"
        let exitCode = try await executeCommandStreaming(command, onOutput: onOutput)
        if exitCode != 0 {
            throw NSError(domain: "SSHConnectionManager", code: exitCode,
                         userInfo: [NSLocalizedDescriptionKey: "freebsd-update failed with exit code \(exitCode)"])
        }
    }

    /// Update a template base system using freebsd-update and recreate the ZFS snapshot
    /// This ensures thin jails created from this template will have the updated version
    func updateTemplateStreaming(path: String, onOutput: @escaping (String) -> Void) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        print("DEBUG: Running freebsd-update for template at path: \(path)")

        // Set PAGER=cat to prevent freebsd-update from using interactive pager
        let command = "PAGER=cat freebsd-update -b '\(path)' fetch install"
        let exitCode = try await executeCommandStreaming(command, onOutput: onOutput)
        if exitCode != 0 {
            throw NSError(domain: "SSHConnectionManager", code: exitCode,
                         userInfo: [NSLocalizedDescriptionKey: "freebsd-update failed with exit code \(exitCode)"])
        }

        // Note: With per-jail snapshots, we don't need to recreate a shared @template snapshot.
        // Each new thin jail will create its own snapshot from the current template state.
        await MainActor.run {
            onOutput("\n\nTemplate updated successfully.\n")
            onOutput("New thin jails will use the updated base system.\n")
            onOutput("Existing thin jails keep their version - update them individually if needed.\n")
        }
    }

    /// Enable jails in rc.conf
    func enableJailsInRcConf() async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let command = """
        {
            sysrc jail_enable=YES
            sysrc jail_parallel_start=YES
            echo "SUCCESS"
        }
        """
        _ = try await executeCommand(command)
        print("DEBUG: Enabled jails in rc.conf")
    }

    /// Ensure jail.conf includes jail.conf.d directory
    func ensureJailConfInclude() async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let command = #"""
        {
            mkdir -p /etc/jail.conf.d
            if [ ! -f /etc/jail.conf ]; then
                printf '%s\n' '# FreeBSD Jail Configuration' '# Individual jail configs are in /etc/jail.conf.d/' '' '.include "/etc/jail.conf.d/*.conf";' > /etc/jail.conf
            fi
            # Add devfs rule for vnet jails with DHCP (need bpf access)
            if ! grep -q 'devfsrules_jail_bpf=11' /etc/devfs.rules 2>/dev/null; then
                printf '\n[devfsrules_jail_bpf=11]\nadd include $devfsrules_jail\nadd path '\''bpf*'\'' unhide\n' >> /etc/devfs.rules
                service devfs restart
            fi
        }
        """#
        _ = try await executeCommand(command)
        print("DEBUG: Ensured jail config and devfs rules are set up")
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
        _ = connectionsOutput.trimmingCharacters(in: .whitespacesAndNewlines)

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

        // Get ZFS ARC stats (returns empty on non-ZFS systems)
        var arcUsed: Double = 0
        var arcMax: Double = 0
        let arcStats = try await executeCommand("sysctl -n kstat.zfs.misc.arcstats.size kstat.zfs.misc.arcstats.c_max 2>/dev/null || echo ''")
        if !arcStats.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            (arcUsed, arcMax) = parseARCStats(arcStats)
        }

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

        for (_, line) in lines.enumerated() {
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
        let output = try await executeCommand("zfs list -H -t all -o name,used,avail,refer,mountpoint,compression,compressratio,quota,reservation,type,sharenfs")

        var datasets: [ZFSDataset] = []

        for line in output.split(separator: "\n") {
            let components = line.split(separator: "\t").map { String($0) }
            guard components.count >= 11 else { continue }

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
                type: components[9],
                sharenfs: components[10]
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

    /// Create a new ZFS dataset
    func createZFSDataset(name: String, type: String = "filesystem", properties: [String: String] = [:]) async throws {
        print("DEBUG: createZFSDataset called - name: \(name), type: \(type), properties: \(properties)")

        var command = "zfs create"

        // Add properties for filesystem
        if type != "volume" {
            for (key, value) in properties {
                command += " -o \(key)=\(value)"
            }
        }

        // Add -V for volumes (zvol)
        if type == "volume" {
            // Volume size is required and should be in properties
            if let size = properties["volsize"] {
                command = "zfs create -V \(size)"
                // Add other properties
                for (key, value) in properties where key != "volsize" {
                    command += " -o \(key)=\(value)"
                }
            } else {
                print("DEBUG: Volume size missing!")
                throw NSError(domain: "ZFS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Volume size (volsize) is required for volume creation"])
            }
        }

        command += " \(name)"
        print("DEBUG: Final ZFS command: \(command)")

        // Use executeCommandDetailed to handle ZFS warnings properly
        // ZFS outputs warnings to stderr even on success
        let result = try await executeCommandDetailed(command)
        print("DEBUG: ZFS create stdout: \(result.stdout)")
        print("DEBUG: ZFS create stderr: \(result.stderr)")

        // Check if stderr contains actual errors (not just warnings)
        let stderr = result.stderr.lowercased()
        if stderr.contains("cannot create") || stderr.contains("failed") || stderr.contains("error:") || stderr.contains("no such") {
            throw NSError(domain: "ZFS", code: -1, userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }

        // If stderr only contains warnings, log them but don't fail
        if !result.stderr.isEmpty {
            print("DEBUG: ZFS warning (non-fatal): \(result.stderr)")
        }
    }

    /// Destroy (delete) a ZFS dataset or volume
    func destroyZFSDataset(name: String, recursive: Bool = false, force: Bool = false) async throws {
        var command = "zfs destroy"

        if recursive {
            command += " -r"
        }

        if force {
            command += " -f"
        }

        command += " \(name)"
        _ = try await executeCommand(command)
    }

    /// Set a property on a ZFS dataset
    func setZFSDatasetProperty(dataset: String, property: String, value: String) async throws {
        _ = try await executeCommand("zfs set \(property)=\(value) \(dataset)")
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
            let issued: String? = nil
            var duration: String?
            var errors = 0

            // Look for scrub information in the output
            let lines = statusOutput.split(separator: "\n")
            for (_, line) in lines.enumerated() {
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

    /// Export a ZFS pool (make it unavailable but preserve data)
    func exportZFSPool(pool: String, force: Bool = false) async throws {
        let forceFlag = force ? "-f " : ""
        _ = try await executeCommand("zpool export \(forceFlag)\(pool)")
    }

    /// Destroy a ZFS pool (permanently deletes all data)
    func destroyZFSPool(pool: String, force: Bool = false) async throws {
        let forceFlag = force ? "-f " : ""
        _ = try await executeCommand("zpool destroy \(forceFlag)\(pool)")
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

    // MARK: - Cron Task Management

    /// List all cron tasks for all users
    func listCronTasks() async throws -> [CronTask] {
        var tasks: [CronTask] = []

        // Get list of users with crontabs
        let usersOutput = try await executeCommand("ls /var/cron/tabs 2>/dev/null || echo ''")
        let users = usersOutput.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }

        // Get cron tasks for each user
        for user in users {
            guard !user.isEmpty else { continue }

            let crontabOutput = try await executeCommand("crontab -u \(user) -l 2>/dev/null || echo ''")

            for line in crontabOutput.split(separator: "\n") {
                let lineStr = String(line).trimmingCharacters(in: .whitespaces)

                // Skip empty lines
                if lineStr.isEmpty {
                    continue
                }

                // Check if line is disabled (commented out)
                let enabled = !lineStr.hasPrefix("#")
                let actualLine = enabled ? lineStr : String(lineStr.dropFirst()).trimmingCharacters(in: .whitespaces)

                // Skip comment lines that don't look like cron entries
                if actualLine.isEmpty || (!actualLine.contains(" ") && actualLine.hasPrefix("#")) {
                    continue
                }

                // Parse cron line: minute hour dayOfMonth month dayOfWeek command
                let parts = actualLine.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)

                // Need at least 6 parts (5 time fields + command)
                guard parts.count >= 6 else { continue }

                let minute = String(parts[0])
                let hour = String(parts[1])
                let dayOfMonth = String(parts[2])
                let month = String(parts[3])
                let dayOfWeek = String(parts[4])
                let command = String(parts[5])

                tasks.append(CronTask(
                    minute: minute,
                    hour: hour,
                    dayOfMonth: dayOfMonth,
                    month: month,
                    dayOfWeek: dayOfWeek,
                    command: command,
                    user: user,
                    enabled: enabled,
                    originalLine: lineStr
                ))
            }
        }

        return tasks
    }

    /// Get cron execution history from logs
    /// Returns a dictionary mapping command substrings to (lastRun, result) tuples
    func getCronHistory() async throws -> [(timestamp: String, user: String, command: String)] {
        // FreeBSD cron logs to /var/log/cron
        // Format: "Jan 16 15:00:00 hostname /usr/sbin/cron[1234]: (user) CMD (command)"
        let output = try await executeCommand("tail -500 /var/log/cron 2>/dev/null | grep 'CMD' || echo ''")

        var history: [(timestamp: String, user: String, command: String)] = []

        for line in output.split(separator: "\n") {
            let lineStr = String(line)

            // Parse: "Jan 16 15:00:00 hostname /usr/sbin/cron[1234]: (user) CMD (command)"
            // Extract timestamp (first 15 chars), user, and command
            guard lineStr.count > 15 else { continue }

            let timestamp = String(lineStr.prefix(15)) // "Jan 16 15:00:00"

            // Find user in parentheses after ": ("
            if let userStart = lineStr.range(of: ": ("),
               let userEnd = lineStr.range(of: ") CMD", range: userStart.upperBound..<lineStr.endIndex) {
                let user = String(lineStr[userStart.upperBound..<userEnd.lowerBound])

                // Find command in parentheses after "CMD ("
                if let cmdStart = lineStr.range(of: "CMD ("),
                   let cmdEnd = lineStr.lastIndex(of: ")") {
                    let command = String(lineStr[cmdStart.upperBound..<cmdEnd])
                    history.append((timestamp: timestamp, user: user, command: command))
                }
            }
        }

        return history
    }

    /// Add a new cron task
    func addCronTask(minute: String, hour: String, dayOfMonth: String, month: String, dayOfWeek: String, command: String, user: String) async throws {
        // Build cron line
        let cronLine = "\(minute) \(hour) \(dayOfMonth) \(month) \(dayOfWeek) \(command)"

        // Get current crontab
        let currentCrontab = try await executeCommand("crontab -u \(user) -l 2>/dev/null || echo ''")

        // Append new line
        let newCrontab = currentCrontab.isEmpty ? cronLine : "\(currentCrontab)\n\(cronLine)"

        // Write back to crontab using heredoc
        let escapedCrontab = newCrontab.replacingOccurrences(of: "'", with: "'\\''")
        _ = try await executeCommand("echo '\(escapedCrontab)' | crontab -u \(user) -")
    }

    /// Delete a cron task
    func deleteCronTask(_ task: CronTask) async throws {
        // Get current crontab
        let currentCrontab = try await executeCommand("crontab -u \(task.user) -l 2>/dev/null || echo ''")

        // Remove the line matching the original line
        var lines = currentCrontab.split(separator: "\n").map(String.init)
        lines.removeAll { $0 == task.originalLine }

        // Write back to crontab
        let newCrontab = lines.joined(separator: "\n")
        if newCrontab.isEmpty {
            // Remove crontab if empty
            _ = try await executeCommand("crontab -u \(task.user) -r 2>/dev/null || true")
        } else {
            let escapedCrontab = newCrontab.replacingOccurrences(of: "'", with: "'\\''")
            _ = try await executeCommand("echo '\(escapedCrontab)' | crontab -u \(task.user) -")
        }
    }

    /// Toggle a cron task (enable/disable by commenting/uncommenting)
    func toggleCronTask(_ task: CronTask) async throws {
        // Get current crontab
        let currentCrontab = try await executeCommand("crontab -u \(task.user) -l 2>/dev/null || echo ''")

        // Toggle the line
        var lines = currentCrontab.split(separator: "\n").map(String.init)
        for i in 0..<lines.count {
            if lines[i] == task.originalLine {
                if task.enabled {
                    // Disable by commenting out
                    lines[i] = "#\(lines[i])"
                } else {
                    // Enable by removing comment
                    if lines[i].hasPrefix("#") {
                        lines[i] = String(lines[i].dropFirst()).trimmingCharacters(in: .whitespaces)
                    }
                }
                break
            }
        }

        // Write back to crontab
        let newCrontab = lines.joined(separator: "\n")
        let escapedCrontab = newCrontab.replacingOccurrences(of: "'", with: "'\\''")
        _ = try await executeCommand("echo '\(escapedCrontab)' | crontab -u \(task.user) -")
    }

    // MARK: - Package Management

    /// List all installed packages
    func listInstalledPackages() async throws -> [Package] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Use pkg query to get package information in a parseable format
        // %R gives the repository name (e.g., "FreeBSD-ports", "FreeBSD-ports-kmods", "FreeBSD-base")
        // Handle case where pkg is not installed or no packages are installed
        let output = try await executeCommand("pkg query -a '%n\t%v\t%c\t%sh\t%R' 2>/dev/null || echo ''")

        var packages: [Package] = []

        for line in output.split(separator: "\n") {
            let components = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map { String($0) }
            guard components.count >= 5 else { continue }

            let name = components[0]
            let version = components[1]
            let description = components[2]
            let size = components[3]
            var repository = components[4].isEmpty ? "Unknown" : components[4]
            // Normalize "FreeBSD" to "FreeBSD-base" to avoid redundant filter
            if repository == "FreeBSD" {
                repository = "FreeBSD-base"
            }

            packages.append(Package(
                name: name,
                version: version,
                description: description,
                size: size,
                repository: repository
            ))
        }

        return packages
    }

    /// Get the current package repository type (quarterly or latest)
    func getCurrentRepository() async throws -> RepositoryType {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Check if there's an override file
        let confOutput = try await executeCommand("cat /usr/local/etc/pkg/repos/FreeBSD.conf 2>/dev/null || echo ''")

        if !confOutput.isEmpty {
            // Parse the override file
            if confOutput.contains("/latest") {
                return .latest
            } else if confOutput.contains("/quarterly") {
                return .quarterly
            }
        }

        // No override file exists, so we're using system defaults
        // System defaults in /etc/pkg/FreeBSD.conf are quarterly
        // Check to confirm
        let systemOutput = try await executeCommand("cat /etc/pkg/FreeBSD.conf 2>/dev/null | grep -A 2 'FreeBSD-ports:' | grep url || echo 'quarterly'")

        if systemOutput.contains("/latest") {
            return .latest
        } else {
            // Default to quarterly (system default)
            return .quarterly
        }
    }

    /// Check for available package updates
    func checkPackageUpdates() async throws -> Int {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Update package repository first
        _ = try await executeCommand("pkg update -f")

        // Check for upgrades
        let output = try await executeCommand("pkg upgrade -n | grep -c 'to be upgraded' || echo '0'")
        let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        return count
    }

    /// Upgrade all packages
    func upgradePackages() async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Perform the upgrade with -y to auto-confirm
        let output = try await executeCommand("pkg upgrade -y")
        return output
    }

    func upgradePackagesStreaming(onOutput: @escaping (String) -> Void) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Perform the upgrade with -y to auto-confirm
        let exitCode = try await executeCommandStreaming("pkg upgrade -y", onOutput: onOutput)
        if exitCode != 0 {
            throw NSError(domain: "SSHConnectionManager", code: exitCode,
                         userInfo: [NSLocalizedDescriptionKey: "Package upgrade failed with exit code \(exitCode)"])
        }
    }

    func getPackageCacheInfo() async throws -> (size: String, count: Int) {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Get cache directory size (handle case where pkg cache doesn't exist)
        let sizeOutput = try await executeCommand("du -sh /var/cache/pkg 2>/dev/null | cut -f1 || echo '0B'")
        let size = sizeOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Get count of cached packages
        let countOutput = try await executeCommand("ls -1 /var/cache/pkg/*.pkg 2>/dev/null | wc -l || echo '0'")
        let count = Int(countOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        return (size: size.isEmpty ? "0B" : size, count: count)
    }

    func cleanPackageCacheStreaming(onOutput: @escaping (String) -> Void) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Clean all cached packages
        let exitCode = try await executeCommandStreaming("pkg clean -ay", onOutput: onOutput)
        if exitCode != 0 {
            throw NSError(domain: "SSHConnectionManager", code: exitCode,
                         userInfo: [NSLocalizedDescriptionKey: "Package cache clean failed with exit code \(exitCode)"])
        }
    }

    func upgradeSelectedPackages(names: [String]) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        guard !names.isEmpty else {
            return "No packages specified"
        }

        // Build the command with specific package names
        let packageList = names.joined(separator: " ")
        let output = try await executeCommand("pkg upgrade -y \(packageList)")
        return output
    }

    func upgradeSelectedPackagesStreaming(names: [String], onOutput: @escaping (String) -> Void) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        guard !names.isEmpty else {
            return
        }

        // Build the command with specific package names
        let packageList = names.joined(separator: " ")
        let exitCode = try await executeCommandStreaming("pkg upgrade -y \(packageList)", onOutput: onOutput)
        if exitCode != 0 {
            throw NSError(domain: "SSHConnectionManager", code: exitCode,
                         userInfo: [NSLocalizedDescriptionKey: "Package upgrade failed with exit code \(exitCode)"])
        }
    }

    /// Switch package repository between quarterly and latest
    /// Get available package mirrors from DNS SRV records
    func getAvailableMirrors() async throws -> [String] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Query DNS SRV records for pkg.freebsd.org
        let output = try await executeCommand("host -t SRV _http._tcp.pkg.freebsd.org 2>/dev/null | grep 'has SRV record' | awk '{print $NF}' | sed 's/\\.$//' | sort -u || echo ''")

        var mirrors: [String] = []
        for line in output.split(separator: "\n") {
            let hostname = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hostname.isEmpty && hostname.contains("freebsd.org") {
                mirrors.append(hostname)
            }
        }

        return mirrors
    }

    /// Get the currently configured mirror hostname, or empty string if using automatic SRV
    func getCurrentMirror() async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Check if there's a custom mirror configured
        let configExists = try await executeCommand("test -f /usr/local/etc/pkg/repos/FreeBSD.conf && echo 'exists' || echo 'none'")
        if configExists.trimmingCharacters(in: .whitespacesAndNewlines) == "none" {
            return ""  // Using automatic
        }

        // Check if using SRV (automatic) or a specific mirror
        let config = try await executeCommand("cat /usr/local/etc/pkg/repos/FreeBSD.conf 2>/dev/null || echo ''")
        if config.contains("mirror_type") && config.contains("srv") {
            return ""  // Using automatic SRV lookup
        }

        // Extract mirror hostname from URL
        // URL format: http://pkg0.nyi.freebsd.org/${ABI}/...
        if let range = config.range(of: "url:\\s*\"?https?://([^/\"]+)", options: .regularExpression) {
            let match = String(config[range])
            if let hostRange = match.range(of: "://") {
                let afterProtocol = match[hostRange.upperBound...]
                let hostname = String(afterProtocol.prefix(while: { $0 != "/" && $0 != "\"" }))
                if hostname != "pkg.FreeBSD.org" && hostname != "pkg.freebsd.org" {
                    return hostname
                }
            }
        }

        return ""  // Using automatic
    }

    /// Set a specific mirror or reset to automatic SRV lookup
    func setMirror(hostname: String, repoType: RepositoryType) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        var outputLog = ""
        let repoPath = repoType == .quarterly ? "quarterly" : "latest"
        let kmodsPath = repoType == .quarterly ? "kmods_quarterly_${VERSION_MINOR}" : "kmods_latest_${VERSION_MINOR}"

        // Ensure the repos directory exists
        _ = try await executeCommand("mkdir -p /usr/local/etc/pkg/repos")

        // Remove existing repository config files
        outputLog += "Removing old repository configurations...\n"
        _ = try await executeCommand("rm -f /usr/local/etc/pkg/repos/*.conf")

        if hostname.isEmpty {
            // Reset to automatic SRV lookup
            outputLog += "Setting up automatic mirror selection (SRV lookup)...\n"

            if repoType == .quarterly {
                // For quarterly with automatic, just use system defaults
                outputLog += "Using system default quarterly repositories...\n"
            } else {
                // For latest with automatic, need to override to latest but keep SRV
                let configContent = """
# Disable the default quarterly repositories
FreeBSD-ports: { enabled: no }
FreeBSD-ports-kmods: { enabled: no }

# Enable the latest repository for packages with automatic mirror selection
FreeBSD: {
  url: "pkg+http://pkg.FreeBSD.org/${ABI}/latest",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}

# Enable the latest repository for kernel modules
FreeBSD-kmods: {
  url: "pkg+http://pkg.FreeBSD.org/${ABI}/kmods_latest_${VERSION_MINOR}",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
"""
                let command = """
cat > /usr/local/etc/pkg/repos/FreeBSD.conf << 'EOFPKG'
\(configContent)
EOFPKG
"""
                _ = try await executeCommand(command)
            }
        } else {
            // Use specific mirror - no SRV, direct HTTP
            outputLog += "Setting mirror to \(hostname) (\(repoPath))...\n"

            let configContent = """
# Disable the default repositories
FreeBSD-ports: { enabled: no }
FreeBSD-ports-kmods: { enabled: no }

# Use specific mirror for packages
FreeBSD: {
  url: "http://\(hostname)/${ABI}/\(repoPath)",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}

# Use specific mirror for kernel modules
FreeBSD-kmods: {
  url: "http://\(hostname)/${ABI}/\(kmodsPath)",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
"""
            let command = """
cat > /usr/local/etc/pkg/repos/FreeBSD.conf << 'EOFPKG'
\(configContent)
EOFPKG
"""
            _ = try await executeCommand(command)
        }

        // Clear repository cache to force a clean switch
        outputLog += "Clearing repository cache...\n"
        _ = try await executeCommand("rm -rf /var/db/pkg/repos/*")

        // Verify repository configuration
        outputLog += "\nVerifying active repositories...\n"
        let verifyOutput = try await executeCommand("pkg -vv 2>&1 | grep -A 10 'Repositories:' | head -15")
        outputLog += verifyOutput + "\n"

        outputLog += "\nMirror configuration complete!\n"

        return outputLog
    }

    func switchPackageRepository(to newRepo: RepositoryType) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        var outputLog = ""

        // Determine the repository URL based on the type
        let repoPath = newRepo == .quarterly ? "quarterly" : "latest"
        outputLog += "Switching to \(repoPath) repository...\n"

        // Ensure the repos directory exists
        _ = try await executeCommand("mkdir -p /usr/local/etc/pkg/repos")

        // Remove ALL existing repository config files first
        outputLog += "Removing old repository configurations...\n"
        _ = try await executeCommand("rm -f /usr/local/etc/pkg/repos/*.conf")

        if newRepo == .quarterly {
            // For quarterly, just remove the override and use system defaults
            // The system default in /etc/pkg/FreeBSD.conf already points to quarterly
            outputLog += "Using system default quarterly repositories...\n"
            outputLog += "No override file needed - using /etc/pkg/FreeBSD.conf defaults\n"
        } else {
            // For latest, create an override file
            // We need to explicitly disable FreeBSD-ports and FreeBSD-ports-kmods
            // which are defined in /etc/pkg/FreeBSD.conf as quarterly
            // And enable the latest versions for both packages and kernel modules
            let configContent = """
# Disable the default quarterly repositories
FreeBSD-ports: { enabled: no }
FreeBSD-ports-kmods: { enabled: no }

# Enable the latest repository for packages
FreeBSD: {
  url: "pkg+http://pkg.FreeBSD.org/${ABI}/latest",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}

# Enable the latest repository for kernel modules
FreeBSD-kmods: {
  url: "pkg+http://pkg.FreeBSD.org/${ABI}/kmods_latest_${VERSION_MINOR}",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
"""

            // Write the configuration to /usr/local/etc/pkg/repos/FreeBSD.conf
            outputLog += "Writing latest repository configuration (packages + kernel modules)...\n"
            let command = """
cat > /usr/local/etc/pkg/repos/FreeBSD.conf << 'EOFPKG'
\(configContent)
EOFPKG
"""

            _ = try await executeCommand(command)
        }

        // Clear repository cache to force a clean switch
        outputLog += "Clearing repository cache...\n"
        _ = try await executeCommand("rm -rf /var/db/pkg/repos/*")

        // Verify repository configuration
        outputLog += "\nVerifying active repositories...\n"
        let verifyOutput = try await executeCommand("pkg -vv 2>&1 | grep -A 10 'Repositories:' | head -15")
        outputLog += verifyOutput + "\n"

        outputLog += "\nRepository switch complete!\n"
        outputLog += "Click 'Check Updates' to update the package catalog.\n"

        return outputLog
    }

    /// Set a custom repository URL (for poudriere or custom package builders)
    func setCustomRepository(url: String) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        var outputLog = ""
        outputLog += "Setting custom repository: \(url)\n"

        // Ensure the repos directory exists
        _ = try await executeCommand("mkdir -p /usr/local/etc/pkg/repos")

        // Remove ALL existing repository config files first
        outputLog += "Removing old repository configurations...\n"
        _ = try await executeCommand("rm -f /usr/local/etc/pkg/repos/*.conf")

        // Create configuration for custom repository
        // Note: Custom repositories typically don't use fingerprint verification
        // Users can add their own signing configuration if needed
        let configContent = """
# Disable the default repositories
FreeBSD-ports: { enabled: no }
FreeBSD-ports-kmods: { enabled: no }

# Custom package repository
Custom: {
  url: "\(url)",
  enabled: yes
}
"""

        // Write the configuration
        outputLog += "Writing custom repository configuration...\n"
        let command = """
cat > /usr/local/etc/pkg/repos/Custom.conf << 'EOFPKG'
\(configContent)
EOFPKG
"""

        _ = try await executeCommand(command)

        // Clear repository cache to force a clean switch
        outputLog += "Clearing repository cache...\n"
        _ = try await executeCommand("rm -rf /var/db/pkg/repos/*")

        // Verify repository configuration
        outputLog += "\nVerifying active repositories...\n"
        let verifyOutput = try await executeCommand("pkg -vv 2>&1 | grep -A 10 'Repositories:' | head -15")
        outputLog += verifyOutput + "\n"

        outputLog += "\nCustom repository configuration complete!\n"
        outputLog += "Click 'Check Updates' to update the package catalog.\n"

        return outputLog
    }

    /// Get the current custom repository URL if one is configured
    func getCurrentCustomRepoURL() async throws -> String? {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Check if there's a custom repository configuration
        let customConfOutput = try await executeCommand("cat /usr/local/etc/pkg/repos/Custom.conf 2>/dev/null || echo ''")

        if !customConfOutput.isEmpty && customConfOutput.contains("Custom:") {
            // Extract the URL from the configuration
            // Looking for: url: "https://..."
            let lines = customConfOutput.split(separator: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.starts(with: "url:") {
                    // Extract the URL between quotes
                    if let startQuote = trimmed.firstIndex(of: "\""),
                       let endQuote = trimmed.lastIndex(of: "\""),
                       startQuote < endQuote {
                        let urlStart = trimmed.index(after: startQuote)
                        return String(trimmed[urlStart..<endQuote])
                    }
                }
            }
        }

        return nil
    }

    /// List packages that have upgrades available
    func listUpgradablePackages() async throws -> [UpgradablePackage] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Update package repository first (ignore errors - might fail due to network)
        _ = try? await executeCommand("pkg update -q 2>/dev/null || true")

        // Get list of packages that can be upgraded
        // Use a more direct approach: just get the full output and parse lines with ->
        let output = try await executeCommand("pkg upgrade -n 2>&1 || true")

        var upgradablePackages: [UpgradablePackage] = []

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip empty lines and header lines
            guard !trimmed.isEmpty else { continue }
            guard trimmed.contains("->") else { continue }

            // Try to parse different possible formats:
            // Format 1: "package-name: 1.0.0 -> 1.0.1"
            // Format 2: "package-name-1.0.0 -> package-name-1.0.1"
            // Format 3: Just has -> somewhere in it

            if let colonIndex = trimmed.firstIndex(of: ":") {
                // Format: "package-name: version -> version"
                let name = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let versionPart = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

                let versions = versionPart.split(separator: "->").map { String($0).trimmingCharacters(in: .whitespaces) }
                guard versions.count == 2 else { continue }

                let currentVersion = versions[0]
                let newVersion = versions[1]

                // Get description
                let descOutput = try? await executeCommand("pkg query '%c' '\(name)' 2>/dev/null || echo ''")
                let description = descOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                upgradablePackages.append(UpgradablePackage(
                    name: name,
                    currentVersion: currentVersion,
                    newVersion: newVersion,
                    description: description
                ))
            } else if trimmed.contains("->") {
                // Format: "package-name-version -> package-name-newversion"
                let parts = trimmed.split(separator: "->").map { String($0).trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }

                let oldPkg = parts[0]
                let newPkg = parts[1]

                // Try to extract package name and versions
                // This is tricky because version numbers can contain dashes
                // We'll use the second part to get the package name
                if let lastDash = newPkg.lastIndex(of: "-") {
                    let name = String(newPkg[..<lastDash])
                    let newVersion = String(newPkg[newPkg.index(after: lastDash)...])

                    // Extract old version
                    let currentVersion: String
                    if let oldLastDash = oldPkg.lastIndex(of: "-") {
                        currentVersion = String(oldPkg[oldPkg.index(after: oldLastDash)...])
                    } else {
                        currentVersion = oldPkg
                    }

                    // Get description
                    let descOutput = try? await executeCommand("pkg query '%c' '\(name)' 2>/dev/null || echo ''")
                    let description = descOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    upgradablePackages.append(UpgradablePackage(
                        name: name,
                        currentVersion: currentVersion,
                        newVersion: newVersion,
                        description: description
                    ))
                }
            }
        }

        return upgradablePackages
    }

    /// Search for available packages in the repository
    func searchPackages(query: String) async throws -> [AvailablePackage] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Use pkg search with a simpler approach
        // Format: "package-name-version     Description here"
        let output = try await executeCommand("pkg search '\(query)' 2>&1 | head -100")

        var availablePackages: [AvailablePackage] = []

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Skip error messages and info lines
            if trimmed.starts(with: "pkg:") || trimmed.starts(with: "Updating") ||
               trimmed.starts(with: "All repositories") || trimmed.starts(with: "Fetching") {
                continue
            }

            // Format is typically: "package-name-version  Description"
            // Split on whitespace to separate package name from description
            let components = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard components.count >= 1 else { continue }

            let packageWithVersion = String(components[0])
            let description = components.count > 1 ? String(components[1]).trimmingCharacters(in: .whitespaces) : ""

            // Extract package name and version
            // Find the last dash which typically separates name from version
            if let lastDash = packageWithVersion.lastIndex(of: "-") {
                let name = String(packageWithVersion[..<lastDash])
                let version = String(packageWithVersion[packageWithVersion.index(after: lastDash)...])

                // Avoid duplicates
                if !availablePackages.contains(where: { $0.name == name }) {
                    availablePackages.append(AvailablePackage(
                        name: name,
                        version: version,
                        description: description
                    ))
                }
            } else {
                // No version separator found, use the whole thing as name
                if !availablePackages.contains(where: { $0.name == packageWithVersion }) {
                    availablePackages.append(AvailablePackage(
                        name: packageWithVersion,
                        version: "",
                        description: description
                    ))
                }
            }
        }

        return availablePackages
    }

    /// Get detailed information about a package
    func getPackageInfo(name: String) async throws -> PackageInfo {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Get comprehensive package info using pkg info
        let output = try await executeCommand("pkg info '\(name)' 2>&1")

        var info = PackageInfo(name: name)

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Name") && trimmed.contains(":") {
                info.name = String(trimmed.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Version") && trimmed.contains(":") {
                info.version = String(trimmed.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Origin") && trimmed.contains(":") {
                info.origin = String(trimmed.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Comment") && trimmed.contains(":") {
                info.comment = String(trimmed.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Maintainer") && trimmed.contains(":") {
                info.maintainer = String(trimmed.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("WWW") && trimmed.contains(":") {
                info.website = String(trimmed.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
                // Fix URL if it was split
                if info.website.hasPrefix("//") {
                    info.website = "https:" + info.website
                }
            } else if trimmed.hasPrefix("Flat size") && trimmed.contains(":") {
                info.flatSize = String(trimmed.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Licenses") && trimmed.contains(":") {
                info.license = String(trimmed.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
            }
        }

        // Get the full description
        let descOutput = try await executeCommand("pkg query '%e' '\(name)' 2>/dev/null || echo ''")
        info.description = descOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Get dependencies
        let depsOutput = try await executeCommand("pkg info -d '\(name)' 2>/dev/null | grep -v '^\(name)' | head -20 || echo ''")
        info.dependencies = depsOutput.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("depends on") }

        // Get required by (reverse dependencies)
        let reqByOutput = try await executeCommand("pkg info -r '\(name)' 2>/dev/null | grep -v '^\(name)' | head -20 || echo ''")
        info.requiredBy = reqByOutput.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("required by") }

        // Check if package is vital (%V = 1 if vital, 0 otherwise)
        let vitalOutput = try await executeCommand("pkg query '%V' '\(name)' 2>/dev/null || echo '0'")
        info.isVital = vitalOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "1"

        // Check if package is locked (%k = 1 if locked, 0 otherwise)
        let lockedOutput = try await executeCommand("pkg query '%k' '\(name)' 2>/dev/null || echo '0'")
        info.isLocked = lockedOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "1"

        return info
    }

    /// Remove an installed package
    func removePackage(name: String, force: Bool = false) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let forceFlag = force ? "-f" : ""
        let output = try await executeCommand("pkg delete -y \(forceFlag) '\(name)' 2>&1")
        return output
    }

    /// Install a package from the repository
    func installPackage(name: String) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let output = try await executeCommand("pkg install -y '\(name)' 2>&1")
        return output
    }

    func installPackageStreaming(name: String, onOutput: @escaping (String) -> Void) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let exitCode = try await executeCommandStreaming("pkg install -y '\(name)'", onOutput: onOutput)
        if exitCode != 0 {
            throw NSError(domain: "SSHConnectionManager", code: exitCode,
                         userInfo: [NSLocalizedDescriptionKey: "Package installation failed with exit code \(exitCode)"])
        }
    }

    func removePackageStreaming(name: String, force: Bool = false, onOutput: @escaping (String) -> Void) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let forceFlag = force ? "-f" : ""
        let exitCode = try await executeCommandStreaming("pkg delete -y \(forceFlag) '\(name)'", onOutput: onOutput)
        if exitCode != 0 {
            throw NSError(domain: "SSHConnectionManager", code: exitCode,
                         userInfo: [NSLocalizedDescriptionKey: "Package removal failed with exit code \(exitCode)"])
        }
    }

    /// Get info about an available (not installed) package
    func getAvailablePackageInfo(name: String) async throws -> PackageInfo {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Use pkg rquery for remote package info
        var info = PackageInfo(name: name)

        // Get basic info
        let queryOutput = try await executeCommand("pkg rquery '%n\t%v\t%c\t%sh\t%w\t%L\t%o' '\(name)' 2>/dev/null | head -1 || echo ''")
        let components = queryOutput.split(separator: "\t").map { String($0) }

        if components.count >= 7 {
            info.name = components[0]
            info.version = components[1]
            info.comment = components[2]
            info.flatSize = components[3]
            info.website = components[4]
            info.license = components[5]
            info.origin = components[6]
        }

        // Get full description
        let descOutput = try await executeCommand("pkg rquery '%e' '\(name)' 2>/dev/null || echo ''")
        info.description = descOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Get dependencies
        let depsOutput = try await executeCommand("pkg rquery '%dn-%dv' '\(name)' 2>/dev/null | head -20 || echo ''")
        info.dependencies = depsOutput.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return info
    }

    // MARK: - Service Management

    /// List services from ports
    func listServices() async throws -> [FreeBSDService] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        var services: [FreeBSDService] = []

        // Get list of enabled services from rc.conf
        let rcConfOutput = try await executeCommand("sysrc -a 2>/dev/null | grep '_enable=' || echo ''")
        var enabledServices: Set<String> = []
        for line in rcConfOutput.split(separator: "\n") {
            let lineStr = String(line).trimmingCharacters(in: .whitespaces)
            if lineStr.contains("_enable=") {
                let parts = lineStr.split(separator: "=")
                if parts.count >= 2 {
                    let varName = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased()
                    if value.contains("yes") || value.contains("true") || value == "\"yes\"" || value == "'yes'" {
                        // Extract service name from variable (e.g., "sshd_enable" -> "sshd")
                        let serviceName = varName.replacingOccurrences(of: "_enable", with: "")
                        enabledServices.insert(serviceName)
                    }
                }
            }
        }

        // Get list of running services
        let runningOutput = try await executeCommand("service -e 2>/dev/null || echo ''")
        var runningServices: Set<String> = []
        for line in runningOutput.split(separator: "\n") {
            let path = String(line).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                // Extract service name from path (e.g., "/usr/local/etc/rc.d/nginx" -> "nginx")
                let name = (path as NSString).lastPathComponent
                runningServices.insert(name)
            }
        }

        // Get ports services from /usr/local/etc/rc.d
        let portsServicesOutput = try await executeCommand("ls /usr/local/etc/rc.d 2>/dev/null || echo ''")
        for line in portsServicesOutput.split(separator: "\n") {
            let name = String(line).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !name.hasPrefix(".") {
                // Get service description from script
                let description = try await getServiceDescription(name: name, source: .ports)
                let rcVar = "\(name)_enable"
                let configPath = try await findServiceConfigPath(name: name, source: .ports)

                let service = FreeBSDService(
                    name: name,
                    source: .ports,
                    status: runningServices.contains(name) ? .running : .stopped,
                    enabled: enabledServices.contains(name),
                    description: description,
                    rcVar: rcVar,
                    configPath: configPath
                )
                services.append(service)
            }
        }

        // Sort by name
        services.sort { $0.name.lowercased() < $1.name.lowercased() }

        return services
    }

    /// Get the description of a service from its rc script
    private func getServiceDescription(name: String, source: ServiceSource) async throws -> String {
        let scriptPath = "\(source.path)/\(name)"
        // Try to extract description from PROVIDE or DESC line in the script
        let output = try await executeCommand("head -30 \(scriptPath) 2>/dev/null | grep -E '^# (PROVIDE|DESC):' | head -1 || echo ''")
        let description = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "# PROVIDE:", with: "")
            .replacingOccurrences(of: "# DESC:", with: "")
            .trimmingCharacters(in: .whitespaces)
        return description
    }

    /// Find the configuration file path for a service
    private func findServiceConfigPath(name: String, source: ServiceSource) async throws -> String? {
        // Common config file locations to check
        var pathsToCheck: [String] = []

        if source == .base {
            // Base system services typically use /etc/<name>.conf or /etc/<name>/<name>.conf
            pathsToCheck = [
                "/etc/\(name).conf",
                "/etc/\(name)/\(name).conf",
                "/etc/\(name).cfg"
            ]
        } else {
            // Ports services use /usr/local/etc/<name>.conf or /usr/local/etc/<name>/<name>.conf
            pathsToCheck = [
                "/usr/local/etc/\(name).conf",
                "/usr/local/etc/\(name)/\(name).conf",
                "/usr/local/etc/\(name).cfg",
                "/usr/local/etc/\(name)/config",
                "/usr/local/etc/\(name).d/\(name).conf"
            ]
        }

        // Check each path
        for path in pathsToCheck {
            let result = try await executeCommand("test -f '\(path)' && echo 'exists' || echo 'no'")
            if result.trimmingCharacters(in: .whitespacesAndNewlines) == "exists" {
                return path
            }
        }

        return nil
    }

    /// Get the content of a service configuration file
    func getServiceConfigFile(path: String) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        return try await executeCommand("cat '\(path)' 2>/dev/null")
    }

    /// Save content to a service configuration file
    func saveServiceConfigFile(path: String, content: String) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Write content using cat with heredoc (quotes in heredoc don't need escaping)
        _ = try await executeCommand("cat > '\(path)' << 'CONFIGEOF'\n\(content)\nCONFIGEOF")
    }

    /// Start a service
    func startService(name: String, source: ServiceSource) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let result = try await executeCommand("service \(name) onestart 2>&1")
        // Check if the command failed
        if result.lowercased().contains("does not exist") || result.lowercased().contains("not found") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to start service: \(result)"])
        }
    }

    /// Stop a service
    func stopService(name: String, source: ServiceSource) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let result = try await executeCommand("service \(name) onestop 2>&1")
        if result.lowercased().contains("does not exist") || result.lowercased().contains("not found") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to stop service: \(result)"])
        }
    }

    /// Restart a service
    func restartService(name: String, source: ServiceSource) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let result = try await executeCommand("service \(name) onerestart 2>&1")
        if result.lowercased().contains("does not exist") || result.lowercased().contains("not found") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to restart service: \(result)"])
        }
    }

    /// Enable a service in rc.conf
    func enableService(name: String, rcVar: String) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        _ = try await executeCommand("sysrc \(rcVar)=YES")
    }

    /// Disable a service in rc.conf
    func disableService(name: String, rcVar: String) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        _ = try await executeCommand("sysrc \(rcVar)=NO")
    }

    /// Get the rc script content for a service
    func getServiceScript(name: String, source: ServiceSource) async throws -> String {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let scriptPath = "\(source.path)/\(name)"
        return try await executeCommand("cat \(scriptPath) 2>/dev/null || echo 'Script not found'")
    }

    /// Get service status
    func getServiceStatus(name: String) async throws -> ServiceStatus {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let output = try await executeCommand("service \(name) onestatus 2>&1; echo \"EXIT:$?\"")

        // Check exit code embedded in output
        if output.contains("EXIT:0") {
            return .running
        } else if output.contains("is not running") || output.contains("EXIT:1") {
            return .stopped
        } else {
            return .unknown
        }
    }

    // MARK: - Network Interface Management

    /// List all network interfaces with detailed information
    func listNetworkInterfaces() async throws -> [NetworkInterfaceInfo] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        var interfaces: [NetworkInterfaceInfo] = []

        // Get interface list with ifconfig -a
        let ifconfigOutput = try await executeCommand("ifconfig -a 2>/dev/null")

        // Get interface statistics from netstat
        let netstatOutput = try await executeCommand("netstat -ibn 2>/dev/null")

        // Parse netstat for traffic statistics
        var interfaceStats: [String: (rxBytes: UInt64, txBytes: UInt64, rxPackets: UInt64, txPackets: UInt64, rxErrors: UInt64, txErrors: UInt64)] = [:]
        for line in netstatOutput.components(separatedBy: .newlines) {
            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // Format: Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
            if components.count >= 11 {
                let name = components[0]
                // Skip header and link-level entries we already have
                if name == "Name" || name.isEmpty { continue }

                if let rxPackets = UInt64(components[4]),
                   let rxErrors = UInt64(components[5]),
                   let rxBytes = UInt64(components[6]),
                   let txPackets = UInt64(components[7]),
                   let txErrors = UInt64(components[8]),
                   let txBytes = UInt64(components[9]) {
                    // Only store the first entry per interface (link-level stats)
                    if interfaceStats[name] == nil {
                        interfaceStats[name] = (rxBytes: rxBytes, txBytes: txBytes, rxPackets: rxPackets, txPackets: txPackets, rxErrors: rxErrors, txErrors: txErrors)
                    }
                }
            }
        }

        // Check which interfaces use DHCP from rc.conf
        let rcConfOutput = try await executeCommand("sysrc -a 2>/dev/null | grep -E 'ifconfig_|dhcp' || echo ''")
        var dhcpInterfaces: Set<String> = []
        for line in rcConfOutput.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("DHCP") || trimmed.contains("dhcp") {
                // Extract interface name from ifconfig_em0="DHCP" style
                if let match = trimmed.range(of: "ifconfig_") {
                    let afterPrefix = String(trimmed[match.upperBound...])
                    if let equalsRange = afterPrefix.range(of: "=") {
                        let ifaceName = String(afterPrefix[..<equalsRange.lowerBound])
                        dhcpInterfaces.insert(ifaceName)
                    }
                }
            }
        }

        // Parse ifconfig output
        let interfaceBlocks = ifconfigOutput.components(separatedBy: "\n").reduce(into: [[String]]()) { result, line in
            if !line.isEmpty && !line.hasPrefix("\t") && !line.hasPrefix(" ") {
                result.append([line])
            } else if !result.isEmpty {
                result[result.count - 1].append(line)
            }
        }

        for block in interfaceBlocks {
            guard !block.isEmpty else { continue }

            let firstLine = block[0]
            guard let colonIndex = firstLine.firstIndex(of: ":") else { continue }

            let name = String(firstLine[..<colonIndex])
            let flagsLine = String(firstLine[firstLine.index(after: colonIndex)...])

            // Parse flags
            var flags: [String] = []
            var mtu = 1500
            if let flagsMatch = flagsLine.range(of: "flags=") {
                let afterFlags = String(flagsLine[flagsMatch.upperBound...])
                if let angleStart = afterFlags.firstIndex(of: "<"),
                   let angleEnd = afterFlags.firstIndex(of: ">") {
                    let flagStr = String(afterFlags[afterFlags.index(after: angleStart)..<angleEnd])
                    flags = flagStr.components(separatedBy: ",")
                }
            }
            if let mtuMatch = flagsLine.range(of: "mtu ") {
                let afterMtu = String(flagsLine[mtuMatch.upperBound...])
                let mtuStr = afterMtu.components(separatedBy: .whitespaces).first ?? ""
                mtu = Int(mtuStr) ?? 1500
            }

            // Determine interface type
            let type: InterfaceType
            if name.hasPrefix("lo") {
                type = .loopback
            } else if name.hasPrefix("bridge") {
                type = .bridge
            } else if name.hasPrefix("tap") {
                type = .tap
            } else if name.hasPrefix("epair") {
                type = .epair
            } else if name.hasPrefix("vlan") || name.contains(".") {
                type = .vlan
            } else if name.hasPrefix("lagg") {
                type = .lagg
            } else if name.hasPrefix("em") || name.hasPrefix("igb") || name.hasPrefix("ix") || name.hasPrefix("ixl") || name.hasPrefix("ixv") || name.hasPrefix("bge") || name.hasPrefix("re") || name.hasPrefix("fxp") || name.hasPrefix("bce") || name.hasPrefix("msk") || name.hasPrefix("xl") || name.hasPrefix("dc") || name.hasPrefix("rl") || name.hasPrefix("sis") || name.hasPrefix("ste") || name.hasPrefix("sk") || name.hasPrefix("sf") || name.hasPrefix("vr") || name.hasPrefix("wb") || name.hasPrefix("vtnet") || name.hasPrefix("vmx") || name.hasPrefix("hn") || name.hasPrefix("mlx") || name.hasPrefix("cxgb") || name.hasPrefix("cxl") || name.hasPrefix("oce") || name.hasPrefix("qlnx") || name.hasPrefix("bnxt") || name.hasPrefix("axe") || name.hasPrefix("axge") || name.hasPrefix("cdce") || name.hasPrefix("cue") || name.hasPrefix("kue") || name.hasPrefix("mos") || name.hasPrefix("rue") || name.hasPrefix("smsc") || name.hasPrefix("udav") || name.hasPrefix("ure") || name.hasPrefix("urndis") {
                type = .ethernet
            } else {
                type = .other
            }

            // Determine status
            let status: InterfaceStatus
            if flags.contains("UP") && flags.contains("RUNNING") {
                status = .up
            } else if flags.contains("UP") && !flags.contains("RUNNING") {
                status = .noCarrier
            } else {
                status = .down
            }

            // Parse remaining lines for addresses and media
            var macAddress = ""
            var ipv4Address = "N/A"
            var ipv4Netmask = "N/A"
            var ipv6Address = "N/A"
            var ipv6Prefix = ""
            var mediaType = ""
            var mediaOptions = ""
            var description = ""

            for line in block.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.hasPrefix("ether ") {
                    macAddress = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("inet ") {
                    let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if parts.count >= 2 {
                        ipv4Address = parts[1]
                    }
                    if let netmaskIdx = parts.firstIndex(of: "netmask"), netmaskIdx + 1 < parts.count {
                        // Convert hex netmask to dotted decimal
                        let hexNetmask = parts[netmaskIdx + 1]
                        ipv4Netmask = hexNetmaskToDotted(hexNetmask)
                    }
                } else if trimmed.hasPrefix("inet6 ") && !trimmed.contains("scopeid") {
                    let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if parts.count >= 2 {
                        let addr = parts[1]
                        // Skip link-local addresses for primary display
                        if !addr.hasPrefix("fe80:") && ipv6Address == "N/A" {
                            if let prefixIdx = parts.firstIndex(of: "prefixlen"), prefixIdx + 1 < parts.count {
                                ipv6Address = addr
                                ipv6Prefix = "/\(parts[prefixIdx + 1])"
                            } else {
                                ipv6Address = addr
                            }
                        }
                    }
                } else if trimmed.hasPrefix("media:") {
                    mediaType = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("status:") {
                    // Already handled via flags
                } else if trimmed.hasPrefix("description:") {
                    description = String(trimmed.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("options=") {
                    if let start = trimmed.firstIndex(of: "<"), let end = trimmed.firstIndex(of: ">") {
                        mediaOptions = String(trimmed[trimmed.index(after: start)..<end])
                    }
                }
            }

            // Get stats from netstat
            let stats = interfaceStats[name] ?? (rxBytes: 0, txBytes: 0, rxPackets: 0, txPackets: 0, rxErrors: 0, txErrors: 0)

            let interface = NetworkInterfaceInfo(
                name: name,
                type: type,
                status: status,
                macAddress: macAddress,
                ipv4Address: ipv4Address,
                ipv4Netmask: ipv4Netmask,
                ipv6Address: ipv6Address,
                ipv6Prefix: ipv6Prefix,
                mtu: mtu,
                dhcp: dhcpInterfaces.contains(name),
                mediaType: mediaType,
                mediaOptions: mediaOptions,
                rxBytes: stats.rxBytes,
                txBytes: stats.txBytes,
                rxPackets: stats.rxPackets,
                txPackets: stats.txPackets,
                rxErrors: stats.rxErrors,
                txErrors: stats.txErrors,
                flags: flags,
                description: description
            )

            interfaces.append(interface)
        }

        return interfaces.sorted { $0.name < $1.name }
    }

    /// Helper to convert hex netmask to dotted decimal
    private func hexNetmaskToDotted(_ hex: String) -> String {
        let cleanHex = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard cleanHex.count == 8 else { return hex }

        var octets: [String] = []
        var index = cleanHex.startIndex
        for _ in 0..<4 {
            let nextIndex = cleanHex.index(index, offsetBy: 2)
            let octetHex = String(cleanHex[index..<nextIndex])
            if let value = UInt8(octetHex, radix: 16) {
                octets.append(String(value))
            } else {
                return hex
            }
            index = nextIndex
        }

        return octets.joined(separator: ".")
    }

    /// Set network interface up
    func setNetworkInterfaceUp(_ name: String) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let output = try await executeCommand("ifconfig \(name) up 2>&1")
        if output.contains("Permission denied") || output.contains("Operation not permitted") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Permission denied. Root access required."])
        }
    }

    /// Set network interface down
    func setNetworkInterfaceDown(_ name: String) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let output = try await executeCommand("ifconfig \(name) down 2>&1")
        if output.contains("Permission denied") || output.contains("Operation not permitted") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Permission denied. Root access required."])
        }
    }

    /// Renew DHCP lease for interface
    func renewDHCP(_ name: String) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Kill existing dhclient for this interface and restart
        _ = try await executeCommand("pkill -f 'dhclient.*\(name)' 2>/dev/null || true")
        let output = try await executeCommand("dhclient \(name) 2>&1")
        if output.contains("Permission denied") || output.contains("Operation not permitted") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Permission denied. Root access required."])
        }
    }

    /// Configure interface for DHCP
    func configureInterfaceDHCP(_ name: String) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Update rc.conf
        var output = try await executeCommand("sysrc ifconfig_\(name)=\"DHCP\" 2>&1")
        if output.contains("Permission denied") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Permission denied. Root access required."])
        }

        // Apply immediately
        _ = try await executeCommand("pkill -f 'dhclient.*\(name)' 2>/dev/null || true")
        output = try await executeCommand("dhclient \(name) 2>&1")
    }

    /// Configure interface with static IP
    func configureInterfaceStatic(_ name: String, ipAddress: String, netmask: String, gateway: String?) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Update rc.conf
        var output = try await executeCommand("sysrc ifconfig_\(name)=\"inet \(ipAddress) netmask \(netmask)\" 2>&1")
        if output.contains("Permission denied") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Permission denied. Root access required."])
        }

        // Kill any dhclient
        _ = try await executeCommand("pkill -f 'dhclient.*\(name)' 2>/dev/null || true")

        // Apply immediately
        output = try await executeCommand("ifconfig \(name) inet \(ipAddress) netmask \(netmask) 2>&1")

        // Set default gateway if provided
        if let gw = gateway, !gw.isEmpty {
            _ = try await executeCommand("sysrc defaultrouter=\"\(gw)\" 2>&1")
            _ = try await executeCommand("route delete default 2>/dev/null || true")
            _ = try await executeCommand("route add default \(gw) 2>&1")
        }
    }

    /// Set interface MTU
    func setInterfaceMTU(_ name: String, mtu: Int) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let output = try await executeCommand("ifconfig \(name) mtu \(mtu) 2>&1")
        if output.contains("Permission denied") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Permission denied. Root access required."])
        }
    }

    /// Set interface description
    func setInterfaceDescription(_ name: String, description: String) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let escapedDesc = description.replacingOccurrences(of: "\"", with: "\\\"")
        let output = try await executeCommand("ifconfig \(name) description \"\(escapedDesc)\" 2>&1")
        if output.contains("Permission denied") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Permission denied. Root access required."])
        }
    }

    // MARK: - Bridge Management

    /// List all bridge interfaces
    func listBridges() async throws -> [BridgeInterface] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        var bridges: [BridgeInterface] = []

        // Get list of bridge interfaces (excluding vm-* which are managed through Switches tab)
        let listOutput = try await executeCommand("ifconfig -l 2>/dev/null | tr ' ' '\\n' | grep -E '^bridge' || true")

        for line in listOutput.components(separatedBy: .newlines) {
            let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }

            // Get bridge details
            let ifconfigOutput = try await executeCommand("ifconfig \(name) 2>/dev/null")
            print("DEBUG listBridges: ifconfig \(name) output has \(ifconfigOutput.components(separatedBy: .newlines).count) lines")

            var members: [String] = []
            var ipv4Address = ""
            var ipv4Netmask = ""
            var status: InterfaceStatus = .down
            var stp = false

            for ifLine in ifconfigOutput.components(separatedBy: .newlines) {
                let trimmed = ifLine.trimmingCharacters(in: .whitespacesAndNewlines)

                // Check for member line first (before flags check, since member lines also contain "flags=")
                if trimmed.hasPrefix("member:") {
                    // Parse member line like "member: re0 flags=143<LEARNING,DISCOVER,AUTOEDGE,AUTOPTP>"
                    print("DEBUG listBridges: Found member line: '\(trimmed)'")
                    if let memberRange = trimmed.range(of: "member:") {
                        let afterMember = String(trimmed[memberRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                        let parts = afterMember.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        if let memberName = parts.first, !memberName.isEmpty {
                            print("DEBUG listBridges: Parsed member: '\(memberName)'")
                            members.append(memberName)
                        }
                    }
                } else if trimmed.contains("flags=") && trimmed.contains(":") && !trimmed.hasPrefix("member:") {
                    // Interface status line like "bridge0: flags=1008843<UP,BROADCAST,RUNNING..."
                    if trimmed.contains("UP") && trimmed.contains("RUNNING") {
                        status = .up
                    } else if trimmed.contains("UP") {
                        status = .noCarrier
                    }
                } else if trimmed.hasPrefix("inet ") {
                    let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if parts.count >= 2 {
                        ipv4Address = parts[1]
                    }
                    if let netmaskIdx = parts.firstIndex(of: "netmask"), netmaskIdx + 1 < parts.count {
                        ipv4Netmask = hexNetmaskToDotted(parts[netmaskIdx + 1])
                    }
                } else if trimmed.contains("stp") {
                    stp = true
                }
            }

            print("DEBUG listBridges: Bridge \(name) has \(members.count) members: \(members)")
            bridges.append(BridgeInterface(
                name: name,
                members: members,
                ipv4Address: ipv4Address,
                ipv4Netmask: ipv4Netmask,
                status: status,
                stp: stp
            ))
        }

        return bridges.sorted { $0.name < $1.name }
    }

    /// List interfaces that can be added to a bridge
    func listBridgeableInterfaces() async throws -> [String] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Filter out virtual/internal interfaces: lo, bridge, epair, pflog, pfsync, enc, gif, stf, tap, vm-
        let output = try await executeCommand("ifconfig -l 2>/dev/null | tr ' ' '\\n' | grep -vE '^(lo|bridge|epair|pflog|pfsync|enc|gif|stf|tap|vm-)' || true")

        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Read interface/bridge configuration from rc.conf
    private func readInterfaceRcConfig(_ interfaceName: String) async throws -> (ipv4: String?, ipv6: String?, isDHCP: Bool) {
        // Read IPv4 configuration
        let ipv4Output = try await executeCommand("sysrc -n ifconfig_\(interfaceName) 2>/dev/null || echo ''")
        let ipv4Config = ipv4Output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Read IPv6 configuration
        let ipv6Output = try await executeCommand("sysrc -n ifconfig_\(interfaceName)_ipv6 2>/dev/null || echo ''")
        let ipv6Config = ipv6Output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if DHCP is used (case insensitive check for DHCP, SYNCDHCP, dhclient)
        let isDHCP = ipv4Config.uppercased().contains("DHCP") || ipv4Config.contains("dhclient")

        return (
            ipv4Config.isEmpty ? nil : ipv4Config,
            ipv6Config.isEmpty ? nil : ipv6Config,
            isDHCP
        )
    }

    /// Convert bridge settings to interface settings (e.g., SYNCDHCP -> DHCP)
    private func convertBridgeSettingsToInterface(_ bridgeConfig: String) -> String {
        var config = bridgeConfig

        // Convert SYNCDHCP to DHCP (SYNCDHCP is bridge-specific for boot timing)
        config = config.replacingOccurrences(of: "SYNCDHCP", with: "DHCP")

        // Remove bridge-specific options that don't apply to regular interfaces
        // Remove "up" if it's the only thing or at the start (interfaces get "up" implicitly with DHCP)
        config = config.replacingOccurrences(of: "up DHCP", with: "DHCP")
        config = config.replacingOccurrences(of: "DHCP up", with: "DHCP")

        return config.trimmingCharacters(in: .whitespaces)
    }

    /// Create a new bridge interface with proper handling of member interface settings
    /// - Parameters:
    ///   - name: Bridge interface name (e.g., "bridge0")
    ///   - members: Member interfaces to add to the bridge
    ///   - ipAddress: Optional static IP address (if nil and member has DHCP, bridge will use DHCP)
    ///   - netmask: Optional netmask for static IP
    ///   - stp: Enable Spanning Tree Protocol
    /// - Returns: True if a restart is required for changes to take effect
    func createBridge(name: String, members: [String], ipAddress: String?, netmask: String?, stp: Bool) async throws -> Bool {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Read existing configurations for member interfaces to determine bridge settings
        var primaryMemberUsesDHCP = false
        var primaryMemberIPv6Config: String?

        for (index, member) in members.enumerated() {
            let config = try await readInterfaceRcConfig(member)

            // Use the first member's settings as the basis for bridge configuration
            if index == 0 {
                primaryMemberUsesDHCP = config.isDHCP
                primaryMemberIPv6Config = config.ipv6
            }
        }

        // Reconfigure member interfaces for bridging
        for member in members {
            // Configure member interface for bridging - strip IP config, just bring it up
            // Using -tso -vlanhwtso for better bridge compatibility
            _ = try await executeCommand("sysrc ifconfig_\(member)=\"up -tso -vlanhwtso\" 2>&1")

            // Remove IPv6 config from member (it will be on the bridge now)
            _ = try await executeCommand("sysrc -x ifconfig_\(member)_ipv6 2>/dev/null || true")
        }

        // Create the bridge interface for immediate use
        var output = try await executeCommand("ifconfig \(name) create 2>&1")
        if output.contains("Permission denied") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Permission denied. Root access required."])
        }
        if output.contains("already exists") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Bridge \(name) already exists"])
        }

        // Add member interfaces
        for member in members {
            output = try await executeCommand("ifconfig \(name) addm \(member) 2>&1")
        }

        // Enable STP if requested
        if stp {
            _ = try await executeCommand("ifconfig \(name) stp \(members.first ?? "") 2>&1")
        }

        // Set IP address if provided, otherwise inherit from member
        if let ip = ipAddress, let mask = netmask {
            _ = try await executeCommand("ifconfig \(name) inet \(ip) netmask \(mask) 2>&1")
        }

        // Bring up the bridge
        _ = try await executeCommand("ifconfig \(name) up 2>&1")

        // Make persistent in rc.conf
        _ = try await executeCommand("sysrc cloned_interfaces+=\"\(name)\" 2>&1")

        // Build create_args for the bridge (used at boot time)
        // This adds members during interface creation before ifconfig runs
        var createArgs = "inet6 auto_linklocal -ifdisabled"
        for member in members {
            createArgs += " addm \(member)"
        }
        _ = try await executeCommand("sysrc create_args_\(name)=\"\(createArgs)\" 2>&1")

        // Build ifconfig for the bridge
        var bridgeConfig = "up"
        if stp {
            bridgeConfig += " stp \(members.first ?? "")"
        }

        // Determine IP configuration for bridge
        if let ip = ipAddress, let mask = netmask {
            // Static IP was explicitly provided
            bridgeConfig = "inet \(ip) netmask \(mask) \(bridgeConfig)"
            _ = try await executeCommand("sysrc ifconfig_\(name)=\"\(bridgeConfig)\" 2>&1")
        } else if primaryMemberUsesDHCP {
            // Primary member used DHCP, configure bridge for DHCP
            // Use SYNCDHCP to ensure DHCP completes before continuing boot
            _ = try await executeCommand("sysrc ifconfig_\(name)=\"up SYNCDHCP\" 2>&1")
        } else {
            // No IP config specified and member didn't have DHCP
            _ = try await executeCommand("sysrc ifconfig_\(name)=\"\(bridgeConfig)\" 2>&1")
        }

        // Configure IPv6 on bridge if primary member had it
        if let ipv6Config = primaryMemberIPv6Config {
            _ = try await executeCommand("sysrc ifconfig_\(name)_ipv6=\"\(ipv6Config)\" 2>&1")
        }

        // Return true to indicate restart is required for proper boot configuration
        return true
    }

    /// Delete a bridge interface and transfer its settings to member interfaces
    /// This updates rc.conf but does NOT destroy the bridge immediately if it has members,
    /// because doing so would break the network connection. A restart is required.
    /// - Parameter name: Bridge interface name to delete
    /// - Returns: True if a restart is required for changes to take effect
    func deleteBridge(_ name: String) async throws -> Bool {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Check if this bridge is used by a VM switch (manual switches reference existing bridges)
        let switchList = try await executeCommand("vm switch list 2>/dev/null | grep -w '\(name)' | awk '{print $1}' || echo ''")
        let vmSwitchName = switchList.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vmSwitchName.isEmpty {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Cannot delete bridge '\(name)' because it is used by VM switch '\(vmSwitchName)'. Please delete the switch first."])
        }

        // Get the list of member interfaces from the running bridge
        var memberInterfaces: [String] = []
        let bridgeInfoOutput = try await executeCommand("ifconfig \(name) 2>/dev/null || echo ''")
        // Parse member interfaces from bridge info (look for "member: <interface>" lines)
        for line in bridgeInfoOutput.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("member:") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if parts.count >= 2 {
                    memberInterfaces.append(parts[1])
                }
            }
        }

        // IMPORTANT: Update rc.conf FIRST before any destructive operations
        // This ensures the configuration is correct even if the connection is lost

        // Read the bridge's current settings from rc.conf
        let bridgeConfig = try await readInterfaceRcConfig(name)

        // Transfer bridge settings to member interfaces
        // The bridge's IP settings should go to the first member (primary interface)
        for (index, member) in memberInterfaces.enumerated() {
            if index == 0 {
                // Primary member gets the bridge's IP settings
                if let ipv4 = bridgeConfig.ipv4 {
                    // Convert bridge settings to interface settings (SYNCDHCP -> DHCP, etc.)
                    let interfaceConfig = convertBridgeSettingsToInterface(ipv4)
                    _ = try await executeCommand("sysrc ifconfig_\(member)=\"\(interfaceConfig)\" 2>&1")
                } else {
                    // No IPv4 config on bridge, set DHCP as default
                    _ = try await executeCommand("sysrc ifconfig_\(member)=\"DHCP\" 2>&1")
                }

                if let ipv6 = bridgeConfig.ipv6 {
                    _ = try await executeCommand("sysrc ifconfig_\(member)_ipv6=\"\(ipv6)\" 2>&1")
                } else {
                    // Set default IPv6 config
                    _ = try await executeCommand("sysrc ifconfig_\(member)_ipv6=\"inet6 accept_rtadv\" 2>&1")
                }
            } else {
                // Additional members just need to be brought up (no IP)
                _ = try await executeCommand("sysrc ifconfig_\(member)=\"up\" 2>&1")
                _ = try await executeCommand("sysrc -x ifconfig_\(member)_ipv6 2>/dev/null || true")
            }
        }

        // Clean up any old backup entries that may exist from previous versions
        for member in memberInterfaces {
            _ = try await executeCommand("sysrc -x hexbsd_backup_ifconfig_\(member) 2>/dev/null || true")
            _ = try await executeCommand("sysrc -x hexbsd_backup_ifconfig_\(member)_ipv6 2>/dev/null || true")
        }

        // Remove bridge configuration from rc.conf
        _ = try await executeCommand("sysrc cloned_interfaces-=\"\(name)\" 2>/dev/null || true")

        // If cloned_interfaces is now empty, remove it entirely
        let clonedIfacesOutput = try await executeCommand("sysrc -n cloned_interfaces 2>/dev/null || echo ''")
        let clonedIfaces = clonedIfacesOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if clonedIfaces.isEmpty {
            _ = try await executeCommand("sysrc -x cloned_interfaces 2>/dev/null || true")
        }

        _ = try await executeCommand("sysrc -x ifconfig_\(name) 2>/dev/null || true")
        _ = try await executeCommand("sysrc -x ifconfig_\(name)_ipv6 2>/dev/null || true")
        _ = try await executeCommand("sysrc -x create_args_\(name) 2>/dev/null || true")

        // If this bridge has member interfaces, we need a restart
        // Do NOT destroy the bridge now - it would break the network connection
        if !memberInterfaces.isEmpty {
            // The bridge will be removed on restart since it's no longer in cloned_interfaces
            // and the interface settings will be applied
            return true
        }

        // For bridges without members, we can safely destroy immediately
        _ = try await executeCommand("ifconfig \(name) down 2>&1 || true")
        let output = try await executeCommand("ifconfig \(name) destroy 2>&1")

        if output.contains("Permission denied") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Permission denied. Root access required."])
        }
        return false
    }

    /// Remove a member from a bridge
    func removeBridgeMember(_ bridgeName: String, member: String) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let output = try await executeCommand("ifconfig \(bridgeName) deletem \(member) 2>&1")
        if output.contains("Permission denied") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Permission denied. Root access required."])
        }
    }

    /// Destroy a cloned interface (bridge, tap, epair, vlan, lagg)
    func destroyClonedInterface(_ name: String) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        // Bring down and destroy the interface
        _ = try await executeCommand("ifconfig \(name) down 2>&1")
        let output = try await executeCommand("ifconfig \(name) destroy 2>&1")

        if output.contains("Permission denied") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Permission denied. Root access required."])
        }

        if output.contains("does not exist") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Interface \(name) does not exist"])
        }

        if output.contains("Invalid argument") || output.contains("Operation not supported") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Interface \(name) cannot be destroyed (not a cloned interface)"])
        }

        // Remove any rc.conf entries for this interface
        _ = try await executeCommand("sysrc -x ifconfig_\(name) 2>/dev/null || true")
    }

    // MARK: - Routing Management

    /// List routing table entries
    func listRoutes(ipv6: Bool) async throws -> [RouteEntry] {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let flag = ipv6 ? "-6" : "-4"
        let output = try await executeCommand("netstat -rn \(flag) 2>/dev/null")

        var routes: [RouteEntry] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip headers and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("Routing") || trimmed.hasPrefix("Destination") || trimmed.hasPrefix("Internet") { continue }

            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // Format: Destination Gateway Flags Netif Expire
            guard parts.count >= 4 else { continue }

            routes.append(RouteEntry(
                destination: parts[0],
                gateway: parts[1],
                flags: parts[2],
                netif: parts[3],
                expire: parts.count > 4 ? parts[4] : ""
            ))
        }

        return routes
    }

    /// Add a route
    func addRoute(destination: String, gateway: String, netif: String?) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        var cmd = "route add \(destination) \(gateway)"
        if let iface = netif {
            cmd += " -interface \(iface)"
        }

        let output = try await executeCommand("\(cmd) 2>&1")
        if output.contains("Permission denied") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Permission denied. Root access required."])
        }
        if output.contains("File exists") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Route already exists"])
        }
    }

    /// Delete a route
    func deleteRoute(destination: String, gateway: String) async throws {
        guard client != nil else {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Not connected to server"])
        }

        let output = try await executeCommand("route delete \(destination) \(gateway) 2>&1")
        if output.contains("Permission denied") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Permission denied. Root access required."])
        }
        if output.contains("not in table") {
            throw NSError(domain: "SSHConnectionManager", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Route not found"])
        }
    }

}
