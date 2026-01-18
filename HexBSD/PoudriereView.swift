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
    let hasBuilds: Bool
}

/// Represents a poudriere jail for building packages
struct PoudriereJail: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let version: String
    let arch: String
    let method: String  // git, http, ftp, etc.
    let timestamp: String
    let path: String

    var displayName: String {
        "\(name) (\(version)-\(arch))"
    }
}

/// Represents a poudriere ports tree
struct PoudrierePortsTree: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let method: String  // git, null, svn, etc.
    let timestamp: String
    let path: String
}

/// Configuration for poudriere.conf
struct PoudriereConfig: Equatable {
    var zpool: String
    var basefs: String
    var poudriereData: String
    var distfilesCache: String
    var freebsdHost: String
    var usePortlint: Bool
    var useTmpfs: String  // "all", "yes", "no", "wrkdir", "data", "localbase"
    var makeJobs: Int
    var allowMakeJobsPackages: String
    var noZfs: Bool  // Set to true for UFS systems without ZFS

    static var `default`: PoudriereConfig {
        PoudriereConfig(
            zpool: "zroot",
            basefs: "/usr/local/poudriere",
            poudriereData: "${BASEFS}/data",
            distfilesCache: "/usr/ports/distfiles",
            freebsdHost: "https://download.FreeBSD.org",
            usePortlint: false,
            useTmpfs: "yes",
            makeJobs: 4,
            allowMakeJobsPackages: "pkg ccache rust*",
            noZfs: false
        )
    }
}

/// Options for creating a new jail
struct CreateJailOptions {
    var name: String = ""
    var version: String = "14.2-RELEASE"
    var arch: String = "amd64"
    var method: JailMethod = .http
    var useCustomVersion: Bool = false
    var useCustomArch: Bool = false
    var customVersion: String = ""
    var customArch: String = ""

    enum JailMethod: String, CaseIterable {
        case http = "http"
        case ftp = "ftp"
        case git = "git"
        case svn = "svn"
        case url = "url"
        case tar = "tar"

        var displayName: String {
            switch self {
            case .http: return "HTTP (download.FreeBSD.org)"
            case .ftp: return "FTP"
            case .git: return "Git (FreeBSD source)"
            case .svn: return "SVN (deprecated)"
            case .url: return "Custom URL"
            case .tar: return "Tarball"
            }
        }
    }

    /// The effective version to use (custom or selected)
    var effectiveVersion: String {
        useCustomVersion ? customVersion : version
    }

    /// The effective architecture to use (custom or selected)
    var effectiveArch: String {
        useCustomArch ? customArch : arch
    }
}

/// Options for creating a new ports tree
struct CreatePortsTreeOptions {
    var name: String = ""
    var method: PortsTreeMethod = .gitHttps
    var branch: String = "main"
    var useCustomBranch: Bool = false
    var customBranch: String = ""
    var useCustomUrl: Bool = false
    var customUrl: String = ""

    enum PortsTreeMethod: String, CaseIterable {
        case gitHttps = "git+https"
        case gitHttpsFull = "git+https+full"
        case gitHttpsShallow = "git+https+shallow"
        case null = "null"

        var displayName: String {
            switch self {
            case .gitHttps: return "Git HTTPS (default depth)"
            case .gitHttpsFull: return "Git HTTPS (full clone)"
            case .gitHttpsShallow: return "Git HTTPS (shallow clone)"
            case .null: return "Null (use existing /usr/ports)"
            }
        }

        var description: String {
            switch self {
            case .gitHttps: return "Standard git clone via HTTPS with reasonable history"
            case .gitHttpsFull: return "Full clone via HTTPS with complete history"
            case .gitHttpsShallow: return "Shallow clone via HTTPS, fastest but limited history"
            case .null: return "Use an existing ports tree at /usr/ports"
            }
        }

        var usesGit: Bool {
            switch self {
            case .gitHttps, .gitHttpsFull, .gitHttpsShallow: return true
            case .null: return false
            }
        }
    }

    static var availableBranches: [String] {
        ["main", "2024Q4", "2024Q3", "2024Q2", "2024Q1"]
    }

    /// The effective branch to use (custom or selected)
    var effectiveBranch: String {
        useCustomBranch ? customBranch : branch
    }

    /// The effective URL to use (custom or default FreeBSD)
    var effectiveUrl: String? {
        useCustomUrl && !customUrl.isEmpty ? customUrl : nil
    }
}

/// Options for starting a bulk build
struct BulkBuildOptions {
    var jail: PoudriereJail?
    var portsTree: PoudrierePortsTree?
    var buildAll: Bool = false
    var packageListFile: String = ""
    var packagesText: String = ""  // Space-separated list of packages
    var cleanBuild: Bool = false
    var testBuild: Bool = false

    /// Packages parsed from the text field
    var packages: [String] {
        packagesText.split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var isValid: Bool {
        guard jail != nil, portsTree != nil else { return false }
        return buildAll || !packageListFile.isEmpty || !packages.isEmpty
    }
}

/// Represents a package that can be built
struct BuildablePackage: Identifiable, Equatable, Hashable {
    let id: String
    let origin: String      // e.g., "www/nginx"
    let name: String        // e.g., "nginx"
    let category: String    // e.g., "www"
    let comment: String

    init(origin: String, comment: String = "") {
        self.id = origin
        self.origin = origin
        let parts = origin.split(separator: "/")
        self.category = parts.first.map(String.init) ?? ""
        self.name = parts.last.map(String.init) ?? origin
        self.comment = comment
    }
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
        // - logs/ files (without data/ prefix) also come from POUDRIERE_DATA/logs/bulk/
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
                let mimeType: String

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
                    mimeType = self.mimeType(for: fullPath)
                } else {
                    // Read as text
                    let command = "cat '\(fullPath)'"
                    print("DEBUG: Reading text file with: \(command)")
                    let content = try await self.sshManager.executeCommand(command)
                    print("DEBUG: Got text content, length: \(content.count)")

                    // Check if this is a log file - wrap in HTML for better display
                    let fileExt = (fullPath as NSString).pathExtension.lowercased()
                    if fileExt == "log" || fileExt == "txt" {
                        // Extract filename for save dialog
                        let filename = (fullPath as NSString).lastPathComponent
                        // Escape content for JSON embedding (for save functionality)
                        let jsonEscapedContent = content
                            .replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
                            .replacingOccurrences(of: "\n", with: "\\n")
                            .replacingOccurrences(of: "\r", with: "\\r")
                            .replacingOccurrences(of: "\t", with: "\\t")
                        // Wrap plain text in HTML for better viewing
                        let escapedContent = content
                            .replacingOccurrences(of: "&", with: "&amp;")
                            .replacingOccurrences(of: "<", with: "&lt;")
                            .replacingOccurrences(of: ">", with: "&gt;")
                        let htmlWrapped = """
                        <!DOCTYPE html>
                        <html>
                        <head>
                            <meta charset="utf-8">
                            <style>
                                * { box-sizing: border-box; }
                                body {
                                    background-color: #ffffff;
                                    color: #1a1a1a;
                                    font-family: 'Menlo', 'Monaco', 'Courier New', monospace;
                                    font-size: 12px;
                                    padding: 0;
                                    margin: 0;
                                }
                                #search-bar {
                                    position: sticky;
                                    top: 0;
                                    background: #f0f0f0;
                                    padding: 8px 10px;
                                    border-bottom: 1px solid #ccc;
                                    display: flex;
                                    gap: 8px;
                                    align-items: center;
                                    z-index: 100;
                                }
                                #search-input {
                                    flex: 1;
                                    max-width: 300px;
                                    padding: 4px 8px;
                                    border: 1px solid #999;
                                    border-radius: 4px;
                                    font-size: 12px;
                                }
                                #search-bar button {
                                    padding: 4px 10px;
                                    border: 1px solid #999;
                                    border-radius: 4px;
                                    background: #fff;
                                    cursor: pointer;
                                    font-size: 12px;
                                }
                                #search-bar button:hover { background: #e0e0e0; }
                                #save-btn { margin-left: auto; }
                                #search-info {
                                    font-size: 11px;
                                    color: #666;
                                    margin-left: 8px;
                                }
                                #log-content {
                                    padding: 10px;
                                    white-space: pre-wrap;
                                    word-wrap: break-word;
                                }
                                .highlight {
                                    background-color: #ffeb3b;
                                    color: #000;
                                }
                                .highlight-current {
                                    background-color: #ff9800;
                                    color: #000;
                                }
                            </style>
                        </head>
                        <body>
                            <div id="search-bar">
                                <input type="text" id="search-input" placeholder="Search log... (Cmd+F)" />
                                <button onclick="findPrev()">Prev</button>
                                <button onclick="findNext()">Next</button>
                                <span id="search-info"></span>
                                <button id="save-btn" onclick="saveLog()">Save</button>
                            </div>
                            <div id="log-content">\(escapedContent)</div>
                            <script>
                                let matches = [];
                                let currentIndex = -1;
                                const content = document.getElementById('log-content');
                                const input = document.getElementById('search-input');
                                const info = document.getElementById('search-info');
                                const originalText = content.textContent;
                                const logFilename = "\(filename)";
                                const logContent = "\(jsonEscapedContent)";

                                function saveLog() {
                                    window.webkit.messageHandlers.saveLog.postMessage({
                                        filename: logFilename,
                                        content: logContent
                                    });
                                }

                                function escapeRegex(s) {
                                    return s.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
                                }

                                function doSearch() {
                                    const query = input.value.trim();
                                    matches = [];
                                    currentIndex = -1;

                                    if (!query) {
                                        content.innerHTML = originalText.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
                                        info.textContent = '';
                                        return;
                                    }

                                    const regex = new RegExp(escapeRegex(query), 'gi');
                                    let match;
                                    let lastIndex = 0;
                                    let html = '';
                                    let matchId = 0;

                                    while ((match = regex.exec(originalText)) !== null) {
                                        const before = originalText.substring(lastIndex, match.index);
                                        html += before.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
                                        html += '<span class="highlight" id="match-' + matchId + '">' +
                                                match[0].replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;') + '</span>';
                                        matches.push('match-' + matchId);
                                        matchId++;
                                        lastIndex = regex.lastIndex;
                                    }
                                    html += originalText.substring(lastIndex).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
                                    content.innerHTML = html;

                                    if (matches.length > 0) {
                                        currentIndex = 0;
                                        highlightCurrent();
                                    }
                                    updateInfo();
                                }

                                function highlightCurrent() {
                                    document.querySelectorAll('.highlight-current').forEach(el => {
                                        el.classList.remove('highlight-current');
                                        el.classList.add('highlight');
                                    });
                                    if (currentIndex >= 0 && currentIndex < matches.length) {
                                        const el = document.getElementById(matches[currentIndex]);
                                        if (el) {
                                            el.classList.remove('highlight');
                                            el.classList.add('highlight-current');
                                            el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                                        }
                                    }
                                }

                                function updateInfo() {
                                    if (matches.length === 0) {
                                        info.textContent = input.value.trim() ? 'No matches' : '';
                                    } else {
                                        info.textContent = (currentIndex + 1) + ' of ' + matches.length;
                                    }
                                }

                                function findNext() {
                                    if (matches.length === 0) return;
                                    currentIndex = (currentIndex + 1) % matches.length;
                                    highlightCurrent();
                                    updateInfo();
                                }

                                function findPrev() {
                                    if (matches.length === 0) return;
                                    currentIndex = (currentIndex - 1 + matches.length) % matches.length;
                                    highlightCurrent();
                                    updateInfo();
                                }

                                input.addEventListener('input', doSearch);
                                input.addEventListener('keydown', function(e) {
                                    if (e.key === 'Enter') {
                                        if (e.shiftKey) findPrev();
                                        else findNext();
                                        e.preventDefault();
                                    }
                                });

                                document.addEventListener('keydown', function(e) {
                                    if ((e.metaKey || e.ctrlKey) && e.key === 'f') {
                                        e.preventDefault();
                                        input.focus();
                                        input.select();
                                    }
                                    if ((e.metaKey || e.ctrlKey) && e.key === 's') {
                                        e.preventDefault();
                                        saveLog();
                                    }
                                });
                            </script>
                        </body>
                        </html>
                        """
                        data = htmlWrapped.data(using: .utf8) ?? Data()
                        mimeType = "text/html"
                        print("DEBUG: Wrapped log in HTML, size: \(data.count) bytes")
                    } else {
                        data = content.data(using: .utf8) ?? Data()
                        mimeType = self.mimeType(for: fullPath)
                    }
                    print("DEBUG: Converted to \(data.count) bytes")
                }

                await MainActor.run {
                    // Use HTTPURLResponse with no-cache headers to ensure fresh data
                    let headers = [
                        "Cache-Control": "no-cache, no-store, must-revalidate",
                        "Pragma": "no-cache",
                        "Expires": "0",
                        "Content-Type": mimeType
                    ]
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: headers
                    )!
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
        case "log", "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - WebView Navigation State

class WebViewNavigationState: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isAtHome = true
    weak var webView: WKWebView?
    var homeHTML: String?
    var onGoHome: (() -> Void)?

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func goHome() {
        // Reload the original HTML content
        if let html = homeHTML {
            let baseURL = URL(string: "poudriere:///")
            webView?.loadHTMLString(html, baseURL: baseURL)
        }
        onGoHome?()
    }

    func updateState() {
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
        // Check if we're at home (the initial HTML string loaded page has no real URL path)
        if let currentURL = webView?.url {
            // When loaded via loadHTMLString with baseURL poudriere:///, the URL is about:blank or poudriere:///
            let path = currentURL.path
            isAtHome = currentURL.scheme == "about" || path == "/" || path.isEmpty
        } else {
            isAtHome = true
        }
    }
}

// MARK: - WebView Container with Navigation

struct WebViewContainer: View {
    let htmlContent: String
    let basePath: String
    let dataPath: String
    let sshManager: SSHConnectionManager
    @StateObject private var navigationState = WebViewNavigationState()
    @State private var modifiedHTMLForHome: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Navigation toolbar
            HStack {
                Button(action: { navigationState.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(!navigationState.canGoBack)
                .help("Go Back")

                Button(action: { navigationState.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(!navigationState.canGoForward)
                .help("Go Forward")

                Button(action: { navigationState.goHome() }) {
                    Image(systemName: "house")
                }
                .buttonStyle(.borderless)
                .disabled(navigationState.isAtHome)
                .help("Go Home")

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            WebView(
                htmlContent: htmlContent,
                basePath: basePath,
                dataPath: dataPath,
                sshManager: sshManager,
                navigationState: navigationState
            )
        }
        .onAppear {
            // Generate modified HTML for home button
            modifiedHTMLForHome = modifyHTMLForPoudriereScheme(htmlContent)
            navigationState.homeHTML = modifiedHTMLForHome
        }
        .onChange(of: htmlContent) { _, newValue in
            modifiedHTMLForHome = modifyHTMLForPoudriereScheme(newValue)
            navigationState.homeHTML = modifiedHTMLForHome
        }
    }

    private func modifyHTMLForPoudriereScheme(_ html: String) -> String {
        var modifiedHTML = html
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
        return modifiedHTML
    }
}

// MARK: - WebView for HTML rendering

struct WebView: NSViewRepresentable {
    let htmlContent: String
    let basePath: String
    let dataPath: String
    let sshManager: SSHConnectionManager
    let navigationState: WebViewNavigationState

    func makeCoordinator() -> Coordinator {
        Coordinator(basePath: basePath, dataPath: dataPath, sshManager: sshManager, navigationState: navigationState)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Register custom scheme handler for loading assets via SSH
        config.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: "poudriere")

        // Add console message handler
        config.userContentController.add(context.coordinator, name: "consoleLog")

        // Add save log message handler
        config.userContentController.add(context.coordinator, name: "saveLog")

        // Configure preferences for better iframe/subframe handling
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)

        // Set navigation delegate to allow navigation within poudriere scheme
        webView.navigationDelegate = context.coordinator

        // Set UI delegate to handle new window requests (convert to same-window navigation)
        webView.uiDelegate = context.coordinator

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

        // Inject auto-refresh script for poudriere data
        // This triggers poudriere's own update_stats() function if available
        let autoRefreshScript = WKUserScript(source: """
            (function() {
                // Auto-refresh every 5 seconds
                setInterval(function() {
                    // Check if poudriere's update function exists
                    if (typeof update_stats === 'function') {
                        // Poudriere's built-in refresh
                        update_stats();
                    } else if (typeof load_data === 'function') {
                        // Some poudriere versions use load_data
                        load_data();
                    }
                    // Note: We don't reload the page as a fallback because
                    // the HTML is loaded via loadHTMLString, not from a URL
                }, 5000);
            })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(autoRefreshScript)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload if the HTML content has actually changed
        // This prevents reloading when the user navigates within the webview
        if context.coordinator.lastLoadedHTML == htmlContent {
            return
        }

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

        // Track what we loaded to avoid unnecessary reloads
        context.coordinator.lastLoadedHTML = htmlContent

        // Set baseURL to poudriere:// so JavaScript can make relative requests
        let baseURL = URL(string: "poudriere:///")
        webView.loadHTMLString(modifiedHTML, baseURL: baseURL)
    }

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let schemeHandler: PoudriereSchemeHandler
        var lastLoadedHTML: String?
        let navigationState: WebViewNavigationState

        init(basePath: String, dataPath: String, sshManager: SSHConnectionManager, navigationState: WebViewNavigationState) {
            self.schemeHandler = PoudriereSchemeHandler(basePath: basePath, sshManager: sshManager, dataPath: dataPath)
            self.navigationState = navigationState
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "consoleLog", let body = message.body as? [String: Any] {
                let type = body["type"] as? String ?? "log"
                let msg = body["message"] as? String ?? ""
                print("JS [\(type.uppercased())]: \(msg)")
            } else if message.name == "saveLog", let body = message.body as? [String: Any] {
                let filename = body["filename"] as? String ?? "log.txt"
                let content = body["content"] as? String ?? ""
                saveLogFile(filename: filename, content: content)
            }
        }

        private func saveLogFile(filename: String, content: String) {
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = filename
            savePanel.allowedContentTypes = [.plainText, .log]
            savePanel.canCreateDirectories = true

            savePanel.begin { response in
                if response == .OK, let url = savePanel.url {
                    do {
                        try content.write(to: url, atomically: true, encoding: .utf8)
                        print("DEBUG: Saved log file to \(url.path)")
                    } catch {
                        print("DEBUG: Failed to save log file: \(error)")
                    }
                }
            }
        }

        // MARK: - WKUIDelegate

        // Handle requests to open new windows (target="_blank" links, window.open, etc.)
        // Return the same webview to load in-place, or nil to block
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Load the URL in the same webview instead of opening a new window
            if let url = navigationAction.request.url {
                print("DEBUG: UI delegate - new window request for: \(url.absoluteString)")
                if url.scheme == "poudriere" {
                    webView.load(navigationAction.request)
                }
            }
            return nil
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            let targetFrame = navigationAction.targetFrame
            let isMainFrame = targetFrame?.isMainFrame ?? true
            print("DEBUG: Navigation request to: \(url.absoluteString), isMainFrame: \(isMainFrame), targetFrame: \(targetFrame != nil ? "exists" : "nil")")

            // Allow navigation to poudriere:// URLs (both main frame and subframes)
            if url.scheme == "poudriere" {
                decisionHandler(.allow)
                return
            }

            // Allow about:blank and data URLs
            if url.scheme == "about" || url.scheme == "data" {
                decisionHandler(.allow)
                return
            }

            // Block external URLs (or open in browser if desired)
            print("DEBUG: Blocking navigation to external URL: \(url.absoluteString)")
            decisionHandler(.cancel)
        }

        // Handle navigation response (needed for custom scheme in subframes)
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            print("DEBUG: Navigation response for: \(navigationResponse.response.url?.absoluteString ?? "nil")")
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("DEBUG: Navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("DEBUG: Provisional navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Update navigation state after navigation completes
            DispatchQueue.main.async {
                self.navigationState.webView = webView
                self.navigationState.updateState()
            }
        }
    }
}

// MARK: - Poudriere Tab Selection

enum PoudriereTab: String, CaseIterable {
    case status = "Build Status"
    case jails = "Jails"
    case ports = "Ports Trees"
    case build = "Build"
    case config = "Configuration"

    var icon: String {
        switch self {
        case .status: return "chart.bar.fill"
        case .jails: return "building.columns.fill"
        case .ports: return "folder.fill"
        case .build: return "hammer.fill"
        case .config: return "gearshape.fill"
        }
    }
}

// MARK: - Poudriere Content View

struct PoudriereContentView: View {
    @StateObject private var viewModel = PoudriereViewModel()
    @State private var showError = false
    @State private var selectedTab: PoudriereTab = .status

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
            }
            .padding()

            // Tab bar (only show when installed)
            if viewModel.isInstalled {
                HStack(spacing: 0) {
                    ForEach(PoudriereTab.allCases, id: \.self) { tab in
                        Button(action: { selectedTab = tab }) {
                            HStack(spacing: 6) {
                                Image(systemName: tab.icon)
                                    .font(.caption)
                                Text(tab.rawValue)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedTab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
                            .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

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
            } else if viewModel.isInstalled && !viewModel.isGitInstalled {
                // Poudriere is installed but git is missing
                ScrollView {
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 72))
                            .foregroundColor(.orange)
                        Text("Git Required")
                            .font(.title)
                            .foregroundColor(.primary)
                        Text("Git is required to create and update ports trees")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 10)

                        // Git package selection
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Select Git Package")
                                .font(.headline)

                            HStack(alignment: .top) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                VStack(alignment: .leading, spacing: 4) {
                                    Picker("Git", selection: $viewModel.selectedGitPackage) {
                                        Text("git").tag("git")
                                        Text("git-lite").tag("git-lite")
                                        Text("git-tiny").tag("git-tiny")
                                    }
                                    .pickerStyle(.radioGroup)

                                    Text(gitPackageDescription(viewModel.selectedGitPackage))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .font(.subheadline)
                        }
                        .padding()
                        .frame(maxWidth: 400, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)

                        // Install button
                        Button(action: {
                            Task {
                                await viewModel.installGit()
                            }
                        }) {
                            Label("Install Git", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Text("This will install \(viewModel.selectedGitPackage)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
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

                            // Git package status
                            HStack(spacing: 8) {
                                Image(systemName: viewModel.isGitInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(viewModel.isGitInstalled ? .green : .red)
                                Text("Git")
                                    .fontWeight(.medium)
                                Text(viewModel.isGitInstalled ? "Installed" : "Not installed")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

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

                        // Required packages
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Required Packages")
                                .font(.headline)

                            // Git selection
                            HStack(alignment: .top) {
                                Image(systemName: viewModel.isGitInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(viewModel.isGitInstalled ? .green : .red)
                                VStack(alignment: .leading, spacing: 4) {
                                    Picker("Git", selection: $viewModel.selectedGitPackage) {
                                        Text("git").tag("git")
                                        Text("git-lite").tag("git-lite")
                                        Text("git-tiny").tag("git-tiny")
                                    }
                                    .pickerStyle(.radioGroup)

                                    Text(gitPackageDescription(viewModel.selectedGitPackage))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .font(.subheadline)

                            // Poudriere selection
                            HStack(alignment: .top) {
                                Image(systemName: viewModel.isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(viewModel.isInstalled ? .green : .red)
                                VStack(alignment: .leading, spacing: 4) {
                                    Picker("Poudriere", selection: $viewModel.selectedPackage) {
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
                            }
                            .font(.subheadline)
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
                            Label("Install Packages", systemImage: "gear")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Text("This will install git and \(viewModel.selectedPackage)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Tabbed content for installed poudriere
                switch selectedTab {
                case .status:
                    PoudriereBuildStatusView(viewModel: viewModel)
                case .jails:
                    PoudriereJailsView(viewModel: viewModel)
                case .ports:
                    PoudrierePortsTreesView(viewModel: viewModel)
                case .build:
                    PoudriereBulkBuildView(viewModel: viewModel)
                case .config:
                    PoudriereConfigView(viewModel: viewModel)
                }
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
        .sheet(isPresented: $viewModel.showingCommandOutput) {
            CommandOutputSheet(
                title: viewModel.commandTitle,
                outputModel: viewModel.commandOutput,
                onCancel: {
                    viewModel.commandOutput.cancel()
                    viewModel.showingCommandOutput = false
                },
                onDismiss: {
                    viewModel.showingCommandOutput = false
                }
            )
        }
        .onChange(of: viewModel.error) { oldValue, newValue in
            if newValue != nil {
                showError = true
            }
        }
        .onChange(of: viewModel.requestedTab) { oldValue, newValue in
            if let tab = newValue {
                selectedTab = tab
                viewModel.requestedTab = nil
            }
        }
        .onAppear {
            Task {
                await viewModel.loadPoudriere()
            }
        }
    }

    private func gitPackageDescription(_ package: String) -> String {
        switch package {
        case "git":
            return "Full git with all optional dependencies (recommended)"
        case "git-lite":
            return "Lightweight git without perl/python/tk"
        case "git-tiny":
            return "Minimal core git commands (smallest)"
        default:
            return ""
        }
    }
}

// MARK: - Build Status View

struct PoudriereBuildStatusView: View {
    @ObservedObject var viewModel: PoudriereViewModel

    var body: some View {
        if !viewModel.hasBuilds {
            VStack(spacing: 20) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 72))
                    .foregroundColor(.secondary)
                Text("No Builds Yet")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("Poudriere is installed but no builds have been run yet.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("Use the Build tab to start a new build.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let htmlContent = viewModel.htmlContent, !htmlContent.isEmpty {
            WebViewContainer(
                htmlContent: htmlContent,
                basePath: viewModel.htmlPath,
                dataPath: viewModel.dataPath,
                sshManager: SSHConnectionManager.shared
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}

// MARK: - Jails Management View

struct PoudriereJailsView: View {
    @ObservedObject var viewModel: PoudriereViewModel
    @State private var showingCreateSheet = false
    @State private var jailToDelete: PoudriereJail?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Jails")
                    .font(.headline)
                Spacer()
                Button(action: { showingCreateSheet = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Create new jail")
            }
            .padding()

            Divider()

            if viewModel.jails.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "building.columns")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Jails")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Create a jail to start building packages")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Create Jail") {
                        showingCreateSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.jails) { jail in
                        PoudriereJailRow(jail: jail, viewModel: viewModel, onDelete: {
                            jailToDelete = jail
                        })
                    }
                }
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateJailSheet(viewModel: viewModel, onDismiss: { showingCreateSheet = false })
        }
        .alert("Delete Jail?", isPresented: Binding(
            get: { jailToDelete != nil },
            set: { if !$0 { jailToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { jailToDelete = nil }
            Button("Delete", role: .destructive) {
                if let jail = jailToDelete {
                    Task {
                        await viewModel.deleteJail(name: jail.name)
                    }
                }
                jailToDelete = nil
            }
        } message: {
            Text("Are you sure you want to delete the jail '\(jailToDelete?.name ?? "")'? This cannot be undone.")
        }
        .onAppear {
            Task {
                await viewModel.loadJails()
            }
        }
    }
}

struct PoudriereJailRow: View {
    let jail: PoudriereJail
    @ObservedObject var viewModel: PoudriereViewModel
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "building.columns.fill")
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(jail.name)
                    .font(.headline)
                Text("\(jail.version) - \(jail.arch)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(jail.method)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)

            Button(action: {
                Task {
                    await viewModel.updateJail(name: jail.name)
                }
            }) {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Update jail")

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
            .help("Delete jail")
        }
        .padding(.vertical, 4)
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

struct CreateJailSheet: View {
    @ObservedObject var viewModel: PoudriereViewModel
    let onDismiss: () -> Void
    @State private var options = CreateJailOptions()
    @State private var isCreating = false
    @State private var isLoadingReleases = true
    @State private var availableVersions: [String] = []
    @State private var availableArchitectures: [String] = []
    @State private var hostArch: String = ""
    @State private var qemuInstalled = false
    @State private var isInstallingQemu = false

    var isValid: Bool {
        let nameValid = !options.name.isEmpty && options.name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let versionValid = options.useCustomVersion ? !options.customVersion.isEmpty : !options.version.isEmpty
        let archValid = options.useCustomArch ? !options.customArch.isEmpty : !options.arch.isEmpty
        return nameValid && versionValid && archValid
    }

    /// Normalize architecture name (FreeBSD uses aarch64, mirror uses arm64)
    var normalizedHostArch: String {
        hostArch == "aarch64" ? "arm64" : hostArch
    }

    var isCrossArchBuild: Bool {
        let selectedArch = options.useCustomArch ? options.customArch : options.arch
        return !hostArch.isEmpty && selectedArch != normalizedHostArch
    }

    var needsQemu: Bool {
        isCrossArchBuild && !qemuInstalled
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Create Jail")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if isLoadingReleases {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Fetching available releases...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Name
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Name")
                                .font(.headline)
                            TextField("e.g., 14amd64", text: $options.name)
                                .textFieldStyle(.roundedBorder)
                            Text("Alphanumeric characters, hyphens, and underscores only")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // Version
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("FreeBSD Version")
                                    .font(.headline)
                                Spacer()
                                Toggle("Custom", isOn: $options.useCustomVersion)
                                    .toggleStyle(.checkbox)
                                    .font(.caption)
                            }

                            if options.useCustomVersion {
                                TextField("e.g., 15.0-CURRENT", text: $options.customVersion)
                                    .textFieldStyle(.roundedBorder)
                                Text("Enter version string (e.g., 14.2-RELEASE, 15.0-CURRENT)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Picker("Version", selection: $options.version) {
                                    ForEach(availableVersions, id: \.self) { version in
                                        Text(version).tag(version)
                                    }
                                }
                                .labelsHidden()
                            }
                        }

                        // Architecture
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Architecture")
                                    .font(.headline)
                                Spacer()
                                if !hostArch.isEmpty {
                                    Text("Host: \(normalizedHostArch)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Toggle("Custom", isOn: $options.useCustomArch)
                                    .toggleStyle(.checkbox)
                                    .font(.caption)
                            }

                            if options.useCustomArch {
                                TextField("e.g., riscv64", text: $options.customArch)
                                    .textFieldStyle(.roundedBorder)
                                Text("Enter architecture (e.g., amd64, arm64, i386)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Picker("Architecture", selection: $options.arch) {
                                    ForEach(availableArchitectures, id: \.self) { arch in
                                        Text(arch).tag(arch)
                                    }
                                }
                                .labelsHidden()
                                .onChange(of: options.arch) { _, newArch in
                                    // Reload available versions for the selected architecture
                                    Task {
                                        await loadVersionsForArch(newArch)
                                    }
                                }
                            }

                            // Cross-architecture warning
                            if isCrossArchBuild {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("Cross-architecture build requires QEMU")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                                .padding(.top, 4)

                                if needsQemu {
                                    HStack {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.caption)
                                        Text("qemu-user-static is not installed")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Button(action: {
                                            Task {
                                                await installQemu()
                                            }
                                        }) {
                                            if isInstallingQemu {
                                                ProgressView()
                                                    .scaleEffect(0.7)
                                            } else {
                                                Text("Install")
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(isInstallingQemu)
                                    }
                                    .padding(8)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(6)
                                } else if isCrossArchBuild && qemuInstalled {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                            .font(.caption)
                                        Text("qemu-user-static is installed")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }

                        // Method
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Download Method")
                                .font(.headline)
                            Picker("Method", selection: $options.method) {
                                ForEach(CreateJailOptions.JailMethod.allCases, id: \.self) { method in
                                    Text(method.displayName).tag(method)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Create") {
                    // Dismiss this sheet first, then start creation
                    // This avoids the "only one sheet" conflict with the progress sheet
                    let capturedOptions = options
                    onDismiss()
                    Task {
                        await viewModel.createJail(options: capturedOptions)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCreating || isLoadingReleases)
            }
            .padding()
        }
        .frame(width: 450, height: 450)
        .onAppear {
            Task {
                await loadAvailableReleases()
            }
        }
    }

    private func loadAvailableReleases() async {
        isLoadingReleases = true
        do {
            // Get host architecture first to set as default
            hostArch = try await SSHConnectionManager.shared.getHostArchitecture()
            print("DEBUG: Host architecture detected: '\(hostArch)'")

            // Check if QEMU is installed
            qemuInstalled = try await SSHConnectionManager.shared.checkQemuInstalled()
            print("DEBUG: QEMU installed: \(qemuInstalled)")

            // Fetch available architectures
            availableArchitectures = try await SSHConnectionManager.shared.getAvailableArchitectures()
            print("DEBUG: Available architectures: \(availableArchitectures)")

            // Default to host architecture if available, otherwise first in list
            // Note: FreeBSD reports aarch64 but mirror uses arm64
            let normalizedHostArch = hostArch == "aarch64" ? "arm64" : hostArch
            print("DEBUG: Normalized host arch: '\(normalizedHostArch)'")
            print("DEBUG: Available archs contains normalized: \(availableArchitectures.contains(normalizedHostArch))")

            if availableArchitectures.contains(normalizedHostArch) {
                options.arch = normalizedHostArch
                print("DEBUG: Selected host arch: \(normalizedHostArch)")
            } else if let firstArch = availableArchitectures.first {
                options.arch = firstArch
                print("DEBUG: Host arch not found, selected first: \(firstArch)")
            }

            // Fetch versions for the selected architecture
            availableVersions = try await SSHConnectionManager.shared.getAvailableFreeBSDReleases(arch: options.arch)
            print("DEBUG: Available versions for \(options.arch): \(availableVersions)")

            // Set default version
            if let firstVersion = availableVersions.first {
                options.version = firstVersion
            }
        } catch {
            print("DEBUG: Error loading releases: \(error)")
            // Use fallback values
            availableVersions = ["15.0-RELEASE", "14.3-RELEASE", "14.2-RELEASE", "13.5-RELEASE", "13.4-RELEASE"]
            availableArchitectures = ["amd64", "arm64", "i386"]
            options.version = "15.0-RELEASE"
            options.arch = hostArch.isEmpty ? "amd64" : hostArch
        }
        isLoadingReleases = false
    }

    private func loadVersionsForArch(_ arch: String) async {
        do {
            availableVersions = try await SSHConnectionManager.shared.getAvailableFreeBSDReleases(arch: arch)
            // Update selected version if current one isn't available for this arch
            if !availableVersions.contains(options.version), let firstVersion = availableVersions.first {
                options.version = firstVersion
            }
            // Re-check QEMU status when arch changes
            qemuInstalled = try await SSHConnectionManager.shared.checkQemuInstalled()
        } catch {
            // Keep current versions on error
        }
    }

    private func installQemu() async {
        isInstallingQemu = true
        do {
            _ = try await SSHConnectionManager.shared.installQemu()
            qemuInstalled = true
        } catch {
            viewModel.error = "Failed to install QEMU: \(error.localizedDescription)"
        }
        isInstallingQemu = false
    }
}

// MARK: - Ports Trees Management View

struct PoudrierePortsTreesView: View {
    @ObservedObject var viewModel: PoudriereViewModel
    @State private var showingCreateSheet = false
    @State private var treeToDelete: PoudrierePortsTree?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Ports Trees")
                    .font(.headline)
                Spacer()
                Button(action: { showingCreateSheet = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Create new ports tree")
            }
            .padding()

            Divider()

            if viewModel.portsTrees.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Ports Trees")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Create a ports tree to build packages from")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Create Ports Tree") {
                        showingCreateSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.portsTrees) { tree in
                        PoudrierePortsTreeRow(tree: tree, viewModel: viewModel, onDelete: {
                            treeToDelete = tree
                        })
                    }
                }
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreatePortsTreeSheet(viewModel: viewModel, onDismiss: { showingCreateSheet = false })
        }
        .alert("Delete Ports Tree?", isPresented: Binding(
            get: { treeToDelete != nil },
            set: { if !$0 { treeToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { treeToDelete = nil }
            Button("Delete", role: .destructive) {
                if let tree = treeToDelete {
                    Task {
                        await viewModel.deletePortsTree(name: tree.name)
                    }
                }
                treeToDelete = nil
            }
        } message: {
            Text("Are you sure you want to delete the ports tree '\(treeToDelete?.name ?? "")'? This cannot be undone.")
        }
        .onAppear {
            Task {
                await viewModel.loadPortsTrees()
            }
        }
    }
}

struct PoudrierePortsTreeRow: View {
    let tree: PoudrierePortsTree
    @ObservedObject var viewModel: PoudriereViewModel
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(tree.name)
                    .font(.headline)
                Text(tree.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(tree.method)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)

            Button(action: {
                Task {
                    await viewModel.updatePortsTree(name: tree.name)
                }
            }) {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Update ports tree")

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
            .help("Delete ports tree")
        }
        .padding(.vertical, 4)
    }
}

struct CreatePortsTreeSheet: View {
    @ObservedObject var viewModel: PoudriereViewModel
    let onDismiss: () -> Void
    @State private var options = CreatePortsTreeOptions()
    @State private var isCreating = false

    var isValid: Bool {
        let nameValid = !options.name.isEmpty && options.name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let branchValid = !options.method.usesGit || !options.effectiveBranch.isEmpty
        let urlValid = !options.useCustomUrl || !options.customUrl.isEmpty
        return nameValid && branchValid && urlValid
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Create Ports Tree")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                            .font(.headline)
                        TextField("e.g., default, quarterly", text: $options.name)
                            .textFieldStyle(.roundedBorder)
                        Text("Alphanumeric characters, hyphens, and underscores only")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Method
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Method")
                            .font(.headline)
                        Picker("Method", selection: $options.method) {
                            ForEach(CreatePortsTreeOptions.PortsTreeMethod.allCases, id: \.self) { method in
                                Text(method.displayName).tag(method)
                            }
                        }
                        .labelsHidden()
                        Text(options.method.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Branch (for git methods)
                    if options.method.usesGit {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Branch")
                                .font(.headline)

                            if options.useCustomBranch {
                                TextField("Branch name", text: $options.customBranch)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                Picker("Branch", selection: $options.branch) {
                                    ForEach(CreatePortsTreeOptions.availableBranches, id: \.self) { branch in
                                        Text(branch).tag(branch)
                                    }
                                }
                                .labelsHidden()
                            }

                            Toggle("Use custom branch", isOn: $options.useCustomBranch)
                                .toggleStyle(.checkbox)

                            Text("main = latest, quarterly branches = more stable")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // Custom Repository URL
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Repository URL")
                                .font(.headline)

                            Toggle("Use custom repository URL", isOn: $options.useCustomUrl)
                                .toggleStyle(.checkbox)

                            if options.useCustomUrl {
                                TextField("https://github.com/user/ports.git", text: $options.customUrl)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Text(options.useCustomUrl ? "Enter the full git repository URL" : "Default: FreeBSD ports repository")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Create") {
                    // Dismiss this sheet first, then start creation
                    // This avoids the "only one sheet" conflict with the progress sheet
                    let capturedOptions = options
                    onDismiss()
                    Task {
                        await viewModel.createPortsTree(options: capturedOptions)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCreating)
            }
            .padding()
        }
        .frame(width: 450, height: 480)
    }
}

// MARK: - Bulk Build View

struct PoudriereBulkBuildView: View {
    @ObservedObject var viewModel: PoudriereViewModel
    @State private var buildOptions = BulkBuildOptions()
    @State private var isStartingBuild = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Start Bulk Build")
                    .font(.title2)
                    .bold()

                // Jail selection
                GroupBox("Select Jail") {
                    if viewModel.jails.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("No jails available. Create one first.")
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Picker("Jail", selection: $buildOptions.jail) {
                            Text("Select a jail...").tag(nil as PoudriereJail?)
                            ForEach(viewModel.jails) { jail in
                                Text(jail.displayName).tag(jail as PoudriereJail?)
                            }
                        }
                        .labelsHidden()
                    }
                }

                // Ports tree selection
                GroupBox("Select Ports Tree") {
                    if viewModel.portsTrees.isEmpty {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("No ports trees available. Create one first.")
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Picker("Ports Tree", selection: $buildOptions.portsTree) {
                            Text("Select a ports tree...").tag(nil as PoudrierePortsTree?)
                            ForEach(viewModel.portsTrees) { tree in
                                Text(tree.name).tag(tree as PoudrierePortsTree?)
                            }
                        }
                        .labelsHidden()
                    }
                }

                // Package selection
                GroupBox("Packages to Build") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Build all packages", isOn: $buildOptions.buildAll)

                        if !buildOptions.buildAll {
                            Divider()

                            // Package list file option
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Package list file")
                                    .font(.subheadline)
                                TextField("/usr/local/etc/poudriere.d/pkglist", text: $buildOptions.packageListFile)
                                    .textFieldStyle(.roundedBorder)
                                Text("Path to a file containing package origins, one per line")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            // Manual package entry
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Or enter packages directly")
                                    .font(.subheadline)
                                TextField("www/nginx security/sudo shells/bash", text: $buildOptions.packagesText)
                                    .textFieldStyle(.roundedBorder)
                                Text("Space-separated list of package origins (e.g., www/nginx editors/vim)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if !buildOptions.packages.isEmpty {
                                    HStack {
                                        Text("\(buildOptions.packages.count) package(s):")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Text(buildOptions.packages.joined(separator: ", "))
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Build options
                GroupBox("Build Options") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Clean build (rebuild all)", isOn: $buildOptions.cleanBuild)
                        Toggle("Test mode (run pkg-plist check)", isOn: $buildOptions.testBuild)
                    }
                    .padding(.vertical, 4)
                }

                // Start button
                HStack {
                    Spacer()
                    Button(action: {
                        Task {
                            await startBuild()
                        }
                    }) {
                        HStack {
                            if isStartingBuild {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "hammer.fill")
                            }
                            Text("Start Build")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!buildOptions.isValid || isStartingBuild)
                }
            }
            .padding()
        }
        .onAppear {
            Task {
                await viewModel.loadJails()
                await viewModel.loadPortsTrees()
            }
        }
    }

    private func startBuild() async {
        guard let jail = buildOptions.jail, let tree = buildOptions.portsTree else { return }
        isStartingBuild = true

        do {
            if buildOptions.buildAll {
                _ = try await SSHConnectionManager.shared.startPoudriereBulkAll(
                    jail: jail.name,
                    portsTree: tree.name,
                    clean: buildOptions.cleanBuild,
                    test: buildOptions.testBuild
                )
            } else if !buildOptions.packageListFile.isEmpty {
                _ = try await SSHConnectionManager.shared.startPoudriereBulkFromFile(
                    jail: jail.name,
                    portsTree: tree.name,
                    listFile: buildOptions.packageListFile,
                    clean: buildOptions.cleanBuild,
                    test: buildOptions.testBuild
                )
            } else if !buildOptions.packages.isEmpty {
                _ = try await SSHConnectionManager.shared.startPoudriereBulkPackages(
                    jail: jail.name,
                    portsTree: tree.name,
                    packages: buildOptions.packages,
                    clean: buildOptions.cleanBuild,
                    test: buildOptions.testBuild
                )
            }
            // Refresh and switch to Build Status tab on success
            await viewModel.refresh()
            viewModel.requestedTab = .status
        } catch {
            viewModel.error = "Failed to start build: \(error.localizedDescription)"
        }

        isStartingBuild = false
    }
}

// MARK: - Flow Layout for Tags

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(subviews: subviews, proposal: proposal)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, proposal: proposal)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(subviews: Subviews, proposal: ProposedViewSize) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX)
        }

        return (CGSize(width: maxX, height: currentY + lineHeight), positions)
    }
}

// MARK: - Configuration View

/// Known FreeBSD mirrors
enum FreeBSDMirror: String, CaseIterable {
    case main = "https://download.FreeBSD.org"
    case ftp = "ftp://ftp.FreeBSD.org"
    // Regional mirrors
    case usWest = "https://download.us-west.FreeBSD.org"
    case usEast = "https://download.us-east.FreeBSD.org"
    case eu = "https://download.eu.FreeBSD.org"
    case uk = "https://download.uk.FreeBSD.org"
    case de = "https://download.de.FreeBSD.org"
    case fr = "https://download.fr.FreeBSD.org"
    case jp = "https://download.jp.FreeBSD.org"
    case tw = "https://download.tw.FreeBSD.org"
    case au = "https://download.au.FreeBSD.org"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .main: return "Main (download.FreeBSD.org)"
        case .ftp: return "FTP (ftp.FreeBSD.org)"
        case .usWest: return "US West"
        case .usEast: return "US East"
        case .eu: return "Europe"
        case .uk: return "United Kingdom"
        case .de: return "Germany"
        case .fr: return "France"
        case .jp: return "Japan"
        case .tw: return "Taiwan"
        case .au: return "Australia"
        case .custom: return "Custom..."
        }
    }

    static func fromURL(_ url: String) -> FreeBSDMirror {
        for mirror in FreeBSDMirror.allCases where mirror != .custom {
            if mirror.rawValue == url {
                return mirror
            }
        }
        return .custom
    }
}

struct PoudriereConfigView: View {
    @ObservedObject var viewModel: PoudriereViewModel
    @State private var config = PoudriereConfig.default
    @State private var zpools: [String] = []
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var hasChanges = false
    @State private var distfilesCacheExists = true
    @State private var isCreatingDistfilesCache = false
    @State private var selectedMirror: FreeBSDMirror = .main
    @State private var customMirrorURL: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Poudriere Configuration")
                        .font(.title2)
                        .bold()
                    Spacer()
                    if hasChanges {
                        Text("Unsaved changes")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding()
                } else {
                    // Storage Mode Selection
                    GroupBox("Storage") {
                        VStack(alignment: .leading, spacing: 12) {
                            // Storage mode toggle
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Storage Mode")
                                    .font(.subheadline)
                                Picker("Storage Mode", selection: Binding(
                                    get: { config.noZfs ? "ufs" : "zfs" },
                                    set: { newValue in
                                        config.noZfs = (newValue == "ufs")
                                        hasChanges = true
                                    }
                                )) {
                                    Text("ZFS").tag("zfs")
                                    Text("UFS").tag("ufs")
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 150)
                            }

                            if config.noZfs {
                                // UFS mode info
                                HStack {
                                    Image(systemName: "info.circle")
                                        .foregroundColor(.blue)
                                    Text("UFS mode uses regular directories instead of ZFS datasets")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                // ZFS Pool picker
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("ZFS Pool")
                                        .font(.subheadline)
                                    if zpools.isEmpty {
                                        HStack {
                                            Image(systemName: "exclamationmark.triangle")
                                                .foregroundColor(.orange)
                                            Text("No ZFS pools available")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    } else {
                                        Picker("ZPool", selection: $config.zpool) {
                                            ForEach(zpools, id: \.self) { pool in
                                                Text(pool).tag(pool)
                                            }
                                        }
                                        .labelsHidden()
                                        .onChange(of: config.zpool) { _, _ in hasChanges = true }
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Base Filesystem")
                                    .font(.subheadline)
                                TextField("/usr/local/poudriere", text: $config.basefs)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: config.basefs) { _, _ in hasChanges = true }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Data Directory")
                                    .font(.subheadline)
                                TextField("${BASEFS}/data", text: $config.poudriereData)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: config.poudriereData) { _, _ in hasChanges = true }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Distfiles Cache")
                                    .font(.subheadline)
                                HStack {
                                    TextField("/usr/ports/distfiles", text: $config.distfilesCache)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: config.distfilesCache) { _, _ in
                                            hasChanges = true
                                            // Check if new path exists
                                            Task {
                                                await checkDistfilesCacheExists()
                                            }
                                        }
                                    if !distfilesCacheExists {
                                        Button(action: {
                                            Task {
                                                await createDistfilesCache()
                                            }
                                        }) {
                                            if isCreatingDistfilesCache {
                                                ProgressView()
                                                    .scaleEffect(0.7)
                                            } else {
                                                Text("Create")
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(isCreatingDistfilesCache)
                                    }
                                }
                                if !distfilesCacheExists {
                                    HStack(spacing: 4) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                            .font(.caption)
                                        Text("Directory does not exist")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // Build settings
                    GroupBox("Build Settings") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("FreeBSD Mirror")
                                    .font(.subheadline)
                                Picker("Mirror", selection: $selectedMirror) {
                                    ForEach(FreeBSDMirror.allCases, id: \.self) { mirror in
                                        Text(mirror.displayName).tag(mirror)
                                    }
                                }
                                .labelsHidden()
                                .onChange(of: selectedMirror) { _, newValue in
                                    if newValue != .custom {
                                        config.freebsdHost = newValue.rawValue
                                    } else {
                                        config.freebsdHost = customMirrorURL
                                    }
                                    hasChanges = true
                                }

                                if selectedMirror == .custom {
                                    TextField("https://example.com", text: $customMirrorURL)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: customMirrorURL) { _, newValue in
                                            config.freebsdHost = newValue
                                            hasChanges = true
                                        }
                                    Text("Enter full URL including protocol (https:// or ftp://)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Parallel Jobs")
                                    .font(.subheadline)
                                Stepper("\(config.makeJobs) jobs", value: $config.makeJobs, in: 1...64)
                                    .onChange(of: config.makeJobs) { _, _ in hasChanges = true }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Use TMPFS")
                                    .font(.subheadline)
                                Picker("TMPFS", selection: $config.useTmpfs) {
                                    Text("All").tag("all")
                                    Text("Yes").tag("yes")
                                    Text("No").tag("no")
                                    Text("Work Dir Only").tag("wrkdir")
                                    Text("Data Only").tag("data")
                                    Text("Localbase Only").tag("localbase")
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .onChange(of: config.useTmpfs) { _, _ in hasChanges = true }
                            }

                            Toggle("Use Portlint", isOn: $config.usePortlint)
                                .onChange(of: config.usePortlint) { _, _ in hasChanges = true }
                        }
                        .padding(.vertical, 4)
                    }

                    // Advanced
                    GroupBox("Advanced") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Packages that can use unlimited jobs")
                                .font(.subheadline)
                            TextField("pkg ccache rust*", text: $config.allowMakeJobsPackages)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: config.allowMakeJobsPackages) { _, _ in hasChanges = true }
                            Text("Space-separated list of package patterns")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }

                    // Save button
                    HStack {
                        Spacer()
                        Button(action: {
                            Task {
                                await saveConfig()
                            }
                        }) {
                            HStack {
                                if isSaving {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "checkmark")
                                }
                                Text("Save Configuration")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasChanges || isSaving)
                    }
                }
            }
            .padding()
        }
        .onAppear {
            Task {
                await loadConfig()
            }
        }
    }

    private func loadConfig() async {
        isLoading = true
        do {
            config = try await SSHConnectionManager.shared.readPoudriereConfig()
            zpools = try await SSHConnectionManager.shared.getAvailableZpools()

            // If ZFS mode and pool not in list, select first available
            if !config.noZfs && !zpools.contains(config.zpool) && !zpools.isEmpty {
                config.zpool = zpools[0]
            }
            // Check for placeholder/unconfigured mirror and default to main
            if config.freebsdHost.contains("CHANGE_THIS") ||
               config.freebsdHost.contains("_PROTO_") ||
               config.freebsdHost.isEmpty {
                selectedMirror = .main
                config.freebsdHost = FreeBSDMirror.main.rawValue
                // Auto-save the fixed config
                try await SSHConnectionManager.shared.writePoudriereConfig(config)
            } else {
                // Set mirror selection based on loaded config
                selectedMirror = FreeBSDMirror.fromURL(config.freebsdHost)
                if selectedMirror == .custom {
                    customMirrorURL = config.freebsdHost
                }
            }
            // Check if distfiles cache directory exists
            await checkDistfilesCacheExists()
        } catch {
            viewModel.error = "Failed to load configuration: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func saveConfig() async {
        isSaving = true
        do {
            try await SSHConnectionManager.shared.writePoudriereConfig(config)
            hasChanges = false
        } catch {
            viewModel.error = "Failed to save configuration: \(error.localizedDescription)"
        }
        isSaving = false
    }

    private func checkDistfilesCacheExists() async {
        guard !config.distfilesCache.isEmpty else {
            distfilesCacheExists = false
            return
        }
        do {
            let command = "test -d '\(config.distfilesCache)' && echo 'exists' || echo 'missing'"
            let result = try await SSHConnectionManager.shared.executeCommand(command)
            distfilesCacheExists = result.trimmingCharacters(in: .whitespacesAndNewlines) == "exists"
        } catch {
            distfilesCacheExists = false
        }
    }

    private func createDistfilesCache() async {
        isCreatingDistfilesCache = true
        do {
            let command = "mkdir -p '\(config.distfilesCache)'"
            _ = try await SSHConnectionManager.shared.executeCommand(command)
            distfilesCacheExists = true
        } catch {
            viewModel.error = "Failed to create directory: \(error.localizedDescription)"
        }
        isCreatingDistfilesCache = false
    }
}

// MARK: - View Model

@MainActor
class PoudriereViewModel: ObservableObject {
    @Published var isInstalled = false
    @Published var isGitInstalled = false
    @Published var htmlPath = ""
    @Published var dataPath = ""
    @Published var configPath: String?
    @Published var runningBuilds: [String] = []
    @Published var hasBuilds = false
    @Published var htmlContent: String?
    @Published var isLoading = false
    @Published var error: String?

    // Jails and Ports Trees
    @Published var jails: [PoudriereJail] = []
    @Published var portsTrees: [PoudrierePortsTree] = []

    // Setup state
    @Published var isSettingUp = false
    @Published var setupStep = ""
    @Published var selectedPackage = "poudriere"
    @Published var selectedGitPackage = "git"

    // Command output for terminal-style sheets
    @Published var showingCommandOutput = false
    @Published var commandTitle = ""
    let commandOutput = CommandOutputModel()

    // Tab navigation request (set to non-nil to request tab change)
    @Published var requestedTab: PoudriereTab?

    private let sshManager = SSHConnectionManager.shared

    func loadPoudriere() async {
        isLoading = true
        error = nil

        do {
            // Check if git is installed
            let gitCheck = try? await sshManager.executeCommand("command -v git >/dev/null 2>&1 && echo 'installed' || echo 'not-installed'")
            isGitInstalled = gitCheck?.trimmingCharacters(in: .whitespacesAndNewlines) == "installed"

            let info = try await sshManager.checkPoudriere()
            isInstalled = info.isInstalled
            htmlPath = info.htmlPath
            dataPath = info.dataPath
            configPath = info.configPath
            runningBuilds = info.runningBuilds
            hasBuilds = info.hasBuilds

            if isInstalled && !htmlPath.isEmpty && hasBuilds {
                // Only load HTML if builds exist, otherwise the webview will show errors
                htmlContent = try await sshManager.loadPoudriereHTML(path: "\(htmlPath)/index.html")
            } else {
                htmlContent = nil
            }

            // Load jails and ports trees
            if isInstalled {
                jails = try await sshManager.listPoudriereJails()
                portsTrees = try await sshManager.listPoudrierePortsTrees()
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
        error = nil

        // Setup command output sheet
        commandOutput.reset()
        commandTitle = "Installing Packages"
        showingCommandOutput = true

        let packages = "\(selectedGitPackage) \(selectedPackage)"
        let command = "pkg install -y \(packages)"

        let task = Task {
            do {
                commandOutput.appendOutput("Installing packages: \(packages)\n")
                commandOutput.appendOutput("Running: \(command)\n\n")

                let exitCode = try await sshManager.executeCommandStreaming(command) { [weak self] output in
                    self?.commandOutput.appendOutput(output)
                }

                if exitCode == 0 {
                    commandOutput.appendOutput("\n\nPackages installed successfully!")
                    isInstalled = true
                    await loadPoudriere()
                } else {
                    commandOutput.appendOutput("\n\nInstallation failed with exit code \(exitCode)")
                }
                commandOutput.complete(exitCode: exitCode)
            } catch {
                await MainActor.run {
                    commandOutput.appendOutput("\n\nError: \(error.localizedDescription)")
                    commandOutput.complete(exitCode: 1)
                }
            }
        }
        commandOutput.setTask(task)
    }

    func installGit() async {
        error = nil

        // Setup command output sheet
        commandOutput.reset()
        commandTitle = "Installing Git"
        showingCommandOutput = true

        let command = "pkg install -y \(selectedGitPackage)"

        let task = Task {
            do {
                commandOutput.appendOutput("Installing package: \(selectedGitPackage)\n")
                commandOutput.appendOutput("Running: \(command)\n\n")

                let exitCode = try await sshManager.executeCommandStreaming(command) { [weak self] output in
                    self?.commandOutput.appendOutput(output)
                }

                if exitCode == 0 {
                    commandOutput.appendOutput("\n\nGit installed successfully!")
                    isGitInstalled = true
                    await loadPoudriere()
                } else {
                    commandOutput.appendOutput("\n\nInstallation failed with exit code \(exitCode)")
                }
                commandOutput.complete(exitCode: exitCode)
            } catch {
                await MainActor.run {
                    commandOutput.appendOutput("\n\nError: \(error.localizedDescription)")
                    commandOutput.complete(exitCode: 1)
                }
            }
        }
        commandOutput.setTask(task)
    }

    // MARK: - Jail Management

    func loadJails() async {
        do {
            jails = try await sshManager.listPoudriereJails()
        } catch {
            self.error = "Failed to load jails: \(error.localizedDescription)"
        }
    }

    func createJail(options: CreateJailOptions) async {
        print("DEBUG: createJail called with name=\(options.name), version=\(options.effectiveVersion), arch=\(options.effectiveArch), method=\(options.method.rawValue)")

        // Poudriere expects architecture in format like "amd64" or "arm64.aarch64"
        let poudriereArch: String
        switch options.effectiveArch {
        case "arm64":
            poudriereArch = "arm64.aarch64"
        case "arm":
            poudriereArch = "arm.armv7"
        case "powerpc":
            poudriereArch = "powerpc.powerpc64"
        case "riscv":
            poudriereArch = "riscv.riscv64"
        default:
            poudriereArch = options.effectiveArch
        }

        let command = "poudriere jail -c -j '\(options.name)' -v '\(options.effectiveVersion)' -a '\(poudriereArch)' -m '\(options.method.rawValue)'"
        let jailName = options.name

        // Setup command output sheet
        commandOutput.reset()
        commandTitle = "Creating Jail: \(jailName)"
        showingCommandOutput = true
        error = nil

        // Set cleanup handler to remove partial jail on cancel
        print("DEBUG: Setting cleanup handler for jail '\(jailName)'")
        commandOutput.setCleanupHandler { [weak self] in
            print("DEBUG: Cleanup handler executing for jail '\(jailName)'")
            guard let self = self else {
                print("DEBUG: self is nil in cleanup handler")
                return
            }
            self.commandOutput.appendOutput("\n\n--- Cancelling and cleaning up partial jail '\(jailName)'... ---\n")
            do {
                // Try to delete any partial jail that was created
                let cleanupCommand = "poudriere jail -d -j '\(jailName)' -C -y 2>&1 || echo 'No jail to clean'"
                print("DEBUG: Running cleanup command: \(cleanupCommand)")
                let result = try await self.sshManager.executeCommand(cleanupCommand)
                print("DEBUG: Cleanup result: \(result)")
                self.commandOutput.appendOutput("Cleanup output: \(result)\n")
                self.commandOutput.appendOutput("Cleanup complete.\n")
            } catch {
                print("DEBUG: Cleanup error: \(error)")
                self.commandOutput.appendOutput("Cleanup error: \(error.localizedDescription)\n")
            }
            await self.loadJails()
        }
        print("DEBUG: Cleanup handler set")

        let task = Task {
            do {
                let exitCode = try await sshManager.executeCommandStreaming(command) { [weak self] output in
                    self?.commandOutput.appendOutput(output)
                }
                commandOutput.complete(exitCode: exitCode)

                if exitCode == 0 {
                    await loadJails()
                }
            } catch {
                if !Task.isCancelled {
                    commandOutput.appendOutput("\n\nError: \(error.localizedDescription)")
                    commandOutput.complete(exitCode: 1)
                    self.error = "Failed to create jail: \(error.localizedDescription)"
                }
            }
        }
        commandOutput.setTask(task)
    }

    func updateJail(name: String) async {
        let command = "poudriere jail -u -j '\(name)'"

        // Setup command output sheet
        commandOutput.reset()
        commandTitle = "Updating Jail: \(name)"
        showingCommandOutput = true
        error = nil

        let task = Task {
            do {
                let exitCode = try await sshManager.executeCommandStreaming(command) { [weak self] output in
                    self?.commandOutput.appendOutput(output)
                }
                commandOutput.complete(exitCode: exitCode)

                if exitCode == 0 {
                    await loadJails()
                }
            } catch {
                if !Task.isCancelled {
                    commandOutput.appendOutput("\n\nError: \(error.localizedDescription)")
                    commandOutput.complete(exitCode: 1)
                    self.error = "Failed to update jail: \(error.localizedDescription)"
                }
            }
        }
        commandOutput.setTask(task)
    }

    func deleteJail(name: String) async {
        isSettingUp = true
        setupStep = "Deleting jail '\(name)'..."
        error = nil

        do {
            _ = try await sshManager.deletePoudriereJail(name: name)
            await loadJails()
        } catch {
            self.error = "Failed to delete jail: \(error.localizedDescription)"
        }

        isSettingUp = false
        setupStep = ""
    }

    // MARK: - Ports Tree Management

    func loadPortsTrees() async {
        do {
            portsTrees = try await sshManager.listPoudrierePortsTrees()
        } catch {
            self.error = "Failed to load ports trees: \(error.localizedDescription)"
        }
    }

    func createPortsTree(options: CreatePortsTreeOptions) async {
        var command = "poudriere ports -c -p '\(options.name)' -m '\(options.method.rawValue)'"

        // Add branch for git methods
        if options.method.usesGit {
            let branch = options.effectiveBranch
            if !branch.isEmpty {
                command += " -B '\(branch)'"
            }

            // Add custom URL if specified
            if let customUrl = options.effectiveUrl {
                command += " -U '\(customUrl)'"
            }
        }
        let portsTreeName = options.name

        // Setup command output sheet
        commandOutput.reset()
        commandTitle = "Creating Ports Tree: \(portsTreeName)"
        showingCommandOutput = true
        error = nil

        // Set cleanup handler to remove partial ports tree on cancel
        commandOutput.setCleanupHandler { [weak self] in
            guard let self = self else { return }
            self.commandOutput.appendOutput("\n\n--- Cancelling and cleaning up partial ports tree '\(portsTreeName)'... ---\n")
            do {
                // Try to delete any partial ports tree that was created
                _ = try await self.sshManager.executeCommand("poudriere ports -d -p '\(portsTreeName)' -C 2>/dev/null || true")
                self.commandOutput.appendOutput("Cleanup complete.\n")
            } catch {
                self.commandOutput.appendOutput("Cleanup error: \(error.localizedDescription)\n")
            }
            await self.loadPortsTrees()
        }

        let task = Task {
            do {
                let exitCode = try await sshManager.executeCommandStreaming(command) { [weak self] output in
                    self?.commandOutput.appendOutput(output)
                }
                commandOutput.complete(exitCode: exitCode)

                if exitCode == 0 {
                    await loadPortsTrees()
                }
            } catch {
                if !Task.isCancelled {
                    commandOutput.appendOutput("\n\nError: \(error.localizedDescription)")
                    commandOutput.complete(exitCode: 1)
                    self.error = "Failed to create ports tree: \(error.localizedDescription)"
                }
            }
        }
        commandOutput.setTask(task)
    }

    func updatePortsTree(name: String) async {
        let command = "poudriere ports -u -p '\(name)'"

        // Setup command output sheet
        commandOutput.reset()
        commandTitle = "Updating Ports Tree: \(name)"
        showingCommandOutput = true
        error = nil

        let task = Task {
            do {
                let exitCode = try await sshManager.executeCommandStreaming(command) { [weak self] output in
                    self?.commandOutput.appendOutput(output)
                }
                commandOutput.complete(exitCode: exitCode)

                if exitCode == 0 {
                    await loadPortsTrees()
                }
            } catch {
                if !Task.isCancelled {
                    commandOutput.appendOutput("\n\nError: \(error.localizedDescription)")
                    commandOutput.complete(exitCode: 1)
                    self.error = "Failed to update ports tree: \(error.localizedDescription)"
                }
            }
        }
        commandOutput.setTask(task)
    }

    func deletePortsTree(name: String) async {
        isSettingUp = true
        setupStep = "Deleting ports tree '\(name)'..."
        error = nil

        do {
            _ = try await sshManager.deletePoudrierePortsTree(name: name)
            await loadPortsTrees()
        } catch {
            self.error = "Failed to delete ports tree: \(error.localizedDescription)"
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

// MARK: - Command Output Sheet (Terminal-style)

struct CommandOutputSheet: View {
    let title: String
    @ObservedObject var outputModel: CommandOutputModel
    let onCancel: () -> Void
    let onDismiss: () -> Void

    private var statusIcon: String {
        if outputModel.isCleaningUp {
            return "trash.circle.fill"
        } else if outputModel.isCancelled && outputModel.isComplete {
            return "xmark.circle.fill"
        } else if outputModel.isComplete {
            return outputModel.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
        } else {
            return "terminal.fill"
        }
    }

    private var statusColor: Color {
        if outputModel.isCleaningUp {
            return .orange
        } else if outputModel.isCancelled && outputModel.isComplete {
            return .orange
        } else if outputModel.isComplete {
            return outputModel.exitCode == 0 ? .green : .red
        } else {
            return .blue
        }
    }

    private var statusText: String {
        if outputModel.isCleaningUp {
            return "Cleaning up..."
        } else if outputModel.isCancelled && outputModel.isComplete {
            return "Cancelled"
        } else if outputModel.isComplete {
            return outputModel.exitCode == 0 ? "Completed" : "Failed (exit \(outputModel.exitCode))"
        } else {
            return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                Text(title)
                    .font(.title2)
                    .bold()
                Spacer()
                if outputModel.isComplete || outputModel.isCleaningUp {
                    HStack(spacing: 6) {
                        if outputModel.isCleaningUp {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(statusColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.1))
                    .cornerRadius(4)
                } else {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding()

            Divider()

            // Terminal output
            ScrollViewReader { proxy in
                ScrollView {
                    Text(outputModel.output.isEmpty ? "Waiting for output..." : outputModel.output)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .id("output")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: outputModel.output) { _, _ in
                    withAnimation {
                        proxy.scrollTo("output", anchor: .bottom)
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                if outputModel.isCleaningUp {
                    Text("Cleaning up partial resources...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if !outputModel.isComplete {
                    Text("Running command...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Command finished")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if outputModel.isComplete && !outputModel.isCleaningUp {
                    Button("Close") {
                        onDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else if !outputModel.isCleaningUp {
                    Button("Cancel") {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding()
        }
        .frame(width: 700, height: 500)
    }
}

// MARK: - Command Output Model

@MainActor
class CommandOutputModel: ObservableObject {
    @Published var output: String = ""
    @Published var isComplete: Bool = false
    @Published var exitCode: Int = 0
    @Published var isCancelled: Bool = false
    @Published var isCleaningUp: Bool = false

    private var task: Task<Void, Never>?
    private var cleanupHandler: (() async -> Void)?

    func appendOutput(_ text: String) {
        output += text
    }

    func complete(exitCode: Int) {
        self.exitCode = exitCode
        self.isComplete = true
    }

    func cancel() {
        print("DEBUG: CommandOutputModel.cancel() called")
        isCancelled = true
        task?.cancel()
        print("DEBUG: Task cancelled, cleanupHandler exists: \(cleanupHandler != nil)")

        // Run cleanup if provided
        if let cleanup = cleanupHandler {
            print("DEBUG: Starting cleanup handler")
            isCleaningUp = true
            Task {
                await cleanup()
                print("DEBUG: Cleanup handler completed")
                isCleaningUp = false
                isComplete = true
            }
        } else {
            print("DEBUG: No cleanup handler set")
        }
    }

    func setTask(_ task: Task<Void, Never>) {
        self.task = task
    }

    func setCleanupHandler(_ handler: @escaping () async -> Void) {
        self.cleanupHandler = handler
    }

    func reset() {
        output = ""
        isComplete = false
        exitCode = 0
        isCancelled = false
        isCleaningUp = false
        task = nil
        cleanupHandler = nil
    }
}
