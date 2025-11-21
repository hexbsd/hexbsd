# HexBSD Architecture Guide

## Quick Overview

HexBSD is a macOS SwiftUI application for managing FreeBSD servers via SSH. It uses a clean MVVM architecture with a sidebar-based navigation system.

```
USER INTERFACE (SwiftUI)
       ↓
  ContentView (Main Navigation)
       ├── SidebarSection (12 tabs)
       └── DetailView (Route to feature)
            ├── BootEnvironmentsContentView
            ├── ZFSContentView
            ├── JailsContentView
            ├── TasksContentView
            └── ... etc (11 more views)
            
       ↓ (Each feature uses)
       
  FeatureViewModel (@MainActor ObservableObject)
       └── Uses: SSHConnectionManager.shared
       
       ↓ (Which executes remote commands via)
       
  SSHConnectionManager (Singleton)
       └── SSH Client (Citadel library)
            └── FreeBSD Server (via SSH key auth)
```

## Core Components

### 1. HexBSDApp.swift
- Entry point using @main SwiftUI modifier
- Sets up SwiftData container for local storage
- Initializes model schema (currently just Item.self)

### 2. ContentView.swift (1342 lines)
- **SidebarSection** enum - defines all 12 available features
- **ContentView** - main window with NavigationSplitView
  - Sidebar: List of sections
  - Detail: Feature-specific content or server list
- **DetailView** - Routes to correct feature view
- **ConnectView** - SSH connection dialog
- **AboutView** - App information and licenses

**Key Responsibilities:**
- Server connection management
- UI navigation and routing
- Dashboard display (system metrics)
- Load/save server configurations (UserDefaults)

### 3. SSHConnectionManager.swift (2742 lines)
- **@Observable class** following modern Swift patterns
- **Singleton**: `SSHConnectionManager.shared` used everywhere
- **Manages:** SSH connection lifecycle, command execution, output parsing

**Core Methods:**
```swift
// Connection
func connect(host: String, port: Int, authMethod: SSHAuthMethod) async throws
func validateFreeBSD() async throws  // Ensure it's FreeBSD
func disconnect() async throws

// Generic command execution
func executeCommand(_ command: String) async throws -> String

// Feature-specific methods (examples):
func fetchSystemStatus() async throws -> SystemStatus
func listZFSPools() async throws -> [ZFSPool]
func listJails() async throws -> [Jail]
func listBootEnvironments() async throws -> [BootEnvironment]
func listCronTasks() async throws -> [CronTask]
// ... and ~50+ more methods
```

**Key Implementation Details:**
- Supports RSA, Ed25519, ECDSA P256 SSH keys
- Tracks CPU per-core usage over time
- Calculates network interface bandwidth rates
- Parses tab/newline-separated command output
- Comprehensive error handling with user-friendly messages

## Feature Implementation Pattern

Every feature follows this identical structure:

### Step 1: Data Models (at file top)
```swift
// Main model
struct MyItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let status: Status
    // ... other properties
}

// Status enum with computed properties
enum Status: String {
    case active, inactive
    
    var color: Color {
        switch self {
        case .active: return .green
        case .inactive: return .gray
        }
    }
    
    var icon: String {
        switch self {
        case .active: return "play.fill"
        case .inactive: return "stop.fill"
        }
    }
}
```

### Step 2: ContentView with Components
```swift
struct MyFeatureContentView: View {
    @StateObject private var viewModel = MyFeatureViewModel()
    @State private var selectedItem: MyItem?
    @State private var showError = false
    
    var body: some View {
        VStack(spacing: 0) {
            // TOOLBAR - with action buttons
            HStack {
                Text("Items: \(viewModel.items.count)")
                Spacer()
                
                // Conditional actions based on selection
                if let item = selectedItem, !item.status.isActive {
                    Button("Activate") {
                        Task { await viewModel.activate(item: item) }
                    }
                }
                
                Button("Refresh") {
                    Task { await viewModel.refresh() }
                }
            }
            .padding()
            
            Divider()
            
            // MAIN CONTENT - with loading/empty states
            if viewModel.isLoading {
                ProgressView()
            } else if viewModel.items.isEmpty {
                Text("No items found")
                    .foregroundColor(.secondary)
            } else {
                List(viewModel.items, selection: $selectedItem) { item in
                    MyItemRow(item: item)
                }
            }
        }
        
        // Error handling
        .alert("Error", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(viewModel.error ?? "Unknown error")
        }
        .onChange(of: viewModel.error) { _, newValue in
            if newValue != nil { showError = true }
        }
        
        // Load on appear
        .onAppear {
            Task { await viewModel.load() }
        }
    }
}

// Supporting views
struct MyItemRow: View {
    let item: MyItem
    
    var body: some View {
        HStack {
            Image(systemName: item.status.icon)
                .foregroundColor(item.status.color)
            
            VStack(alignment: .leading) {
                Text(item.name).font(.headline)
                Text(item.status.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
}
```

### Step 3: ViewModel (Reactive, ObservableObject)
```swift
@MainActor
class MyFeatureViewModel: ObservableObject {
    @Published var items: [MyItem] = []
    @Published var isLoading = false
    @Published var error: String?
    
    private let sshManager = SSHConnectionManager.shared
    
    // Load data
    func load() async {
        isLoading = true
        error = nil
        
        do {
            items = try await sshManager.fetchMyItems()
        } catch {
            self.error = error.localizedDescription
            items = []
        }
        
        isLoading = false
    }
    
    // Refresh (same as load)
    func refresh() async {
        await load()
    }
    
    // Action
    func activate(item: MyItem) async {
        error = nil
        do {
            try await sshManager.activateMyItem(name: item.name)
            await load()  // Refresh list
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

### Step 4: SSH Manager Methods
Add to SSHConnectionManager.swift:

```swift
// MARK: - My Feature Management

func fetchMyItems() async throws -> [MyItem] {
    let output = try await executeCommand("my-list-command -format tab")
    
    var items: [MyItem] = []
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: "\t").map(String.init)
        guard parts.count >= 2 else { continue }
        
        let item = MyItem(
            name: parts[0],
            status: Status(rawValue: parts[1]) ?? .unknown
        )
        items.append(item)
    }
    return items
}

func activateMyItem(name: String) async throws {
    _ = try await executeCommand("my-command activate \(name)")
}
```

### Step 5: Register in ContentView
Modify `ContentView.swift`:

```swift
enum SidebarSection: String, CaseIterable, Identifiable {
    // Add new case (alphabetically)
    case myFeature = "My Feature"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .myFeature: return "myicon"
        // ... other cases ...
        }
    }
}

struct DetailView: View {
    let section: SidebarSection
    
    var body: some View {
        // ... existing cases ...
        if section == .myFeature {
            MyFeatureContentView()
        }
        // ... rest of cases ...
    }
}
```

## File Organization

```
HexBSD/
├── HexBSDApp.swift                    [40 lines]
├── ContentView.swift                  [1342 lines] ← Main entry point
├── SSHConnectionManager.swift         [2742 lines] ← All SSH commands
│
├── FEATURE FILES (alphabetical):
├── BootEnvironmentsView.swift         [531 lines]  ← Simple example
├── FilesView.swift
├── JailsView.swift                    [644 lines]  ← Medium example
├── LogsView.swift
├── NetworkView.swift
├── PortsView.swift                    [673 lines]
├── PoudriereView.swift                [516 lines]
├── SecurityView.swift                 [555 lines]
├── SessionsView.swift
├── TasksView.swift                    [587 lines]  ← Cron management
├── TerminalView.swift
├── ZFSView.swift                      [2986 lines] ← Complex example
├── AppNotifications.swift
│
├── Item.swift                         ← SwiftData model (unused currently)
├── HexBSD.entitlements                ← Sandbox permissions
│
└── Assets.xcassets/
    ├── AppIcon/
    ├── AccentColor/
    └── Contents.json
```

## SSH Execution Flow

### 1. Command Execution
```
executeCommand("my-command args")
    ↓
SSHClient.executeCommand()
    ↓
    Citadel library connects to remote
    ↓
Remote FreeBSD system executes command
    ↓
Output captured (stdout + stderr combined)
    ↓
Returns String to caller
```

### 2. Output Parsing Pattern
FreeBSD tools usually output tab/newline-separated data (using `-H` flag):
```
# Example: zfs list -H
tank    1.2T    500G    200G    50%
tank/data    300G    150G    100G    75%
```

Parsing pattern:
```swift
let output = try await executeCommand("zfs list -H")
for line in output.split(separator: "\n") {
    let parts = line.split(separator: "\t").map(String.init)
    // parts[0] = name, parts[1] = size, etc.
}
```

### 3. Error Handling
Each command can throw:
- SSH connection errors
- Command not found
- Permission denied (need root)
- Parsing errors (unexpected format)

ViewModels catch these and display to user:
```swift
do {
    items = try await sshManager.fetchItems()
} catch {
    self.error = error.localizedDescription  // Shows to user
}
```

## Connection Lifecycle

1. **App Launch**
   - ContentView loads saved servers from UserDefaults
   - Shows server list if not connected

2. **User Connects**
   - ConnectView sheet opens
   - User enters host, username, selects SSH key
   - ConnectView calls `sshManager.connect()`
   - SSHConnectionManager validates FreeBSD (uname -s)
   - On success, prompts to save server config

3. **Connected State**
   - All sidebar buttons enabled
   - Can navigate to any feature
   - Dashboard auto-refreshes every 5 seconds
   - Each feature loads its own data on appear

4. **During Use**
   - Each feature view loads data independently
   - ViewModel calls SSHConnectionManager methods
   - Errors display in alerts
   - User can perform actions (create, delete, etc.)

5. **Disconnection**
   - User can close app or click disconnect
   - SSHConnectionManager closes SSH connection
   - All sidebar buttons disabled again

## Data Persistence

### Using UserDefaults:
```swift
// Saving servers
if let data = try? JSONEncoder().encode(savedServers) {
    UserDefaults.standard.set(data, forKey: "savedServers")
}

// Loading servers
if let data = UserDefaults.standard.data(forKey: "savedServers"),
   let servers = try? JSONDecoder().decode([SavedServer].self, from: data) {
    savedServers = servers
}
```

### Using SwiftData:
- Currently defined in HexBSDApp but not heavily used
- Could be extended for caching feature data
- Requires SwiftUI 5.0 (iOS 17+, macOS 14+)

## UI Patterns

### 1. Toolbar Pattern
Every feature view has a standard toolbar:
```swift
HStack {
    // Status/count info
    Text("\(items.count) items")
    
    Spacer()
    
    // Conditional action buttons
    if let selected = selectedItem {
        Button("Action") { ... }
    }
    
    // Always have refresh
    Button("Refresh") {
        Task { await viewModel.refresh() }
    }
}
.padding()
```

### 2. Loading States
```swift
if viewModel.isLoading {
    VStack(spacing: 20) {
        ProgressView().scaleEffect(1.5)
        Text("Loading...").foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

### 3. Empty States
```swift
else if viewModel.items.isEmpty {
    VStack(spacing: 20) {
        Image(systemName: "icon")
            .font(.system(size: 72))
            .foregroundColor(.secondary)
        Text("No Items")
            .font(.title2)
        Text("Description of what would appear here")
            .font(.caption)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

### 4. Modal Dialogs
For create/edit operations, use .sheet() modifier:
```swift
.sheet(isPresented: $showCreateDialog) {
    CreateItemSheet(
        onCreate: { name in
            Task {
                await viewModel.create(name: name)
                showCreateDialog = false
            }
        }
    )
}
```

## Best Practices Used

### ✓ Async/Await
- No callback hell
- Natural sequential code flow
- Proper error propagation

### ✓ @MainActor
- ViewModels run on main thread
- UI updates are safe
- No race conditions on UI state

### ✓ @StateObject / @ObservedObject
- Proper lifecycle management
- One instance per view
- Automatic cleanup

### ✓ Error Handling
- Try/catch in async operations
- User-facing error messages
- @Published error property

### ✓ Identifiable/Hashable
- Items in lists need both
- Required for List selection
- Used for proper diffing

### ✓ Separation of Concerns
- Views: Only UI
- ViewModels: Logic + state
- SSHConnectionManager: Remote commands
- Models: Data structures

## Common Commands Used

### System Info
- `uname -s` - OS name (FreeBSD)
- `uptime` - System uptime
- `sysctl` - Kernel parameters
- `df -h` - Disk usage

### Processes
- `ps aux` - Process list
- `top -bn 1` - Top output (for memory/CPU)
- `sockstat -4` - Network connections

### ZFS
- `zfs list -H` - List pools/datasets
- `zfs create` - Create dataset
- `zfs destroy` - Delete dataset
- `zfs snapshot` - Create snapshot
- `zfs send | receive` - Replicate

### Boot Environment
- `bectl list -H` - List boot environments
- `bectl create` - Create BE
- `bectl activate` - Set active BE
- `bectl destroy` - Delete BE

### Jails
- `jls` - List jails
- `jail` - Start jail
- `jexec` - Execute in jail
- `jctl` - Jail control

### Cron
- `crontab -l` - List crontab
- `crontab -e` - Edit crontab

### Packages
- `pkg info` - Installed packages
- `pkg audit` - Security audit

## Adding VM/Bhyve Feature

### New File: VMsView.swift
```swift
// Data models
struct VM: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let status: VMStatus
    let memory: String
    let vcpus: Int
    // ... more properties
}

enum VMStatus: String {
    case running, stopped, error
    var icon: String { ... }
    var color: Color { ... }
}

// Content view
struct VMsContentView: View {
    @StateObject private var viewModel = VMsViewModel()
    // ... follows standard pattern
}

// View model
@MainActor
class VMsViewModel: ObservableObject {
    @Published var vms: [VM] = []
    
    func listVMs() async { ... }
    func startVM(name: String) async { ... }
    func stopVM(name: String) async { ... }
}
```

### Add to SSHConnectionManager
```swift
func listVMs() async throws -> [VM] {
    // Parse bhyvectl or ps output
}

func startVM(name: String) async throws {
    // Execute bhyve or service command
}

func stopVM(name: String) async throws {
    // Execute bhyvectl --force-reset
}
```

### Add to ContentView
```swift
enum SidebarSection {
    case vms = "Virtual Machines"
    // ...
}

struct DetailView {
    if section == .vms {
        VMsContentView()
    }
    // ...
}
```

## Performance Considerations

1. **SSH Latency** - Each command takes time. Batch when possible.
2. **Parsing** - Simple line-by-line parsing is fast. Complex regex could be slow.
3. **Reloading** - Don't refresh too frequently. Dashboard is every 5 seconds.
4. **Memory** - Large lists (100+ items) may need pagination.
5. **UI Responsiveness** - Always use async/await to keep UI thread free.

## Testing Strategy

No automated tests are currently in place. Testing is:
1. Manual testing with live FreeBSD servers
2. Try different scenarios (empty lists, errors, large data)
3. Check SSH error messages display correctly
4. Verify parsing with various command outputs

## Future Improvements

1. **Sub-navigation** - Complex features (like ZFS) could use nested tabs
2. **Data Caching** - Use SwiftData to cache remote data
3. **Background Refresh** - Update data in background periodically
4. **Search/Filter** - Add search to large lists
5. **Favorites** - Mark important items
6. **Bulk Operations** - Select multiple items for batch actions
7. **Scripting** - User-defined command shortcuts

