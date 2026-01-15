//
//  SSHConnectionTests.swift
//  HexBSD
//
//  Tests for SSH connection behavior using Swift Testing.
//

import Foundation
import Testing
@testable import HexBSD

@Suite("SSH Connection")
struct SSHConnectionTests {

    @Test("Mock connection succeeds")
    func mockConnectionSucceeds() async throws {
        let mock = MockSSHConnectionManager()

        try await mock.connect(
            host: "192.168.1.100",
            port: 22,
            authMethod: SSHAuthMethod(
                username: "root",
                privateKeyURL: URL(fileURLWithPath: "/tmp/test_key")
            )
        )

        #expect(mock.isConnected)
        #expect(mock.serverAddress == "192.168.1.100")
        #expect(mock.connectAttempts.count == 1)
        #expect(mock.connectAttempts[0].username == "root")
    }

    @Test("Mock connection failure throws error")
    func mockConnectionFailure() async {
        let mock = MockSSHConnectionManager()
        mock.shouldConnectSucceed = false

        await #expect(throws: MockError.self) {
            try await mock.connect(
                host: "192.168.1.100",
                port: 22,
                authMethod: SSHAuthMethod(
                    username: "root",
                    privateKeyURL: URL(fileURLWithPath: "/tmp/test_key")
                )
            )
        }

        #expect(!mock.isConnected)
    }

    @Test("FreeBSD validation succeeds for FreeBSD server")
    func freebsdValidationSucceeds() async throws {
        let mock = MockSSHConnectionManager()
        mock.isFreeBSD = true

        try await mock.validateFreeBSD()
        // No error thrown means success
    }

    @Test("FreeBSD validation fails for non-FreeBSD server")
    func freebsdValidationFails() async {
        let mock = MockSSHConnectionManager()
        mock.isFreeBSD = false

        await #expect(throws: MockError.self) {
            try await mock.validateFreeBSD()
        }
    }

    @Test("Command execution is tracked")
    func commandExecutionTracked() async throws {
        let mock = MockSSHConnectionManager()
        mock.commandResponses["ls -la"] = "file1.txt\nfile2.txt"

        let result = try await mock.executeCommand("ls -la")

        #expect(result == "file1.txt\nfile2.txt")
        #expect(mock.executedCommands.contains("ls -la"))
    }

    @Test("Custom command error is thrown")
    func customCommandError() async {
        let mock = MockSSHConnectionManager()
        mock.commandErrors["bad-command"] = MockError.commandFailed("bad-command")

        await #expect(throws: MockError.self) {
            try await mock.executeCommand("bad-command")
        }
    }

    @Test("Disconnect resets state")
    func disconnectResetsState() async throws {
        let mock = MockSSHConnectionManager()

        try await mock.connect(
            host: "192.168.1.100",
            port: 22,
            authMethod: SSHAuthMethod(
                username: "root",
                privateKeyURL: URL(fileURLWithPath: "/tmp/test_key")
            )
        )

        #expect(mock.isConnected)

        await mock.disconnect()

        #expect(!mock.isConnected)
        #expect(mock.serverAddress.isEmpty)
        #expect(mock.disconnectCallCount == 1)
    }

    @Test("System status returns mock data")
    func systemStatusReturnsMockData() async throws {
        let mock = MockSSHConnectionManager()

        let status = try await mock.fetchSystemStatus()

        #expect(status.cpuUsage == "25%")
        #expect(status.cpuCores.count == 4)
        #expect(status.memoryUsage == "8 GB / 16 GB")
    }

    @Test("Custom system status can be configured")
    func customSystemStatus() async throws {
        let mock = MockSSHConnectionManager()
        mock.mockSystemStatus = SystemStatus(
            cpuUsage: "99%",
            cpuCores: [99.0],
            memoryUsage: "15 GB / 16 GB",
            zfsArcUsage: "4 GB / 4 GB",
            swapUsage: "2 GB / 4 GB",
            storageUsage: "450 GB / 500 GB",
            uptime: "100 days",
            disks: [],
            networkInterfaces: []
        )

        let status = try await mock.fetchSystemStatus()

        #expect(status.cpuUsage == "99%")
        #expect(status.memoryUsage == "15 GB / 16 GB")
    }

    @Test("Reset clears all state")
    func resetClearsState() async throws {
        let mock = MockSSHConnectionManager()

        try await mock.connect(
            host: "test",
            port: 22,
            authMethod: SSHAuthMethod(
                username: "user",
                privateKeyURL: URL(fileURLWithPath: "/tmp/key")
            )
        )
        _ = try await mock.executeCommand("ls")

        mock.reset()

        #expect(!mock.isConnected)
        #expect(mock.executedCommands.isEmpty)
        #expect(mock.connectAttempts.isEmpty)
    }
}

// MARK: - Async Semaphore Tests

@Suite("Async Semaphore")
struct AsyncSemaphoreTests {

    @Test("Semaphore limits concurrent access")
    func semaphoreLimitsConcurrency() async {
        let semaphore = AsyncSemaphore(limit: 2)
        var concurrentCount = 0
        var maxConcurrent = 0
        let lock = NSLock()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await semaphore.acquire()

                    lock.lock()
                    concurrentCount += 1
                    maxConcurrent = max(maxConcurrent, concurrentCount)
                    lock.unlock()

                    // Simulate work
                    try? await Task.sleep(nanoseconds: 10_000_000)

                    lock.lock()
                    concurrentCount -= 1
                    lock.unlock()

                    await semaphore.release()
                }
            }
        }

        #expect(maxConcurrent <= 2, "Should never exceed semaphore limit of 2")
    }
}
