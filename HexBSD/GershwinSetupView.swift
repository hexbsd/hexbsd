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
    let adduserConfExists: Bool
    let homePrefix: String
    let defaultShell: String
    let uidStart: String
    let zshInstalled: Bool
    let zshAutosuggestionsInstalled: Bool
    let zshCompletionsInstalled: Bool
    let zshrcConfigured: Bool

    var isConfigured: Bool {
        homePrefix == "/Local/Users" &&
        defaultShell == "/usr/local/bin/zsh" &&
        uidStart == "1001" &&
        zshInstalled
    }

    var hasAllPrerequisites: Bool {
        zshInstalled && zshAutosuggestionsInstalled && zshCompletionsInstalled
    }

    var status: SetupStatus {
        if !zshInstalled {
            return .error
        } else if !adduserConfExists {
            return .pending
        } else if isConfigured && hasAllPrerequisites && zshrcConfigured {
            return .configured
        } else if isConfigured {
            return .partiallyConfigured
        } else {
            return .partiallyConfigured
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

        // Check /Network (should be in zpool root) - only if server role is selected
        if selectedNetworkRole == .server {
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
        }

        return (datasets, bootEnv, zpoolRoot)
    }

    private func detectUserConfig() async throws -> UserConfigStatus {
        // Check if /etc/adduser.conf exists and read its settings
        let checkExists = try await sshManager.executeCommand("test -f /etc/adduser.conf && echo 'exists' || echo 'missing'")
        let exists = checkExists.trimmingCharacters(in: .whitespacesAndNewlines) == "exists"

        // Check for zsh installation
        let zshCheck = try await sshManager.executeCommand("test -f /usr/local/bin/zsh && echo 'installed' || echo 'missing'")
        let zshInstalled = zshCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "installed"

        // Check for zsh-autosuggestions
        let autosuggestCheck = try await sshManager.executeCommand("test -f /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh && echo 'installed' || echo 'missing'")
        let zshAutosuggestionsInstalled = autosuggestCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "installed"

        // Check for zsh-completions (check if the package is installed via pkg)
        let completionsCheck = try await sshManager.executeCommand("pkg info -e zsh-completions && echo 'installed' || echo 'missing'")
        let zshCompletionsInstalled = completionsCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "installed"

        // Check if .zshrc exists in /usr/share/skel
        let zshrcCheck = try await sshManager.executeCommand("test -f /usr/share/skel/.zshrc && echo 'configured' || echo 'missing'")
        let zshrcConfigured = zshrcCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "configured"

        var homePrefix = ""
        var defaultShell = ""
        var uidStart = ""

        if exists {
            // Read the configuration
            let content = try await sshManager.executeCommand("cat /etc/adduser.conf")

            // Parse key values
            for line in content.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("homeprefix=") {
                    homePrefix = trimmed.replacingOccurrences(of: "homeprefix=", with: "")
                } else if trimmed.hasPrefix("defaultshell=") {
                    defaultShell = trimmed.replacingOccurrences(of: "defaultshell=", with: "")
                } else if trimmed.hasPrefix("uidstart=") {
                    uidStart = trimmed.replacingOccurrences(of: "uidstart=", with: "")
                }
            }
        }

        return UserConfigStatus(
            adduserConfExists: exists,
            homePrefix: homePrefix,
            defaultShell: defaultShell,
            uidStart: uidStart,
            zshInstalled: zshInstalled,
            zshAutosuggestionsInstalled: zshAutosuggestionsInstalled,
            zshCompletionsInstalled: zshCompletionsInstalled,
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

    func setupZFSDatasets() async {
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

            // Create /Network dataset in zpool root - only if server role is selected
            if selectedNetworkRole == .server {
                let networkDataset = setupState.zfsDatasets.first { $0.name == "/Network" }
                if let network = networkDataset, !network.exists {
                    _ = try await sshManager.executeCommand("zfs create -o mountpoint=/Network \(zpoolRoot)/Network")
                }
            }

            // Reload state
            await loadSetupState()

        } catch {
            self.error = "Failed to create ZFS datasets: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func setupUserConfig() async {
        isLoading = true
        isConfiguringUser = true
        error = nil

        do {
            // Check and install required packages
            guard let userConfig = setupState.userConfig else {
                throw NSError(domain: "GershwinSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "User config status not loaded"])
            }

            // Run pkg update first if any packages need to be installed
            if !userConfig.zshInstalled || !userConfig.zshAutosuggestionsInstalled || !userConfig.zshCompletionsInstalled {
                userConfigStep = "Updating package repository..."
                _ = try await sshManager.executeCommand("pkg update")
            }

            // Install zsh if not present
            if !userConfig.zshInstalled {
                userConfigStep = "Installing zsh..."
                _ = try await sshManager.executeCommand("pkg install -y zsh")
            }

            // Install zsh-autosuggestions if not present
            if !userConfig.zshAutosuggestionsInstalled {
                userConfigStep = "Installing zsh-autosuggestions..."
                _ = try await sshManager.executeCommand("pkg install -y zsh-autosuggestions")
            }

            // Install zsh-completions if not present
            if !userConfig.zshCompletionsInstalled {
                userConfigStep = "Installing zsh-completions..."
                _ = try await sshManager.executeCommand("pkg install -y zsh-completions")
            }

            // Create .zshrc configuration in /usr/share/skel if not present
            if !userConfig.zshrcConfigured {
                userConfigStep = "Creating zsh configuration..."
                let zshrcContent = """
# Gershwin GNUstep zsh configuration

# Path to zsh-completions (adjust if needed)
fpath=(/usr/local/share/zsh-completions $fpath)

# Initialize completion system
autoload -Uz compinit && compinit

ZSH_AUTOSUGGEST_STRATEGY=(match_prev_cmd history completion)

source /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# Use fish-style command history
HISTFILE=~/.zsh_history      # Location of history file
HISTSIZE=10000               # Number of lines kept in memory
SAVEHIST=10000               # Number of lines saved to file

# Options for fish-like behavior
setopt hist_ignore_dups      # Don't record duplicate lines
setopt hist_reduce_blanks    # Remove unnecessary blanks
setopt inc_append_history    # Save each command as soon as it's run
setopt share_history         # Share history across all zsh sessions
setopt extended_history      # Add timestamps to history
setopt hist_find_no_dups     # Skip duplicate entries during search

# Fish-style up-arrow history search (per command line input)
autoload -Uz up-line-or-beginning-search
autoload -Uz down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey "^[[A" up-line-or-beginning-search     # Up arrow
bindkey "^[[B" down-line-or-beginning-search   # Down arrow

# Load color module
autoload -U colors && colors

# Enable prompt substitution
setopt PROMPT_SUBST

# Function to abbreviate path like Fish
function fish_like_path() {
  local dir_path=$PWD
  # Handle home directory and subdirectories
  if [[ $dir_path == $HOME ]]; then
    echo "~"
  elif [[ $dir_path == $HOME/* ]]; then
    local sub_path=${dir_path#$HOME/}
    local components=(${(s:/:)sub_path})
    local abbreviated=()
    # Abbreviate all but the last component
    for ((i=1; i<${#components}; i++)); do
      [[ -n $components[$i] ]] && abbreviated+=${components[$i][1]}
    done
    # Add the last component fully
    [[ -n $components[-1] ]] && abbreviated+=$components[-1]
    echo "~/${(j:/:)abbreviated}"
  else
    # Abbreviate non-home paths
    local components=(${(s:/:)dir_path})
    local abbreviated=()
    # Abbreviate all but the last component
    for ((i=1; i<${#components}; i++)); do
      [[ -n $components[$i] ]] && abbreviated+=${components[$i][1]}
    done
    # Add the last component fully
    [[ -n $components[-1] ]] && abbreviated+=$components[-1]
    echo "/${(j:/:)abbreviated}"
  fi
}

# Use Terminator's 3rd palette color (ANSI 2) for user and path, terminal foreground for host
local user_color='2'      # ANSI 2 (Terminator's 3rd color, green)
local host_color='fg'     # Terminal's default foreground
local path_color='2'      # ANSI 2 (Terminator's 3rd color, green)

# Git info function to show branch info in prompt, with fallback if Git is not installed
function git_info() {
  # Check if Git is installed
  if ! command -v git &>/dev/null; then
    return 1  # Return 1 if Git is not installed
  fi

  # Check if inside a Git repository
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    return 1  # Return 1 if not inside a Git repository
  fi

  # Get the current Git branch or fallback to describe if in detached HEAD
  local branch=$(git symbolic-ref --short HEAD 2>/dev/null)
  if [[ -z "$branch" ]]; then
    branch=$(git describe --tags --always 2>/dev/null)
  fi

  # Return the Git info with the branch or fallback name
  echo "%F{$host_color}($branch)%f"
}

# Check for 256-color support
if [[ "$TERM" == *256color* ]]; then
  # Use ANSI 2 and terminal foreground with Fish-like path
  PROMPT="%F{$user_color}%n%f@%F{$host_color}%m%f %F{$path_color}\\$(fish_like_path)\\$(git_info)%f %# "
else
  # Fallback to ANSI 2 and terminal foreground with Fish-like path
  PROMPT="%F{$user_color}%n%f@%F{$host_color}%m%f %F{$path_color}\\$(fish_like_path)\\$(git_info)%f %# "
fi
"""

                // Create /usr/share/skel if it doesn't exist
                _ = try await sshManager.executeCommand("mkdir -p /usr/share/skel")

                // Write .zshrc to skeleton directory using heredoc to avoid escaping issues
                _ = try await sshManager.executeCommand("cat > /usr/share/skel/.zshrc << 'ZSHRC_EOF'\n\(zshrcContent)\nZSHRC_EOF")
            }

            // Create /etc/adduser.conf with Gershwin settings
            userConfigStep = "Configuring adduser.conf..."
            let config = """
defaultHomePerm=0700
defaultLgroup=
defaultclass=
defaultgroups=
passwdtype=yes
homeprefix=/Local/Users
defaultshell=/usr/local/bin/zsh
udotdir=/usr/share/skel
msgfile=/etc/adduser.msg
disableflag=
uidstart=1001
"""

            // Write configuration using heredoc to avoid escaping issues
            _ = try await sshManager.executeCommand("cat > /etc/adduser.conf << 'ADDUSER_EOF'\n\(config)\nADDUSER_EOF")

            userConfigStep = "Refreshing status..."

            // Reload state
            await loadSetupState()

        } catch {
            self.error = "Failed to configure user settings: \(error.localizedDescription)"
        }

        isConfiguringUser = false
        userConfigStep = ""
        isLoading = false
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
            self.error = "Failed to configure network domain: \(error.localizedDescription)"
        }

        isConfiguringNetwork = false
        networkConfigStep = ""
        isLoading = false
    }

    private func setupNetworkServer() async throws {
        // Configure NIS server
        networkConfigStep = "Configuring NIS server..."
        _ = try await sshManager.executeCommand("sysrc nisdomainname=\"\(nisDomainName)\"")
        _ = try await sshManager.executeCommand("sysrc nis_server_enable=\"YES\"")
        _ = try await sshManager.executeCommand("sysrc nis_yppasswdd_enable=\"YES\"")

        // Configure NFS server
        networkConfigStep = "Configuring NFS server..."
        _ = try await sshManager.executeCommand("sysrc rpcbind_enable=\"YES\"")
        _ = try await sshManager.executeCommand("sysrc nfs_server_enable=\"YES\"")
        _ = try await sshManager.executeCommand("sysrc mountd_enable=\"YES\"")
        _ = try await sshManager.executeCommand("sysrc rpc_lockd_enable=\"YES\"")

        // Create /etc/exports if it doesn't exist
        networkConfigStep = "Configuring /etc/exports..."
        _ = try await sshManager.executeCommand("touch /etc/exports")

        // Check if /Network export already exists
        let exportsContent = try await sshManager.executeCommand("cat /etc/exports 2>/dev/null || echo ''")
        if !exportsContent.contains("/Network") {
            _ = try await sshManager.executeCommand("echo '/Network -maproot=root -alldirs' >> /etc/exports")
        }

        confirmationMessage = """
        NIS/NFS server configuration files created successfully!

        Automatic configuration completed:
        ✓ NIS domain: \(nisDomainName)
        ✓ rc.conf updated for NIS/NFS server
        ✓ /etc/exports configured to share /Network

        Manual steps required to complete setup:

        1. Create NIS user database:
           cp /etc/master.passwd /var/yp/master.passwd
           vi /var/yp/master.passwd
           (Remove all users except those you want to share)

        2. Initialize NIS maps:
           cd /var/yp
           ypinit -m \(nisDomainName)

        3. Start services:
           service ypserv restart
           service nfsd start
           service lockd start

        4. After adding users in the future:
           cd /var/yp
           make \(nisDomainName)

        See NETWORK.md for detailed instructions.
        """
        showingConfirmation = true
    }

    private func setupNetworkClient() async throws {
        guard !nisServerAddress.isEmpty else {
            throw NSError(domain: "GershwinSetup", code: 3, userInfo: [NSLocalizedDescriptionKey: "Please enter NIS server address"])
        }

        // Check if /Network is a ZFS dataset (clients should not have this)
        networkConfigStep = "Checking for local /Network dataset..."
        let zfsCheck = try await sshManager.executeCommand("zfs list -H -o name /Network 2>/dev/null || echo 'none'")
        let networkDataset = zfsCheck.trimmingCharacters(in: .whitespacesAndNewlines)
        var removedLocalDataset = false

        if networkDataset != "none" && !networkDataset.isEmpty {
            // /Network is a ZFS dataset - need to unmount and destroy it for NFS client
            networkConfigStep = "Removing local /Network dataset..."
            _ = try await sshManager.executeCommand("zfs unmount /Network 2>&1 || true")
            _ = try await sshManager.executeCommand("zfs destroy \(networkDataset) 2>&1 || true")
            removedLocalDataset = true
        }

        // Configure NIS client
        networkConfigStep = "Configuring NIS client..."
        _ = try await sshManager.executeCommand("sysrc nisdomainname=\"\(nisDomainName)\"")
        _ = try await sshManager.executeCommand("sysrc rpcbind_enable=\"YES\"")
        _ = try await sshManager.executeCommand("sysrc nis_client_enable=\"YES\"")

        // Configure NFS client
        networkConfigStep = "Configuring NFS client..."
        _ = try await sshManager.executeCommand("sysrc nfs_client_enable=\"YES\"")
        _ = try await sshManager.executeCommand("sysrc rpc_lockd_enable=\"YES\"")

        // Update /etc/nsswitch.conf
        // Use "files nis" order so local users (like root) always work even if NIS is down
        networkConfigStep = "Configuring nsswitch.conf..."
        let nsswitchContent = """
group: files nis
group_compat: nis
hosts: files dns
netgroup: compat
networks: files
passwd: files nis
passwd_compat: nis
shells: files
services: compat
services_compat: nis
protocols: files
rpc: files
"""
        // Use heredoc to avoid escaping issues
        _ = try await sshManager.executeCommand("cat > /etc/nsswitch.conf << 'NSSWITCH_EOF'\n\(nsswitchContent)\nNSSWITCH_EOF")

        // Check if /Network mount already exists in /etc/fstab
        networkConfigStep = "Configuring /etc/fstab..."
        let fstabContent = try await sshManager.executeCommand("cat /etc/fstab 2>/dev/null || echo ''")
        if !fstabContent.contains("/Network") {
            let fstabEntry = "\(nisServerAddress):/Network         /Network        nfs     rw              0       0"
            _ = try await sshManager.executeCommand("echo '\(fstabEntry)' >> /etc/fstab")
        }

        // Create /Network directory if it doesn't exist
        _ = try await sshManager.executeCommand("mkdir -p /Network")

        // Start NIS client service
        networkConfigStep = "Starting NIS client service..."
        // Set the NIS domain name directly (faster than /etc/netstart)
        _ = try await sshManager.executeCommand("domainname \(nisDomainName)")
        // Start rpcbind if not running (required for NIS/NFS)
        _ = try await sshManager.executeCommand("service rpcbind onestart 2>&1 || true")
        _ = try await sshManager.executeCommand("service ypbind onestart 2>&1 || true")

        // Start NFS client services
        networkConfigStep = "Starting NFS client services..."
        _ = try await sshManager.executeCommand("service nfsclient onestart 2>&1 || true")
        _ = try await sshManager.executeCommand("service lockd onestart 2>&1 || true")

        // Mount the network share
        networkConfigStep = "Mounting /Network..."
        _ = try await sshManager.executeCommand("mount /Network 2>&1 || true")

        // Verify NIS connectivity
        networkConfigStep = "Verifying NIS connectivity..."
        let ypcatResult = try await sshManager.executeCommand("ypcat passwd 2>&1 || echo 'NIS not responding'")
        let getentResult = try await sshManager.executeCommand("getent passwd 2>&1 | grep -v '^root:' | head -5 || echo 'No network users found'")

        var configSteps = """
        Configuration completed:
        ✓ NIS domain: \(nisDomainName)
        ✓ NIS server: \(nisServerAddress)
        """

        if removedLocalDataset {
            configSteps += "\n✓ Removed local /Network ZFS dataset (clients use NFS mount)"
        }

        configSteps += """

        ✓ Services started (ypbind, nfsclient, lockd)
        ✓ /Network mounted from \(nisServerAddress)
        """

        confirmationMessage = """
        NIS/NFS client configured and started successfully!

        \(configSteps)

        NIS verification:
        \(ypcatResult.prefix(200))

        Network users found:
        \(getentResult.prefix(300))

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
            _ = try await sshManager.executeCommand("sed -i '' '/\\/Network/d' /etc/fstab")

            // Disable NIS client in rc.conf
            networkConfigStep = "Disabling NIS client..."
            _ = try await sshManager.executeCommand("sysrc -x nis_client_enable 2>/dev/null || true")
            _ = try await sshManager.executeCommand("sysrc -x nisdomainname 2>/dev/null || true")
            _ = try await sshManager.executeCommand("sysrc -x rpcbind_enable 2>/dev/null || true")

            // Disable NFS client in rc.conf
            networkConfigStep = "Disabling NFS client..."
            _ = try await sshManager.executeCommand("sysrc -x nfs_client_enable 2>/dev/null || true")
            _ = try await sshManager.executeCommand("sysrc -x rpc_lockd_enable 2>/dev/null || true")

            // Restore default nsswitch.conf
            networkConfigStep = "Restoring nsswitch.conf..."
            let defaultNsswitchContent = """
group: compat
group_compat: nis
hosts: files dns
netgroup: compat
networks: files
passwd: compat
passwd_compat: nis
shells: files
services: compat
services_compat: nis
protocols: files
rpc: files
"""
            _ = try await sshManager.executeCommand("cat > /etc/nsswitch.conf << 'NSSWITCH_EOF'\n\(defaultNsswitchContent)\nNSSWITCH_EOF")

            // Remove /Network directory
            networkConfigStep = "Removing /Network directory..."
            _ = try await sshManager.executeCommand("rmdir /Network 2>&1 || true")

            networkConfigStep = "Refreshing status..."

            // Reload state
            await loadSetupState()

            confirmationMessage = """
            Successfully left the network domain.

            Configuration removed:
            ✓ NIS client disabled
            ✓ NFS client disabled
            ✓ /Network unmounted and removed from fstab
            ✓ nsswitch.conf restored to defaults

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
            // Get settings from adduser.conf (or use defaults)
            let homePrefix = setupState.userConfig?.homePrefix ?? "/Local/Users"
            let shell = setupState.userConfig?.defaultShell ?? "/usr/local/bin/zsh"

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
                message += "\n\nUser has been added to the wheel group."
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
            // Check if /var/yp/master.passwd exists
            let checkFile = try await sshManager.executeCommand("test -f /var/yp/master.passwd && echo 'exists' || echo 'missing'")
            if checkFile.trimmingCharacters(in: .whitespacesAndNewlines) == "missing" {
                setupState.networkUsers = []
                isLoading = false
                return
            }

            // Get list of network users from /var/yp/master.passwd
            let passwdOutput = try await sshManager.executeCommand("cat /var/yp/master.passwd")
            var users: [LocalUser] = []

            for line in passwdOutput.split(separator: "\n") {
                let parts = line.split(separator: ":")
                guard parts.count >= 7 else { continue }

                let username = String(parts[0])
                let uid = Int(parts[2]) ?? 0
                let fullName = String(parts[4])
                let homeDirectory = String(parts[5])
                let shell = String(parts[6])

                // Only show users with UID >= 1001 (Gershwin uidstart) and < 60000
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

            // Get settings from adduser.conf (or use defaults)
            // For network users, use /Network/Users instead of /Local/Users
            let homePrefix = "/Network/Users"
            let shell = setupState.userConfig?.defaultShell ?? "/usr/local/bin/zsh"

            // Use pw command to create user non-interactively in local system first
            var createCommand = "pw useradd \(username) -c '\(fullName)' -d \(homePrefix)/\(username) -s \(shell) -m"

            if addToWheel {
                createCommand += " -G wheel"
            }

            createCommand += " -h 0"
            _ = try await sshManager.executeCommand("echo '\(password)' | \(createCommand)")

            // Get the user's entry from /etc/master.passwd
            let userEntry = try await sshManager.executeCommand("grep '^\(username):' /etc/master.passwd")
            let trimmedEntry = userEntry.trimmingCharacters(in: .whitespacesAndNewlines)

            // Append to /var/yp/master.passwd
            _ = try await sshManager.executeCommand("echo '\(trimmedEntry)' >> /var/yp/master.passwd")

            // Rebuild NIS maps
            guard let domain = setupState.networkDomain?.domainName else {
                throw NSError(domain: "GershwinSetup", code: 7, userInfo: [NSLocalizedDescriptionKey: "NIS domain name not found"])
            }

            _ = try await sshManager.executeCommand("cd /var/yp && make \(domain) 2>&1")

            // Remove the user from local system (keep it only in NIS)
            _ = try await sshManager.executeCommand("pw userdel \(username) 2>&1 || true")

            var message = "Network user '\(username)' created successfully!\n\nNIS maps have been rebuilt. Clients should now see this user."
            if addToWheel {
                message += "\n\nUser has been added to the wheel group."
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
            _ = try await sshManager.executeCommand("sed -i '' '/^\(user.username):/d' /var/yp/master.passwd")

            // Rebuild NIS maps
            guard let domain = setupState.networkDomain?.domainName else {
                throw NSError(domain: "GershwinSetup", code: 7, userInfo: [NSLocalizedDescriptionKey: "NIS domain name not found"])
            }

            _ = try await sshManager.executeCommand("cd /var/yp && make \(domain) 2>&1")

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

    var body: some View {
        TabView {
            // User Management Tab
            UserManagementTab(viewModel: viewModel)
                .tabItem {
                    Label("User Management", systemImage: "person.2")
                }

            // System Setup Tab
            SystemSetupTab(viewModel: viewModel)
                .tabItem {
                    Label("System Setup", systemImage: "wrench.and.screwdriver")
                }
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

                // Local Domain (ZFS Datasets + User Configuration)
                SetupPhaseCard(
                    title: "Local Domain",
                    icon: "internaldrive",
                    status: localDomainStatus(viewModel: viewModel)
                ) {
                    LocalDomainPhase(viewModel: viewModel)
                }

                // Network Domain
                SetupPhaseCard(
                    title: "Network Domain",
                    icon: "network",
                    status: viewModel.setupState.networkDomain?.status ?? .pending
                ) {
                    NetworkDomainPhase(viewModel: viewModel)
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

    private func localDomainStatus(viewModel: GershwinSetupViewModel) -> SetupStatus {
        let zfsConfigured = viewModel.setupState.zfsDatasets.allSatisfy { $0.status == .configured }
        let userConfigured = viewModel.setupState.userConfig?.status == .configured

        if zfsConfigured && userConfigured {
            return .configured
        } else if viewModel.setupState.zfsDatasets.isEmpty && viewModel.setupState.userConfig == nil {
            return .pending
        } else {
            return .partiallyConfigured
        }
    }
}

// MARK: - Local Domain Phase (Combined ZFS + User Config)

struct LocalDomainPhase: View {
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
        return zfsConfigured && config.isConfigured && config.zshrcConfigured
    }

    private var allConfigured: Bool {
        packagesConfigured && userConfigConfigured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

                // User templates
                if let config = viewModel.setupState.userConfig {
                    Text("User Templates")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.top, 8)

                    ConfigDetailRow(label: ".zshrc", isConfigured: config.zshrcConfigured)
                }

                // adduser.conf settings
                if let config = viewModel.setupState.userConfig {
                    Text("adduser.conf")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.top, 8)

                    ConfigDetailRow(
                        label: "Home prefix",
                        isConfigured: config.homePrefix == "/Local/Users",
                        detail: config.homePrefix.isEmpty ? nil : config.homePrefix
                    )
                    ConfigDetailRow(
                        label: "Default shell",
                        isConfigured: config.defaultShell == "/usr/local/bin/zsh",
                        detail: config.defaultShell.isEmpty ? nil : config.defaultShell
                    )
                    ConfigDetailRow(
                        label: "UID start",
                        isConfigured: config.uidStart == "1001",
                        detail: config.uidStart.isEmpty ? nil : config.uidStart
                    )
                }
            }

            // Configure button - only show if not fully configured
            if !allConfigured {
                Divider()

                Button(action: {
                    Task {
                        await viewModel.setupUserConfig()
                    }
                }) {
                    Label("Configure Local Domain", systemImage: "gear")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading)
            }
        }
        .sheet(isPresented: $viewModel.isConfiguringUser) {
            UserConfigProgressSheet(step: viewModel.userConfigStep)
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
                    // Client - no user management
                    VStack(spacing: 16) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)

                        Text("User management not available")
                            .font(.title3)
                            .bold()

                        Text("This system is configured as an NIS client. Users are managed on the NIS server.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(60)
                }
            }
            .padding()
        }
        .onAppear {
            // Auto-load users when navigating to User Management tab
            Task {
                if viewModel.selectedNetworkRole == .none {
                    await viewModel.loadLocalUsers()
                } else if viewModel.selectedNetworkRole == .server {
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
            Text("Configuring User Settings")
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

struct NetworkDomainPhase: View {
    @ObservedObject var viewModel: GershwinSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure NIS/NFS for network-wide user accounts and shared applications:")
                .font(.caption)
                .foregroundColor(.secondary)

            if let network = viewModel.setupState.networkDomain {
                if network.role != .none {
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
                }
            }

            // Check if already configured as server or client
            let isConfiguredAsServer = viewModel.setupState.networkDomain?.role == .server
            let isConfiguredAsClient = viewModel.setupState.networkDomain?.role == .client &&
                                       viewModel.setupState.networkDomain?.nisConfigured == true

            // Only show role picker and text fields when not configured
            if !isConfiguredAsServer && !isConfiguredAsClient {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Setup Role:")
                        .font(.headline)

                    Picker("Role", selection: $viewModel.selectedNetworkRole) {
                        Text("Not Configured").tag(NetworkRole.none)
                        Text("Server (Share users/apps)").tag(NetworkRole.server)
                        Text("Client (Mount from server)").tag(NetworkRole.client)
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: viewModel.selectedNetworkRole) { oldValue, newValue in
                        // Reload setup state when role changes to update ZFS dataset list
                        // Don't update the network role from detection since user just changed it
                        Task {
                            await viewModel.loadSetupState(updateNetworkRole: false)

                            // Reload appropriate user list based on new role
                            if newValue == .none {
                                await viewModel.loadLocalUsers()
                            } else if newValue == .server {
                                await viewModel.loadNetworkUsers()
                            }
                        }
                    }

                    if viewModel.selectedNetworkRole == .server || viewModel.selectedNetworkRole == .client {
                        TextField("NIS Domain Name", text: $viewModel.nisDomainName)
                            .textFieldStyle(.roundedBorder)
                    }

                    if viewModel.selectedNetworkRole == .client {
                        TextField("NIS Server Address (hostname or IP)", text: $viewModel.nisServerAddress)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            // Show appropriate button based on role and current state
            let isServerConfigured = viewModel.setupState.networkDomain?.role == .server
            let isClientJoined = viewModel.setupState.networkDomain?.role == .client &&
                                 viewModel.setupState.networkDomain?.nisConfigured == true

            if viewModel.selectedNetworkRole == .server && !isServerConfigured {
                // Server selected but not yet configured
                Button(action: {
                    Task {
                        await viewModel.setupNetworkDomain()
                    }
                }) {
                    Label("Configure Network Domain", systemImage: "network")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading)
            } else if isClientJoined {
                // Client is joined - show leave button
                Button(action: {
                    Task {
                        await viewModel.leaveNetworkDomain()
                    }
                }) {
                    Label("Leave Network Domain", systemImage: "network.slash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(viewModel.isLoading)
            } else if viewModel.selectedNetworkRole == .client && !isClientJoined {
                // Client selected but not yet joined
                Button(action: {
                    Task {
                        await viewModel.setupNetworkDomain()
                    }
                }) {
                    Label("Join Network Domain", systemImage: "network.badge.shield.half.filled")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading || viewModel.nisServerAddress.isEmpty)
            }
            // No button shown when selectedNetworkRole == .none or server already configured
        }
        .sheet(isPresented: $viewModel.isConfiguringNetwork) {
            NetworkConfigProgressSheet(step: viewModel.networkConfigStep)
        }
    }
}

struct NetworkConfigProgressSheet: View {
    let step: String

    var body: some View {
        VStack(spacing: 20) {
            Text("Configuring Network Domain")
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
                        Text("\(user.id)")
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
    @State private var showPasswordMismatchError = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Local User")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Text("Username")
                    .font(.caption)
                TextField("Username (lowercase, no spaces)", text: $username)
                    .textFieldStyle(.roundedBorder)

                Text("Full Name")
                    .font(.caption)
                TextField("Full Name", text: $fullName)
                    .textFieldStyle(.roundedBorder)

                Text("Password")
                    .font(.caption)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)

                Text("Confirm Password")
                    .font(.caption)
                SecureField("Confirm Password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)

                if showPasswordMismatchError {
                    Text("Passwords do not match")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Divider()

                Toggle(isOn: $addToWheel) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add to wheel group")
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
                    Text("User will be created with settings from adduser.conf")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("Home directory will be created automatically in \(viewModel.setupState.userConfig?.homePrefix ?? "/Local/Users")")
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

                Button("Create User") {
                    if password != confirmPassword {
                        showPasswordMismatchError = true
                        return
                    }

                    Task {
                        await viewModel.createUser(username: username, fullName: fullName, password: password, addToWheel: addToWheel)
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(username.isEmpty || password.isEmpty || confirmPassword.isEmpty || viewModel.isLoading)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manage network user accounts (NIS):")
                .font(.caption)
                .foregroundColor(.secondary)

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
                Label("Create New Network User", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isLoading)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Network users are shared across all NIS clients")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("Home directories should be in /Network/Users for NFS access")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.1))
            )
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
                        Text("\(user.id)")
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
            .help("Delete network user")
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
    @State private var showPasswordMismatchError = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Network User")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Text("Username")
                    .font(.caption)
                TextField("Username (lowercase, no spaces)", text: $username)
                    .textFieldStyle(.roundedBorder)

                Text("Full Name")
                    .font(.caption)
                TextField("Full Name", text: $fullName)
                    .textFieldStyle(.roundedBorder)

                Text("Password")
                    .font(.caption)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)

                Text("Confirm Password")
                    .font(.caption)
                SecureField("Confirm Password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)

                if showPasswordMismatchError {
                    Text("Passwords do not match")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Divider()

                Toggle(isOn: $addToWheel) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add to wheel group")
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

                Button("Create Network User") {
                    if password != confirmPassword {
                        showPasswordMismatchError = true
                        return
                    }

                    Task {
                        await viewModel.createNetworkUser(username: username, fullName: fullName, password: password, addToWheel: addToWheel)
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(username.isEmpty || password.isEmpty || confirmPassword.isEmpty || viewModel.isLoading)
            }
        }
        .padding()
        .frame(width: 450)
    }
}

#Preview {
    GershwinSetupView()
}
