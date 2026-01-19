//
//  TerminalView.swift
//  HexBSD
//
//  Created by Joseph Maloney on 3/17/25.
//

import SwiftUI
import SwiftTerm
import Citadel
import NIOCore
import AppKit

/// Main terminal content view that manages the terminal session
struct TerminalContentView: View {
    @Environment(\.sshManager) private var sshManager

    var body: some View {
        TerminalContentViewImpl(sshManager: sshManager)
    }
}

struct TerminalContentViewImpl: View {
    let sshManager: SSHConnectionManager
    @StateObject private var coordinator: TerminalCoordinator

    init(sshManager: SSHConnectionManager) {
        self.sshManager = sshManager
        _coordinator = StateObject(wrappedValue: TerminalCoordinator(sshManager: sshManager))
    }
    @State private var showError = false
    @State private var pendingCommand: String?

    var body: some View {
        Group {
            if coordinator.isConnected {
                SSHTerminalView(terminalCoordinator: coordinator)
            } else {
                // Show connecting state
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Connecting to terminal...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Terminal Error", isPresented: $showError) {
            Button("OK") {
                showError = false
            }
        } message: {
            Text(coordinator.error ?? "Unknown error")
        }
        .onChange(of: coordinator.error) { oldValue, newValue in
            if newValue != nil {
                showError = true
            }
        }
        .onChange(of: coordinator.isReady) { oldValue, newValue in
            // When terminal becomes ready (stdin writer available), send any pending command
            if newValue && !oldValue, let command = pendingCommand {
                print("DEBUG: Terminal ready, sending pending command: \(command)")
                // Wait a bit for the shell prompt to appear
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    coordinator.sendCommand(command)
                    pendingCommand = nil
                }
            }
        }
        .onAppear {
            // Auto-connect when terminal view appears
            if !coordinator.isConnected {
                Task {
                    if #available(macOS 15.0, *) {
                        await coordinator.startShell()
                    }
                }
            } else if let command = pendingCommand {
                // Terminal already connected, send command immediately
                print("DEBUG: Terminal already connected, sending command: \(command)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    coordinator.sendCommand(command)
                    pendingCommand = nil
                }
            }
        }
        .onDisappear {
            // Disconnect when navigating away
            coordinator.stopShell()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openTerminalWithCommand)) { notification in
            // Listen for command notifications
            if let command = notification.userInfo?["command"] as? String {
                print("DEBUG: Terminal received command notification: \(command)")
                if coordinator.isConnected && coordinator.isReady {
                    // Terminal is ready, send immediately
                    print("DEBUG: Sending command immediately")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        coordinator.sendCommand(command)
                    }
                } else {
                    // Store command to send when terminal is ready
                    print("DEBUG: Storing pending command")
                    pendingCommand = command
                }
            }
        }
    }
}

/// SwiftUI wrapper for SwiftTerm's terminal view
struct SSHTerminalView: NSViewRepresentable {
    @ObservedObject var terminalCoordinator: TerminalCoordinator

    func makeNSView(context: Context) -> TerminalViewImpl {
        let terminal = TerminalViewImpl(frame: .zero)
        terminal.terminalDelegate = terminalCoordinator
        terminalCoordinator.terminalView = terminal
        return terminal
    }

    func updateNSView(_ nsView: TerminalViewImpl, context: Context) {
        // Terminal view updates handled through coordinator
    }
}

/// Coordinator that bridges between SwiftTerm and SSH connection
class TerminalCoordinator: NSObject, ObservableObject, TerminalViewDelegate {
    weak var terminalView: TerminalViewImpl?
    private var sshManager: SSHConnectionManager
    private var stdinWriter: ((ByteBuffer) async throws -> Void)?
    private var shellTask: Task<Void, Error>?

    @Published var isConnected = false
    @Published var isReady = false  // True when stdinWriter is available
    @Published var error: String?

    init(sshManager: SSHConnectionManager) {
        self.sshManager = sshManager
        super.init()
    }

    /// Start the interactive shell session
    @available(macOS 15.0, *)
    func startShell() async {
        await MainActor.run {
            isConnected = true
        }

        shellTask = Task {
            do {
                try await sshManager.startInteractiveShell(delegate: self)
            } catch {
                await MainActor.run {
                    self.error = "Failed to start shell: \(error.localizedDescription)"
                    self.isConnected = false
                }
            }
        }
    }

    /// Stop the shell session
    func stopShell() {
        shellTask?.cancel()
        shellTask = nil
        stdinWriter = nil

        Task { @MainActor in
            isConnected = false
            isReady = false
        }
    }

    /// Called by SSH manager when shell output is received
    func receiveOutput(_ data: Data) {
        guard let terminalView = terminalView else { return }

        // Convert Data to array of UInt8 and feed to terminal
        let bytes = [UInt8](data)
        DispatchQueue.main.async {
            terminalView.feed(byteArray: bytes[...])
        }
    }

    /// Called by SSH manager to provide stdin writer
    func setStdinWriter(_ writer: @escaping (ByteBuffer) async throws -> Void) {
        self.stdinWriter = writer
        Task { @MainActor in
            self.isReady = true
            print("DEBUG: Terminal is now ready (stdin writer set)")
        }
    }

    /// Send a command string to the terminal
    func sendCommand(_ command: String) {
        guard let stdinWriter = stdinWriter else {
            print("DEBUG: Cannot send command, no stdin writer available")
            return
        }

        print("DEBUG: Sending command to terminal: \(command)")
        Task {
            do {
                // Send the command followed by Enter
                var buffer = ByteBuffer()
                buffer.writeString(command + "\n")
                try await stdinWriter(buffer)
                print("DEBUG: Command sent successfully")
            } catch {
                print("DEBUG: Failed to send command: \(error)")
                await MainActor.run {
                    self.error = "Failed to send command: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Send user input to SSH
        guard let stdinWriter = stdinWriter else { return }

        Task {
            do {
                var buffer = ByteBuffer()
                buffer.writeBytes(Array(data))
                try await stdinWriter(buffer)
            } catch {
                await MainActor.run {
                    self.error = "Failed to send data: \(error.localizedDescription)"
                }
            }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Handle terminal resize - would need to send SIGWINCH to remote
        // For now, initial size is set when starting PTY
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // Could update window title here if desired
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Optional: track current directory
    }

    func scrolled(source: TerminalView, position: Double) {
        // Handle scroll position changes if needed
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String:String]) {
        // Handle link clicks - could open in browser
        #if os(macOS)
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    func bell(source: TerminalView) {
        // Handle terminal bell
        #if os(macOS)
        NSSound.beep()
        #endif
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        // Handle clipboard copy
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(content, forType: .string)
        #endif
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        // Handle iTerm2-specific content
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        // Handle visual changes notification
    }
}

/// Custom terminal view class (extends SwiftTerm's TerminalView for macOS)
class TerminalViewImpl: TerminalView {

    // MARK: - Custom Selection Tracking

    private struct SelectionPosition {
        var col: Int
        var row: Int
    }

    private var selectionStart: SelectionPosition?
    private var selectionEnd: SelectionPosition?
    private var isSelecting = false
    private var eventMonitor: Any?
    private let terminalFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureTerminal()
        setupEventMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTerminal()
        setupEventMonitor()
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func configureTerminal() {
        // Configure terminal appearance
        nativeForegroundColor = NSColor.white
        nativeBackgroundColor = NSColor.black
        font = terminalFont
    }

    // MARK: - Event Monitor for Selection Tracking

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        // Only handle events for this view
        guard let eventWindow = event.window,
              eventWindow == self.window else {
            return
        }

        let locationInWindow = event.locationInWindow
        let locationInView = convert(locationInWindow, from: nil)

        // Check if the event is within our bounds
        guard bounds.contains(locationInView) else {
            return
        }

        let position = convertToTerminalPosition(locationInView: locationInView)

        switch event.type {
        case .leftMouseDown:
            selectionStart = position
            selectionEnd = position
            isSelecting = true
        case .leftMouseDragged:
            if isSelecting {
                selectionEnd = position
            }
        case .leftMouseUp:
            if isSelecting {
                selectionEnd = position
                isSelecting = false
            }
        default:
            break
        }
    }

    /// Calculate cell dimensions from font metrics
    private func getCellDimensions() -> (width: CGFloat, height: CGFloat) {
        let fontAttributes: [NSAttributedString.Key: Any] = [.font: terminalFont]
        let charSize = "W".size(withAttributes: fontAttributes)
        // Use line height for cell height
        let lineHeight = terminalFont.ascender - terminalFont.descender + terminalFont.leading
        return (charSize.width, max(lineHeight, charSize.height))
    }

    /// Convert view location to terminal column/row position
    private func convertToTerminalPosition(locationInView: NSPoint) -> SelectionPosition {
        let (cellWidth, cellHeight) = getCellDimensions()

        // Calculate column and row (0-based)
        let col = max(0, min(Int(locationInView.x / cellWidth), terminal.cols - 1))
        // Y is flipped in AppKit - origin is bottom-left
        let flippedY = bounds.height - locationInView.y
        let row = max(0, min(Int(flippedY / cellHeight), terminal.rows - 1))

        return SelectionPosition(col: col, row: row)
    }

    // MARK: - Custom Copy Implementation

    /// Override copy to use our own selection tracking
    @objc override func copy(_ sender: Any) {
        guard let text = getSelectedText(), !text.isEmpty else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Extract selected text from terminal buffer using our tracked selection
    private func getSelectedText() -> String? {
        guard let start = selectionStart, let end = selectionEnd else {
            return nil
        }

        // Normalize selection (start should be before end)
        let (normalizedStart, normalizedEnd) = normalizeSelection(start: start, end: end)

        var result = ""

        // Single line selection
        if normalizedStart.row == normalizedEnd.row {
            result = getTextFromLine(row: normalizedStart.row, startCol: normalizedStart.col, endCol: normalizedEnd.col)
        } else {
            // Multi-line selection
            // First line: from start column to end of line
            result += getTextFromLine(row: normalizedStart.row, startCol: normalizedStart.col, endCol: terminal.cols - 1)
            result += "\n"

            // Middle lines: full lines
            for row in (normalizedStart.row + 1)..<normalizedEnd.row {
                result += getTextFromLine(row: row, startCol: 0, endCol: terminal.cols - 1)
                result += "\n"
            }

            // Last line: from start of line to end column
            result += getTextFromLine(row: normalizedEnd.row, startCol: 0, endCol: normalizedEnd.col)
        }

        return result.isEmpty ? nil : result
    }

    /// Normalize selection so start is always before end
    private func normalizeSelection(start: SelectionPosition, end: SelectionPosition) -> (SelectionPosition, SelectionPosition) {
        if start.row < end.row || (start.row == end.row && start.col <= end.col) {
            return (start, end)
        } else {
            return (end, start)
        }
    }

    /// Extract text from a single line between column positions
    private func getTextFromLine(row: Int, startCol: Int, endCol: Int) -> String {
        var lineText = ""

        for col in startCol...endCol {
            if let char = terminal.getCharacter(col: col, row: row) {
                lineText.append(char)
            }
        }

        // Trim trailing whitespace from line
        return lineText.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }
}
