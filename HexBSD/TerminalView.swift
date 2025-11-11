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
    @StateObject private var coordinator = TerminalCoordinator(sshManager: SSHConnectionManager.shared)
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
    override init(frame: CGRect) {
        super.init(frame: frame)
        configureTerminal()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTerminal()
    }

    private func configureTerminal() {
        // Configure terminal appearance
        nativeForegroundColor = NSColor.white
        nativeBackgroundColor = NSColor.black
        font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }
}
