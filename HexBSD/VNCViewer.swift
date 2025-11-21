//
//  VNCViewer.swift
//  HexBSD
//
//  Native VNC viewer implementation using RFB protocol
//

import SwiftUI
import Network
import AppKit

// MARK: - Pixel Format

struct PixelFormat {
    let bitsPerPixel: UInt8
    let depth: UInt8
    let bigEndian: Bool
    let trueColor: Bool
    let redMax: UInt16
    let greenMax: UInt16
    let blueMax: UInt16
    let redShift: UInt8
    let greenShift: UInt8
    let blueShift: UInt8
}

// MARK: - VNC Viewer View

struct VNCViewerView: View {
    let host: String
    let port: Int
    @StateObject private var vncClient = VNCClient()
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var mousePosition = CGPoint.zero

    var body: some View {
        VStack(spacing: 0) {
            if vncClient.isConnected {
                // Display the VNC frame
                if let image = vncClient.currentFrame {
                    VNCInteractiveImage(image: image, vncClient: vncClient)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .focusable()
                        .onTapGesture {
                            // Tap to ensure focus
                        }
                } else {
                    VStack {
                        ProgressView()
                        Text("Waiting for display...")
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                }
            } else if vncClient.isConnecting {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Connecting to \(host):\(port)...")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text("Not Connected")
                        .font(.headline)
                    Button("Connect") {
                        vncClient.connect(host: host, port: port)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("VNC Connection Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            vncClient.connect(host: host, port: port)
        }
        .onDisappear {
            vncClient.disconnect()
        }
        .onChange(of: vncClient.error) { oldValue, newValue in
            if let error = newValue {
                errorMessage = error
                showError = true
            }
        }
    }
}

// MARK: - VNC Interactive Image View

struct VNCInteractiveImage: NSViewRepresentable {
    let image: NSImage
    let vncClient: VNCClient

    func makeNSView(context: Context) -> VNCImageView {
        let view = VNCImageView()
        view.vncClient = vncClient
        view.image = image

        // Ensure view is properly set up for interaction
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }

        return view
    }

    func updateNSView(_ nsView: VNCImageView, context: Context) {
        nsView.image = image

        // Ensure view maintains first responder status
        if nsView.window?.firstResponder != nsView {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

class VNCImageView: NSImageView {
    weak var vncClient: VNCClient?
    private var lastMousePosition: CGPoint?
    private var mouseUpdateTimer: Timer?
    private var lastModifiers = NSEvent.ModifierFlags()
    private var pressedKeys: [UInt16: UInt32] = [:]  // Track keyCode -> keysym for consistent key up/down

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        // Enable mouse tracking
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)

        print("VNC: View setup complete, acceptsFirstResponder: \(acceptsFirstResponder)")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            print("VNC: View added to window, requesting first responder")
        }
    }

    deinit {
        mouseUpdateTimer?.invalidate()
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override var canBecomeKeyView: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        print("VNC: Became first responder")
        return true
    }

    override func resignFirstResponder() -> Bool {
        print("VNC: Resigned first responder")
        return super.resignFirstResponder()
    }

    // MARK: - Mouse Events

    private func convertToVNCCoordinates(_ windowLocation: NSPoint) -> CGPoint? {
        guard let vncClient = vncClient,
              vncClient.framebufferWidth > 0,
              vncClient.framebufferHeight > 0 else {
            print("VNC: Cannot convert coordinates - no framebuffer")
            return nil
        }

        // Convert window coordinates to view coordinates
        let locationInView = convert(windowLocation, from: nil)

        print("VNC: Window location: \(windowLocation)")
        print("VNC: View location: \(locationInView)")
        print("VNC: View bounds: \(bounds)")

        let imageSize = CGSize(width: CGFloat(vncClient.framebufferWidth),
                              height: CGFloat(vncClient.framebufferHeight))
        let viewSize = bounds.size

        // Calculate scaling (maintain aspect ratio)
        let scaleX = viewSize.width / imageSize.width
        let scaleY = viewSize.height / imageSize.height
        let scale = min(scaleX, scaleY)

        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale

        // Calculate letterbox offsets
        let offsetX = (viewSize.width - scaledWidth) / 2
        let offsetY = (viewSize.height - scaledHeight) / 2

        print("VNC: Image size: \(imageSize), View size: \(viewSize)")
        print("VNC: Scale: \(scale), Offsets: (\(offsetX), \(offsetY))")

        // Convert view coordinates to scaled image coordinates
        let scaledX = locationInView.x - offsetX
        let scaledY = locationInView.y - offsetY

        // Check if click is within the image area
        if scaledX < 0 || scaledX > scaledWidth || scaledY < 0 || scaledY > scaledHeight {
            print("VNC: Click outside image bounds")
            return nil
        }

        // Convert to VNC coordinates
        // VNC uses top-left origin (0,0 at top-left)
        // AppKit uses bottom-left origin, so we need to flip Y
        let vncX = scaledX / scale
        let vncY = imageSize.height - (scaledY / scale)

        // Clamp to image bounds
        let clampedX = max(0, min(imageSize.width - 1, vncX))
        let clampedY = max(0, min(imageSize.height - 1, vncY))

        print("VNC: Calculated VNC coords: (\(clampedX), \(clampedY))")

        return CGPoint(x: clampedX, y: clampedY)
    }

    override func mouseDown(with event: NSEvent) {
        print("VNC: mouseDown at window coords: \(event.locationInWindow)")
        guard let coords = convertToVNCCoordinates(event.locationInWindow) else {
            print("VNC: Failed to convert coordinates")
            return
        }
        print("VNC: Sending mouseDown to VNC coords: (\(Int(coords.x)), \(Int(coords.y)))")
        vncClient?.sendMouseEvent(x: Int(coords.x), y: Int(coords.y), buttonMask: 1)
    }

    override func mouseUp(with event: NSEvent) {
        print("VNC: mouseUp at window coords: \(event.locationInWindow)")
        guard let coords = convertToVNCCoordinates(event.locationInWindow) else {
            print("VNC: Failed to convert coordinates")
            return
        }
        print("VNC: Sending mouseUp to VNC coords: (\(Int(coords.x)), \(Int(coords.y)))")
        vncClient?.sendMouseEvent(x: Int(coords.x), y: Int(coords.y), buttonMask: 0)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let coords = convertToVNCCoordinates(event.locationInWindow) else { return }
        vncClient?.sendMouseEvent(x: Int(coords.x), y: Int(coords.y), buttonMask: 1)
    }

    override func mouseMoved(with event: NSEvent) {
        // Store position but don't send - mouse moves are too frequent
        // Only send mouse position during clicks and drags
        guard let coords = convertToVNCCoordinates(event.locationInWindow) else { return }
        lastMousePosition = coords
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let coords = convertToVNCCoordinates(event.locationInWindow) else { return }
        vncClient?.sendMouseEvent(x: Int(coords.x), y: Int(coords.y), buttonMask: 4)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let coords = convertToVNCCoordinates(event.locationInWindow) else { return }
        vncClient?.sendMouseEvent(x: Int(coords.x), y: Int(coords.y), buttonMask: 0)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let coords = convertToVNCCoordinates(event.locationInWindow) else { return }
        vncClient?.sendMouseEvent(x: Int(coords.x), y: Int(coords.y), buttonMask: 4)
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        print("VNC: keyDown - keyCode: \(event.keyCode), characters: \(event.characters ?? "nil")")

        guard let keysym = mapKeyToVNCKeysym(event: event) else {
            print("VNC: Failed to map key")
            return
        }

        // Store the keysym so we can send the same one on keyUp
        pressedKeys[event.keyCode] = keysym

        print("VNC: Sending keyDown - keysym: 0x\(String(keysym, radix: 16))")
        vncClient?.sendKeyEvent(key: keysym, down: true)
    }

    override func keyUp(with event: NSEvent) {
        // Use the keysym we sent on keyDown, not what it maps to now
        // This handles cases where modifiers (like Shift) are released before the key
        guard let keysym = pressedKeys.removeValue(forKey: event.keyCode) else {
            print("VNC: keyUp for unknown key - keyCode: \(event.keyCode)")
            return
        }

        print("VNC: Sending keyUp - keysym: 0x\(String(keysym, radix: 16))")
        vncClient?.sendKeyEvent(key: keysym, down: false)
    }

    private func mapKeyToVNCKeysym(event: NSEvent) -> UInt32? {
        // Map special keys by keyCode first
        switch event.keyCode {
        case 36: return 0xff0d  // Return/Enter
        case 48: return 0xff09  // Tab
        case 51: return 0xff08  // Backspace
        case 53: return 0xff1b  // Escape
        case 123: return 0xff51 // Left Arrow
        case 124: return 0xff53 // Right Arrow
        case 125: return 0xff54 // Down Arrow
        case 126: return 0xff52 // Up Arrow
        case 117: return 0xffff // Delete/Forward Delete
        case 115: return 0xff50 // Home
        case 119: return 0xff57 // End
        case 116: return 0xff55 // Page Up
        case 121: return 0xff56 // Page Down
        case 122: return 0xffbe // F1
        case 120: return 0xffbf // F2
        case 99: return 0xffc0  // F3
        case 118: return 0xffc1 // F4
        case 96: return 0xffc2  // F5
        case 97: return 0xffc3  // F6
        case 98: return 0xffc4  // F7
        case 100: return 0xffc5 // F8
        case 101: return 0xffc6 // F9
        case 109: return 0xffc7 // F10
        case 103: return 0xffc8 // F11
        case 111: return 0xffc9 // F12
        default:
            // For regular characters, use Unicode value
            if let characters = event.charactersIgnoringModifiers,
               let firstChar = characters.unicodeScalars.first {
                return UInt32(firstChar.value)
            }
            return nil
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // Handle modifier keys - track pressed/released state
        let modifiers = event.modifierFlags

        // Shift
        if modifiers.contains(.shift) != lastModifiers.contains(.shift) {
            vncClient?.sendKeyEvent(key: 0xffe1, down: modifiers.contains(.shift)) // XK_Shift_L
        }

        // Control
        if modifiers.contains(.control) != lastModifiers.contains(.control) {
            vncClient?.sendKeyEvent(key: 0xffe3, down: modifiers.contains(.control)) // XK_Control_L
        }

        // Option/Alt
        if modifiers.contains(.option) != lastModifiers.contains(.option) {
            vncClient?.sendKeyEvent(key: 0xffe9, down: modifiers.contains(.option)) // XK_Alt_L
        }

        // Command/Super
        if modifiers.contains(.command) != lastModifiers.contains(.command) {
            vncClient?.sendKeyEvent(key: 0xffeb, down: modifiers.contains(.command)) // XK_Super_L
        }

        lastModifiers = modifiers
    }
}

// MARK: - Thread-Safe Event Queue

private class VNCEventQueue {
    private var queue: [Data] = []
    private let lock = NSLock()

    func enqueue(_ event: Data) {
        lock.lock()
        queue.append(event)
        lock.unlock()
    }

    func dequeueAll() -> [Data] {
        lock.lock()
        let events = queue
        queue.removeAll()
        lock.unlock()
        return events
    }

    var count: Int {
        lock.lock()
        let c = queue.count
        lock.unlock()
        return c
    }
}

// MARK: - VNC Client

@MainActor
class VNCClient: ObservableObject {
    @Published var currentFrame: NSImage?
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var error: String?

    private var connection: NWConnection?
    var framebufferWidth: Int = 0
    var framebufferHeight: Int = 0
    private var pixelFormat: PixelFormat?
    private var framebufferData: Data?
    nonisolated private let sendQueue = DispatchQueue(label: "com.hexbsd.vnc.send", qos: .userInteractive)
    private var pendingUpdateRequest = false
    nonisolated private let connectionLock = NSLock()
    nonisolated private let inputEventQueue = VNCEventQueue()

    func connect(host: String, port: Int) {
        isConnecting = true
        error = nil

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port))
        )

        connection = NWConnection(to: endpoint, using: .tcp)

        connection?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    print("VNC: Connected to \(host):\(port)")
                    self?.handleConnection()
                case .failed(let error):
                    print("VNC: Connection failed: \(error)")
                    self?.error = "Connection failed: \(error.localizedDescription)"
                    self?.isConnecting = false
                case .waiting(let error):
                    print("VNC: Waiting: \(error)")
                case .cancelled:
                    print("VNC: Connection cancelled")
                    self?.isConnecting = false
                    self?.isConnected = false
                default:
                    break
                }
            }
        }

        connection?.start(queue: .global(qos: .userInitiated))
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        isConnecting = false
    }

    nonisolated func sendMouseEvent(x: Int, y: Int, buttonMask: UInt8) {
        // Queue the event instead of sending immediately
        var message = Data()
        message.append(5) // PointerEvent message type
        message.append(buttonMask) // Button mask

        // X position (UInt16)
        message.append(contentsOf: withUnsafeBytes(of: UInt16(x).bigEndian) { Data($0) })
        // Y position (UInt16)
        message.append(contentsOf: withUnsafeBytes(of: UInt16(y).bigEndian) { Data($0) })

        inputEventQueue.enqueue(message)

        print("VNC: Queued mouse event - x:\(x), y:\(y), buttonMask:\(buttonMask) (queue size: \(inputEventQueue.count))")
    }

    nonisolated func sendKeyEvent(key: UInt32, down: Bool) {
        // Queue the event instead of sending immediately
        var message = Data()
        message.append(4) // KeyEvent message type
        message.append(down ? 1 : 0) // Down flag
        message.append(contentsOf: [0, 0]) // Padding

        // Key (UInt32)
        message.append(contentsOf: withUnsafeBytes(of: key.bigEndian) { Data($0) })

        inputEventQueue.enqueue(message)

        print("VNC: Queued key event - key:0x\(String(key, radix: 16)), down:\(down) (queue size: \(inputEventQueue.count))")
    }

    private func handleConnection() {
        Task {
            do {
                // RFB Protocol Version Handshake
                try await sendProtocolVersion()
                try await receiveSecurityTypes()
                try await initializeSession()

                await MainActor.run {
                    self.isConnecting = false
                    self.isConnected = true
                }

                // Start receiving framebuffer updates
                try await receiveServerMessages()
            } catch {
                await MainActor.run {
                    print("VNC: Connection error: \(error)")
                    self.error = "VNC Protocol error: \(error.localizedDescription)"
                    self.isConnecting = false
                    self.isConnected = false
                }
            }
        }
    }

    private func sendProtocolVersion() async throws {
        // Send RFB 003.008 (most compatible version)
        let version = "RFB 003.008\n"
        try await send(version.data(using: .ascii)!)

        // Receive server version
        let serverVersion = try await receive(count: 12)
        print("VNC: Server version: \(String(data: serverVersion, encoding: .ascii) ?? "unknown")")
    }

    private func receiveSecurityTypes() async throws {
        // Receive number of security types
        let countData = try await receive(count: 1)
        let count = countData[0]

        // Receive security types
        let typesData = try await receive(count: Int(count))
        print("VNC: Security types: \(Array(typesData))")

        // Look for "None" security type (value 1)
        if typesData.contains(1) {
            // Select "None" authentication
            try await send(Data([1]))
            print("VNC: Selected 'None' security type")

            // For RFB 3.8, receive security result
            let resultData = try await receive(count: 4)
            let result = resultData.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
            if result != 0 {
                throw NSError(domain: "VNC", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "Security handshake failed"])
            }
        } else {
            throw NSError(domain: "VNC", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server requires authentication (no 'None' type available)"])
        }
    }

    private func initializeSession() async throws {
        // Send ClientInit (shared flag = 1)
        try await send(Data([1]))

        // Receive ServerInit
        let serverInit = try await receive(count: 24)

        // Parse framebuffer dimensions
        framebufferWidth = Int(serverInit.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) }.bigEndian)
        framebufferHeight = Int(serverInit.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) }.bigEndian)

        // Parse pixel format (16 bytes starting at offset 4)
        let bitsPerPixel = serverInit[4]
        let depth = serverInit[5]
        let bigEndian = serverInit[6] != 0
        let trueColor = serverInit[7] != 0
        let redMax = serverInit.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt16.self) }.bigEndian
        let greenMax = serverInit.withUnsafeBytes { $0.load(fromByteOffset: 10, as: UInt16.self) }.bigEndian
        let blueMax = serverInit.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt16.self) }.bigEndian
        let redShift = serverInit[14]
        let greenShift = serverInit[15]
        let blueShift = serverInit[16]

        pixelFormat = PixelFormat(
            bitsPerPixel: bitsPerPixel,
            depth: depth,
            bigEndian: bigEndian,
            trueColor: trueColor,
            redMax: redMax,
            greenMax: greenMax,
            blueMax: blueMax,
            redShift: redShift,
            greenShift: greenShift,
            blueShift: blueShift
        )

        print("VNC: Framebuffer size: \(framebufferWidth)x\(framebufferHeight)")
        print("VNC: Pixel format: \(bitsPerPixel) bpp, depth \(depth), RGB shifts: \(redShift)/\(greenShift)/\(blueShift)")

        // Initialize framebuffer
        let bytesPerPixel = Int(bitsPerPixel) / 8
        let bufferSize = framebufferWidth * framebufferHeight * bytesPerPixel
        framebufferData = Data(count: bufferSize)

        // Set pixel format to 32-bit RGBA for easier rendering
        try await setPixelFormat()

        // Read name length
        let nameLength = Int(serverInit.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }.bigEndian)

        // Read name
        if nameLength > 0 {
            let nameData = try await receive(count: nameLength)
            let name = String(data: nameData, encoding: .utf8) ?? "Unknown"
            print("VNC: Desktop name: \(name)")
        }
    }

    private func setPixelFormat() async throws {
        // Request 32-bit RGBA format for easier rendering
        var message = Data()
        message.append(0) // SetPixelFormat message type
        message.append(contentsOf: [0, 0, 0]) // Padding

        // Pixel format (16 bytes)
        message.append(32) // bits-per-pixel
        message.append(24) // depth
        message.append(0)  // big-endian-flag
        message.append(1)  // true-color-flag

        // Red max (255)
        message.append(contentsOf: withUnsafeBytes(of: UInt16(255).bigEndian) { Data($0) })
        // Green max (255)
        message.append(contentsOf: withUnsafeBytes(of: UInt16(255).bigEndian) { Data($0) })
        // Blue max (255)
        message.append(contentsOf: withUnsafeBytes(of: UInt16(255).bigEndian) { Data($0) })

        message.append(16) // red-shift
        message.append(8)  // green-shift
        message.append(0)  // blue-shift
        message.append(contentsOf: [0, 0, 0]) // padding

        try await send(message)

        // Update our pixel format
        pixelFormat = PixelFormat(
            bitsPerPixel: 32,
            depth: 24,
            bigEndian: false,
            trueColor: true,
            redMax: 255,
            greenMax: 255,
            blueMax: 255,
            redShift: 16,
            greenShift: 8,
            blueShift: 0
        )
    }

    private func requestFramebufferUpdate(incremental: Bool = false) async throws {
        // FramebufferUpdateRequest message
        var message = Data()
        message.append(3) // Message type
        message.append(incremental ? 1 : 0) // Incremental flag (0 = full update, 1 = incremental)

        // X, Y position (UInt16)
        message.append(contentsOf: withUnsafeBytes(of: UInt16(0).bigEndian) { Data($0) })
        message.append(contentsOf: withUnsafeBytes(of: UInt16(0).bigEndian) { Data($0) })

        // Width, Height (UInt16)
        message.append(contentsOf: withUnsafeBytes(of: UInt16(framebufferWidth).bigEndian) { Data($0) })
        message.append(contentsOf: withUnsafeBytes(of: UInt16(framebufferHeight).bigEndian) { Data($0) })

        try await send(message)
    }

    private func sendQueuedInputEvents() async throws {
        // Get all queued events
        let eventsToSend = inputEventQueue.dequeueAll()

        // Send them all
        if !eventsToSend.isEmpty {
            print("VNC: Sending \(eventsToSend.count) queued input event(s)")
            for (index, event) in eventsToSend.enumerated() {
                // Log event details
                if event.count >= 1 {
                    let messageType = event[0]
                    if messageType == 5, event.count >= 8 { // Key event
                        let down = event[1] != 0
                        let keysym = event.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }.bigEndian
                        print("VNC:   Event \(index+1): KeyEvent down=\(down) keysym=0x\(String(keysym, radix: 16))")
                    } else if messageType == 4, event.count >= 6 { // Mouse event
                        let buttonMask = event[1]
                        let x = event.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) }.bigEndian
                        let y = event.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }.bigEndian
                        print("VNC:   Event \(index+1): MouseEvent x=\(x) y=\(y) buttons=\(buttonMask)")
                    }
                }
                try await send(event)
            }
            print("VNC: All queued events sent successfully")
        }
    }

    private func receiveServerMessages() async throws {
        // Main update loop
        var isFirstUpdate = true
        var updateCount = 0

        while isConnected {
            // Send any queued input events FIRST, before requesting update
            // This ensures we don't send input while waiting for a framebuffer update
            try await sendQueuedInputEvents()

            // ALWAYS request full updates (never incremental)
            // This ensures the server always responds, even when screen hasn't changed
            // bhyve VNC server blocks on incremental updates when nothing changes
            print("VNC: Requesting full update #\(updateCount)...")
            try await requestFramebufferUpdate(incremental: false)
            pendingUpdateRequest = true

            // Wait for response from server
            do {
                let messageData = try await receive(count: 1)

                let messageType = messageData[0]

                pendingUpdateRequest = false

                switch messageType {
                case 0: // FramebufferUpdate
                    try await handleFramebufferUpdate()
                    updateCount += 1
                default:
                    print("VNC: Unknown message type: \(messageType)")
                    // Skip unknown message by reading padding
                    _ = try? await receive(count: 3)
                }
            } catch {
                // If receive fails, log it but don't crash - just retry
                print("VNC: Receive error (will retry): \(error)")
                pendingUpdateRequest = false
                // Longer delay on error to avoid tight loop
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                continue
            }

            // Small delay before next cycle to avoid hammering the server
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
    }


    private func handleFramebufferUpdate() async throws {
        // Read padding byte
        _ = try await receive(count: 1)

        // Read number of rectangles
        let countData = try await receive(count: 2)
        let rectangleCount = Int(countData.withUnsafeBytes { $0.load(as: UInt16.self) }.bigEndian)

        print("VNC: Receiving \(rectangleCount) rectangles")

        for i in 0..<rectangleCount {
            // Read rectangle header (12 bytes)
            let header = try await receive(count: 12)

            let x = Int(header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt16.self) }.bigEndian)
            let y = Int(header.withUnsafeBytes { $0.load(fromByteOffset: 2, as: UInt16.self) }.bigEndian)
            let width = Int(header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt16.self) }.bigEndian)
            let height = Int(header.withUnsafeBytes { $0.load(fromByteOffset: 6, as: UInt16.self) }.bigEndian)
            let encoding = header.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Int32.self) }.bigEndian

            print("VNC: Rectangle \(i+1)/\(rectangleCount) at (\(x),\(y)) size \(width)x\(height) encoding \(encoding)")

            // Handle Raw encoding (0)
            if encoding == 0 {
                let bytesPerPixel = 4 // 32-bit RGBA
                let pixelDataSize = width * height * bytesPerPixel
                print("VNC: Reading \(pixelDataSize) bytes of pixel data...")
                let pixelData = try await receive(count: pixelDataSize)
                print("VNC: Received pixel data, updating framebuffer...")

                // Update framebuffer with received pixel data
                updateFramebuffer(x: x, y: y, width: width, height: height, pixelData: pixelData)
            } else {
                print("VNC: Unsupported encoding: \(encoding)")
                // Skip this rectangle - we don't know how much data to read
                throw NSError(domain: "VNC", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported encoding: \(encoding)"])
            }
        }

        print("VNC: All rectangles processed, updating display...")
        // Convert framebuffer to NSImage and update display
        await MainActor.run {
            self.currentFrame = createImageFromFramebuffer()
        }
    }

    private func updateFramebuffer(x: Int, y: Int, width: Int, height: Int, pixelData: Data) {
        guard var framebuffer = framebufferData else { return }

        let bytesPerPixel = 4
        let rowBytes = framebufferWidth * bytesPerPixel

        // Copy pixel data row by row into framebuffer
        for row in 0..<height {
            let srcOffset = row * width * bytesPerPixel
            let dstOffset = (y + row) * rowBytes + x * bytesPerPixel
            let rowSize = width * bytesPerPixel

            // Ensure we don't write past the buffer bounds
            if dstOffset + rowSize <= framebuffer.count && srcOffset + rowSize <= pixelData.count {
                framebuffer.replaceSubrange(dstOffset..<(dstOffset + rowSize),
                                           with: pixelData[srcOffset..<(srcOffset + rowSize)])
            }
        }

        framebufferData = framebuffer
    }

    private func createImageFromFramebuffer() -> NSImage? {
        guard let framebuffer = framebufferData else { return nil }
        guard framebufferWidth > 0 && framebufferHeight > 0 else { return nil }

        let bytesPerPixel = 4
        let rowBytes = framebufferWidth * bytesPerPixel

        // Convert BGRA to RGBA (VNC sends in big-endian format)
        var rgbaData = Data(count: framebuffer.count)
        rgbaData.withUnsafeMutableBytes { rgbaPtr in
            framebuffer.withUnsafeBytes { bgraPtr in
                guard let rgbaBase = rgbaPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let bgraBase = bgraPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }

                // Convert from BGRA (what VNC sends) to RGBA (what NSBitmapImageRep expects)
                for i in stride(from: 0, to: framebuffer.count, by: 4) {
                    rgbaBase[i + 0] = bgraBase[i + 2]  // R = B
                    rgbaBase[i + 1] = bgraBase[i + 1]  // G = G
                    rgbaBase[i + 2] = bgraBase[i + 0]  // B = R
                    rgbaBase[i + 3] = 255              // A = 255 (opaque)
                }
            }
        }

        // Create bitmap image rep from converted data
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: framebufferWidth,
            pixelsHigh: framebufferHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: rowBytes,
            bitsPerPixel: 32
        ) else {
            print("VNC: Failed to create bitmap representation")
            return nil
        }

        // Copy converted RGBA data to bitmap
        rgbaData.withUnsafeBytes { bufferPtr in
            if let baseAddress = bufferPtr.baseAddress,
               let bitmapData = bitmapRep.bitmapData {
                memcpy(bitmapData, baseAddress, rgbaData.count)
            }
        }

        // Create NSImage from bitmap representation
        let image = NSImage(size: NSSize(width: framebufferWidth, height: framebufferHeight))
        image.addRepresentation(bitmapRep)

        return image
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection?.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receive(count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection?.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error = error {
                    print("VNC: Receive error: \(error)")
                    continuation.resume(throwing: error)
                } else if let data = data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    print("VNC: Connection closed by server")
                    continuation.resume(throwing: NSError(domain: "VNC", code: -2, userInfo: [NSLocalizedDescriptionKey: "Connection closed"]))
                } else {
                    // No data yet, but connection still open - this shouldn't normally happen
                    // but if it does, treat it as a temporary error
                    print("VNC: No data received (connection still open)")
                    continuation.resume(throwing: NSError(domain: "VNC", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"]))
                }
            }
        }
    }
}
