# HexBSD Quick Reference Guide

## Project Overview in 30 Seconds

**HexBSD** = macOS SwiftUI app for managing FreeBSD servers via SSH

- **Language**: Swift 100%
- **Size**: 12,200 LOC
- **Features**: 12 admin tabs (ZFS, Jails, Boot Envs, Tasks, etc.)
- **Architecture**: MVVM with singleton SSH manager
- **No existing VM code** = Clean slate for new features

---

## File Guide

### The Three Core Files

| File | Lines | Purpose |
|------|-------|---------|
| **HexBSDApp.swift** | 40 | Entry point, SwiftData setup |
| **ContentView.swift** | 1,342 | Navigation, Dashboard, Server list |
| **SSHConnectionManager.swift** | 2,742 | All SSH commands, output parsing |

### Feature Files (Pick One to Understand Pattern)
- **BootEnvironmentsView.swift** (531 lines) - **START HERE** - Simplest
- **JailsView.swift** (644 lines) - Good reference
- **TasksView.swift** (587 lines) - Cron example
- **ZFSView.swift** (2,986 lines) - Most complex

---

## Feature Implementation Pattern (Minimal)

### 1. Create File: FeatureView.swift
```swift
import SwiftUI

// MARK: - Models
struct Item: Identifiable, Hashable {
    let id = UUID()
    let name: String
}

// MARK: - Main View
struct FeatureContentView: View {
    @StateObject private var viewModel = FeatureViewModel()
    
    var body: some View {
        VStack {
            // Toolbar
            HStack {
                Text("\(viewModel.items.count) items")
                Spacer()
                Button("Refresh") {
                    Task { await viewModel.load() }
                }
            }
            .padding()
            
            // Content
            if viewModel.isLoading {
                ProgressView()
            } else if viewModel.items.isEmpty {
                Text("No items")
            } else {
                List(viewModel.items) { item in
                    Text(item.name)
                }
            }
        }
        .onAppear { Task { await viewModel.load() } }
    }
}

// MARK: - ViewModel
@MainActor
class FeatureViewModel: ObservableObject {
    @Published var items: [Item] = []
    @Published var isLoading = false
    @Published var error: String?
    
    private let ssh = SSHConnectionManager.shared
    
    func load() async {
        isLoading = true
        do {
            items = try await ssh.listItems()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
```

### 2. Add to SSHConnectionManager.swift
```swift
// MARK: - Feature Management

func listItems() async throws -> [Item] {
    let output = try await executeCommand("my-command -H")
    var items: [Item] = []
    
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: "\t").map(String.init)
        guard parts.count >= 1 else { continue }
        items.append(Item(name: parts[0]))
    }
    
    return items
}
```

### 3. Register in ContentView.swift
```swift
enum SidebarSection: String, CaseIterable {
    case feature = "Feature"  // Add this line
    // ... other cases
    
    var icon: String {
        switch self {
        case .feature: return "myicon"  // Add this
        // ... other cases
        }
    }
}

struct DetailView: View {
    var body: some View {
        if section == .feature {  // Add this
            FeatureContentView()
        }
        // ... other sections
    }
}
```

---

## Common SSH Commands Used

### For VM/Bhyve Feature
```
# List VMs
ps aux | grep bhyve
bhyvectl --vm=<name> --info
bhyvectl --list

# Start/Stop
bhyve -c cpus -m memory -A -H -P -s ...
bhyvectl --vm=<name> --force-reset

# Get stats
bhyvectl --vm=<name> --get-stats
```

### Other Examples (Learn From)
```
# ZFS
zfs list -H
zfs create pool/dataset
zfs destroy pool/dataset

# Boot Environments
bectl list -H
bectl create <name>
bectl activate <name>

# Jails
jls
jail -c <config>

# Cron
crontab -l -u <user>
crontab -u <user> -
```

---

## Key Concepts

### MVVM Pattern
```
View (SwiftUI)
  ↓ uses
ViewModel (@MainActor, @Published)
  ↓ calls
SSHConnectionManager (Singleton)
  ↓ executes
RemoteCommand via SSH
```

### Async/Await Pattern
```swift
// In ViewModel:
@MainActor
func doAction() async {
    do {
        let result = try await ssh.remoteAction()  // Waits for SSH
        self.data = result  // Updates @Published on main thread
    } catch {
        self.error = error.localizedDescription
    }
}
```

### Observable vs ObservableObject
```swift
// New style (SSHConnectionManager)
@Observable class SSHConnectionManager {
    var isConnected: Bool = false
}

// Old style (ViewModels)
@MainActor class ViewModel: ObservableObject {
    @Published var items: [Item] = []
}
```

---

## Add VM Feature - Checklist

- [ ] Create `VMsView.swift` with VMsContentView + VMsViewModel
- [ ] Add `listVMs()` method to SSHConnectionManager
- [ ] Add `startVM(name)` method to SSHConnectionManager
- [ ] Add `stopVM(name)` method to SSHConnectionManager
- [ ] Add `case vms = "Virtual Machines"` to SidebarSection enum
- [ ] Add VM icon to SidebarSection.icon switch
- [ ] Add routing in DetailView: `if section == .vms { VMsContentView() }`
- [ ] Test VM list loads
- [ ] Test VM control works
- [ ] Test error handling

---

## Testing Quick Commands

### Check What's Available on Your FreeBSD
```bash
# Can you list VMs?
bhyvectl --list

# Can you get bhyve processes?
ps aux | grep bhyve

# Can you run as root?
sudo -l

# Check bhyve is installed
which bhyve
which bhyvectl
```

### Test SSH Command Parsing
```bash
# Get tab-separated output (what HexBSD parses)
bhyvectl --list 2>/dev/null || echo "test"

# Format output for easier parsing
ps aux | grep bhyve | grep -v grep
```

---

## File Locations

```
/Users/jmaloney/Projects/HexBSD/

├── HexBSD/                           ← All source files here
│   ├── HexBSDApp.swift               ← Start here to understand app
│   ├── ContentView.swift             ← Modify for new features
│   ├── SSHConnectionManager.swift    ← Add SSH commands here
│   ├── BootEnvironmentsView.swift    ← Copy this pattern
│   └── ... (other features)
│
├── ARCHITECTURE.md                   ← Full technical guide
├── PROJECT_SUMMARY.md                ← This overview
└── QUICK_REFERENCE.md                ← This file
```

---

## Common Errors & Solutions

### "Permission denied"
- Feature requires root access
- Solution: User must connect as root on FreeBSD

### "Command not found"
- bhyvectl/zfs/bectl not installed
- Solution: Check if bhyve is installed: `which bhyvectl`

### "SSH connection failed"
- Wrong host/user/key
- Not FreeBSD system
- Solution: Check server with `uname -s` == "FreeBSD"

### "Parsing error"
- Command output format changed
- Empty result set
- Solution: Test command on FreeBSD directly, check output format

---

## Performance Tips

1. **Batch operations** - Combine multiple commands if possible
2. **Cache data** - Don't refresh too frequently
3. **Async operations** - Always use `async throws` for SSH
4. **Error messages** - Show user-friendly errors, not raw output

---

## Code Style Guide

### Do:
```swift
// Use guard/if let
guard let value = optional else { return }

// Use async/await
func doSomething() async throws -> String {
    return try await executeCommand("cmd")
}

// Meaningful names
let allRunningVMs: [VM] = []

// Error handling
do {
    result = try await ...
} catch {
    self.error = error.localizedDescription
}
```

### Don't:
```swift
// Force unwrap
let value = optional!  // BAD

// Nested callbacks
executeCommand("cmd") { result in { ... } }  // BAD

// Single letter variables
let v = [VM]()  // BAD

// Silent failures
try? ...  // BAD without error reporting
```

---

## Feature Scope for VM Management

### Minimum Viable (MVP)
- List VMs with status
- Start/stop buttons
- Show basic VM info

### Nice to Have
- CPU/memory usage per VM
- Create VM dialog
- Delete VM option
- Force reset button

### Advanced (Later)
- VM console/VNC access
- Snapshots (if ZFS-backed)
- Network config
- Storage management

---

## Deploy/Build

### For Development
```bash
cd /Users/jmaloney/Projects/HexBSD
open HexBSD.xcodeproj
# Xcode → Product → Run
```

### For Distribution
```bash
# Build archive in Xcode
# Xcode → Product → Archive
# Then export/notarize/sign
```

### Requirements for Users
- macOS 12.0+
- SSH key (RSA/Ed25519/ECDSA P256)
- FreeBSD server access
- Root access on target (for some features)

---

## Useful Resources

### In This Project
- `BootEnvironmentsView.swift` - Simplest working feature
- `JailsView.swift` - Medium complexity example
- `SSHConnectionManager.swift` - All SSH commands documented

### Bhyve/VM Info
- FreeBSD Bhyve Wiki: https://wiki.freebsd.org/bhyve
- bhyvectl man page: `man bhyvectl`
- bhyve man page: `man bhyve`

### SwiftUI Documentation
- Apple Developer: https://developer.apple.com/swiftui
- Async/Await: https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html

---

## One-Liner Debugging

```swift
// Print SSH manager state
print("Connected: \(SSHConnectionManager.shared.isConnected)")

// Test command execution
Task {
    let result = try await SSHConnectionManager.shared.executeCommand("uname -a")
    print(result)
}

// Check ViewModel state
print("Items: \(viewModel.items.count), Loading: \(viewModel.isLoading)")
```

---

## Summary

1. **Understand**: Read ARCHITECTURE.md
2. **Learn**: Study BootEnvironmentsView.swift pattern
3. **Create**: New VMsView.swift file
4. **Add**: Methods to SSHConnectionManager
5. **Register**: In ContentView.swift
6. **Test**: Against FreeBSD with bhyve
7. **Deploy**: Build and run

The codebase is clean, well-organized, and ready for VM feature addition!

