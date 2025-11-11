//
//  AppNotifications.swift
//  HexBSD
//
//  Shared notification names for app-wide events
//

import Foundation

extension Notification.Name {
    /// Posted when a terminal should be opened with a specific command
    /// UserInfo contains: "command" (String)
    static let openTerminalWithCommand = Notification.Name("openTerminalWithCommand")
}
