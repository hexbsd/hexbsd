//
//  PoudriereView.swift
//  HexBSD
//
//  Poudriere build status viewer
//

import SwiftUI
import WebKit

// MARK: - Poudriere Models

struct PoudriereInfo: Equatable {
    let isInstalled: Bool
    let htmlPath: String
    let dataPath: String
    let configPath: String?
    let runningBuilds: [String]
}

// MARK: - Custom URL Scheme Handler for SSH Assets

class PoudriereSchemeHandler: NSObject, WKURLSchemeHandler {
    let basePath: String
    let sshManager: SSHConnectionManager
    let dataPath: String

    init(basePath: String, sshManager: SSHConnectionManager, dataPath: String = "") {
        self.basePath = basePath
        self.sshManager = sshManager
        self.dataPath = dataPath
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            print("DEBUG: Poudriere scheme handler - URL is nil")
            urlSchemeTask.didFailWithError(NSError(domain: "PoudriereSchemeHandler", code: 1, userInfo: nil))
            return
        }

        // Convert poudriere:// URL to file path
        // For poudriere://assets/logo.svg, url.host is "assets" and url.path is "/logo.svg"
        // We need to combine them
        var path = ""
        if let host = url.host, !host.isEmpty {
            path = host
        }

        if !url.path.isEmpty && url.path != "/" {
            if !path.isEmpty {
                path += url.path
            } else {
                path = url.path
            }
        }

        // Remove leading slash if present
        if path.hasPrefix("/") {
            path = String(path.dropFirst())
        }

        // Check for empty path - this might be the root request
        if path.isEmpty {
            print("DEBUG: Poudriere scheme handler - Empty path for URL: \(url.absoluteString)")
            // Return a simple response for empty path
            Task {
                await MainActor.run {
                    let emptyData = Data()
                    let response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil)
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(emptyData)
                    urlSchemeTask.didFinish()
                }
            }
            return
        }

        // Build full path - determine which base to use
        // - data/ files come from POUDRIERE_DATA/logs/bulk/ (strip the data/ prefix)
        // - assets/ files come from HTML template directory (basePath = htmlPath from config)
        let fullPath: String
        if path.hasPrefix("data/") && !dataPath.isEmpty {
            // Data files are in the poudriere data directory
            // dataPath is POUDRIERE_DATA, need to append /logs/bulk
            // Strip "data/" prefix since files are directly in bulk/, not in bulk/data/
            let dataFilePath = String(path.dropFirst(5)) // Remove "data/"
            let dataBasePath = dataPath.hasSuffix("/") ? "\(dataPath)logs/bulk" : "\(dataPath)/logs/bulk"
            if dataBasePath.hasSuffix("/") {
                fullPath = dataBasePath + dataFilePath
            } else {
                fullPath = dataBasePath + "/" + dataFilePath
            }
            print("DEBUG: Data file - POUDRIERE_DATA=\(dataPath), bulk=\(dataBasePath), file=\(dataFilePath)")
        } else {
            // Assets are in the HTML template directory
            // basePath is already the full path to the HTML directory (includes logs/bulk for custom configs)
            if basePath.hasSuffix("/") {
                fullPath = basePath + path
            } else {
                fullPath = basePath + "/" + path
            }
            print("DEBUG: Asset file - basePath=\(basePath), file=\(path)")
        }

        print("DEBUG: Poudriere loading asset - URL: \(url.absoluteString), Host: \(url.host ?? "nil"), URLPath: \(url.path), CombinedPath: \(path), FullPath: \(fullPath)")

        Task {
            do {
                // For binary files (images, fonts), use base64 encoding
                let ext = (fullPath as NSString).pathExtension.lowercased()
                let isBinary = ["png", "jpg", "jpeg", "gif", "ico", "woff", "woff2", "ttf", "eot", "otf"].contains(ext)

                // First check if file exists
                let checkCommand = "test -f '\(fullPath)' && echo 'exists' || echo 'missing'"
                let checkResult = try await self.sshManager.executeCommand(checkCommand)
                print("DEBUG: File existence check for \(fullPath): \(checkResult.trimmingCharacters(in: .whitespacesAndNewlines))")

                if checkResult.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
                    print("DEBUG: File does not exist: \(fullPath)")

                    // For JSON data files that don't exist, return empty data structure
                    // This prevents poudriere.js from erroring when no builds exist
                    if fullPath.hasSuffix(".json") {
                        print("DEBUG: Returning empty JSON for missing data file")
                        let emptyJSON = "{}"
                        let data = emptyJSON.data(using: .utf8) ?? Data()

                        await MainActor.run {
                            let response = URLResponse(
                                url: url,
                                mimeType: "application/json",
                                expectedContentLength: data.count,
                                textEncodingName: "utf-8"
                            )
                            urlSchemeTask.didReceive(response)
                            urlSchemeTask.didReceive(data)
                            urlSchemeTask.didFinish()
                        }
                        return
                    }

                    throw NSError(domain: "PoudriereSchemeHandler", code: 404, userInfo: [NSLocalizedDescriptionKey: "File not found: \(fullPath)"])
                }

                let data: Data
                if isBinary {
                    // Read as base64 and decode
                    let command = "base64 '\(fullPath)'"
                    print("DEBUG: Reading binary file with: \(command)")
                    let base64Content = try await self.sshManager.executeCommand(command)
                    print("DEBUG: Got base64 content, length: \(base64Content.count)")
                    // Remove ALL newlines (base64 command wraps at 76 chars per line)
                    let cleanedBase64 = base64Content.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
                    print("DEBUG: Cleaned base64 length: \(cleanedBase64.count)")
                    data = Data(base64Encoded: cleanedBase64) ?? Data()
                    print("DEBUG: Decoded to \(data.count) bytes")
                } else {
                    // Read as text
                    let command = "cat '\(fullPath)'"
                    print("DEBUG: Reading text file with: \(command)")
                    let content = try await self.sshManager.executeCommand(command)
                    print("DEBUG: Got text content, length: \(content.count)")
                    data = content.data(using: .utf8) ?? Data()
                    print("DEBUG: Converted to \(data.count) bytes")
                }

                // Determine MIME type
                let mimeType = self.mimeType(for: fullPath)

                await MainActor.run {
                    let response = URLResponse(
                        url: url,
                        mimeType: mimeType,
                        expectedContentLength: data.count,
                        textEncodingName: nil
                    )
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                }
            } catch {
                print("DEBUG: Failed to load asset \(fullPath): \(error)")
                await MainActor.run {
                    urlSchemeTask.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Task stopped
    }

    private func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "eot": return "application/vnd.ms-fontobject"
        case "otf": return "font/otf"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - WebView for HTML rendering

struct WebView: NSViewRepresentable {
    let htmlContent: String
    let basePath: String
    let dataPath: String
    let sshManager: SSHConnectionManager

    func makeCoordinator() -> Coordinator {
        Coordinator(basePath: basePath, dataPath: dataPath, sshManager: sshManager)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Register custom scheme handler for loading assets via SSH
        config.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: "poudriere")

        // Add console message handler
        config.userContentController.add(context.coordinator, name: "consoleLog")

        let webView = WKWebView(frame: .zero, configuration: config)

        // Set white background for light mode HTML content
        webView.setValue(true, forKey: "drawsBackground")

        // Inject console.log capture
        let consoleScript = """
        (function() {
            var oldLog = console.log;
            var oldError = console.error;
            var oldWarn = console.warn;

            console.log = function() {
                window.webkit.messageHandlers.consoleLog.postMessage({type: 'log', message: Array.from(arguments).join(' ')});
                oldLog.apply(console, arguments);
            };
            console.error = function() {
                window.webkit.messageHandlers.consoleLog.postMessage({type: 'error', message: Array.from(arguments).join(' ')});
                oldError.apply(console, arguments);
            };
            console.warn = function() {
                window.webkit.messageHandlers.consoleLog.postMessage({type: 'warn', message: Array.from(arguments).join(' ')});
                oldWarn.apply(console, arguments);
            };
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        // Inject CSS to ensure white background
        let css = "body { background-color: white !important; }"
        let styleScript = WKUserScript(source: "var style = document.createElement('style'); style.innerHTML = '\(css)'; document.head.appendChild(style);", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(styleScript)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Modify HTML to use poudriere:// scheme for relative URLs only
        var modifiedHTML = htmlContent

        // Use regex to replace only relative URLs (not http:// or https://)
        let patterns = [
            ("src=\"(?!http://|https://|poudriere://)", "src=\"poudriere://"),
            ("href=\"(?!http://|https://|poudriere://|#)", "href=\"poudriere://"),
            ("src='(?!http://|https://|poudriere://)", "src='poudriere://"),
            ("href='(?!http://|https://|poudriere://|#)", "href='poudriere://")
        ]

        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(modifiedHTML.startIndex..., in: modifiedHTML)
                modifiedHTML = regex.stringByReplacingMatches(
                    in: modifiedHTML,
                    options: [],
                    range: range,
                    withTemplate: replacement
                )
            }
        }

        print("DEBUG: BasePath: \(basePath)")
        print("DEBUG: Modified HTML preview: \(String(modifiedHTML.prefix(500)))")

        // Set baseURL to poudriere:// so JavaScript can make relative requests
        let baseURL = URL(string: "poudriere:///")
        webView.loadHTMLString(modifiedHTML, baseURL: baseURL)
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        let schemeHandler: PoudriereSchemeHandler

        init(basePath: String, dataPath: String, sshManager: SSHConnectionManager) {
            self.schemeHandler = PoudriereSchemeHandler(basePath: basePath, sshManager: sshManager, dataPath: dataPath)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "consoleLog", let body = message.body as? [String: Any] {
                let type = body["type"] as? String ?? "log"
                let msg = body["message"] as? String ?? ""
                print("JS [\(type.uppercased())]: \(msg)")
            }
        }
    }
}

// MARK: - Poudriere Content View

struct PoudriereContentView: View {
    @StateObject private var viewModel = PoudriereViewModel()
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                if viewModel.isInstalled {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Poudriere installed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !viewModel.runningBuilds.isEmpty {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: "hammer.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("\(viewModel.runningBuilds.count) build\(viewModel.runningBuilds.count == 1 ? "" : "s") running")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let configPath = viewModel.configPath {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Config: \(configPath)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text("Poudriere not found")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if viewModel.isInstalled {
                    Button(action: {
                        Task {
                            await viewModel.refresh()
                        }
                    }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding()

            Divider()

            // Content area
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading Poudriere...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.isInstalled {
                ScrollView {
                    VStack(spacing: 20) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 72))
                            .foregroundColor(.secondary)
                        Text("Poudriere Not Installed")
                            .font(.title)
                            .foregroundColor(.secondary)
                        Text("Poudriere is a bulk package builder for FreeBSD")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 10)

                        // Requirements status
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Requirements")
                                .font(.headline)

                            // Poudriere package status
                            HStack(spacing: 8) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text("Poudriere")
                                    .fontWeight(.medium)
                                Text("Not installed")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                        .frame(maxWidth: 400, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)

                        // Package selection
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Package")
                                .font(.headline)

                            Picker("Package", selection: $viewModel.selectedPackage) {
                                Text("poudriere").tag("poudriere")
                                Text("poudriere-devel").tag("poudriere-devel")
                            }
                            .pickerStyle(.radioGroup)

                            Text(viewModel.selectedPackage == "poudriere-devel"
                                 ? "Development version with latest features"
                                 : "Stable release version")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: 400, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)

                        // Setup button
                        Button(action: {
                            Task {
                                await viewModel.setupPoudriere()
                            }
                        }) {
                            Label("Install \(viewModel.selectedPackage)", systemImage: "gear")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Text("This will install the selected poudriere package")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let htmlContent = viewModel.htmlContent, !htmlContent.isEmpty {
                // Display HTML in WebView
                WebView(
                    htmlContent: htmlContent,
                    basePath: viewModel.htmlPath,
                    dataPath: viewModel.dataPath,
                    sshManager: SSHConnectionManager.shared
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    print("DEBUG: WebView using paths:")
                    print("  - HTML/Assets: \(viewModel.htmlPath)")
                    print("  - Data: \(viewModel.dataPath)")
                    if let config = viewModel.configPath {
                        print("  - Config: \(config)")
                    }
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Build Status Available")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("HTML Path: \(viewModel.htmlPath)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Poudriere Error", isPresented: $showError) {
            Button("OK") {
                showError = false
            }
        } message: {
            Text(viewModel.error ?? "Unknown error")
        }
        .sheet(isPresented: $viewModel.isSettingUp) {
            PoudriereSetupProgressSheet(step: viewModel.setupStep)
        }
        .onChange(of: viewModel.error) { oldValue, newValue in
            if newValue != nil {
                showError = true
            }
        }
        .onAppear {
            Task {
                await viewModel.loadPoudriere()
            }
        }
    }
}

// MARK: - View Model

@MainActor
class PoudriereViewModel: ObservableObject {
    @Published var isInstalled = false
    @Published var htmlPath = ""
    @Published var dataPath = ""
    @Published var configPath: String?
    @Published var runningBuilds: [String] = []
    @Published var htmlContent: String?
    @Published var isLoading = false
    @Published var error: String?

    // Setup state
    @Published var isSettingUp = false
    @Published var setupStep = ""
    @Published var selectedPackage = "poudriere"

    private let sshManager = SSHConnectionManager.shared

    func loadPoudriere() async {
        isLoading = true
        error = nil

        do {
            let info = try await sshManager.checkPoudriere()
            isInstalled = info.isInstalled
            htmlPath = info.htmlPath
            dataPath = info.dataPath
            configPath = info.configPath
            runningBuilds = info.runningBuilds

            if isInstalled && !htmlPath.isEmpty {
                // Try to load the index.html
                htmlContent = try await sshManager.loadPoudriereHTML(path: "\(htmlPath)/index.html")
            }
        } catch {
            self.error = "Failed to load Poudriere: \(error.localizedDescription)"
            isInstalled = false
        }

        isLoading = false
    }

    func refresh() async {
        await loadPoudriere()
    }

    func setupPoudriere() async {
        isSettingUp = true
        error = nil

        do {
            setupStep = "Installing \(selectedPackage)..."
            _ = try await sshManager.executeCommand("pkg install -y \(selectedPackage)")
            isInstalled = true

            setupStep = "Setup complete!"

            // Reload poudriere data
            await loadPoudriere()

        } catch {
            self.error = "Setup failed: \(error.localizedDescription)"
        }

        isSettingUp = false
        setupStep = ""
    }
}

// MARK: - Poudriere Setup Progress Sheet

struct PoudriereSetupProgressSheet: View {
    let step: String

    var body: some View {
        VStack(spacing: 20) {
            Text("Setting Up Poudriere")
                .font(.title2)
                .bold()

            ProgressView()
                .scaleEffect(1.5)
                .padding()

            Text(step)
                .font(.body)
                .foregroundColor(.secondary)
                .frame(minWidth: 300)
                .multilineTextAlignment(.center)

            Text("Please wait...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(40)
        .frame(minWidth: 400)
        .interactiveDismissDisabled()
    }
}
