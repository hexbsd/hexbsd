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

struct GershwinSetupState {
    var zfsDatasets: [ZFSDatasetStatus] = []
    var userConfig: UserConfigStatus?
    var networkDomain: NetworkDomainStatus?
    var bootEnvironment: String?
    var zpoolRoot: String?

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

    private let sshManager = SSHConnectionManager.shared

    func loadSetupState() async {
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

            // Set initial network role based on detection
            selectedNetworkRole = network.role

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
        error = nil

        do {
            // Check and install required packages
            guard let userConfig = setupState.userConfig else {
                throw NSError(domain: "GershwinSetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "User config status not loaded"])
            }

            // Install zsh if not present
            if !userConfig.zshInstalled {
                _ = try await sshManager.executeCommand("pkg install -y zsh")
            }

            // Install zsh-autosuggestions if not present
            if !userConfig.zshAutosuggestionsInstalled {
                _ = try await sshManager.executeCommand("pkg install -y zsh-autosuggestions")
            }

            // Install zsh-completions if not present
            if !userConfig.zshCompletionsInstalled {
                _ = try await sshManager.executeCommand("pkg install -y zsh-completions")
            }

            // Create .zshrc configuration in /usr/share/skel if not present
            if !userConfig.zshrcConfigured {
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

            // Reload state
            await loadSetupState()

        } catch {
            self.error = "Failed to configure user settings: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func setupNetworkDomain() async {
        isLoading = true
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

            // Reload state
            await loadSetupState()

        } catch {
            self.error = "Failed to configure network domain: \(error.localizedDescription)"
        }

        isLoading = false
    }

    private func setupNetworkServer() async throws {
        // Configure NIS server
        _ = try await sshManager.executeCommand("sysrc nisdomainname=\"\(nisDomainName)\"")
        _ = try await sshManager.executeCommand("sysrc nis_server_enable=\"YES\"")
        _ = try await sshManager.executeCommand("sysrc nis_yppasswdd_enable=\"YES\"")

        // Configure NFS server
        _ = try await sshManager.executeCommand("sysrc rpcbind_enable=\"YES\"")
        _ = try await sshManager.executeCommand("sysrc nfs_server_enable=\"YES\"")
        _ = try await sshManager.executeCommand("sysrc mountd_enable=\"YES\"")
        _ = try await sshManager.executeCommand("sysrc rpc_lockd_enable=\"YES\"")

        // Create /etc/exports if it doesn't exist
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
        let zfsCheck = try await sshManager.executeCommand("zfs list -H -o name /Network 2>/dev/null || echo 'none'")
        let networkDataset = zfsCheck.trimmingCharacters(in: .whitespacesAndNewlines)
        var removedLocalDataset = false

        if networkDataset != "none" && !networkDataset.isEmpty {
            // /Network is a ZFS dataset - need to unmount and destroy it for NFS client
            _ = try await sshManager.executeCommand("zfs unmount /Network 2>&1 || true")
            _ = try await sshManager.executeCommand("zfs destroy \(networkDataset) 2>&1 || true")
            removedLocalDataset = true
        }

        // Configure NIS client
        _ = try await sshManager.executeCommand("sysrc nisdomainname=\"\(nisDomainName)\"")
        _ = try await sshManager.executeCommand("sysrc nis_client_enable=\"YES\"")

        // Configure NFS client
        _ = try await sshManager.executeCommand("sysrc nfs_client_enable=\"YES\"")
        _ = try await sshManager.executeCommand("sysrc rpc_lockd_enable=\"YES\"")

        // Update /etc/nsswitch.conf
        let nsswitchContent = """
group: nis files
group_compat: nis
hosts: files dns
netgroup: compat
networks: files
passwd: nis files
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
        let fstabContent = try await sshManager.executeCommand("cat /etc/fstab 2>/dev/null || echo ''")
        if !fstabContent.contains("/Network") {
            let fstabEntry = "\(nisServerAddress):/Network         /Network        nfs     rw              0       0"
            _ = try await sshManager.executeCommand("echo '\(fstabEntry)' >> /etc/fstab")
        }

        // Create /Network directory if it doesn't exist
        _ = try await sshManager.executeCommand("mkdir -p /Network")

        // Start NIS client service
        _ = try await sshManager.executeCommand("/etc/netstart")
        _ = try await sshManager.executeCommand("service ypbind start 2>&1 || true")

        // Start NFS client services
        _ = try await sshManager.executeCommand("service nfsclient start 2>&1 || true")
        _ = try await sshManager.executeCommand("service lockd start 2>&1 || true")

        // Mount the network share
        _ = try await sshManager.executeCommand("mount /Network 2>&1 || true")

        // Verify NIS connectivity
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Refresh button
                HStack {
                    Spacer()

                    Button(action: {
                        Task {
                            await viewModel.loadSetupState()
                        }
                    }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoading)
                }

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

                // Phase 1: ZFS Datasets
                SetupPhaseCard(
                    title: "ZFS Datasets",
                    icon: "cylinder.split.1x2",
                    status: viewModel.setupState.zfsDatasets.allSatisfy({ $0.status == .configured }) ? .configured :
                            viewModel.setupState.zfsDatasets.isEmpty ? .pending : .partiallyConfigured
                ) {
                    ZFSDatasetsPhase(viewModel: viewModel)
                }

                // Phase 2: User Configuration
                SetupPhaseCard(
                    title: "User Configuration",
                    icon: "person.circle",
                    status: viewModel.setupState.userConfig?.status ?? .pending
                ) {
                    UserConfigPhase(viewModel: viewModel)
                }

                // Phase 3: Network Domain
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await viewModel.loadSetupState()
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

struct ZFSDatasetsPhase: View {
    @ObservedObject var viewModel: GershwinSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gershwin requires three ZFS datasets with specific mountpoints:")
                .font(.caption)
                .foregroundColor(.secondary)

            if let bootEnv = viewModel.setupState.bootEnvironment {
                Text("Boot Environment: \(bootEnv)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(viewModel.setupState.zfsDatasets, id: \.name) { dataset in
                    DatasetRow(dataset: dataset)
                }
            }

            Button(action: {
                Task {
                    await viewModel.setupZFSDatasets()
                }
            }) {
                Label("Create Missing Datasets", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isLoading || viewModel.setupState.zfsDatasets.allSatisfy { $0.status == .configured })

            // Info about /Network dataset - only show if role is selected
            if viewModel.selectedNetworkRole == .server {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Note: The /Network dataset is for servers only.")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("This dataset will be used to share applications and user data with client machines via NFS.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.1))
                )
            } else if viewModel.selectedNetworkRole == .client {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Note: /Network dataset is not created for client machines.")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("Client machines will mount /Network from the server via NFS after configuring the Network Domain.")
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
        }
    }
}

struct DatasetRow: View {
    let dataset: ZFSDatasetStatus

    var body: some View {
        HStack {
            Image(systemName: dataset.status.icon)
                .foregroundColor(dataset.status.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(dataset.name)
                    .font(.system(.body, design: .monospaced))
                Text(dataset.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if dataset.exists {
                if dataset.correctLocation {
                    Text("Configured")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text("Wrong Location")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            } else {
                Text("Missing")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct UserConfigPhase: View {
    @ObservedObject var viewModel: GershwinSetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure user account settings with zsh and Gershwin defaults:")
                .font(.caption)
                .foregroundColor(.secondary)

            if let config = viewModel.setupState.userConfig {
                // Prerequisites section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Prerequisites:")
                        .font(.caption)
                        .fontWeight(.semibold)

                    PackageRow(label: "zsh", installed: config.zshInstalled)
                    PackageRow(label: "zsh-autosuggestions", installed: config.zshAutosuggestionsInstalled)
                    PackageRow(label: "zsh-completions", installed: config.zshCompletionsInstalled)
                    PackageRow(label: ".zshrc config", installed: config.zshrcConfigured)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )

                // Configuration section
                VStack(alignment: .leading, spacing: 8) {
                    Text("adduser.conf Settings:")
                        .font(.caption)
                        .fontWeight(.semibold)

                    ConfigRow(label: "Home Prefix", value: config.homePrefix, expected: "/Local/Users")
                    ConfigRow(label: "Default Shell", value: config.defaultShell, expected: "/usr/local/bin/zsh")
                    ConfigRow(label: "UID Start", value: config.uidStart, expected: "1001")
                }
            }

            Button(action: {
                Task {
                    await viewModel.setupUserConfig()
                }
            }) {
                if let config = viewModel.setupState.userConfig, !config.hasAllPrerequisites {
                    Label("Install Packages & Configure", systemImage: "arrow.down.circle.fill")
                } else {
                    Label(viewModel.setupState.userConfig?.status == .configured ? "Reconfigure" : "Configure User Settings", systemImage: "gear")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isLoading)
        }
    }
}

struct PackageRow: View {
    let label: String
    let installed: Bool

    var body: some View {
        HStack {
            Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(installed ? .green : .red)
                .font(.caption)

            Text(label)
                .font(.caption)

            Spacer()

            Text(installed ? "Installed" : "Missing")
                .font(.caption)
                .foregroundColor(installed ? .green : .red)
        }
    }
}

struct ConfigRow: View {
    let label: String
    let value: String
    let expected: String

    var isCorrect: Bool {
        value == expected
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            Text(value.isEmpty ? "(not set)" : value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(isCorrect ? .green : (value.isEmpty ? .secondary : .orange))

            Spacer()

            if !value.isEmpty {
                Image(systemName: isCorrect ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundColor(isCorrect ? .green : .orange)
                    .font(.caption)
            }
        }
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
                    Task {
                        await viewModel.loadSetupState()
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

            Button(action: {
                Task {
                    await viewModel.setupNetworkDomain()
                }
            }) {
                Label("Configure Network Domain", systemImage: "network")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isLoading || viewModel.selectedNetworkRole == .none)
        }
    }
}

#Preview {
    GershwinSetupView()
}
