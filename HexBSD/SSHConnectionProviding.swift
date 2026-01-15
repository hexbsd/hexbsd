//
//  SSHConnectionProviding.swift
//  HexBSD
//
//  Protocol abstraction for SSH connections to enable testability.
//  Views can accept any SSHConnectionProviding implementation,
//  allowing mock implementations for unit testing.
//

import Foundation

/// Protocol defining the interface for SSH connection operations.
/// Enables dependency injection and mock implementations for testing.
protocol SSHConnectionProviding: AnyObject {
    /// Whether a connection is currently established
    var isConnected: Bool { get }

    /// The address of the connected server
    var serverAddress: String { get }

    /// The last error message, if any
    var lastError: String? { get }

    /// Execute a command on the remote server
    /// - Parameter command: The shell command to execute
    /// - Returns: The command output as a string
    /// - Throws: If the command fails or connection is lost
    func executeCommand(_ command: String) async throws -> String

    /// Connect to a server
    /// - Parameters:
    ///   - host: The hostname or IP address
    ///   - port: The SSH port (default 22)
    ///   - authMethod: The authentication method to use
    func connect(host: String, port: Int, authMethod: SSHAuthMethod) async throws

    /// Disconnect from the current server
    func disconnect() async

    /// Validate that the server is running FreeBSD
    func validateFreeBSD() async throws

    /// Fetch current system status
    func fetchSystemStatus() async throws -> SystemStatus
}

// MARK: - SSHConnectionManager Conformance

extension SSHConnectionManager: SSHConnectionProviding {
    // SSHConnectionManager already implements all required methods
}
