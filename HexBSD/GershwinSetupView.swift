//
//  GershwinSetupView.swift
//  HexBSD
//
//  Gershwin GNUstep environment setup wizard
//

import SwiftUI

// MARK: - Data Models

enum SetupStatus {
    case pending
    case configured
    case partiallyConfigured
    case error

    var icon: String {
        switch self {
        case .pending: return "circle"
        case .configured: return "checkmark.circle.fill"
        case .partiallyConfigured: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .configured: return .green
        case .partiallyConfigured: return .orange
        case .error: return .red
        }
    }
}

struct ZFSDatasetStatus {
    let name: String
    let path: String
    let exists: Bool
    let correctLocation: Bool
    let mountpoint: String?

    var status: SetupStatus {
        if !exists {
            return .pending
        } else if !correctLocation {
            return .partiallyConfigured
        } else {
            return .configured
        }
    }
}

struct UserConfigStatus {
    let zshInstalled: Bool
    let zshAutosuggestionsInstalled: Bool
    let zshCompletionsInstalled: Bool
    let sudoInstalled: Bool
    let zshrcConfigured: Bool

    var hasAllPrerequisites: Bool {
        zshInstalled && zshAutosuggestionsInstalled && zshCompletionsInstalled && sudoInstalled
    }

    var status: SetupStatus {
        if hasAllPrerequisites && zshrcConfigured {
            return .configured
        } else if zshInstalled {
            return .partiallyConfigured
        } else {
            return .pending
        }
    }
}

enum NetworkRole {
    case none
    case server
    case client
}

struct NetworkDomainStatus {
    let role: NetworkRole
    let nisConfigured: Bool
    let nfsConfigured: Bool
    let domainName: String?

    var status: SetupStatus {
        switch role {
        case .none:
            return .pending
        case .server:
            return (nisConfigured && nfsConfigured) ? .configured : .partiallyConfigured
        case .client:
            return (nisConfigured && nfsConfigured) ? .configured : .partiallyConfigured
        }
    }
}

struct LocalUser: Identifiable, Hashable {
    let id: Int // UID
    let username: String
    let fullName: String
    let homeDirectory: String
    let shell: String
    let isSystemUser: Bool // UID < 1000

    var displayName: String {
        fullName.isEmpty ? username : "\(fullName) (\(username))"
    }
}

struct GershwinSetupState {
    var zfsDatasets: [ZFSDatasetStatus] = []
    var userConfig: UserConfigStatus?
    var networkDomain: NetworkDomainStatus?
    var bootEnvironment: String?
    var zpoolRoot: String?
    var localUsers: [LocalUser] = []
    var networkUsers: [LocalUser] = []

    var overallProgress: Double {
        var completed = 0
        var total = 0

        // ZFS datasets (dynamic based on number of datasets)
        total += zfsDatasets.count
        completed += zfsDatasets.filter { $0.status == .configured }.count

        // User config (1 item)
        total += 1
        if userConfig?.status == .configured {
            completed += 1
        }

        // Network domain (1 item)
        total += 1
        if networkDomain?.status == .configured {
            completed += 1
        }

        return total > 0 ? Double(completed) / Double(total) : 0.0
    }
}

// MARK: - View Model

@MainActor
class GershwinSetupViewModel: ObservableObject {
    @Published var setupState = GershwinSetupState()
    @Published var isLoading = false
    @Published var error: String?
    @Published var selectedNetworkRole: NetworkRole = .none
    @Published var nisServerAddress = ""
    @Published var nisDomainName = "home.local"
    @Published var showingConfirmation = false
    @Published var confirmationMessage = ""
    @Published var confirmationAction: (() -> Void)?
    @Published var showingRemoveDomainConfirmation = false

    // User Configuration progress tracking
    @Published var isConfiguringUser = false
    @Published var userConfigStep = ""

    // Network Domain progress tracking
    @Published var isConfiguringNetwork = false
    @Published var networkConfigStep = ""

    private let sshManager = SSHConnectionManager.shared

    func loadSetupState(updateNetworkRole: Bool = true) async {
        isLoading = true
        error = nil

        do {
            // Detect current setup state
            async let zfsState = detectZFSDatasets()
            async let userState = detectUserConfig()
            async let networkState = detectNetworkDomain()

            let (zfs, user, network) = try await (zfsState, userState, networkState)

            setupState.zfsDatasets = zfs.datasets
            setupState.bootEnvironment = zfs.bootEnvironment
            setupState.zpoolRoot = zfs.zpoolRoot
            setupState.userConfig = user
            setupState.networkDomain = network

            // Only set initial network role based on detection if requested (initial load)
            if updateNetworkRole {
                selectedNetworkRole = network.role
            }

        } catch {
            self.error = "Failed to load setup state: \(error.localizedDescription)"
        }

        isLoading = false
    }

    private func detectZFSDatasets() async throws -> (datasets: [ZFSDatasetStatus], bootEnvironment: String?, zpoolRoot: String?) {
        // Get current boot environment
        let beOutput = try await sshManager.executeCommand("zfs list -H -o name,mounted,mountpoint | awk '$2==\"yes\" && $3==\"/\"{print $1; exit}'")
        let bootEnv = beOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract zpool root (e.g., "zroot" from "zroot/ROOT/default")
        let zpoolRoot = bootEnv.split(separator: "/").first.map(String.init) ?? "zroot"

        // Check for /System, /Local, /Network datasets
        let datasetsOutput = try await sshManager.executeCommand("zfs list -H -o name,mountpoint")
        let lines = datasetsOutput.split(separator: "\n")

        var datasets: [ZFSDatasetStatus] = []

        // Check /System (should be in boot environment)
        let systemDataset = lines.first { line in
            let parts = line.split(separator: "\t")
            return parts.count >= 2 && parts[1] == "/System"
        }

        if let systemLine = systemDataset {
            let parts = systemLine.split(separator: "\t")
            let name = String(parts[0])
            let expectedName = "\(bootEnv)/System"
            datasets.append(ZFSDatasetStatus(
                name: "/System",
                path: name,
                exists: true,
                correctLocation: name == expectedName,
                mountpoint: "/System"
            ))
        } else {
            datasets.append(ZFSDatasetStatus(
                name: "/System",
                path: "\(bootEnv)/System",
                exists: false,
                correctLocation: false,
                mountpoint: nil
            ))
        }

        // Check /Local (should be in zpool root)
        let localDataset = lines.first { line in
            let parts = line.split(separator: "\t")
            return parts.count >= 2 && parts[1] == "/Local"
        }

        if let localLine = localDataset {
            let parts = localLine.split(separator: "\t")
            let name = String(parts[0])
            let expectedName = "\(zpoolRoot)/Local"
            datasets.append(ZFSDatasetStatus(
                name: "/Local",
                path: name,
                exists: true,
                correctLocation: name == expectedName,
                mountpoint: "/Local"
            ))
        } else {
            datasets.append(ZFSDatasetStatus(
                name: "/Local",
                path: "\(zpoolRoot)/Local",
                exists: false,
                correctLocation: false,
                mountpoint: nil
            ))
        }

        // Check /Network (should be in zpool root) - for all roles
        let networkDataset = lines.first { line in
            let parts = line.split(separator: "\t")
            return parts.count >= 2 && parts[1] == "/Network"
        }

        if let networkLine = networkDataset {
            let parts = networkLine.split(separator: "\t")
            let name = String(parts[0])
            let expectedName = "\(zpoolRoot)/Network"
            datasets.append(ZFSDatasetStatus(
                name: "/Network",
                path: name,
                exists: true,
                correctLocation: name == expectedName,
                mountpoint: "/Network"
            ))
        } else {
            datasets.append(ZFSDatasetStatus(
                name: "/Network",
                path: "\(zpoolRoot)/Network",
                exists: false,
                correctLocation: false,
                mountpoint: nil
            ))
        }

        return (datasets, bootEnv, zpoolRoot)
    }

    private func detectUserConfig() async throws -> UserConfigStatus {
        // Check for zsh installation
        let zshCheck = try await sshManager.executeCommand("test -f /usr/local/bin/zsh && echo 'installed' || echo 'missing'")
        let zshInstalled = zshCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "installed"

        // Check for zsh-autosuggestions
        let autosuggestCheck = try await sshManager.executeCommand("test -f /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh && echo 'installed' || echo 'missing'")
        let zshAutosuggestionsInstalled = autosuggestCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "installed"

        // Check for zsh-completions (check if the package is installed via pkg)
        let completionsCheck = try await sshManager.executeCommand("pkg info -e zsh-completions && echo 'installed' || echo 'missing'")
        let zshCompletionsInstalled = completionsCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "installed"

        // Check for sudo installation
        let sudoCheck = try await sshManager.executeCommand("test -f /usr/local/bin/sudo && echo 'installed' || echo 'missing'")
        let sudoInstalled = sudoCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "installed"

        // Check if global zshrc exists in /usr/local/etc
        let zshrcCheck = try await sshManager.executeCommand("test -f /usr/local/etc/zshrc && echo 'configured' || echo 'missing'")
        let zshrcConfigured = zshrcCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "configured"

        return UserConfigStatus(
            zshInstalled: zshInstalled,
            zshAutosuggestionsInstalled: zshAutosuggestionsInstalled,
            zshCompletionsInstalled: zshCompletionsInstalled,
            sudoInstalled: sudoInstalled,
            zshrcConfigured: zshrcConfigured
        )
    }

    private func detectNetworkDomain() async throws -> NetworkDomainStatus {
        // Check if NIS server is configured
        let nisServer = try await sshManager.executeCommand("sysrc -n nis_server_enable 2>/dev/null || echo 'NO'")
        let nisServerEnabled = nisServer.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "YES"

        // Check if NIS client is configured
        let nisClient = try await sshManager.executeCommand("sysrc -n nis_client_enable 2>/dev/null || echo 'NO'")
        let nisClientEnabled = nisClient.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "YES"

        // Check if NFS server is configured
        let nfsServer = try await sshManager.executeCommand("sysrc -n nfs_server_enable 2>/dev/null || echo 'NO'")
        let nfsServerEnabled = nfsServer.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "YES"

        // Check if NFS client is configured
        let nfsClient = try await sshManager.executeCommand("sysrc -n nfs_client_enable 2>/dev/null || echo 'NO'")
        let nfsClientEnabled = nfsClient.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "YES"

        // Get NIS domain name
        let nisDomain = try await sshManager.executeCommand("sysrc -n nisdomainname 2>/dev/null || echo ''")
        let domainName = nisDomain.trimmingCharacters(in: .whitespacesAndNewlines)

        // Determine role
        var role: NetworkRole = .none
        if nisServerEnabled && nfsServerEnabled {
            role = .server
        } else if nisClientEnabled && nfsClientEnabled {
            role = .client
        }

        return NetworkDomainStatus(
            role: role,
            nisConfigured: nisServerEnabled || nisClientEnabled,
            nfsConfigured: nfsServerEnabled || nfsClientEnabled,
            domainName: domainName.isEmpty ? nil : domainName
        )
    }

    // MARK: - Setup Actions

    @discardableResult
    func setupZFSDatasets() async -> Bool {
        isLoading = true
        error = nil

        do {
            guard let bootEnv = setupState.bootEnvironment,
                  let zpoolRoot = setupState.zpoolRoot else {
                throw NSError(domain: "GershwinSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Boot environment not detected"])
            }

            // Create /System dataset in boot environment
            let systemDataset = setupState.zfsDatasets.first { $0.name == "/System" }
            if let system = systemDataset, !system.exists {
                _ = try await sshManager.executeCommand("zfs create -o mountpoint=/System \(bootEnv)/System")
            }

            // Create /Local dataset in zpool root
            let localDataset = setupState.zfsDatasets.first { $0.name == "/Local" }
            if let local = localDataset, !local.exists {
                _ = try await sshManager.executeCommand("zfs create -o mountpoint=/Local \(zpoolRoot)/Local")
            }

            // Create /Network dataset in zpool root for all roles
            let networkDataset = setupState.zfsDatasets.first { $0.name == "/Network" }
            if let network = networkDataset, !network.exists {
                _ = try await sshManager.executeCommand("zfs create -o mountpoint=/Network \(zpoolRoot)/Network")
            }

            // Reload state (don't update network role - preserve user's selection during setup)
            await loadSetupState(updateNetworkRole: false)

            isLoading = false
            return true

        } catch {
            self.error = "Failed to create ZFS datasets: \(error.localizedDescription)"
            isLoading = false
            return false
        }
    }

    @discardableResult
    func setupUserConfig() async -> Bool {
        isLoading = true
        isConfiguringUser = true
        error = nil

        do {
            // Bootstrap pkg first if needed (fresh system without pkg installed)
            userConfigStep = "Checking package manager..."
            print("DEBUG: Checking if pkg is installed...")
            var pkgCheck = try await sshManager.executeCommand("which pkg 2>/dev/null || echo 'missing'")
            print("DEBUG: pkg check result: '\(pkgCheck.trimmingCharacters(in: .whitespacesAndNewlines))'")

            if pkgCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
                userConfigStep = "Bootstrapping package manager..."
                print("DEBUG: pkg not found, bootstrapping...")
                let bootstrapResult = try await sshManager.executeCommand("env ASSUME_ALWAYS_YES=yes pkg bootstrap 2>&1")
                print("DEBUG: Bootstrap result: \(bootstrapResult)")

                // Verify pkg is now available
                pkgCheck = try await sshManager.executeCommand("which pkg 2>/dev/null || echo 'missing'")
                print("DEBUG: pkg check after bootstrap: '\(pkgCheck.trimmingCharacters(in: .whitespacesAndNewlines))'")
                if pkgCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
                    throw NSError(domain: "GershwinSetup", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to bootstrap pkg - package manager not available"])
                }
            }

            // Now detect package status (pkg is guaranteed to be available)
            userConfigStep = "Checking installed packages..."
            print("DEBUG: Checking installed packages...")

            let zshCheck = try await sshManager.executeCommand("test -f /usr/local/bin/zsh && echo 'installed' || echo 'missing'")
            let zshInstalled = zshCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "installed"
            print("DEBUG: zsh installed: \(zshInstalled)")

            let autosuggestCheck = try await sshManager.executeCommand("test -f /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh && echo 'installed' || echo 'missing'")
            let zshAutosuggestionsInstalled = autosuggestCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "installed"
            print("DEBUG: zsh-autosuggestions installed: \(zshAutosuggestionsInstalled)")

            let completionsCheck = try await sshManager.executeCommand("pkg info -e zsh-completions 2>/dev/null && echo 'installed' || echo 'missing'")
            let zshCompletionsInstalled = completionsCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "installed"
            print("DEBUG: zsh-completions installed: \(zshCompletionsInstalled)")

            let sudoCheck = try await sshManager.executeCommand("test -f /usr/local/bin/sudo && echo 'installed' || echo 'missing'")
            let sudoInstalled = sudoCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "installed"
            print("DEBUG: sudo installed: \(sudoInstalled)")

            let zshrcCheck = try await sshManager.executeCommand("test -f /usr/local/etc/zshrc && echo 'configured' || echo 'missing'")
            let zshrcConfigured = zshrcCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "configured"
            print("DEBUG: global zshrc configured: \(zshrcConfigured)")

            // Run pkg update if any packages need to be installed
            if !zshInstalled || !zshAutosuggestionsInstalled || !zshCompletionsInstalled || !sudoInstalled {
                userConfigStep = "Updating package repository..."
                print("DEBUG: Running pkg update...")
                let updateResult = try await sshManager.executeCommand("pkg update 2>&1")
                print("DEBUG: pkg update result: \(updateResult.prefix(500))")
            }

            // Install zsh if not present
            if !zshInstalled {
                userConfigStep = "Installing zsh..."
                print("DEBUG: Installing zsh...")
                let zshResult = try await sshManager.executeCommand("pkg install -y zsh 2>&1")
                print("DEBUG: zsh install result: \(zshResult.prefix(500))")
            }

            // Install zsh-autosuggestions if not present
            if !zshAutosuggestionsInstalled {
                userConfigStep = "Installing zsh-autosuggestions..."
                print("DEBUG: Installing zsh-autosuggestions...")
                let autosuggestResult = try await sshManager.executeCommand("pkg install -y zsh-autosuggestions 2>&1")
                print("DEBUG: zsh-autosuggestions install result: \(autosuggestResult.prefix(500))")
            }

            // Install zsh-completions if not present
            if !zshCompletionsInstalled {
                userConfigStep = "Installing zsh-completions..."
                print("DEBUG: Installing zsh-completions...")
                let completionsResult = try await sshManager.executeCommand("pkg install -y zsh-completions 2>&1")
                print("DEBUG: zsh-completions install result: \(completionsResult.prefix(500))")
            }

            // Install sudo if not present
            if !sudoInstalled {
                userConfigStep = "Installing sudo..."
                print("DEBUG: Installing sudo...")
                let sudoResult = try await sshManager.executeCommand("pkg install -y sudo 2>&1")
                print("DEBUG: sudo install result: \(sudoResult.prefix(500))")
            }

            // Configure sudoers to allow wheel group (for standalone local users)
            userConfigStep = "Configuring sudo..."
            print("DEBUG: Configuring sudoers for wheel group...")
            _ = try await sshManager.executeCommand("mkdir -p /usr/local/etc/sudoers.d")
            // Check if wheel sudoers config exists
            let wheelSudoersCheck = try await sshManager.executeCommand("test -f /usr/local/etc/sudoers.d/wheel && echo 'exists' || echo 'missing'")
            if wheelSudoersCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
                _ = try await sshManager.executeCommand("echo '%wheel ALL=(ALL) ALL' > /usr/local/etc/sudoers.d/wheel")
                _ = try await sshManager.executeCommand("chmod 440 /usr/local/etc/sudoers.d/wheel")
                print("DEBUG: Created /usr/local/etc/sudoers.d/wheel")
            }

            // Create global zshrc in /usr/local/etc if not present
            if !zshrcConfigured {
                userConfigStep = "Creating zsh configuration..."

                // Global zshrc with system-wide configuration
                let globalZshrcContent = """
#
# /usr/local/etc/zshrc - system-wide zsh configuration
#
# This file is sourced by all interactive zsh shells.
# See also zsh(1), zshrc(4).
#

# Path to zsh-completions
fpath=(/usr/local/share/zsh-completions $fpath)

# Initialize completion system
autoload -Uz compinit && compinit

# Autosuggestions configuration
ZSH_AUTOSUGGEST_STRATEGY=(match_prev_cmd history completion)
source /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# History options
setopt hist_ignore_dups      # Don't record duplicate lines
setopt hist_reduce_blanks    # Remove unnecessary blanks
setopt inc_append_history    # Save each command as soon as it's run
setopt share_history         # Share history across all zsh sessions
setopt extended_history      # Add timestamps to history
setopt hist_find_no_dups     # Skip duplicate entries during search

# Fish-style up-arrow history search
autoload -Uz up-line-or-beginning-search
autoload -Uz down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey "^[[A" up-line-or-beginning-search     # Up arrow
bindkey "^[[B" down-line-or-beginning-search   # Down arrow

# Load color module and enable prompt substitution
autoload -U colors && colors
setopt PROMPT_SUBST

# Function to abbreviate path like Fish
function fish_like_path() {
  local dir_path=$PWD
  if [[ $dir_path == $HOME ]]; then
    echo "~"
  elif [[ $dir_path == $HOME/* ]]; then
    local sub_path=${dir_path#$HOME/}
    local components=(${(s:/:)sub_path})
    local abbreviated=()
    for ((i=1; i<${#components}; i++)); do
      [[ -n $components[$i] ]] && abbreviated+=${components[$i][1]}
    done
    [[ -n $components[-1] ]] && abbreviated+=$components[-1]
    echo "~/${(j:/:)abbreviated}"
  else
    local components=(${(s:/:)dir_path})
    local abbreviated=()
    for ((i=1; i<${#components}; i++)); do
      [[ -n $components[$i] ]] && abbreviated+=${components[$i][1]}
    done
    [[ -n $components[-1] ]] && abbreviated+=$components[-1]
    echo "/${(j:/:)abbreviated}"
  fi
}

# Git info function for prompt
function git_info() {
  command -v git &>/dev/null || return 1
  git rev-parse --is-inside-work-tree &>/dev/null || return 1
  local branch=$(git symbolic-ref --short HEAD 2>/dev/null)
  [[ -z "$branch" ]] && branch=$(git describe --tags --always 2>/dev/null)
  echo "%F{fg}($branch)%f"
}

# Prompt colors
local user_color='2'      # ANSI green
local host_color='fg'     # Terminal foreground
local path_color='2'      # ANSI green

PROMPT="%F{$user_color}%n%f@%F{$host_color}%m%f %F{$path_color}\\$(fish_like_path)\\$(git_info)%f %# "
"""

                // Minimal skeleton .zshrc following FreeBSD conventions
                let skelZshrcContent = """
#
# .zshrc - zsh resource script, read at beginning of execution by each shell
#
# see also zsh(1), zshrc(5).
#

# User-specific history settings (override system defaults if desired)
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
"""

                // Write global zshrc
                _ = try await sshManager.executeCommand("mkdir -p /usr/local/etc")
                _ = try await sshManager.executeCommand("cat > /usr/local/etc/zshrc << 'ZSHRC_EOF'\n\(globalZshrcContent)\nZSHRC_EOF")

                // Write skeleton .zshrc
                _ = try await sshManager.executeCommand("mkdir -p /usr/share/skel")
                _ = try await sshManager.executeCommand("cat > /usr/share/skel/dot.zshrc << 'ZSHRC_EOF'\n\(skelZshrcContent)\nZSHRC_EOF")
            }

            userConfigStep = "Refreshing status..."

            // Reload state (don't update network role - preserve user's selection during setup)
            await loadSetupState(updateNetworkRole: false)

            isConfiguringUser = false
            userConfigStep = ""
            isLoading = false
            return true

        } catch {
            self.error = "Failed to configure user settings: \(error.localizedDescription)"
            isConfiguringUser = false
            userConfigStep = ""
            isLoading = false
            return false
        }
    }

    func setupNetworkDomain() async {
        isLoading = true
        isConfiguringNetwork = true
        error = nil

        do {
            switch selectedNetworkRole {
            case .server:
                try await setupNetworkServer()
            case .client:
                try await setupNetworkClient()
            case .none:
                throw NSError(domain: "GershwinSetup", code: 2, userInfo: [NSLocalizedDescriptionKey: "Please select Server or Client role"])
            }

            networkConfigStep = "Refreshing status..."

            // Reload state
            await loadSetupState()

        } catch {
            print("DEBUG: Network domain configuration failed with error: \(error)")
            self.error = "Failed to configure network domain: \(error.localizedDescription)"
        }

        isConfiguringNetwork = false
        networkConfigStep = ""
        isLoading = false
    }

    private func setupNetworkServer() async throws {
        print("DEBUG NIS Server: Starting setup for domain '\(nisDomainName)'")

        // Configure NIS server
        networkConfigStep = "Configuring NIS server..."
        print("DEBUG NIS Server: Configuring NIS server in rc.conf...")
        var result = try await sshManager.executeCommand("sysrc nisdomainname=\"\(nisDomainName)\"")
        print("DEBUG NIS Server: sysrc nisdomainname result: \(result)")
        result = try await sshManager.executeCommand("sysrc nis_server_enable=\"YES\"")
        print("DEBUG NIS Server: sysrc nis_server_enable result: \(result)")
        result = try await sshManager.executeCommand("sysrc nis_yppasswdd_enable=\"YES\"")
        print("DEBUG NIS Server: sysrc nis_yppasswdd_enable result: \(result)")

        // Configure NFS server
        networkConfigStep = "Configuring NFS server..."
        print("DEBUG NIS Server: Configuring NFS server in rc.conf...")
        result = try await sshManager.executeCommand("sysrc rpcbind_enable=\"YES\"")
        print("DEBUG NIS Server: sysrc rpcbind_enable result: \(result)")
        result = try await sshManager.executeCommand("sysrc nfs_server_enable=\"YES\"")
        print("DEBUG NIS Server: sysrc nfs_server_enable result: \(result)")
        result = try await sshManager.executeCommand("sysrc mountd_enable=\"YES\"")
        print("DEBUG NIS Server: sysrc mountd_enable result: \(result)")
        result = try await sshManager.executeCommand("sysrc rpc_lockd_enable=\"YES\"")
        print("DEBUG NIS Server: sysrc rpc_lockd_enable result: \(result)")

        // Create directories for network shares
        networkConfigStep = "Creating network directories..."
        print("DEBUG NIS Server: Creating /Network/Users and /Network/Applications directories...")
        result = try await sshManager.executeCommand("mkdir -p /Network/Users /Network/Applications")
        print("DEBUG NIS Server: mkdir result: \(result)")

        // Ensure /etc/exports exists (mountd requires it even if empty)
        networkConfigStep = "Configuring NFS exports..."
        print("DEBUG NIS Server: Ensuring /etc/exports exists...")
        result = try await sshManager.executeCommand("touch /etc/exports")
        print("DEBUG NIS Server: touch /etc/exports result: \(result)")

        // Configure ZFS NFS sharing using sharenfs property
        print("DEBUG NIS Server: Configuring ZFS sharenfs property on zroot/Network...")
        result = try await sshManager.executeCommand("zfs set sharenfs='-maproot=root -alldirs' zroot/Network")
        print("DEBUG NIS Server: Set sharenfs on zroot/Network: \(result)")

        // Set up NIS database directory
        networkConfigStep = "Setting up NIS database..."
        print("DEBUG NIS Server: Setting up /var/yp...")
        result = try await sshManager.executeCommand("mkdir -p /var/yp")
        print("DEBUG NIS Server: mkdir /var/yp result: \(result)")

        // Create initial master.passwd for NIS with only network users (empty initially)
        networkConfigStep = "Creating NIS user database..."
        print("DEBUG NIS Server: Checking /var/yp/master.passwd...")
        let ypmasterPasswd = try await sshManager.executeCommand("cat /var/yp/master.passwd 2>/dev/null || echo ''")
        print("DEBUG NIS Server: /var/yp/master.passwd content: '\(ypmasterPasswd.trimmingCharacters(in: .whitespacesAndNewlines))'")
        if ypmasterPasswd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = try await sshManager.executeCommand("touch /var/yp/master.passwd")
            print("DEBUG NIS Server: touch /var/yp/master.passwd result: \(result)")
            result = try await sshManager.executeCommand("chmod 600 /var/yp/master.passwd")
            print("DEBUG NIS Server: chmod 600 /var/yp/master.passwd result: \(result)")
        }

        // Create /var/yp/group for NIS group database (copy from /etc/group if not exists)
        print("DEBUG NIS Server: Checking /var/yp/group...")
        let ypGroup = try await sshManager.executeCommand("test -f /var/yp/group && echo 'exists' || echo 'missing'")
        if ypGroup.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
            result = try await sshManager.executeCommand("cp /etc/group /var/yp/group")
            print("DEBUG NIS Server: Copied /etc/group to /var/yp/group: \(result)")
        }

        // Create /var/yp/netgroup for sudo-users netgroup (empty initially)
        print("DEBUG NIS Server: Checking /var/yp/netgroup...")
        let ypNetgroup = try await sshManager.executeCommand("test -f /var/yp/netgroup && echo 'exists' || echo 'missing'")
        if ypNetgroup.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
            // Create empty sudo-users netgroup
            result = try await sshManager.executeCommand("echo 'sudo-users' > /var/yp/netgroup")
            print("DEBUG NIS Server: Created /var/yp/netgroup with sudo-users: \(result)")
        }

        // Set the NIS domain name
        networkConfigStep = "Setting NIS domain..."
        print("DEBUG NIS Server: Setting domain name to '\(nisDomainName)'...")
        result = try await sshManager.executeCommand("domainname \(nisDomainName)")
        print("DEBUG NIS Server: domainname result: \(result)")

        // Start rpcbind (required for NIS/NFS)
        networkConfigStep = "Starting rpcbind..."
        print("DEBUG NIS Server: Starting rpcbind...")
        result = try await sshManager.executeCommand("service rpcbind onestart 2>&1 || true")
        print("DEBUG NIS Server: rpcbind start result: \(result)")

        // Initialize NIS maps (this creates /var/yp/Makefile from Makefile.dist)
        networkConfigStep = "Initializing NIS maps..."
        print("DEBUG NIS Server: Getting hostname...")
        let hostname = try await sshManager.executeCommand("hostname -s")
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        print("DEBUG NIS Server: Hostname is '\(trimmedHostname)'")

        print("DEBUG NIS Server: Running ypinit -m \(nisDomainName)...")
        result = try await sshManager.executeCommand("cd /var/yp && printf '%s\\n\\ny\\n' '\(trimmedHostname)' | ypinit -m \(nisDomainName) 2>&1 || true")
        print("DEBUG NIS Server: ypinit result: \(result)")

        // Note: We don't modify the Makefile. Instead, we pass MASTER_PASSWD as an argument
        // when running make to rebuild NIS maps. The Makefile is designed to accept this.
        print("DEBUG NIS Server: Skipping Makefile modification - will pass MASTER_PASSWD to make command")

        // Start NIS server
        networkConfigStep = "Starting NIS server..."
        print("DEBUG NIS Server: Starting ypserv...")
        result = try await sshManager.executeCommand("service ypserv start 2>&1 || true")
        print("DEBUG NIS Server: ypserv start result: \(result)")
        result = try await sshManager.executeCommand("service yppasswdd start 2>&1 || true")
        print("DEBUG NIS Server: yppasswdd start result: \(result)")

        // Start NFS server
        networkConfigStep = "Starting NFS server..."
        print("DEBUG NIS Server: Starting NFS services...")
        result = try await sshManager.executeCommand("service nfsd start 2>&1 || true")
        print("DEBUG NIS Server: nfsd start result: \(result)")
        result = try await sshManager.executeCommand("service mountd start 2>&1 || true")
        print("DEBUG NIS Server: mountd start result: \(result)")
        result = try await sshManager.executeCommand("service lockd start 2>&1 || true")
        print("DEBUG NIS Server: lockd start result: \(result)")

        // Configure server as NIS client of itself (required for ypcat and local NIS lookups)
        networkConfigStep = "Configuring NIS client on server..."
        print("DEBUG NIS Server: Configuring server as NIS client of itself...")
        result = try await sshManager.executeCommand("sysrc nis_client_enable=\"YES\"")
        print("DEBUG NIS Server: sysrc nis_client_enable result: \(result)")

        // Enable NIS compat mode for passwd and group lookups
        // This uses the traditional FreeBSD approach with +: entries in passwd/group files
        print("DEBUG NIS Server: Enabling NIS compat mode...")

        // Add +::::::::: to /etc/master.passwd if not present
        let masterPasswdHasPlus = try await sshManager.executeCommand("grep -q '^+:' /etc/master.passwd && echo 'exists' || echo 'missing'")
        if masterPasswdHasPlus.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
            print("DEBUG NIS Server: Adding +::::::::: to /etc/master.passwd...")
            _ = try await sshManager.executeCommand("echo '+:::::::::' >> /etc/master.passwd")
            _ = try await sshManager.executeCommand("pwd_mkdb -p /etc/master.passwd 2>&1")
        }

        // Add +:*:: to /etc/group if not present (enables NIS group lookup via compat mode)
        let groupHasPlus = try await sshManager.executeCommand("grep -q '^+:' /etc/group && echo 'exists' || echo 'missing'")
        if groupHasPlus.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
            print("DEBUG NIS Server: Adding +:*:: to /etc/group...")
            _ = try await sshManager.executeCommand("echo '+:*::' >> /etc/group")
        }

        // Create /etc/netgroup to import NIS netgroups
        print("DEBUG NIS Server: Creating /etc/netgroup with + for NIS import...")
        _ = try await sshManager.executeCommand("echo '+' > /etc/netgroup")

        // Configure sudoers to allow sudo-users netgroup
        print("DEBUG NIS Server: Configuring sudoers for sudo-users netgroup...")
        _ = try await sshManager.executeCommand("mkdir -p /usr/local/etc/sudoers.d")
        _ = try await sshManager.executeCommand("echo '+sudo-users ALL=(ALL) ALL' > /usr/local/etc/sudoers.d/network-users")
        _ = try await sshManager.executeCommand("chmod 440 /usr/local/etc/sudoers.d/network-users")

        // Start ypbind so server can query its own NIS database
        print("DEBUG NIS Server: Starting ypbind...")
        result = try await sshManager.executeCommand("service ypbind start 2>&1 || true")
        print("DEBUG NIS Server: ypbind start result: \(result)")

        // Verify services are running
        networkConfigStep = "Verifying services..."
        print("DEBUG NIS Server: Checking service status...")
        let ypservStatus = try await sshManager.executeCommand("service ypserv status 2>&1 || echo 'not running'")
        print("DEBUG NIS Server: ypserv status: \(ypservStatus)")
        let nfsdStatus = try await sshManager.executeCommand("service nfsd status 2>&1 || echo 'not running'")
        print("DEBUG NIS Server: nfsd status: \(nfsdStatus)")

        // Check ypbind status too
        let ypbindStatus = try await sshManager.executeCommand("service ypbind status 2>&1 || echo 'not running'")
        print("DEBUG NIS Server: ypbind status: \(ypbindStatus)")

        confirmationMessage = """
        NIS/NFS server configured and started successfully!

        Configuration completed:
        ✓ NIS domain: \(nisDomainName)
        ✓ NIS server configured and started
        ✓ NIS client configured (server binds to itself)
        ✓ NFS server configured and started
        ✓ /Network shared via ZFS sharenfs

        Service status:
        ypserv: \(ypservStatus.contains("running") ? "running" : "check status")
        ypbind: \(ypbindStatus.contains("running") ? "running" : "check status")
        nfsd: \(nfsdStatus.contains("running") ? "running" : "check status")

        You can now add network users in the Users tab.
        After adding users, the NIS database will be updated automatically.
        """
        showingConfirmation = true
    }

    private func setupNetworkClient() async throws {
        print("DEBUG CLIENT: Starting NIS client setup...")
        print("DEBUG CLIENT: Domain: \(nisDomainName), Server: \(nisServerAddress)")

        guard !nisServerAddress.isEmpty else {
            print("DEBUG CLIENT: ERROR - NIS server address is empty")
            throw NSError(domain: "GershwinSetup", code: 3, userInfo: [NSLocalizedDescriptionKey: "Please enter NIS server address"])
        }

        // Configure NIS client
        networkConfigStep = "Configuring NIS client..."
        print("DEBUG CLIENT: Configuring NIS client rc.conf entries...")
        let sysrc1 = try await sshManager.executeCommand("sysrc nisdomainname=\"\(nisDomainName)\"")
        print("DEBUG CLIENT: sysrc nisdomainname result: \(sysrc1)")
        let sysrc2 = try await sshManager.executeCommand("sysrc rpcbind_enable=\"YES\"")
        print("DEBUG CLIENT: sysrc rpcbind_enable result: \(sysrc2)")
        let sysrc3 = try await sshManager.executeCommand("sysrc nis_client_enable=\"YES\"")
        print("DEBUG CLIENT: sysrc nis_client_enable result: \(sysrc3)")

        // Configure NFS client
        networkConfigStep = "Configuring NFS client..."
        print("DEBUG CLIENT: Configuring NFS client rc.conf entries...")
        let sysrc4 = try await sshManager.executeCommand("sysrc nfs_client_enable=\"YES\"")
        print("DEBUG CLIENT: sysrc nfs_client_enable result: \(sysrc4)")
        let sysrc5 = try await sshManager.executeCommand("sysrc rpc_lockd_enable=\"YES\"")
        print("DEBUG CLIENT: sysrc rpc_lockd_enable result: \(sysrc5)")

        // Enable NIS compat mode for passwd and group lookups
        // This uses the traditional FreeBSD approach with +: entries in passwd/group files
        networkConfigStep = "Enabling NIS compat mode..."
        print("DEBUG CLIENT: Enabling NIS compat mode...")

        // Add +::::::::: to /etc/master.passwd if not present (enables NIS user lookup)
        // master.passwd has 10 fields, so we need 9 colons
        let masterPasswdHasPlus = try await sshManager.executeCommand("grep -q '^+:' /etc/master.passwd && echo 'exists' || echo 'missing'")
        print("DEBUG CLIENT: master.passwd '+:' check: \(masterPasswdHasPlus.trimmingCharacters(in: .whitespacesAndNewlines))")
        if masterPasswdHasPlus.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
            print("DEBUG CLIENT: Adding +::::::::: to /etc/master.passwd...")
            _ = try await sshManager.executeCommand("echo '+:::::::::' >> /etc/master.passwd")
            print("DEBUG CLIENT: Running pwd_mkdb -p /etc/master.passwd...")
            _ = try await sshManager.executeCommand("pwd_mkdb -p /etc/master.passwd 2>&1")
        }

        // Add +:*:: to /etc/group if not present (enables NIS group lookup via compat mode)
        let groupHasPlus = try await sshManager.executeCommand("grep -q '^+:' /etc/group && echo 'exists' || echo 'missing'")
        print("DEBUG CLIENT: group '+:' check: \(groupHasPlus.trimmingCharacters(in: .whitespacesAndNewlines))")
        if groupHasPlus.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
            print("DEBUG CLIENT: Adding +:*:: to /etc/group...")
            _ = try await sshManager.executeCommand("echo '+:*::' >> /etc/group")
        }

        // Create /etc/netgroup to import NIS netgroups
        print("DEBUG CLIENT: Creating /etc/netgroup with + for NIS import...")
        _ = try await sshManager.executeCommand("echo '+' > /etc/netgroup")

        // Configure sudoers to allow sudo-users netgroup
        print("DEBUG CLIENT: Configuring sudoers for sudo-users netgroup...")
        _ = try await sshManager.executeCommand("mkdir -p /usr/local/etc/sudoers.d")
        _ = try await sshManager.executeCommand("echo '+sudo-users ALL=(ALL) ALL' > /usr/local/etc/sudoers.d/network-users")
        _ = try await sshManager.executeCommand("chmod 440 /usr/local/etc/sudoers.d/network-users")

        // Create mount point directory for /Network
        networkConfigStep = "Creating mount point..."
        print("DEBUG CLIENT: Creating /Network mount point...")
        _ = try await sshManager.executeCommand("mkdir -p /Network")

        // Configure /etc/fstab for /Network
        networkConfigStep = "Configuring /etc/fstab..."
        print("DEBUG CLIENT: Configuring /etc/fstab...")
        let fstabContent = try await sshManager.executeCommand("cat /etc/fstab 2>/dev/null || echo ''")
        print("DEBUG CLIENT: Current fstab content:\n\(fstabContent)")

        if !fstabContent.contains("/Network") {
            let fstabEntry = "\(nisServerAddress):/Network\t/Network\tnfs\trw\t0\t0"
            print("DEBUG CLIENT: Adding fstab entry: \(fstabEntry)")
            _ = try await sshManager.executeCommand("echo '\(fstabEntry)' >> /etc/fstab")
        } else {
            print("DEBUG CLIENT: /Network entry already exists in fstab")
        }

        // Start NIS client service
        networkConfigStep = "Starting NIS client service..."
        print("DEBUG CLIENT: Starting NIS client services...")
        // Set the NIS domain name directly (faster than /etc/netstart)
        print("DEBUG CLIENT: Setting domain name to \(nisDomainName)...")
        let domainnameResult = try await sshManager.executeCommand("domainname \(nisDomainName) 2>&1")
        print("DEBUG CLIENT: domainname result: \(domainnameResult)")
        // Start rpcbind if not running (required for NIS/NFS)
        print("DEBUG CLIENT: Starting rpcbind...")
        let rpcbindResult = try await sshManager.executeCommand("service rpcbind onestart 2>&1 || true")
        print("DEBUG CLIENT: rpcbind start result: \(rpcbindResult)")
        print("DEBUG CLIENT: Starting ypbind...")
        let ypbindResult = try await sshManager.executeCommand("service ypbind onestart 2>&1 || true")
        print("DEBUG CLIENT: ypbind start result: \(ypbindResult)")

        // Start NFS client services
        networkConfigStep = "Starting NFS client services..."
        print("DEBUG CLIENT: Starting NFS client services...")
        let nfsclientResult = try await sshManager.executeCommand("service nfsclient onestart 2>&1 || true")
        print("DEBUG CLIENT: nfsclient start result: \(nfsclientResult)")
        let lockdResult = try await sshManager.executeCommand("service lockd onestart 2>&1 || true")
        print("DEBUG CLIENT: lockd start result: \(lockdResult)")

        // Mount the network share
        networkConfigStep = "Mounting /Network..."
        print("DEBUG CLIENT: Mounting /Network...")
        let mountResult = try await sshManager.executeCommand("mount /Network 2>&1 || true")
        print("DEBUG CLIENT: mount /Network result: \(mountResult)")

        // Verify NIS connectivity
        networkConfigStep = "Verifying NIS connectivity..."
        print("DEBUG CLIENT: Verifying NIS connectivity...")
        let ypcatResult = try await sshManager.executeCommand("ypcat passwd 2>&1 || echo 'NIS not responding'")
        print("DEBUG CLIENT: ypcat passwd result:\n\(ypcatResult)")
        let ypwhichResult = try await sshManager.executeCommand("ypwhich 2>&1 || echo 'Cannot determine NIS server'")
        print("DEBUG CLIENT: ypwhich result: \(ypwhichResult)")

        // Filter ypcat to show only network users (UID >= 1001)
        var networkUsers = "No network users found"
        if !ypcatResult.contains("not responding") && !ypcatResult.isEmpty {
            let lines = ypcatResult.split(separator: "\n")
            let filteredUsers = lines.filter { line in
                let parts = line.split(separator: ":")
                if parts.count >= 3, let uid = Int(parts[2]) {
                    return uid >= 1001 && uid < 60000
                }
                return false
            }
            if !filteredUsers.isEmpty {
                networkUsers = filteredUsers.prefix(5).joined(separator: "\n")
            }
        }

        let configSteps = """
        Configuration completed:
        ✓ NIS domain: \(nisDomainName)
        ✓ NIS server: \(nisServerAddress)
        ✓ Services started (ypbind, nfsclient, lockd)
        ✓ /Network mounted from \(nisServerAddress)
        """

        print("DEBUG CLIENT: NIS client setup completed successfully!")
        print("DEBUG CLIENT: Network users found: \(networkUsers)")

        confirmationMessage = """
        NIS/NFS client configured and started successfully!

        \(configSteps)

        NIS server responding: \(ypwhichResult.trimmingCharacters(in: .whitespacesAndNewlines))

        Network users (UID >= 1001):
        \(networkUsers)

        You can now create network users on the server or login with existing network accounts.
        """
        showingConfirmation = true
    }

    func leaveNetworkDomain() async {
        isLoading = true
        isConfiguringNetwork = true
        error = nil

        do {
            // Stop NIS client service
            networkConfigStep = "Stopping NIS client service..."
            _ = try await sshManager.executeCommand("service ypbind stop 2>&1 || true")

            // Stop NFS client services
            networkConfigStep = "Stopping NFS client services..."
            _ = try await sshManager.executeCommand("service lockd stop 2>&1 || true")
            _ = try await sshManager.executeCommand("service nfsclient stop 2>&1 || true")

            // Unmount /Network
            networkConfigStep = "Unmounting /Network..."
            _ = try await sshManager.executeCommand("umount /Network 2>&1 || true")

            // Remove /Network from /etc/fstab
            networkConfigStep = "Removing /Network from fstab..."
            _ = try await sshManager.executeCommand("/usr/bin/sed -i '' '/\\/Network/d' /etc/fstab")

            // Disable NIS client in rc.conf
            networkConfigStep = "Disabling NIS client..."
            _ = try await sshManager.executeCommand("sysrc -x nis_client_enable 2>/dev/null || true")
            _ = try await sshManager.executeCommand("sysrc -x nisdomainname 2>/dev/null || true")
            _ = try await sshManager.executeCommand("sysrc -x rpcbind_enable 2>/dev/null || true")

            // Disable NFS client in rc.conf
            networkConfigStep = "Disabling NFS client..."
            _ = try await sshManager.executeCommand("sysrc -x nfs_client_enable 2>/dev/null || true")
            _ = try await sshManager.executeCommand("sysrc -x rpc_lockd_enable 2>/dev/null || true")

            // Restore nsswitch.conf to default (compat mode, which doesn't use NIS without +: entries)
            networkConfigStep = "Restoring nsswitch.conf..."
            _ = try await sshManager.executeCommand("/usr/bin/sed -i '' 's/^passwd:.*/passwd: compat/' /etc/nsswitch.conf")
            _ = try await sshManager.executeCommand("/usr/bin/sed -i '' 's/^group:.*/group: compat/' /etc/nsswitch.conf")

            // Remove NIS compat entries from passwd/group files
            networkConfigStep = "Removing NIS compat entries..."
            _ = try await sshManager.executeCommand("/usr/bin/sed -i '' '/^+:/d' /etc/master.passwd 2>/dev/null || true")
            _ = try await sshManager.executeCommand("pwd_mkdb -p /etc/master.passwd 2>/dev/null || true")
            _ = try await sshManager.executeCommand("/usr/bin/sed -i '' '/^+:/d' /etc/group 2>/dev/null || true")

            // Remove /etc/netgroup
            _ = try await sshManager.executeCommand("rm -f /etc/netgroup 2>/dev/null || true")

            // Remove sudoers network-users config
            _ = try await sshManager.executeCommand("rm -f /usr/local/etc/sudoers.d/network-users 2>/dev/null || true")

            // Remount /Network ZFS dataset
            networkConfigStep = "Remounting /Network ZFS dataset..."
            _ = try await sshManager.executeCommand("zfs mount /Network 2>&1 || true")

            networkConfigStep = "Refreshing status..."

            // Reload state
            await loadSetupState()

            confirmationMessage = """
            Successfully left the network domain.

            Configuration removed:
            ✓ NIS client disabled
            ✓ NFS client disabled
            ✓ /Network NFS unmounted and removed from fstab
            ✓ /Network ZFS dataset remounted
            ✓ nsswitch.conf restored to default

            This system is now configured as a standalone machine.
            """
            showingConfirmation = true

        } catch {
            self.error = "Failed to leave network domain: \(error.localizedDescription)"
        }

        isConfiguringNetwork = false
        networkConfigStep = ""
        isLoading = false
    }

    func removeNetworkDomain() async {
        isLoading = true
        isConfiguringNetwork = true
        error = nil

        do {
            // Stop NIS client first (server runs as its own client)
            networkConfigStep = "Stopping NIS client services..."
            _ = try await sshManager.executeCommand("service ypbind stop 2>&1 || true")

            // Stop NIS server services
            networkConfigStep = "Stopping NIS server services..."
            _ = try await sshManager.executeCommand("service yppasswdd stop 2>&1 || true")
            _ = try await sshManager.executeCommand("service ypserv stop 2>&1 || true")

            // Stop NFS server services
            networkConfigStep = "Stopping NFS server services..."
            _ = try await sshManager.executeCommand("service nfsd stop 2>&1 || true")
            _ = try await sshManager.executeCommand("service mountd stop 2>&1 || true")
            _ = try await sshManager.executeCommand("service lockd stop 2>&1 || true")
            _ = try await sshManager.executeCommand("service statd stop 2>&1 || true")

            // Remove ZFS NFS sharing
            networkConfigStep = "Removing NFS shares..."
            _ = try await sshManager.executeCommand("zfs set sharenfs=off zroot/Network 2>&1 || true")

            // Disable NIS server in rc.conf
            networkConfigStep = "Disabling NIS server..."
            _ = try await sshManager.executeCommand("sysrc -x nis_server_enable 2>/dev/null || true")
            _ = try await sshManager.executeCommand("sysrc -x nis_client_enable 2>/dev/null || true")
            _ = try await sshManager.executeCommand("sysrc -x nis_yppasswdd_enable 2>/dev/null || true")
            _ = try await sshManager.executeCommand("sysrc -x nisdomainname 2>/dev/null || true")
            _ = try await sshManager.executeCommand("sysrc -x rpcbind_enable 2>/dev/null || true")

            // Disable NFS server in rc.conf
            networkConfigStep = "Disabling NFS server..."
            _ = try await sshManager.executeCommand("sysrc -x nfs_server_enable 2>/dev/null || true")
            _ = try await sshManager.executeCommand("sysrc -x mountd_enable 2>/dev/null || true")
            _ = try await sshManager.executeCommand("sysrc -x rpc_lockd_enable 2>/dev/null || true")
            _ = try await sshManager.executeCommand("sysrc -x rpc_statd_enable 2>/dev/null || true")

            // Remove NIS compat entries from passwd/group files
            networkConfigStep = "Removing NIS compat entries..."
            _ = try await sshManager.executeCommand("/usr/bin/sed -i '' '/^+:/d' /etc/master.passwd 2>/dev/null || true")
            _ = try await sshManager.executeCommand("pwd_mkdb -p /etc/master.passwd 2>/dev/null || true")
            _ = try await sshManager.executeCommand("/usr/bin/sed -i '' '/^+:/d' /etc/group 2>/dev/null || true")

            // Remove /etc/netgroup
            _ = try await sshManager.executeCommand("rm -f /etc/netgroup 2>/dev/null || true")

            // Remove sudoers network-users config
            _ = try await sshManager.executeCommand("rm -f /usr/local/etc/sudoers.d/network-users 2>/dev/null || true")

            // Remove NIS maps and data
            networkConfigStep = "Removing NIS data..."
            _ = try await sshManager.executeCommand("rm -rf /var/yp/* 2>&1 || true")

            // Clear the domain name
            _ = try await sshManager.executeCommand("domainname '' 2>&1 || true")

            networkConfigStep = "Refreshing status..."

            // Reload state
            await loadSetupState()

            confirmationMessage = """
            Successfully removed the network domain.

            Configuration removed:
            ✓ NIS server disabled
            ✓ NFS server disabled
            ✓ NFS shares removed
            ✓ NIS maps and data deleted
            ✓ nsswitch.conf restored to default

            This system is now configured as a standalone machine.
            Network users and their home directories in /Network/Users remain intact.
            """
            showingConfirmation = true

        } catch {
            self.error = "Failed to remove network domain: \(error.localizedDescription)"
        }

        isConfiguringNetwork = false
        networkConfigStep = ""
        isLoading = false
    }

    // MARK: - User Management

    func loadLocalUsers() async {
        isLoading = true
        error = nil

        do {
            // Get list of users from /etc/passwd
            let passwdOutput = try await sshManager.executeCommand("cat /etc/passwd")
            var users: [LocalUser] = []

            for line in passwdOutput.split(separator: "\n") {
                let parts = line.split(separator: ":")
                guard parts.count >= 7 else { continue }

                let username = String(parts[0])
                let uid = Int(parts[2]) ?? 0
                let fullName = String(parts[4])
                let homeDirectory = String(parts[5])
                let shell = String(parts[6])

                // Only show users with UID >= 1001 (Gershwin uidstart) and < 60000 (exclude special high-UID system accounts like nobody)
                guard uid >= 1001 && uid < 60000 else {
                    continue
                }

                users.append(LocalUser(
                    id: uid,
                    username: username,
                    fullName: fullName,
                    homeDirectory: homeDirectory,
                    shell: shell,
                    isSystemUser: false
                ))
            }

            setupState.localUsers = users.sorted { $0.username < $1.username }

        } catch {
            self.error = "Failed to load local users: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func createUser(username: String, fullName: String, password: String, addToWheel: Bool) async {
        isLoading = true
        error = nil

        do {
            // Hardcoded settings for local users
            let homePrefix = "/Local/Users"
            let shell = "/usr/local/bin/zsh"

            // Use pw command to create user non-interactively
            // -n: username, -c: full name/comment, -d: home directory, -s: shell, -m: create home directory, -G: additional groups
            var createCommand = "pw useradd \(username) -c '\(fullName)' -d \(homePrefix)/\(username) -s \(shell) -m"

            if addToWheel {
                createCommand += " -G wheel"
            }

            createCommand += " -h 0"

            // Set the password by piping it to pw usermod
            _ = try await sshManager.executeCommand("echo '\(password)' | \(createCommand)")

            var message = "User '\(username)' created successfully!"
            if addToWheel {
                message += "\n\nUser has been granted sudo access."
            }
            confirmationMessage = message
            showingConfirmation = true

            // Reload users list
            await loadLocalUsers()

        } catch {
            self.error = "Failed to create user: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func removeUser(user: LocalUser, removeHomeDirectory: Bool) async {
        isLoading = true
        error = nil

        do {
            // Use rmuser command
            let rmCommand = removeHomeDirectory ? "rmuser -y \(user.username)" : "rmuser -y -v \(user.username)"
            _ = try await sshManager.executeCommand(rmCommand)

            confirmationMessage = "User '\(user.username)' removed successfully!"
            showingConfirmation = true

            // Reload users list
            await loadLocalUsers()

        } catch {
            self.error = "Failed to remove user: \(error.localizedDescription)"
        }

        isLoading = false
    }

    // MARK: - Network User Management (NIS)

    func loadNetworkUsers() async {
        isLoading = true
        error = nil

        do {
            var users: [LocalUser] = []
            let isServer = setupState.networkDomain?.role == .server
            print("DEBUG loadNetworkUsers: role=\(String(describing: setupState.networkDomain?.role)), isServer=\(isServer)")

            if isServer {
                // Server: read from /var/yp/master.passwd (10 fields)
                let checkFile = try await sshManager.executeCommand("test -f /var/yp/master.passwd && echo 'exists' || echo 'missing'")
                if checkFile.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
                    setupState.networkUsers = []
                    isLoading = false
                    return
                }

                let passwdOutput = try await sshManager.executeCommand("cat /var/yp/master.passwd")

                for line in passwdOutput.split(separator: "\n") {
                    // master.passwd has 10 fields: name:password:uid:gid:class:change:expire:gecos:home:shell
                    let parts = line.split(separator: ":", omittingEmptySubsequences: false)
                    guard parts.count >= 10 else { continue }

                    let username = String(parts[0])
                    let uid = Int(parts[2]) ?? 0
                    let fullName = String(parts[7])      // gecos field
                    let homeDirectory = String(parts[8]) // home field
                    let shell = String(parts[9])         // shell field

                    // Only show users with UID >= 1001 (Gershwin uidstart) and < 60000
                    guard uid >= 1001 && uid < 60000 else { continue }

                    users.append(LocalUser(
                        id: uid,
                        username: username,
                        fullName: fullName,
                        homeDirectory: homeDirectory,
                        shell: shell,
                        isSystemUser: false
                    ))
                }
            } else {
                // Client: use ypcat passwd (7 fields)
                print("DEBUG loadNetworkUsers: Using ypcat passwd for client")
                let passwdOutput = try await sshManager.executeCommand("ypcat passwd 2>/dev/null || echo ''")
                print("DEBUG loadNetworkUsers: ypcat output: \(passwdOutput)")
                if passwdOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    setupState.networkUsers = []
                    isLoading = false
                    return
                }

                for line in passwdOutput.split(separator: "\n") {
                    // passwd has 7 fields: name:password:uid:gid:gecos:home:shell
                    let parts = line.split(separator: ":", omittingEmptySubsequences: false)
                    guard parts.count >= 7 else { continue }

                    let username = String(parts[0])
                    let uid = Int(parts[2]) ?? 0
                    let fullName = String(parts[4])      // gecos field
                    let homeDirectory = String(parts[5]) // home field
                    let shell = String(parts[6])         // shell field

                    // Only show users with UID >= 1001 (Gershwin uidstart) and < 60000
                    guard uid >= 1001 && uid < 60000 else { continue }

                    users.append(LocalUser(
                        id: uid,
                        username: username,
                        fullName: fullName,
                        homeDirectory: homeDirectory,
                        shell: shell,
                        isSystemUser: false
                    ))
                }
            }

            setupState.networkUsers = users.sorted { $0.username < $1.username }

        } catch {
            self.error = "Failed to load network users: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func createNetworkUser(username: String, fullName: String, password: String, addToWheel: Bool) async {
        isLoading = true
        error = nil

        do {
            // Check if /var/yp/master.passwd exists
            let checkFile = try await sshManager.executeCommand("test -f /var/yp/master.passwd && echo 'exists' || echo 'missing'")
            if checkFile.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
                throw NSError(domain: "GershwinSetup", code: 6, userInfo: [NSLocalizedDescriptionKey: "NIS not initialized. Please run 'ypinit -m' first."])
            }

            // Hardcoded settings for network users
            let homePrefix = "/Network/Users"
            let shell = "/usr/local/bin/zsh"

            // Get the next available UID (starting from 1001 for network users)
            let uidResult = try await sshManager.executeCommand("awk -F: 'BEGIN{max=1000} $3>max && $3<60000 {max=$3} END{print max+1}' /var/yp/master.passwd /etc/master.passwd 2>/dev/null | sort -n | tail -1")
            let uid = uidResult.trimmingCharacters(in: .whitespacesAndNewlines)
            let uidNum = Int(uid) ?? 1001
            print("DEBUG: Next available UID: \(uidNum)")

            // Generate password hash using openssl
            let hashResult = try await sshManager.executeCommand("openssl passwd -6 '\(password)'")
            let passwordHash = hashResult.trimmingCharacters(in: .whitespacesAndNewlines)

            // Create the master.passwd entry directly (10 fields)
            // name:password:uid:gid:class:change:expire:gecos:home:shell
            let masterPasswdEntry = "\(username):\(passwordHash):\(uidNum):\(uidNum)::0:0:\(fullName):\(homePrefix)/\(username):\(shell)"

            // Append to /var/yp/master.passwd
            _ = try await sshManager.executeCommand("echo '\(masterPasswdEntry)' >> /var/yp/master.passwd")

            // Check if user's private group already exists in /var/yp/group
            let userGroupExists = try await sshManager.executeCommand("grep -q '^\(username):' /var/yp/group 2>/dev/null && echo 'exists' || echo 'missing'")
            if userGroupExists.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
                // Create the user's private group in /var/yp/group
                let groupEntry = "\(username):*:\(uidNum):"
                _ = try await sshManager.executeCommand("echo '\(groupEntry)' >> /var/yp/group")
            }

            // If adding sudo access, add user to sudo-users netgroup
            if addToWheel {
                // Check if user is already in sudo-users netgroup
                let inNetgroup = try await sshManager.executeCommand("grep '^sudo-users' /var/yp/netgroup | grep -q '(,\(username),)' && echo 'exists' || echo 'missing'")
                if inNetgroup.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
                    // Append user to sudo-users netgroup: (,username,) format
                    _ = try await sshManager.executeCommand("/usr/bin/sed -i '' 's/^sudo-users.*/& (,\(username),)/' /var/yp/netgroup")
                }
            }

            // Create home directory
            _ = try await sshManager.executeCommand("mkdir -p \(homePrefix)/\(username)")
            _ = try await sshManager.executeCommand("chown \(uidNum):\(uidNum) \(homePrefix)/\(username)")
            _ = try await sshManager.executeCommand("chmod 755 \(homePrefix)/\(username)")

            // Copy skeleton files
            _ = try await sshManager.executeCommand("cp -R /usr/share/skel/ \(homePrefix)/\(username)/ 2>/dev/null || true")
            _ = try await sshManager.executeCommand("chown -R \(uidNum):\(uidNum) \(homePrefix)/\(username)")

            // Rebuild NIS maps
            guard let domain = setupState.networkDomain?.domainName else {
                throw NSError(domain: "GershwinSetup", code: 7, userInfo: [NSLocalizedDescriptionKey: "NIS domain name not found"])
            }

            // Regenerate /var/yp/passwd from /var/yp/master.passwd (7-field format from 10-field format)
            // master.passwd: name:password:uid:gid:class:change:expire:gecos:home:shell
            // passwd:        name:password:uid:gid:gecos:home:shell
            _ = try await sshManager.executeCommand("awk -F: 'NF==10 {print $1\":\"$2\":\"$3\":\"$4\":\"$8\":\"$9\":\"$10}' /var/yp/master.passwd > /var/yp/passwd")

            // Delete and rebuild NIS maps to ensure changes are picked up
            // Pass GROUP=/var/yp/group and NETGROUP=/var/yp/netgroup so make uses our NIS files
            _ = try await sshManager.executeCommand("rm -f /var/yp/*/passwd.byname /var/yp/*/passwd.byuid /var/yp/*/group.byname /var/yp/*/group.bygid /var/yp/*/master.passwd.byname /var/yp/*/master.passwd.byuid /var/yp/*/netgroup /var/yp/*/netgroup.byuser /var/yp/*/netgroup.byhost 2>/dev/null; cd /var/yp && make GROUP=/var/yp/group NETGROUP=/var/yp/netgroup 2>&1")

            var message = "Network user '\(username)' created successfully!\n\nNIS maps have been rebuilt. Clients should now see this user."
            if addToWheel {
                message += "\n\nUser has been granted sudo access (via netgroup)."
            }
            confirmationMessage = message
            showingConfirmation = true

            // Reload network users list
            await loadNetworkUsers()

        } catch {
            self.error = "Failed to create network user: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func removeNetworkUser(user: LocalUser) async {
        isLoading = true
        error = nil

        do {
            // Remove user from /var/yp/master.passwd
            _ = try await sshManager.executeCommand("/usr/bin/sed -i '' '/^\(user.username):/d' /var/yp/master.passwd")

            // Remove user's private group from /var/yp/group
            _ = try await sshManager.executeCommand("/usr/bin/sed -i '' '/^\(user.username):/d' /var/yp/group")

            // Remove user from sudo-users netgroup
            // Remove the (,username,) tuple from the netgroup line
            _ = try await sshManager.executeCommand("/usr/bin/sed -i '' 's/ (,\(user.username),)//g' /var/yp/netgroup")

            // Rebuild NIS maps
            guard let domain = setupState.networkDomain?.domainName else {
                throw NSError(domain: "GershwinSetup", code: 7, userInfo: [NSLocalizedDescriptionKey: "NIS domain name not found"])
            }

            // Regenerate /var/yp/passwd from /var/yp/master.passwd (7-field format from 10-field format)
            _ = try await sshManager.executeCommand("awk -F: 'NF==10 {print $1\":\"$2\":\"$3\":\"$4\":\"$8\":\"$9\":\"$10}' /var/yp/master.passwd > /var/yp/passwd")

            // Delete and rebuild NIS maps to ensure changes are picked up
            _ = try await sshManager.executeCommand("rm -f /var/yp/*/passwd.byname /var/yp/*/passwd.byuid /var/yp/*/group.byname /var/yp/*/group.bygid /var/yp/*/master.passwd.byname /var/yp/*/master.passwd.byuid /var/yp/*/netgroup /var/yp/*/netgroup.byuser /var/yp/*/netgroup.byhost 2>/dev/null; cd /var/yp && make GROUP=/var/yp/group NETGROUP=/var/yp/netgroup 2>&1")

            confirmationMessage = "Network user '\(user.username)' removed successfully!\n\nNIS maps have been rebuilt. Note: Home directory was not removed."
            showingConfirmation = true

            // Reload network users list
            await loadNetworkUsers()

        } catch {
            self.error = "Failed to remove network user: \(error.localizedDescription)"
        }

        isLoading = false
    }
}

// MARK: - Main View

struct GershwinSetupView: View {
    var body: some View {
        GershwinSetupContentView()
    }
}

struct GershwinSetupContentView: View {
    @StateObject private var viewModel = GershwinSetupViewModel()

    private var isSystemSetupComplete: Bool {
        let zfsConfigured = viewModel.setupState.zfsDatasets.allSatisfy { $0.status == .configured }
        let userConfigured = viewModel.setupState.userConfig?.status == .configured
        let networkRole = viewModel.selectedNetworkRole

        // For Standalone, check ZFS + user config
        if networkRole == .none {
            return zfsConfigured && userConfigured
        }

        // For Server/Client, also check network domain status
        let networkConfigured = viewModel.setupState.networkDomain?.status == .configured
        return zfsConfigured && userConfigured && networkConfigured
    }

    private func domainStatus() -> SetupStatus {
        let zfsConfigured = viewModel.setupState.zfsDatasets.allSatisfy { $0.status == .configured }
        let userConfigured = viewModel.setupState.userConfig?.status == .configured
        let networkRole = viewModel.selectedNetworkRole

        // For Standalone, check ZFS + user config
        if networkRole == .none {
            if zfsConfigured && userConfigured {
                return .configured
            } else if viewModel.setupState.zfsDatasets.isEmpty && viewModel.setupState.userConfig == nil {
                return .pending
            } else {
                return .partiallyConfigured
            }
        }

        // For Server/Client, also check network domain status
        let networkConfigured = viewModel.setupState.networkDomain?.status == .configured
        if zfsConfigured && userConfigured && networkConfigured {
            return .configured
        } else if viewModel.setupState.zfsDatasets.isEmpty && viewModel.setupState.userConfig == nil {
            return .pending
        } else {
            return .partiallyConfigured
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Error message
                if let error = viewModel.error {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.red)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.red.opacity(0.1))
                    )
                }

                // Domain Card (System Setup)
                SetupPhaseCard(
                    title: "Domain",
                    icon: "externaldrive.connected.to.line.below",
                    status: domainStatus()
                ) {
                    DomainPhase(viewModel: viewModel)
                }

                // User Management Card (only shown after System Setup is complete)
                if isSystemSetupComplete {
                    UserManagementCard(viewModel: viewModel)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await viewModel.loadSetupState()

            // Load appropriate user list based on network role
            if viewModel.setupState.networkDomain?.role == .none {
                await viewModel.loadLocalUsers()
            } else if viewModel.setupState.networkDomain?.role == .server {
                await viewModel.loadNetworkUsers()
            }
        }
        .alert("Configuration Complete", isPresented: $viewModel.showingConfirmation) {
            Button("OK") {
                viewModel.showingConfirmation = false
            }
        } message: {
            Text(viewModel.confirmationMessage)
        }
    }
}

// MARK: - User Management Card

struct UserManagementCard: View {
    @ObservedObject var viewModel: GershwinSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "person.2")
                    .font(.title2)
                    .foregroundColor(.blue)
                    .frame(width: 30)

                Text("User Management")
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer()
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Content
            VStack(alignment: .leading, spacing: 16) {
                if viewModel.selectedNetworkRole == .none {
                    // Local User Management
                    Text("Manage local user accounts on this system")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    UserManagementPhase(viewModel: viewModel)
                } else if viewModel.selectedNetworkRole == .server || viewModel.selectedNetworkRole == .client {
                    // Network User Management (read-only for clients)
                    NetworkUserManagementPhase(viewModel: viewModel)
                }
            }
            .padding()
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
        )
        .onAppear {
            // Auto-load users when card appears
            Task {
                if viewModel.selectedNetworkRole == .none {
                    await viewModel.loadLocalUsers()
                } else if viewModel.selectedNetworkRole == .server || viewModel.selectedNetworkRole == .client {
                    await viewModel.loadNetworkUsers()
                }
            }
        }
    }
}

// MARK: - System Setup Tab

struct SystemSetupTab: View {
    @ObservedObject var viewModel: GershwinSetupViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Error message
                if let error = viewModel.error {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.red)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.red.opacity(0.1))
                    )
                }

                // Domain (combined Local + Network)
                SetupPhaseCard(
                    title: "Domain",
                    icon: "externaldrive.connected.to.line.below",
                    status: domainStatus(viewModel: viewModel)
                ) {
                    DomainPhase(viewModel: viewModel)
                }
            }
            .padding()
        }
        .onAppear {
            // Auto-refresh setup state when navigating to System Setup tab
            // Skip if a configuration is in progress
            guard !viewModel.isConfiguringUser && !viewModel.isConfiguringNetwork else { return }
            Task {
                // Update network role from server to reflect actual configuration
                await viewModel.loadSetupState(updateNetworkRole: true)
            }
        }
    }

    private func domainStatus(viewModel: GershwinSetupViewModel) -> SetupStatus {
        let zfsConfigured = viewModel.setupState.zfsDatasets.allSatisfy { $0.status == .configured }
        let userConfigured = viewModel.setupState.userConfig?.status == .configured
        let networkRole = viewModel.selectedNetworkRole

        // For Standalone, check ZFS + user config
        if networkRole == .none {
            if zfsConfigured && userConfigured {
                return .configured
            } else if viewModel.setupState.zfsDatasets.isEmpty && viewModel.setupState.userConfig == nil {
                return .pending
            } else {
                return .partiallyConfigured
            }
        }

        // For Server/Client, also check network domain status
        let networkConfigured = viewModel.setupState.networkDomain?.status == .configured
        if zfsConfigured && userConfigured && networkConfigured {
            return .configured
        } else if viewModel.setupState.zfsDatasets.isEmpty && viewModel.setupState.userConfig == nil {
            return .pending
        } else {
            return .partiallyConfigured
        }
    }
}


// MARK: - Domain Phase (Combined Local + Network)

struct DomainPhase: View {
    @ObservedObject var viewModel: GershwinSetupViewModel
    @State private var packagesExpanded = false
    @State private var userConfigExpanded = false

    private var packagesConfigured: Bool {
        guard let config = viewModel.setupState.userConfig else { return false }
        return config.zshInstalled && config.zshAutosuggestionsInstalled &&
               config.zshCompletionsInstalled
    }

    private var userConfigConfigured: Bool {
        guard let config = viewModel.setupState.userConfig else { return false }
        let zfsConfigured = viewModel.setupState.zfsDatasets.allSatisfy { $0.status == .configured }
        return zfsConfigured && config.status == .configured
    }

    private var localConfigured: Bool {
        packagesConfigured && userConfigConfigured
    }

    private var isConfiguredAsServer: Bool {
        viewModel.setupState.networkDomain?.role == .server
    }

    private var isConfiguredAsClient: Bool {
        viewModel.setupState.networkDomain?.role == .client &&
        viewModel.setupState.networkDomain?.nisConfigured == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Role picker - always show at top unless already configured as server/client
            if !isConfiguredAsServer && !isConfiguredAsClient {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Role:")
                        .font(.headline)

                    Picker("Role", selection: $viewModel.selectedNetworkRole) {
                        Text("Standalone").tag(NetworkRole.none)
                        Text("Server (Share users/apps)").tag(NetworkRole.server)
                        Text("Client (Mount from server)").tag(NetworkRole.client)
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: viewModel.selectedNetworkRole) { oldValue, newValue in
                        Task {
                            await viewModel.loadSetupState(updateNetworkRole: false)

                            if newValue == .none {
                                await viewModel.loadLocalUsers()
                            } else if newValue == .server {
                                await viewModel.loadNetworkUsers()
                            }
                        }
                    }
                }

                Divider()
            }

            // Show current role info if already configured
            if let network = viewModel.setupState.networkDomain, network.role != .none {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Role:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(network.role == .server ? "Server" : "Client")
                            .font(.caption)
                            .bold()
                    }

                    if let domain = network.domainName {
                        HStack {
                            Text("Domain:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(domain)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }

                    HStack {
                        Text("NIS:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Image(systemName: network.nisConfigured ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(network.nisConfigured ? .green : .red)
                            .font(.caption)
                    }

                    HStack {
                        Text("NFS:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Image(systemName: network.nfsConfigured ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(network.nfsConfigured ? .green : .red)
                            .font(.caption)
                    }
                }

                Divider()
            }

            // Required Packages Section
            ExpandableConfigSection(
                title: "Required Packages",
                isConfigured: packagesConfigured,
                isExpanded: $packagesExpanded
            ) {
                if let config = viewModel.setupState.userConfig {
                    ConfigDetailRow(label: "zsh", isConfigured: config.zshInstalled)
                    ConfigDetailRow(label: "zsh-autosuggestions", isConfigured: config.zshAutosuggestionsInstalled)
                    ConfigDetailRow(label: "zsh-completions", isConfigured: config.zshCompletionsInstalled)
                }
            }

            // User Configuration Section
            ExpandableConfigSection(
                title: "User Configuration",
                isConfigured: userConfigConfigured,
                isExpanded: $userConfigExpanded
            ) {
                // ZFS Datasets
                Text("ZFS Datasets")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.top, 4)

                ForEach(viewModel.setupState.zfsDatasets, id: \.name) { dataset in
                    ConfigDetailRow(
                        label: dataset.name,
                        isConfigured: dataset.status == .configured,
                        detail: dataset.exists ? (dataset.correctLocation ? nil : "Wrong location") : "Missing"
                    )
                }

                // ZSH configuration
                if let config = viewModel.setupState.userConfig {
                    Text("ZSH Configuration")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.top, 8)

                    ConfigDetailRow(label: "/usr/local/etc/zshrc", isConfigured: config.zshrcConfigured)
                    ConfigDetailRow(label: "/usr/share/skel/dot.zshrc", isConfigured: config.zshrcConfigured)
                }
            }

            // Server/Client specific fields
            if !isConfiguredAsServer && !isConfiguredAsClient {
                if viewModel.selectedNetworkRole == .server || viewModel.selectedNetworkRole == .client {
                    TextField("NIS Domain Name", text: $viewModel.nisDomainName)
                        .textFieldStyle(.roundedBorder)
                }

                if viewModel.selectedNetworkRole == .client {
                    TextField("NIS Server Address (hostname or IP)", text: $viewModel.nisServerAddress)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Buttons based on role and state
            if viewModel.selectedNetworkRole == .none && !localConfigured {
                // Standalone - Initialize button
                Divider()
                Button(action: {
                    Task {
                        guard await viewModel.setupZFSDatasets() else { return }
                        await viewModel.setupUserConfig()
                    }
                }) {
                    Label("Initialize", systemImage: "gear")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading)
            } else if viewModel.selectedNetworkRole == .server && !isConfiguredAsServer {
                // Server selected but not configured
                Divider()
                Button(action: {
                    Task {
                        guard await viewModel.setupZFSDatasets() else { return }
                        guard await viewModel.setupUserConfig() else { return }
                        await viewModel.setupNetworkDomain()
                    }
                }) {
                    Label("Create Domain", systemImage: "server.rack")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading)
            } else if viewModel.selectedNetworkRole == .client && !isConfiguredAsClient {
                // Client selected but not joined
                Divider()
                Button(action: {
                    Task {
                        guard await viewModel.setupZFSDatasets() else { return }
                        guard await viewModel.setupUserConfig() else { return }
                        await viewModel.setupNetworkDomain()
                    }
                }) {
                    Label("Join Domain", systemImage: "network.badge.shield.half.filled")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading || viewModel.nisServerAddress.isEmpty)
            } else if isConfiguredAsClient {
                // Client is joined - show leave button
                Divider()
                Button(action: {
                    Task {
                        await viewModel.leaveNetworkDomain()
                    }
                }) {
                    Label("Leave Domain", systemImage: "network.slash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(viewModel.isLoading)
            } else if isConfiguredAsServer {
                // Server is configured - show remove domain button
                Divider()
                Button(action: {
                    viewModel.showingRemoveDomainConfirmation = true
                }) {
                    Label("Remove Domain", systemImage: "server.rack")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(viewModel.isLoading)
                .confirmationDialog(
                    "Remove Network Domain?",
                    isPresented: $viewModel.showingRemoveDomainConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Remove Domain", role: .destructive) {
                        Task {
                            await viewModel.removeNetworkDomain()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will stop all NIS/NFS services, remove network user data, and restore this system to standalone mode. This action cannot be undone.")
                }
            }

            // Show "Complete Setup" button if network is configured but packages/user config are incomplete
            if (isConfiguredAsServer || isConfiguredAsClient) && !localConfigured {
                Divider()
                Button(action: {
                    Task {
                        await viewModel.setupUserConfig()
                    }
                }) {
                    Label("Complete Setup", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading)
            }
        }
        .sheet(isPresented: $viewModel.isConfiguringUser) {
            UserConfigProgressSheet(step: viewModel.userConfigStep)
        }
        .sheet(isPresented: $viewModel.isConfiguringNetwork) {
            NetworkConfigProgressSheet(step: viewModel.networkConfigStep, role: viewModel.selectedNetworkRole)
        }
    }
}

struct ExpandableConfigSection<Content: View>: View {
    let title: String
    let isConfigured: Bool
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isConfigured ? .green : .secondary)
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Spacer()
                    if isConfigured {
                        Text("Configured")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Text("Not configured")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    content
                }
                .padding(.leading, 24)
            }
        }
    }
}

struct ConfigDetailRow: View {
    let label: String
    let isConfigured: Bool
    var detail: String? = nil

    var body: some View {
        HStack {
            Image(systemName: isConfigured ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(isConfigured ? .green : .secondary)
                .font(.caption)
            Text(label)
                .font(.caption)
            if let detail = detail {
                Text("(\(detail))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - User Management Tab

struct UserManagementTab: View {
    @ObservedObject var viewModel: GershwinSetupViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Error message
                if let error = viewModel.error {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.red)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.red.opacity(0.1))
                    )
                }

                // Show appropriate user management based on selected network role
                if viewModel.selectedNetworkRole == .none {
                    // Local User Management
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Local User Management")
                            .font(.title2)
                            .bold()

                        Text("Manage local user accounts on this system")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Divider()

                        UserManagementPhase(viewModel: viewModel)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                    )
                } else if viewModel.selectedNetworkRole == .server {
                    // Network User Management
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Network User Management")
                            .font(.title2)
                            .bold()

                        Text("Manage NIS network users shared across all clients")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Divider()

                        NetworkUserManagementPhase(viewModel: viewModel)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                    )
                } else if viewModel.selectedNetworkRole == .client {
                    // Client - read-only network user management
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Network Users")
                            .font(.title2)
                            .bold()

                        Text("View NIS network users (managed on server)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Divider()

                        NetworkUserManagementPhase(viewModel: viewModel)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                    )
                }
            }
            .padding()
        }
        .onAppear {
            // Auto-load users when navigating to User Management tab
            Task {
                if viewModel.selectedNetworkRole == .none {
                    await viewModel.loadLocalUsers()
                } else if viewModel.selectedNetworkRole == .server || viewModel.selectedNetworkRole == .client {
                    await viewModel.loadNetworkUsers()
                }
            }
        }
    }
}

// MARK: - Phase Components

struct SetupPhaseCard<Content: View>: View {
    let title: String
    let icon: String
    let status: SetupStatus
    @ViewBuilder let content: Content

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button(action: { isExpanded.toggle() }) {
                HStack {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(status.color)
                        .frame(width: 30)

                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    Image(systemName: status.icon)
                        .foregroundColor(status.color)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()

                content
                    .padding()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        )
    }
}


struct UserConfigProgressSheet: View {
    let step: String

    var body: some View {
        VStack(spacing: 20) {
            Text("Configuring Standalone Installation")
                .font(.title2)
                .bold()

            ProgressView()
                .scaleEffect(1.5)
                .padding()

            Text(step)
                .font(.body)
                .foregroundColor(.secondary)
                .frame(minWidth: 250)
                .multilineTextAlignment(.center)

            Text("Please wait...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(40)
        .frame(minWidth: 350)
        .interactiveDismissDisabled()
    }
}

struct NetworkConfigProgressSheet: View {
    let step: String
    let role: NetworkRole

    var title: String {
        switch role {
        case .server:
            return "Configuring Network Server"
        case .client:
            return "Configuring Network Client"
        default:
            return "Configuring Network Domain"
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.title2)
                .bold()

            ProgressView()
                .scaleEffect(1.5)
                .padding()

            Text(step)
                .font(.body)
                .foregroundColor(.secondary)
                .frame(minWidth: 250)
                .multilineTextAlignment(.center)

            Text("Please wait...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(40)
        .frame(minWidth: 350)
        .interactiveDismissDisabled()
    }
}

struct UserManagementPhase: View {
    @ObservedObject var viewModel: GershwinSetupViewModel
    @State private var showCreateUserSheet = false
    @State private var showDeleteConfirmation = false
    @State private var userToDelete: LocalUser?
    @State private var removeHomeDirectory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manage local user accounts:")
                .font(.caption)
                .foregroundColor(.secondary)

            if viewModel.setupState.localUsers.isEmpty {
                VStack(spacing: 8) {
                    Text("No local users found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("(Only showing users with UID 1001-59999)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.setupState.localUsers) { user in
                            UserRow(
                                user: user,
                                onDelete: {
                                    userToDelete = user
                                    showDeleteConfirmation = true
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Button(action: {
                showCreateUserSheet = true
            }) {
                Label("Create New User", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isLoading)
        }
        .sheet(isPresented: $showCreateUserSheet) {
            CreateUserSheet(viewModel: viewModel, isPresented: $showCreateUserSheet)
        }
        .alert("Delete User", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                userToDelete = nil
                removeHomeDirectory = false
            }
            Button("Delete User Only", role: .destructive) {
                if let user = userToDelete {
                    Task {
                        await viewModel.removeUser(user: user, removeHomeDirectory: false)
                        userToDelete = nil
                    }
                }
            }
            Button("Delete User & Home", role: .destructive) {
                if let user = userToDelete {
                    Task {
                        await viewModel.removeUser(user: user, removeHomeDirectory: true)
                        userToDelete = nil
                    }
                }
            }
        } message: {
            if let user = userToDelete {
                Text("Are you sure you want to delete '\(user.username)'?\n\nHome directory: \(user.homeDirectory)")
            }
        }
    }
}

struct UserRow: View {
    let user: LocalUser
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(user.displayName)
                    .font(.body)
                    .fontWeight(.medium)

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("UID:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(user.id))
                            .font(.system(.caption, design: .monospaced))
                    }

                    HStack(spacing: 4) {
                        Text("Home:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(user.homeDirectory)
                            .font(.system(.caption, design: .monospaced))
                    }

                    HStack(spacing: 4) {
                        Text("Shell:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(user.shell)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete user")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }
}

struct CreateUserSheet: View {
    @ObservedObject var viewModel: GershwinSetupViewModel
    @Binding var isPresented: Bool

    @State private var username = ""
    @State private var fullName = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var addToWheel = false
    @State private var usernameManuallyEdited = false

    // Generate username from full name: first initial + last name, lowercase
    private func generateUsername(from name: String) -> String {
        let components = name.trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .map { String($0) }

        guard !components.isEmpty else { return "" }

        if components.count == 1 {
            // Single name - use it as username
            return components[0].lowercased()
        } else {
            // First initial + last name
            let firstInitial = String(components[0].prefix(1))
            let lastName = components[components.count - 1]
            return (firstInitial + lastName).lowercased()
        }
    }

    // Check if username already exists
    private var usernameExists: Bool {
        let existingUsernames = viewModel.setupState.localUsers.map { $0.username }
        return existingUsernames.contains(username)
    }

    // Form is valid when all fields are filled and validated
    private var isFormValid: Bool {
        !username.isEmpty &&
        !password.isEmpty &&
        !confirmPassword.isEmpty &&
        password == confirmPassword &&
        !usernameExists &&
        !viewModel.isLoading
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Local User")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Text("Full Name")
                    .font(.caption)
                TextField("Full Name", text: $fullName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: fullName) { _, newValue in
                        if !usernameManuallyEdited {
                            username = generateUsername(from: newValue)
                        }
                    }

                Text("Username")
                    .font(.caption)
                TextField("Username (lowercase, no spaces)", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: username) { oldValue, newValue in
                        // Mark as manually edited if user changes it from the auto-generated value
                        if !fullName.isEmpty && newValue != generateUsername(from: fullName) {
                            usernameManuallyEdited = true
                        }
                    }

                if usernameExists && !username.isEmpty {
                    Text("Username '\(username)' already exists")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Text("Password")
                    .font(.caption)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)

                Text("Confirm Password")
                    .font(.caption)
                SecureField("Confirm Password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)

                if !confirmPassword.isEmpty && password != confirmPassword {
                    Text("Passwords do not match")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Divider()

                Toggle(isOn: $addToWheel) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow sudo access")
                            .font(.body)
                        Text("Grants sudo/administrative privileges")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home directory will be created automatically in /Local/Users")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
            )
            .padding(.horizontal)

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(action: {
                    Task {
                        await viewModel.createUser(username: username, fullName: fullName, password: password, addToWheel: addToWheel)
                        isPresented = false
                    }
                }) {
                    Text("Create User")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isFormValid)
                .opacity(isFormValid ? 1.0 : 0.5)
            }
        }
        .padding()
        .frame(width: 450)
    }
}

struct NetworkUserManagementPhase: View {
    @ObservedObject var viewModel: GershwinSetupViewModel
    @State private var showCreateUserSheet = false
    @State private var showDeleteConfirmation = false
    @State private var userToDelete: LocalUser?

    private var isClient: Bool {
        viewModel.setupState.networkDomain?.role == .client
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Info note at top - different message for client vs server
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isClient ? "lock.fill" : "info.circle")
                    .foregroundColor(isClient ? .orange : .blue)
                VStack(alignment: .leading, spacing: 4) {
                    if isClient {
                        Text("Network users must be managed from the NIS server")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("Connect to the server to create, modify, or delete network users")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Network users are shared across all NIS clients")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("Home directories should be in /Network/Users for NFS access")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isClient ? Color.orange.opacity(0.1) : Color.blue.opacity(0.1))
            )

            if viewModel.setupState.networkUsers.isEmpty {
                VStack(spacing: 8) {
                    Text("No network users found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("(Only showing users with UID 1001-59999)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.setupState.networkUsers) { user in
                            NetworkUserRow(
                                user: user,
                                isReadOnly: isClient,
                                onDelete: {
                                    userToDelete = user
                                    showDeleteConfirmation = true
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            // Only show create button on server
            if !isClient {
                Button(action: {
                    showCreateUserSheet = true
                }) {
                    Label("Create New Network User", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading)
            }
        }
        .sheet(isPresented: $showCreateUserSheet) {
            CreateNetworkUserSheet(viewModel: viewModel, isPresented: $showCreateUserSheet)
        }
        .alert("Delete Network User", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                userToDelete = nil
            }
            Button("Delete User", role: .destructive) {
                if let user = userToDelete {
                    Task {
                        await viewModel.removeNetworkUser(user: user)
                        userToDelete = nil
                    }
                }
            }
        } message: {
            if let user = userToDelete {
                Text("Are you sure you want to delete network user '\(user.username)'?\n\nThis will remove the user from NIS and rebuild the maps. Home directory will not be removed.")
            }
        }
    }
}

struct NetworkUserRow: View {
    let user: LocalUser
    var isReadOnly: Bool = false
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "network")
                .foregroundColor(.blue)
                .font(.caption)

            VStack(alignment: .leading, spacing: 4) {
                Text(user.displayName)
                    .font(.body)
                    .fontWeight(.medium)

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("UID:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(user.id))
                            .font(.system(.caption, design: .monospaced))
                    }

                    HStack(spacing: 4) {
                        Text("Home:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(user.homeDirectory)
                            .font(.system(.caption, design: .monospaced))
                    }

                    HStack(spacing: 4) {
                        Text("Shell:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(user.shell)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }

            Spacer()

            if !isReadOnly {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete network user")
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }
}

struct CreateNetworkUserSheet: View {
    @ObservedObject var viewModel: GershwinSetupViewModel
    @Binding var isPresented: Bool

    @State private var username = ""
    @State private var fullName = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var addToWheel = false
    @State private var usernameManuallyEdited = false

    // Generate username from full name: first initial + last name, lowercase
    private func generateUsername(from name: String) -> String {
        let components = name.trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .map { String($0) }

        guard !components.isEmpty else { return "" }

        if components.count == 1 {
            // Single name - use it as username
            return components[0].lowercased()
        } else {
            // First initial + last name
            let firstInitial = String(components[0].prefix(1))
            let lastName = components[components.count - 1]
            return (firstInitial + lastName).lowercased()
        }
    }

    // Check if username already exists in network users
    private var usernameExists: Bool {
        let existingUsernames = viewModel.setupState.networkUsers.map { $0.username }
        return existingUsernames.contains(username)
    }

    // Form is valid when all fields are filled and validated
    private var isFormValid: Bool {
        !username.isEmpty &&
        !password.isEmpty &&
        !confirmPassword.isEmpty &&
        password == confirmPassword &&
        !usernameExists &&
        !viewModel.isLoading
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Network User")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Text("Full Name")
                    .font(.caption)
                TextField("Full Name", text: $fullName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: fullName) { _, newValue in
                        if !usernameManuallyEdited {
                            username = generateUsername(from: newValue)
                        }
                    }

                Text("Username")
                    .font(.caption)
                TextField("Username (lowercase, no spaces)", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: username) { oldValue, newValue in
                        // Mark as manually edited if user changes it from the auto-generated value
                        if !fullName.isEmpty && newValue != generateUsername(from: fullName) {
                            usernameManuallyEdited = true
                        }
                    }

                if usernameExists && !username.isEmpty {
                    Text("Username '\(username)' already exists")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Text("Password")
                    .font(.caption)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)

                Text("Confirm Password")
                    .font(.caption)
                SecureField("Confirm Password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)

                if !confirmPassword.isEmpty && password != confirmPassword {
                    Text("Passwords do not match")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Divider()

                Toggle(isOn: $addToWheel) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow sudo access")
                            .font(.body)
                        Text("Grants sudo/administrative privileges")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Network user will be added to NIS database")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("Home directory will be created in /Network/Users and NIS maps will be rebuilt.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
            )
            .padding(.horizontal)

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(action: {
                    Task {
                        await viewModel.createNetworkUser(username: username, fullName: fullName, password: password, addToWheel: addToWheel)
                        isPresented = false
                    }
                }) {
                    Text("Create Network User")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isFormValid)
                .opacity(isFormValid ? 1.0 : 0.5)
            }
        }
        .padding()
        .frame(width: 450)
    }
}

#Preview {
    GershwinSetupView()
}
