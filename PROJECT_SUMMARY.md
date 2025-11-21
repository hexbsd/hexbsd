# HexBSD Project Summary

## What is HexBSD?

HexBSD is a macOS native application for managing FreeBSD servers. It provides a modern graphical interface to administrate FreeBSD systems remotely via SSH with full key-based authentication support.

Think of it as a system administration dashboard for FreeBSD, similar to how vSphere manages VMware, or how Proxmox web UI manages virtual infrastructure. But instead of just managing VMs, it manages the entire FreeBSD operating system features and services.

### Target Users
- FreeBSD server administrators
- System engineers managing FreeBSD infrastructure  
- Anyone needing a GUI for FreeBSD management instead of SSH/CLI

### Key Differentiators
- Pure macOS native (not a web app, not cross-platform)
- Beautiful modern UI using SwiftUI
- SSH-based (no agents needed on target systems)
- Single-window multi-tab interface
- Support for multiple saved server configurations

---

## Quick Facts

| Aspect | Details |
|--------|---------|
| **Language** | Swift 100% |
| **UI Framework** | SwiftUI (modern macOS app) |
| **Architecture** | MVVM (Model-View-ViewModel) |
| **Size** | ~12,200 lines of code |
| **Main Components** | 3 core + 12 feature views |
| **Dependencies** | Citadel (SSH), Crypto, NIOCore |
| **Build Target** | macOS 12.0+ |
| **Deployment** | Native app (Xcode/App Store possible) |
| **Active Development** | Yes (as of November 2025) |

---

## Features Currently Implemented

The app is organized into 12 main feature tabs:

### 1. **Dashboard**
- System status overview
- CPU usage (per-core visualization)
- Memory and ZFS ARC cache usage
- Disk I/O statistics per disk
- Network traffic per interface
- Swap, Storage, and Uptime display
- Auto-refreshes every 5 seconds

### 2. **Files**
- File browser and manager
- Navigate FreeBSD filesystem
- View file properties

### 3. **Jails**
- FreeBSD jails management
- List running and stopped jails
- Start/stop jails
- View jail configuration
- Resource monitoring per jail
- Console access to jails

### 4. **Logs**
- System log viewer
- Browse /var/log files
- Real-time log monitoring

### 5. **Ports**
- FreeBSD Ports tree browser
- Search and view port information
- Package information lookup

### 6. **Poudriere**
- Package builder status
- Monitor build jobs
- View build queues and history

### 7. **Security**
- Security vulnerability scanning
- `pkg audit` integration
- Package security status

### 8. **Sessions**
- View logged-in users
- User session information
- Active connections

### 9. **Sockets** (Network Connections)
- Network connection viewer
- `sockstat` output display
- Protocol and port information

### 10. **Tasks**
- Cron job management
- Create/edit/delete cron tasks
- Enable/disable tasks without deleting
- Schedule viewer for all users

### 11. **Terminal**
- SSH terminal emulator
- Full terminal inside the app
- Command line interface when needed

### 12. **ZFS**
- Complete ZFS pool and dataset management
- Pool creation, destruction, import/export
- Dataset management with properties
- Snapshot creation and management
- Replication to other systems (zfs send/receive)
- Pool status monitoring

### 13. **Boot Environments** (Bonus)
- FreeBSD boot environment management
- Create/clone boot environments
- Set active boot environment
- Mount/unmount for modification
- Automatic system snapshots before upgrades

---

## Project Structure at a Glance

```
HexBSD/
├── Core App Files:
│   ├── HexBSDApp.swift                 # Entry point (@main)
│   ├── ContentView.swift               # Navigation & dashboard
│   └── SSHConnectionManager.swift      # SSH command execution
│
├── Feature Views (12 files):
│   ├── BootEnvironmentsView.swift
│   ├── FilesView.swift
│   ├── JailsView.swift
│   ├── LogsView.swift
│   ├── NetworkView.swift
│   ├── PortsView.swift
│   ├── PoudriereView.swift
│   ├── SecurityView.swift
│   ├── SessionsView.swift
│   ├── TasksView.swift
│   ├── TerminalView.swift
│   └── ZFSView.swift
│
├── Supporting Files:
│   ├── AppNotifications.swift
│   ├── Item.swift
│   ├── HexBSD.entitlements
│   └── Assets.xcassets/
│
└── Xcode Project: HexBSD.xcodeproj/
```

**Total Lines of Code:**
- HexBSDApp.swift: 40 lines
- ContentView.swift: 1,342 lines
- SSHConnectionManager.swift: 2,742 lines
- Feature views combined: ~6,000 lines
- **Total: ~12,200 lines**

---

## How It Works

### 1. User Connection
```
User opens HexBSD
   ↓
Chooses saved server or enters new one
   ↓
Selects SSH private key
   ↓
App connects via SSH
   ↓
Validates target is FreeBSD (checks uname -s)
   ↓
Optionally saves server config to UserDefaults
   ↓
User sees Dashboard with live system stats
```

### 2. Feature Usage
```
User clicks a feature tab (e.g., "ZFS")
   ↓
ZFSContentView loads with ViewModel
   ↓
ViewModel calls SSHConnectionManager
   ↓
SSH command executes on FreeBSD (e.g., "zfs list -H")
   ↓
Output parsed into Swift objects
   ↓
SwiftUI re-renders with new data
   ↓
User can perform actions (create, delete, etc.)
```

### 3. SSH Execution
```
executeCommand("some command")
   ↓
Citadel SSH library connection
   ↓
Remote system executes command
   ↓
Output captured and returned as String
   ↓
Caller parses the output
   ↓
Objects created from parsed data
```

---

## Technology Stack

### Core Frameworks
- **SwiftUI** - Modern UI framework (macOS 12+)
- **Swift Concurrency** - Async/await for non-blocking operations
- **Combine** - Reactive programming (some legacy usage)
- **SwiftData** - Local data persistence

### External Dependencies
- **Citadel** - SSH client library for FreeBSD
- **Crypto / _CryptoExtras** - SSH key cryptography
- **NIOCore / NIOSSH** - Network I/O for SSH

### Target & Requirements
- macOS 12.0 or later
- Xcode 15.0+
- Native Apple Silicon (M1/M2/M3) and Intel support

---

## Code Quality & Architecture

### Strengths
- Clean MVVM architecture
- Consistent patterns across all features
- Proper async/await usage (no callbacks)
- Good error handling with user-facing messages
- Modern SwiftUI (@main, @Observable, @MainActor)
- Single SSH connection shared across app (singleton pattern)

### File Sizes (Largest Files)
| File | Lines | Complexity |
|------|-------|-----------|
| SSHConnectionManager.swift | 2,742 | High - All SSH commands |
| ZFSView.swift | 2,986 | High - Most features |
| ContentView.swift | 1,342 | Medium - Navigation hub |
| BootEnvironmentsView.swift | 531 | Low - Good example |
| JailsView.swift | 644 | Low-Medium - Good reference |
| TasksView.swift | 587 | Low-Medium - Cron management |

### Architectural Decisions
- **Single SSH Connection** - Reused across entire app
- **Singleton SSHConnectionManager** - Shared state pattern
- **@MainActor ViewModels** - Ensures UI thread safety
- **Tab-based Navigation** - 12 feature tabs from enum
- **Modal Dialogs** - Create/edit operations use .sheet()
- **UserDefaults** - Save server configs locally

---

## Recent Development

### Latest Commits (as of Nov 20, 2025)
1. **Improvements to ZFS** - Latest work
2. **Fix replication** - ZFS send/receive fixes
3. **Changes to ZFS** - Feature additions
4. **Remove features and add tasks** - Refactoring
5. **Add WIP firewall feature** - In progress work

### Current Status
- On main branch only (no feature branches)
- Active development (commits within days)
- Working features (ZFS, Jails, Boot Environments, etc.)
- No existing VM/Bhyve code (clean slate for VM feature)

---

## For VM/Bhyve Integration

### Readiness
- **Clean Codebase** - No existing VM code
- **Clear Pattern** - Easy to follow for new features
- **Simple Example** - BootEnvironmentsView is perfect template
- **SSH Commands** - bhyvectl and ps available on FreeBSD

### What Would Be Needed

**New File: VMsView.swift** (~500-1000 lines)
- VM list with status
- Start/stop/reset controls
- VM details display
- Console access if available

**SSHConnectionManager additions** (~200-300 lines)
- `listVMs()` - Parse bhyvectl output
- `startVM(name)` - Execute bhyve commands
- `stopVM(name)` - Force reset or shutdown
- `getVMStats(name)` - Resource usage
- `createVM(config)` - New VM creation

**ContentView.swift changes** (~20 lines)
- Add `case vms = "Virtual Machines"` to SidebarSection
- Add icon for VMs (e.g., "desktopcomputer")
- Add routing in DetailView: `if section == .vms { VMsContentView() }`

### Integration Points
1. **ContentView.swift** - Navigation
2. **SSHConnectionManager.swift** - SSH commands
3. **VMsView.swift** - UI and ViewModel (new file)

---

## Development Workflow

### Setting Up Development
```bash
# Clone the repository
git clone https://github.com/user/HexBSD.git
cd HexBSD

# Open in Xcode
open HexBSD.xcodeproj

# Build (Xcode menu: Product → Build)
# Run (Xcode menu: Product → Run)
```

### Adding a New Feature
1. Create new Swift file: `FeatureView.swift`
2. Define models (struct + enum with status)
3. Create FeatureContentView (main UI)
4. Create FeatureViewModel (@MainActor ObservableObject)
5. Add methods to SSHConnectionManager
6. Register in ContentView (SidebarSection + DetailView)
7. Test with FreeBSD server

### Code Style
- SwiftUI conventions
- No force unwraps (use guard/if let)
- Meaningful variable names
- Comments for complex logic
- Error handling with user messages

---

## Deployment

### Current State
- Fully functional macOS app
- Ready for distribution
- No external servers required (SSH only)

### Distribution Options
1. **Direct (DIY)** - Build and run from source
2. **App Store** - Requires Apple Developer account, code signing
3. **Direct download** - Build binary and share
4. **GitHub releases** - Automated builds with Actions

### Requirements for Users
- macOS 12.0+
- FreeBSD server with SSH access
- SSH private key (RSA/Ed25519/ECDSA P256)
- Root access on target (for some features)

---

## Getting Started as a Developer

### To Understand the Codebase
1. Read **ARCHITECTURE.md** (comprehensive guide)
2. Open **BootEnvironmentsView.swift** (simplest feature)
3. Review **ContentView.swift** (navigation/routing)
4. Study **SSHConnectionManager.swift** (command execution)
5. Look at another feature like **JailsView.swift** (reference)

### To Add VM Management
1. Create `VMsView.swift` following pattern
2. Add VM methods to `SSHConnectionManager.swift`
3. Register in `ContentView.swift` SidebarSection
4. Test against FreeBSD system with bhyve

### Key Files to Modify
- **Must**: ContentView.swift, SSHConnectionManager.swift
- **Create**: VMsView.swift
- **Reference**: BootEnvironmentsView.swift, JailsView.swift

---

## Testing

### Current Approach
- Manual testing with live FreeBSD systems
- No automated unit tests
- Integration testing required

### Testing VM Feature
1. Setup FreeBSD with bhyve
2. Create test VMs using bhyvectl
3. Run HexBSD against test system
4. Verify:
   - VM list loads correctly
   - Start/stop operations work
   - Stats display accurately
   - Error cases handled gracefully

---

## Documentation Files

In the project directory, you'll find:
- **ARCHITECTURE.md** - Complete technical reference
- **PROJECT_SUMMARY.md** - This file
- **HexBSD.entitlements** - App permissions

---

## Next Steps

To get started with the VM feature:

1. **Read** ARCHITECTURE.md (full technical details)
2. **Review** BootEnvironmentsView.swift (template to follow)
3. **Examine** SSHConnectionManager.swift (understand bhyve commands)
4. **Plan** VM feature scope (which commands/features)
5. **Implement** VMsView.swift (follow the pattern)
6. **Add** methods to SSHConnectionManager
7. **Register** in ContentView
8. **Test** against FreeBSD system

---

## Questions & Exploration

To better understand specific aspects:

- **SSH implementation**: Check SSHConnectionManager lines 1-150
- **Command execution**: Check SSHConnectionManager.executeCommand()
- **UI patterns**: Check BootEnvironmentsView.swift
- **Navigation**: Check ContentView.swift DetailView struct
- **Data persistence**: Check ContentView.swift for UserDefaults usage
- **View models**: Check any feature's ViewModel class
- **Parsing**: Check ZFSView.swift for complex parsing examples

---

## Summary

HexBSD is a well-structured, actively developed macOS application for FreeBSD system administration. It demonstrates excellent SwiftUI architecture, clean code organization, and thoughtful feature design. The codebase is ready for VM management feature addition with a clear pattern to follow and no existing VM code to conflict with.

The project is ideal for:
- Learning SwiftUI architecture patterns
- Understanding SSH client implementation in Swift
- System administration UI design
- FreeBSD platform management

All documentation and code patterns are in place to add new features quickly and consistently.

