//
//  MockSSHConnectionManager.swift
//  HexBSD
//
//  Mock implementation of SSHConnectionProviding for unit testing.
//  Allows tests to run without actual SSH connections.
//

import Foundation
@testable import HexBSD

/// Mock SSH connection manager for testing purposes.
/// Allows configuring responses and tracking method calls.
final class MockSSHConnectionManager: SSHConnectionProviding {

    // MARK: - Protocol Properties

    var isConnected: Bool = false
    var serverAddress: String = ""
    var lastError: String?

    // MARK: - Mock Configuration

    /// Responses to return for specific commands
    var commandResponses: [String: String] = [:]

    /// Errors to throw for specific commands
    var commandErrors: [String: Error] = [:]

    /// Whether connect should succeed
    var shouldConnectSucceed: Bool = true

    /// Error to throw on connect failure
    var connectError: Error?

    /// Whether the server should validate as FreeBSD
    var isFreeBSD: Bool = true

    /// Custom system status to return
    var mockSystemStatus: SystemStatus?

    // MARK: - Call Tracking

    /// Track all commands executed
    private(set) var executedCommands: [String] = []

    /// Track connect attempts
    private(set) var connectAttempts: [(host: String, port: Int, username: String)] = []

    /// Track disconnect calls
    private(set) var disconnectCallCount: Int = 0

    // MARK: - Protocol Methods

    func executeCommand(_ command: String) async throws -> String {
        executedCommands.append(command)

        if let error = commandErrors[command] {
            throw error
        }

        if let response = commandResponses[command] {
            return response
        }

        // Default responses for common commands
        return defaultResponse(for: command)
    }

    func connect(host: String, port: Int, authMethod: SSHAuthMethod) async throws {
        connectAttempts.append((host: host, port: port, username: authMethod.username))

        if !shouldConnectSucceed {
            throw connectError ?? MockError.connectionFailed
        }

        isConnected = true
        serverAddress = host
    }

    func disconnect() async {
        disconnectCallCount += 1
        isConnected = false
        serverAddress = ""
    }

    func validateFreeBSD() async throws {
        if !isFreeBSD {
            throw MockError.notFreeBSD
        }
    }

    func fetchSystemStatus() async throws -> SystemStatus {
        if let status = mockSystemStatus {
            return status
        }

        return SystemStatus(
            cpuUsage: "25%",
            cpuCores: [20.0, 30.0, 25.0, 25.0],
            memoryUsage: "8 GB / 16 GB",
            zfsArcUsage: "2 GB / 4 GB",
            swapUsage: "0 GB / 4 GB",
            storageUsage: "100 GB / 500 GB",
            uptime: "5 days, 3:42",
            disks: [
                DiskIO(name: "ada0", readMBps: 10.5, writeMBps: 5.2, totalMBps: 15.7)
            ],
            networkInterfaces: [
                NetworkInterface(name: "em0", inRate: "1.5 MB/s", outRate: "500 KB/s")
            ]
        )
    }

    // MARK: - Helper Methods

    /// Reset all tracked state
    func reset() {
        isConnected = false
        serverAddress = ""
        lastError = nil
        executedCommands = []
        connectAttempts = []
        disconnectCallCount = 0
        commandResponses = [:]
        commandErrors = [:]
        shouldConnectSucceed = true
        connectError = nil
        isFreeBSD = true
        mockSystemStatus = nil
    }

    private func defaultResponse(for command: String) -> String {
        switch command {
        case "uname -s":
            return "FreeBSD"
        case "uname -r":
            return "14.0-RELEASE"
        case "hostname":
            return "freebsd-server"
        default:
            return ""
        }
    }
}

// MARK: - Mock Errors

enum MockError: Error, LocalizedError {
    case connectionFailed
    case notFreeBSD
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Mock connection failed"
        case .notFreeBSD:
            return "Server is not running FreeBSD"
        case .commandFailed(let command):
            return "Command failed: \(command)"
        }
    }
}
