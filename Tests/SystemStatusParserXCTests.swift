//
//  SystemStatusParserXCTests.swift
//  HexBSD
//
//  XCTest tests for SystemStatusParser.
//  Demonstrates familiarity with traditional XCTest alongside Swift Testing.
//

import XCTest
@testable import HexBSD

final class SystemStatusParserXCTests: XCTestCase {

    // MARK: - Percentage Parsing

    func testParsePercentage_withValidInteger() {
        XCTAssertEqual(SystemStatusParser.parsePercentage(from: "45%"), 45.0)
    }

    func testParsePercentage_withValidDecimal() {
        XCTAssertEqual(SystemStatusParser.parsePercentage(from: "45.5%"), 45.5)
    }

    func testParsePercentage_withoutSymbol() {
        XCTAssertEqual(SystemStatusParser.parsePercentage(from: "75"), 75.0)
    }

    func testParsePercentage_withWhitespace() {
        XCTAssertEqual(SystemStatusParser.parsePercentage(from: "  50%  "), 50.0)
    }

    func testParsePercentage_withInvalidInput_returnsZero() {
        XCTAssertEqual(SystemStatusParser.parsePercentage(from: "invalid"), 0.0)
        XCTAssertEqual(SystemStatusParser.parsePercentage(from: ""), 0.0)
    }

    // MARK: - Usage Ratio Parsing

    func testParseUsageRatio_withGBFormat() throws {
        let result = try XCTUnwrap(SystemStatusParser.parseUsageRatio(from: "8 GB / 16 GB"))
        XCTAssertEqual(result.used, 8.0)
        XCTAssertEqual(result.total, 16.0)
    }

    func testParseUsageRatio_withMBFormat() throws {
        let result = try XCTUnwrap(SystemStatusParser.parseUsageRatio(from: "512 MB / 1024 MB"))
        XCTAssertEqual(result.used, 512.0)
        XCTAssertEqual(result.total, 1024.0)
    }

    func testParseUsageRatio_withInvalidFormat_returnsNil() {
        XCTAssertNil(SystemStatusParser.parseUsageRatio(from: "invalid"))
        XCTAssertNil(SystemStatusParser.parseUsageRatio(from: "8 GB"))
        XCTAssertNil(SystemStatusParser.parseUsageRatio(from: ""))
    }

    func testParseUsagePercentage_calculatesCorrectly() {
        XCTAssertEqual(SystemStatusParser.parseUsagePercentage(from: "8 GB / 16 GB"), 50.0)
        XCTAssertEqual(SystemStatusParser.parseUsagePercentage(from: "0 GB / 16 GB"), 0.0)
        XCTAssertEqual(SystemStatusParser.parseUsagePercentage(from: "16 GB / 16 GB"), 100.0)
    }

    func testParseUsagePercentage_withZeroTotal_returnsZero() {
        XCTAssertEqual(SystemStatusParser.parseUsagePercentage(from: "0 GB / 0 GB"), 0.0)
    }

    // MARK: - Network Rate Parsing

    func testParseNetworkRate_withBytesPerSecond() {
        XCTAssertEqual(SystemStatusParser.parseNetworkRate(from: "500 B/s"), 500.0)
    }

    func testParseNetworkRate_withKilobytesPerSecond() {
        XCTAssertEqual(SystemStatusParser.parseNetworkRate(from: "1.5 KB/s"), 1500.0)
    }

    func testParseNetworkRate_withMegabytesPerSecond() {
        XCTAssertEqual(SystemStatusParser.parseNetworkRate(from: "10 MB/s"), 10_000_000.0)
    }

    func testParseNetworkRate_withGigabytesPerSecond() {
        XCTAssertEqual(SystemStatusParser.parseNetworkRate(from: "1 GB/s"), 1_000_000_000.0)
    }

    // MARK: - Disk Activity Normalization

    func testNormalizeDiskActivity_withZero_returnsZero() {
        XCTAssertEqual(SystemStatusParser.normalizeDiskActivity(0), 0.0)
    }

    func testNormalizeDiskActivity_withNegative_returnsZero() {
        XCTAssertEqual(SystemStatusParser.normalizeDiskActivity(-10), 0.0)
    }

    func testNormalizeDiskActivity_isWithinExpectedRange() {
        let result = SystemStatusParser.normalizeDiskActivity(50)
        XCTAssertGreaterThan(result, 0)
        XCTAssertLessThanOrEqual(result, 100)
    }

    func testNormalizeDiskActivity_usesLogarithmicScaling() {
        // Verify that doubling input doesn't double output
        let result10 = SystemStatusParser.normalizeDiskActivity(10)
        let result20 = SystemStatusParser.normalizeDiskActivity(20)
        let ratio = result20 / result10
        XCTAssertLessThan(ratio, 2.0, "Logarithmic scaling should not double output when input doubles")
    }

    // MARK: - Host Validation

    func testIsValidHost_acceptsValidHostname() {
        XCTAssertTrue(SystemStatusParser.isValidHost("freebsd.example.com"))
    }

    func testIsValidHost_acceptsIPAddress() {
        XCTAssertTrue(SystemStatusParser.isValidHost("192.168.1.100"))
    }

    func testIsValidHost_acceptsLocalhost() {
        XCTAssertTrue(SystemStatusParser.isValidHost("localhost"))
    }

    func testIsValidHost_rejectsEmptyString() {
        XCTAssertFalse(SystemStatusParser.isValidHost(""))
    }

    func testIsValidHost_rejectsInvalidCharacters() {
        XCTAssertFalse(SystemStatusParser.isValidHost("host@name"))
        XCTAssertFalse(SystemStatusParser.isValidHost("host name"))
        XCTAssertFalse(SystemStatusParser.isValidHost("host;name"))
    }

    // MARK: - Port Validation

    func testIsValidPort_acceptsSSHPort() {
        XCTAssertTrue(SystemStatusParser.isValidPort(22))
    }

    func testIsValidPort_acceptsMinimumPort() {
        XCTAssertTrue(SystemStatusParser.isValidPort(1))
    }

    func testIsValidPort_acceptsMaximumPort() {
        XCTAssertTrue(SystemStatusParser.isValidPort(65535))
    }

    func testIsValidPort_rejectsZero() {
        XCTAssertFalse(SystemStatusParser.isValidPort(0))
    }

    func testIsValidPort_rejectsNegative() {
        XCTAssertFalse(SystemStatusParser.isValidPort(-1))
    }

    func testIsValidPort_rejectsAboveMaximum() {
        XCTAssertFalse(SystemStatusParser.isValidPort(65536))
    }

    // MARK: - Uptime Parsing

    func testParseUptime_withDaysAndTime() throws {
        let result = try XCTUnwrap(SystemStatusParser.parseUptime("5 days, 3:42"))
        XCTAssertEqual(result.days, 5)
        XCTAssertEqual(result.hours, 3)
        XCTAssertEqual(result.minutes, 42)
    }

    func testParseUptime_withSingleDay() throws {
        let result = try XCTUnwrap(SystemStatusParser.parseUptime("1 day, 12:30"))
        XCTAssertEqual(result.days, 1)
        XCTAssertEqual(result.hours, 12)
        XCTAssertEqual(result.minutes, 30)
    }

    func testParseUptime_withTimeOnly() throws {
        let result = try XCTUnwrap(SystemStatusParser.parseUptime("6:15"))
        XCTAssertEqual(result.days, 0)
        XCTAssertEqual(result.hours, 6)
        XCTAssertEqual(result.minutes, 15)
    }

    // MARK: - Performance Tests

    func testPerformance_parsePercentage() {
        measure {
            for _ in 0..<10000 {
                _ = SystemStatusParser.parsePercentage(from: "45.5%")
            }
        }
    }

    func testPerformance_parseUsageRatio() {
        measure {
            for _ in 0..<10000 {
                _ = SystemStatusParser.parseUsageRatio(from: "8 GB / 16 GB")
            }
        }
    }
}
