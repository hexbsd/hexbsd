//
//  SystemStatusParserTests.swift
//  HexBSD
//
//  Tests for SystemStatusParser using Swift Testing framework.
//

import Testing
@testable import HexBSD

// MARK: - Percentage Parsing Tests

@Suite("Percentage Parsing")
struct PercentageParsingTests {

    @Test("Parses integer percentage")
    func integerPercentage() {
        #expect(SystemStatusParser.parsePercentage(from: "45%") == 45.0)
    }

    @Test("Parses decimal percentage")
    func decimalPercentage() {
        #expect(SystemStatusParser.parsePercentage(from: "45.5%") == 45.5)
    }

    @Test("Handles percentage without symbol")
    func percentageWithoutSymbol() {
        #expect(SystemStatusParser.parsePercentage(from: "75") == 75.0)
    }

    @Test("Handles whitespace in percentage string")
    func percentageWithWhitespace() {
        #expect(SystemStatusParser.parsePercentage(from: "  50%  ") == 50.0)
    }

    @Test("Returns zero for invalid input")
    func invalidPercentage() {
        #expect(SystemStatusParser.parsePercentage(from: "invalid") == 0.0)
        #expect(SystemStatusParser.parsePercentage(from: "") == 0.0)
    }

    @Test("Handles edge case percentages", arguments: [
        ("0%", 0.0),
        ("100%", 100.0),
        ("99.9%", 99.9),
    ])
    func edgeCasePercentages(input: String, expected: Double) {
        #expect(SystemStatusParser.parsePercentage(from: input) == expected)
    }
}

// MARK: - Usage Ratio Parsing Tests

@Suite("Usage Ratio Parsing")
struct UsageRatioParsingTests {

    @Test("Parses standard GB usage format")
    func standardGBFormat() {
        let result = SystemStatusParser.parseUsageRatio(from: "8 GB / 16 GB")
        #expect(result?.used == 8.0)
        #expect(result?.total == 16.0)
    }

    @Test("Parses MB usage format")
    func mbFormat() {
        let result = SystemStatusParser.parseUsageRatio(from: "512 MB / 1024 MB")
        #expect(result?.used == 512.0)
        #expect(result?.total == 1024.0)
    }

    @Test("Parses TB usage format")
    func tbFormat() {
        let result = SystemStatusParser.parseUsageRatio(from: "1.5 TB / 4 TB")
        #expect(result?.used == 1.5)
        #expect(result?.total == 4.0)
    }

    @Test("Returns nil for invalid format")
    func invalidFormat() {
        #expect(SystemStatusParser.parseUsageRatio(from: "invalid") == nil)
        #expect(SystemStatusParser.parseUsageRatio(from: "8 GB") == nil)
        #expect(SystemStatusParser.parseUsageRatio(from: "") == nil)
    }

    @Test("Calculates usage percentage correctly", arguments: [
        ("8 GB / 16 GB", 50.0),
        ("0 GB / 16 GB", 0.0),
        ("16 GB / 16 GB", 100.0),
        ("4 GB / 16 GB", 25.0),
    ])
    func usagePercentageCalculation(input: String, expected: Double) {
        #expect(SystemStatusParser.parseUsagePercentage(from: input) == expected)
    }

    @Test("Handles zero total gracefully")
    func zeroTotal() {
        #expect(SystemStatusParser.parseUsagePercentage(from: "0 GB / 0 GB") == 0.0)
    }
}

// MARK: - Network Rate Parsing Tests

@Suite("Network Rate Parsing")
struct NetworkRateParsingTests {

    @Test("Parses bytes per second")
    func bytesPerSecond() {
        #expect(SystemStatusParser.parseNetworkRate(from: "500 B/s") == 500.0)
    }

    @Test("Parses kilobytes per second")
    func kilobytesPerSecond() {
        #expect(SystemStatusParser.parseNetworkRate(from: "1.5 KB/s") == 1500.0)
    }

    @Test("Parses megabytes per second")
    func megabytesPerSecond() {
        #expect(SystemStatusParser.parseNetworkRate(from: "10 MB/s") == 10_000_000.0)
    }

    @Test("Parses gigabytes per second")
    func gigabytesPerSecond() {
        #expect(SystemStatusParser.parseNetworkRate(from: "1 GB/s") == 1_000_000_000.0)
    }

    @Test("Returns zero for invalid input")
    func invalidInput() {
        #expect(SystemStatusParser.parseNetworkRate(from: "invalid") == 0.0)
        #expect(SystemStatusParser.parseNetworkRate(from: "") == 0.0)
    }
}

// MARK: - Disk Activity Normalization Tests

@Suite("Disk Activity Normalization")
struct DiskActivityTests {

    @Test("Returns zero for zero input")
    func zeroActivity() {
        #expect(SystemStatusParser.normalizeDiskActivity(0) == 0.0)
    }

    @Test("Returns zero for negative input")
    func negativeActivity() {
        #expect(SystemStatusParser.normalizeDiskActivity(-10) == 0.0)
    }

    @Test("Normalizes within expected range")
    func normalizationRange() {
        let result = SystemStatusParser.normalizeDiskActivity(50)
        #expect(result > 0)
        #expect(result <= 100)
    }

    @Test("High activity approaches but doesn't exceed 100")
    func highActivity() {
        let result = SystemStatusParser.normalizeDiskActivity(1000)
        #expect(result <= 100)
    }

    @Test("Uses logarithmic scaling")
    func logarithmicScaling() {
        // Verify that doubling input doesn't double output (logarithmic behavior)
        let result10 = SystemStatusParser.normalizeDiskActivity(10)
        let result20 = SystemStatusParser.normalizeDiskActivity(20)
        let ratio = result20 / result10
        #expect(ratio < 2.0, "Logarithmic scaling should not double output when input doubles")
    }
}

// MARK: - Host Validation Tests

@Suite("Host Validation")
struct HostValidationTests {

    @Test("Accepts valid hostname")
    func validHostname() {
        #expect(SystemStatusParser.isValidHost("freebsd.example.com"))
    }

    @Test("Accepts valid IP address")
    func validIPAddress() {
        #expect(SystemStatusParser.isValidHost("192.168.1.100"))
    }

    @Test("Accepts localhost")
    func localhost() {
        #expect(SystemStatusParser.isValidHost("localhost"))
    }

    @Test("Rejects empty string")
    func emptyString() {
        #expect(!SystemStatusParser.isValidHost(""))
    }

    @Test("Rejects whitespace-only string")
    func whitespaceOnly() {
        #expect(!SystemStatusParser.isValidHost("   "))
    }

    @Test("Rejects hostname with invalid characters")
    func invalidCharacters() {
        #expect(!SystemStatusParser.isValidHost("host@name"))
        #expect(!SystemStatusParser.isValidHost("host name"))
        #expect(!SystemStatusParser.isValidHost("host;name"))
    }
}

// MARK: - Port Validation Tests

@Suite("Port Validation")
struct PortValidationTests {

    @Test("Accepts valid SSH port")
    func validSSHPort() {
        #expect(SystemStatusParser.isValidPort(22))
    }

    @Test("Accepts minimum valid port")
    func minimumPort() {
        #expect(SystemStatusParser.isValidPort(1))
    }

    @Test("Accepts maximum valid port")
    func maximumPort() {
        #expect(SystemStatusParser.isValidPort(65535))
    }

    @Test("Rejects port zero")
    func portZero() {
        #expect(!SystemStatusParser.isValidPort(0))
    }

    @Test("Rejects negative port")
    func negativePort() {
        #expect(!SystemStatusParser.isValidPort(-1))
    }

    @Test("Rejects port above maximum")
    func portAboveMax() {
        #expect(!SystemStatusParser.isValidPort(65536))
    }

    @Test("Common ports are valid", arguments: [22, 80, 443, 8080, 3000])
    func commonPorts(port: Int) {
        #expect(SystemStatusParser.isValidPort(port))
    }
}

// MARK: - Uptime Parsing Tests

@Suite("Uptime Parsing")
struct UptimeParsingTests {

    @Test("Parses days and time format")
    func daysAndTime() {
        let result = SystemStatusParser.parseUptime("5 days, 3:42")
        #expect(result?.days == 5)
        #expect(result?.hours == 3)
        #expect(result?.minutes == 42)
    }

    @Test("Parses single day format")
    func singleDay() {
        let result = SystemStatusParser.parseUptime("1 day, 12:30")
        #expect(result?.days == 1)
        #expect(result?.hours == 12)
        #expect(result?.minutes == 30)
    }

    @Test("Parses time only format")
    func timeOnly() {
        let result = SystemStatusParser.parseUptime("6:15")
        #expect(result?.days == 0)
        #expect(result?.hours == 6)
        #expect(result?.minutes == 15)
    }

    @Test("Parses days only format")
    func daysOnly() {
        let result = SystemStatusParser.parseUptime("10 days")
        #expect(result?.days == 10)
        #expect(result?.hours == 0)
        #expect(result?.minutes == 0)
    }
}
