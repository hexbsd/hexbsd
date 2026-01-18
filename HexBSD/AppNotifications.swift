//
//  AppNotifications.swift
//  HexBSD
//
//  Shared notification names for app-wide events
//

import Foundation
import SwiftUI

// MARK: - Window ID Environment Key

/// Environment key for passing window-specific ID to child views
/// Used to scope notifications to the current window only
struct WindowIDKey: EnvironmentKey {
    static let defaultValue: UUID = UUID()
}

extension EnvironmentValues {
    var windowID: UUID {
        get { self[WindowIDKey.self] }
        set { self[WindowIDKey.self] = newValue }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a terminal should be opened with a specific command
    /// UserInfo contains: "command" (String)
    static let openTerminalWithCommand = Notification.Name("openTerminalWithCommand")

    /// Posted when navigation to Network > Bridges tab is requested
    static let navigateToNetworkBridges = Notification.Name("navigateToNetworkBridges")

    /// Posted when sidebar navigation should be locked/unlocked (during long-running operations)
    /// UserInfo contains: "locked" (Bool)
    static let sidebarNavigationLock = Notification.Name("sidebarNavigationLock")

    /// Posted when navigation to Tasks page is requested
    static let navigateToTasks = Notification.Name("navigateToTasks")

    /// Posted when navigation to ZFS page is requested (opens Pools sheet)
    static let navigateToZFS = Notification.Name("navigateToZFS")
}
