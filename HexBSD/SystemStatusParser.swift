//
//  SystemStatusParser.swift
//  HexBSD
//
//  Parsing utilities for system status data.
//  Extracted for testability.
//

import Foundation

/// Parsing utilities for system status strings returned from FreeBSD commands
enum SystemStatusParser {

    /// Extracts a percentage value from a string like "45%" or "45.5%"
    /// - Parameter string: A string containing a percentage value
    /// - Returns: The numeric percentage value, or 0 if parsing fails
    static func parsePercentage(from string: String) -> Double {
        let cleaned = string.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned) ?? 0
    }

    /// Parses a usage string in the format "X GB / Y GB" and returns the percentage used
    /// - Parameter usageString: A string like "8 GB / 16 GB"
    /// - Returns: The percentage of usage (0-100), or 0 if parsing fails
    static func parseUsagePercentage(from usageString: String) -> Double {
        guard let ratio = parseUsageRatio(from: usageString) else { return 0 }
        return ratio.total > 0 ? (ratio.used / ratio.total) * 100 : 0
    }

    /// Parses a usage string in the format "X GB / Y GB" and returns the used and total values
    /// - Parameter usageString: A string like "8 GB / 16 GB"
    /// - Returns: A tuple of (used, total) values, or nil if parsing fails
    static func parseUsageRatio(from usageString: String) -> (used: Double, total: Double)? {
        let parts = usageString.split(separator: "/")
        guard parts.count == 2 else { return nil }

        let usedString = parts[0].trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " GB", with: "")
            .replacingOccurrences(of: " MB", with: "")
            .replacingOccurrences(of: " TB", with: "")

        let totalString = parts[1].trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " GB", with: "")
            .replacingOccurrences(of: " MB", with: "")
            .replacingOccurrences(of: " TB", with: "")

        guard let used = Double(usedString),
              let total = Double(totalString) else {
            return nil
        }

        return (used, total)
    }

    /// Parses network rate strings like "1.5 MB/s" or "500 KB/s" and returns bytes per second
    /// - Parameter rateString: A string representing network rate
    /// - Returns: The rate in bytes per second, or 0 if parsing fails
    static func parseNetworkRate(from rateString: String) -> Double {
        let cleaned = rateString.trimmingCharacters(in: .whitespaces)

        if cleaned.hasSuffix("GB/s") {
            let value = cleaned.replacingOccurrences(of: " GB/s", with: "")
            return (Double(value) ?? 0) * 1_000_000_000
        } else if cleaned.hasSuffix("MB/s") {
            let value = cleaned.replacingOccurrences(of: " MB/s", with: "")
            return (Double(value) ?? 0) * 1_000_000
        } else if cleaned.hasSuffix("KB/s") {
            let value = cleaned.replacingOccurrences(of: " KB/s", with: "")
            return (Double(value) ?? 0) * 1_000
        } else if cleaned.hasSuffix("B/s") {
            let value = cleaned.replacingOccurrences(of: " B/s", with: "")
            return Double(value) ?? 0
        }

        return 0
    }

    /// Parses disk I/O activity and normalizes to a 0-100 scale using logarithmic scaling
    /// - Parameter totalMBps: Total MB/s of disk activity
    /// - Returns: A normalized activity level from 0-100
    static func normalizeDiskActivity(_ totalMBps: Double) -> Double {
        guard totalMBps > 0 else { return 0 }
        // Scale: 0 MB/s = 0%, 100 MB/s = ~100%
        // Using log scale to better represent wide range of values
        return min(100, (log10(totalMBps + 1) / log10(101)) * 100)
    }

    /// Validates that a string represents a valid FreeBSD hostname or IP address
    /// - Parameter host: The hostname or IP address string
    /// - Returns: true if the format appears valid
    static func isValidHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        // Basic validation - not empty and doesn't contain invalid characters
        let invalidCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: ".-"))
            .inverted

        return trimmed.rangeOfCharacter(from: invalidCharacters) == nil
    }

    /// Validates that a port number is within valid range
    /// - Parameter port: The port number
    /// - Returns: true if port is valid (1-65535)
    static func isValidPort(_ port: Int) -> Bool {
        return port >= 1 && port <= 65535
    }

    /// Parses uptime string and returns components
    /// - Parameter uptimeString: A string like "5 days, 3:42"
    /// - Returns: A tuple of days, hours, minutes or nil if parsing fails
    static func parseUptime(_ uptimeString: String) -> (days: Int, hours: Int, minutes: Int)? {
        var days = 0
        var hours = 0
        var minutes = 0

        let trimmed = uptimeString.trimmingCharacters(in: .whitespaces)

        // Handle "X days" format
        if let daysRange = trimmed.range(of: #"(\d+)\s*days?"#, options: .regularExpression) {
            let daysStr = trimmed[daysRange]
            if let daysNum = Int(daysStr.filter { $0.isNumber }) {
                days = daysNum
            }
        }

        // Handle "H:MM" format
        if let timeRange = trimmed.range(of: #"(\d+):(\d+)"#, options: .regularExpression) {
            let timeStr = String(trimmed[timeRange])
            let parts = timeStr.split(separator: ":")
            if parts.count == 2 {
                hours = Int(parts[0]) ?? 0
                minutes = Int(parts[1]) ?? 0
            }
        }

        return (days, hours, minutes)
    }
}
