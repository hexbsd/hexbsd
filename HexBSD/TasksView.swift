//
//  TasksView.swift
//  HexBSD
//
//  Cron task scheduler and viewer
//

import SwiftUI
import AppKit

// MARK: - Data Models

struct CronTask: Identifiable, Hashable {
    let id = UUID()
    let minute: String
    let hour: String
    let dayOfMonth: String
    let month: String
    let dayOfWeek: String
    let command: String
    let user: String
    let enabled: Bool
    let originalLine: String
    var lastRun: String?

    init(minute: String, hour: String, dayOfMonth: String, month: String, dayOfWeek: String, command: String, user: String, enabled: Bool, originalLine: String, lastRun: String? = nil) {
        self.minute = minute
        self.hour = hour
        self.dayOfMonth = dayOfMonth
        self.month = month
        self.dayOfWeek = dayOfWeek
        self.command = command
        self.user = user
        self.enabled = enabled
        self.originalLine = originalLine
        self.lastRun = lastRun
    }

    var schedule: String {
        "\(minute) \(hour) \(dayOfMonth) \(month) \(dayOfWeek)"
    }

    var scheduleDescription: String {
        // Try to provide a human-readable description
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

        // Handle */X patterns for minutes
        if minute.hasPrefix("*/"), let interval = Int(minute.dropFirst(2)) {
            if hour == "*" && dayOfMonth == "*" && month == "*" && dayOfWeek == "*" {
                return "Every \(interval) minute\(interval == 1 ? "" : "s")"
            }
        }

        // Every minute
        if minute == "*" && hour == "*" && dayOfMonth == "*" && month == "*" && dayOfWeek == "*" {
            return "Every minute"
        }

        // Hourly at specific minute
        if let min = Int(minute), hour == "*" && dayOfMonth == "*" && month == "*" && dayOfWeek == "*" {
            return "Hourly at :\(String(format: "%02d", min))"
        }

        // Daily at specific time
        if let min = Int(minute), let hr = Int(hour), dayOfMonth == "*" && month == "*" && dayOfWeek == "*" {
            return "Daily at \(String(format: "%02d:%02d", hr, min))"
        }

        // Weekly on specific day
        if let min = Int(minute), let hr = Int(hour), let dow = Int(dayOfWeek), dayOfMonth == "*" && month == "*" {
            let dayName = dow >= 0 && dow < 7 ? days[dow] : "day \(dow)"
            return "Weekly on \(dayName) at \(String(format: "%02d:%02d", hr, min))"
        }

        // Monthly on specific day
        if let min = Int(minute), let hr = Int(hour), let dom = Int(dayOfMonth), month == "*" && dayOfWeek == "*" {
            let suffix: String
            switch dom {
            case 1, 21, 31: suffix = "st"
            case 2, 22: suffix = "nd"
            case 3, 23: suffix = "rd"
            default: suffix = "th"
            }
            return "Monthly on the \(dom)\(suffix) at \(String(format: "%02d:%02d", hr, min))"
        }

        // Fallback to cron syntax
        return schedule
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(originalLine)
    }

    static func == (lhs: CronTask, rhs: CronTask) -> Bool {
        lhs.originalLine == rhs.originalLine
    }

    // MARK: - Replication Task Detection

    /// Checks if this is a ZFS replication task created by HexBSD
    var isReplicationTask: Bool {
        command.contains("zfs snapshot") && command.contains("zfs send") && command.contains("zfs receive")
    }

    /// Parsed replication task details (nil if not a replication task)
    var replicationDetails: ReplicationTaskDetails? {
        guard isReplicationTask else { return nil }

        // Extract source dataset from: SNAP="dataset@auto-
        var sourceDataset: String?
        if let range = command.range(of: #"SNAP="([^@]+)@auto-"#, options: .regularExpression) {
            let match = String(command[range])
            sourceDataset = match
                .replacingOccurrences(of: "SNAP=\"", with: "")
                .replacingOccurrences(of: "@auto-", with: "")
        }

        // Extract target server from: ssh ... user@server 'zfs receive
        var targetServer: String?
        if let range = command.range(of: #"ssh [^']+?(\S+@\S+)\s+'zfs receive"#, options: .regularExpression) {
            let match = String(command[range])
            // Extract user@server part
            if let serverRange = match.range(of: #"\S+@\S+(?=\s+'zfs)"#, options: .regularExpression) {
                targetServer = String(match[serverRange])
            }
        }

        // Extract target dataset from: zfs receive -F dataset'
        var targetDataset: String?
        if let range = command.range(of: #"zfs receive -F ([^']+)'"#, options: .regularExpression) {
            let match = String(command[range])
            targetDataset = match
                .replacingOccurrences(of: "zfs receive -F ", with: "")
                .replacingOccurrences(of: "'", with: "")
        }

        // Extract retention seconds from: - SECONDS)); (note: two closing parens)
        var retentionSeconds: Int?
        if let range = command.range(of: #"- (\d+)\)\);"#, options: .regularExpression) {
            let match = String(command[range])
            let digits = match.filter { $0.isNumber }
            retentionSeconds = Int(digits)
        }

        return ReplicationTaskDetails(
            sourceDataset: sourceDataset ?? "Unknown",
            targetServer: targetServer ?? "Local",
            targetDataset: targetDataset ?? "Unknown",
            retentionSeconds: retentionSeconds
        )
    }
}

/// Details parsed from a replication task command
struct ReplicationTaskDetails {
    let sourceDataset: String
    let targetServer: String
    let targetDataset: String
    let retentionSeconds: Int?

    var retentionDescription: String {
        guard let seconds = retentionSeconds else { return "Forever" }
        switch seconds {
        case 0: return "Forever"
        case 3600: return "1 Hour"
        case 86400: return "1 Day"
        case 604800: return "1 Week"
        case 2592000: return "1 Month"
        case 7776000: return "3 Months"
        case 31536000: return "1 Year"
        default:
            // Fallback for other values
            if seconds < 3600 {
                return "\(seconds / 60) minutes"
            } else if seconds < 86400 {
                return "\(seconds / 3600) hours"
            } else {
                return "\(seconds / 86400) days"
            }
        }
    }
}

// MARK: - Main View

struct TasksContentView: View {
    @Environment(\.sshManager) private var sshManager

    var body: some View {
        TasksContentViewImpl(sshManager: sshManager)
    }
}

struct TasksContentViewImpl: View {
    let sshManager: SSHConnectionManager
    @StateObject private var viewModel: TasksViewModel

    init(sshManager: SSHConnectionManager) {
        self.sshManager = sshManager
        _viewModel = StateObject(wrappedValue: TasksViewModel(sshManager: sshManager))
    }
    @State private var showAddTask = false
    @State private var selectedTask: CronTask?
    @State private var showError = false
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scheduled Tasks")
                        .font(.headline)
                    Text("\(viewModel.tasks.count) task\(viewModel.tasks.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    selectedTask = nil
                    showAddTask = true
                }) {
                    Label("Add Task", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

            }
            .padding()

            Divider()

            // Content
            if viewModel.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading tasks...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.tasks.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "clock")
                        .font(.system(size: 72))
                        .foregroundColor(.secondary)
                    Text("No Scheduled Tasks")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Click the + button to create your first task")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(viewModel.tasks) {
                    TableColumn("Status") { task in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(task.enabled ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(task.enabled ? "Enabled" : "Disabled")
                                .foregroundColor(task.enabled ? .green : .secondary)
                                .font(.caption)
                        }
                    }
                    .width(min: 80, ideal: 100, max: 120)

                    TableColumn("Schedule") { task in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.scheduleDescription)
                                .font(.system(size: 12, weight: .medium))
                            Text(task.schedule)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .width(min: 150, ideal: 180)

                    TableColumn("Last Run") { task in
                        if let lastRun = task.lastRun {
                            Text(lastRun)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        } else {
                            Text("Never")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }
                    .width(min: 120, ideal: 150)

                    TableColumn("Task") { task in
                        if let details = task.replicationDetails {
                            // Replication task - show friendly details
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 10))
                                        .foregroundColor(.blue)
                                    Text("ZFS Replication")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.blue)
                                }
                                HStack(spacing: 4) {
                                    Text(details.sourceDataset)
                                        .font(.system(size: 11))
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                    Text(details.targetServer)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                HStack(spacing: 4) {
                                    Image(systemName: "clock")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                    Text("Keep: \(details.retentionDescription)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .help(task.command)
                        } else {
                            // Regular command
                            Text(task.command)
                                .font(.system(size: 11))
                                .lineLimit(2)
                                .help(task.command)
                        }
                    }
                    .width(min: 220, ideal: 320)

                    TableColumn("User", value: \.user)
                        .width(min: 60, ideal: 80)

                    TableColumn("Actions") { task in
                        HStack(spacing: 8) {
                            Button(action: {
                                selectedTask = task
                                showAddTask = true
                            }) {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("Edit task")

                            Button(action: {
                                Task {
                                    await viewModel.toggleTask(task)
                                }
                            }) {
                                Image(systemName: task.enabled ? "pause.circle" : "play.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(task.enabled ? "Disable task" : "Enable task")

                            Button(action: {
                                confirmDelete(task)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Delete task")
                        }
                    }
                    .width(min: 100, ideal: 120)
                }
            }
        }
        .sheet(isPresented: $showAddTask) {
            AddTaskView(
                task: selectedTask,
                onSave: { minute, hour, dayOfMonth, month, dayOfWeek, command, user in
                    Task {
                        if let existing = selectedTask {
                            await viewModel.updateTask(existing, minute: minute, hour: hour, dayOfMonth: dayOfMonth, month: month, dayOfWeek: dayOfWeek, command: command, user: user)
                        } else {
                            await viewModel.addTask(minute: minute, hour: hour, dayOfMonth: dayOfMonth, month: month, dayOfWeek: dayOfWeek, command: command, user: user)
                        }
                    }
                }
            )
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {
                showError = false
            }
        } message: {
            Text(viewModel.error ?? "Unknown error")
        }
        .onChange(of: viewModel.error) { oldValue, newValue in
            if newValue != nil {
                showError = true
            }
        }
        .onAppear {
            Task {
                await viewModel.loadTasks()
            }
            // Auto-refresh every 60 seconds
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                Task {
                    await viewModel.loadTasks()
                }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func confirmDelete(_ task: CronTask) {
        let alert = NSAlert()
        alert.messageText = "Delete Task?"
        alert.informativeText = "Are you sure you want to delete this cron task?\n\n\(task.command)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                await viewModel.deleteTask(task)
            }
        }
    }
}

// MARK: - Add/Edit Task View

struct AddTaskView: View {
    @Environment(\.dismiss) private var dismiss
    let task: CronTask?
    let onSave: (String, String, String, String, String, String, String) -> Void

    @State private var command: String
    @State private var user: String

    @State private var frequency = 0 // 0=minute, 1=hourly, 2=daily, 3=weekly, 4=monthly
    @State private var minuteInterval = 5 // For "every X minutes" option
    @State private var selectedMinute = 0
    @State private var selectedHour = 0
    @State private var selectedDayOfWeek = 0
    @State private var selectedDayOfMonth = 1

    init(task: CronTask?, onSave: @escaping (String, String, String, String, String, String, String) -> Void) {
        self.task = task
        self.onSave = onSave

        if let task = task {
            _command = State(initialValue: task.command)
            _user = State(initialValue: task.user)
            // Try to parse existing schedule into simple mode values
            if let min = Int(task.minute), let hr = Int(task.hour) {
                _selectedMinute = State(initialValue: min)
                _selectedHour = State(initialValue: hr)
            }
        } else {
            _command = State(initialValue: "")
            _user = State(initialValue: "root")
        }
    }

    var computedCronSchedule: (String, String, String, String, String) {
        switch frequency {
        case 0: // Every X minutes
            return ("*/\(minuteInterval)", "*", "*", "*", "*")
        case 1: // Hourly
            return ("\(selectedMinute)", "*", "*", "*", "*")
        case 2: // Daily
            return ("\(selectedMinute)", "\(selectedHour)", "*", "*", "*")
        case 3: // Weekly
            return ("\(selectedMinute)", "\(selectedHour)", "*", "*", "\(selectedDayOfWeek)")
        case 4: // Monthly
            return ("\(selectedMinute)", "\(selectedHour)", "\(selectedDayOfMonth)", "*", "*")
        default:
            return ("*", "*", "*", "*", "*")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text(task == nil ? "New Scheduled Task" : "Edit Scheduled Task")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    simpleScheduleView

                    Divider()

                    // Command section
                    commandSection
                }
                .padding()
            }
            .frame(height: 400)

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(task == nil ? "Add Task" : "Save Changes") {
                    let schedule = computedCronSchedule
                    onSave(schedule.0, schedule.1, schedule.2, schedule.3, schedule.4, command, user)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(command.isEmpty || user.isEmpty)
            }
            .padding()
        }
        .frame(width: 520)
    }

    var simpleScheduleView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Frequency")
                .font(.headline)

            Picker("Run", selection: $frequency) {
                Text("Minute").tag(0)
                Text("Hourly").tag(1)
                Text("Daily").tag(2)
                Text("Weekly").tag(3)
                Text("Monthly").tag(4)
            }
            .pickerStyle(.radioGroup)

            // Time settings based on frequency
            VStack(alignment: .leading, spacing: 12) {
                if frequency == 0 {
                    // Every X minutes
                    HStack {
                        Text("Every:")
                            .frame(width: 80, alignment: .trailing)
                        Stepper(value: $minuteInterval, in: 1...59) {
                            Text("\(minuteInterval)")
                                .frame(width: 30, alignment: .center)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(4)
                        }
                        Text("minute\(minuteInterval == 1 ? "" : "s")")
                            .foregroundColor(.secondary)
                    }
                } else if frequency >= 2 {
                    // Daily, weekly, monthly - pick time
                    HStack {
                        Text("At time:")
                            .frame(width: 80, alignment: .trailing)
                        Picker("Hour", selection: $selectedHour) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(String(format: "%02d", hour)).tag(hour)
                            }
                        }
                        .frame(width: 80)

                        Text(":")

                        Picker("Minute", selection: $selectedMinute) {
                            ForEach([0, 15, 30, 45], id: \.self) { min in
                                Text(String(format: "%02d", min)).tag(min)
                            }
                        }
                        .frame(width: 80)
                    }
                } else if frequency == 1 {
                    // Hourly - just pick minute
                    HStack {
                        Text("At minute:")
                            .frame(width: 80, alignment: .trailing)
                        Picker("Minute", selection: $selectedMinute) {
                            ForEach([0, 15, 30, 45], id: \.self) { min in
                                Text(String(format: ":%02d", min)).tag(min)
                            }
                        }
                        .frame(width: 100)
                    }
                }

                if frequency == 3 {
                    // Weekly - pick day of week
                    HStack {
                        Text("On:")
                            .frame(width: 80, alignment: .trailing)
                        Picker("Day", selection: $selectedDayOfWeek) {
                            Text("Sunday").tag(0)
                            Text("Monday").tag(1)
                            Text("Tuesday").tag(2)
                            Text("Wednesday").tag(3)
                            Text("Thursday").tag(4)
                            Text("Friday").tag(5)
                            Text("Saturday").tag(6)
                        }
                        .frame(width: 150)
                    }
                }

                if frequency == 4 {
                    // Monthly - pick day of month
                    HStack {
                        Text("On day:")
                            .frame(width: 80, alignment: .trailing)
                        Picker("Day", selection: $selectedDayOfMonth) {
                            ForEach(1...28, id: \.self) { day in
                                Text("\(day)").tag(day)
                            }
                        }
                        .frame(width: 100)
                        Text("of the month")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    var commandSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Command")
                    .font(.headline)
                TextField("e.g., /usr/local/bin/backup.sh", text: $command)
                    .textFieldStyle(.roundedBorder)
                Text("Enter the full path to the script or command")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Run as User")
                    .font(.headline)
                HStack {
                    TextField("root", text: $user)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Text("Tasks will execute with this user's permissions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - View Model

@MainActor
class TasksViewModel: ObservableObject {
    @Published var tasks: [CronTask] = []
    @Published var isLoading = false
    @Published var error: String?

    private let sshManager: SSHConnectionManager

    init(sshManager: SSHConnectionManager) {
        self.sshManager = sshManager
    }

    func loadTasks() async {
        isLoading = true
        error = nil

        do {
            var loadedTasks = try await sshManager.listCronTasks()

            // Try to get execution history from cron logs
            if let history = try? await sshManager.getCronHistory() {
                // Match history entries to tasks and update lastRun
                for i in 0..<loadedTasks.count {
                    let task = loadedTasks[i]
                    // Find the most recent history entry that matches this task's command
                    // We check if the history command contains a significant portion of the task command
                    // Note: crontab has \% but log shows % (unescaped), so we normalize both
                    let taskCmdNormalized = task.command.replacingOccurrences(of: "\\%", with: "%")
                    let taskCmdPrefix = String(taskCmdNormalized.prefix(30))
                    if let match = history.last(where: { entry in
                        entry.user == task.user && entry.command.contains(taskCmdPrefix)
                    }) {
                        loadedTasks[i] = CronTask(
                            minute: task.minute,
                            hour: task.hour,
                            dayOfMonth: task.dayOfMonth,
                            month: task.month,
                            dayOfWeek: task.dayOfWeek,
                            command: task.command,
                            user: task.user,
                            enabled: task.enabled,
                            originalLine: task.originalLine,
                            lastRun: match.timestamp
                        )
                    }
                }
            }

            tasks = loadedTasks
        } catch {
            self.error = "Failed to load tasks: \(error.localizedDescription)"
            tasks = []
        }

        isLoading = false
    }

    func refresh() async {
        await loadTasks()
    }

    func addTask(minute: String, hour: String, dayOfMonth: String, month: String, dayOfWeek: String, command: String, user: String) async {
        error = nil

        do {
            try await sshManager.addCronTask(minute: minute, hour: hour, dayOfMonth: dayOfMonth, month: month, dayOfWeek: dayOfWeek, command: command, user: user)
            await refresh()
        } catch {
            self.error = "Failed to add task: \(error.localizedDescription)"
        }
    }

    func updateTask(_ task: CronTask, minute: String, hour: String, dayOfMonth: String, month: String, dayOfWeek: String, command: String, user: String) async {
        error = nil

        do {
            // Delete old task and add new one
            try await sshManager.deleteCronTask(task)
            try await sshManager.addCronTask(minute: minute, hour: hour, dayOfMonth: dayOfMonth, month: month, dayOfWeek: dayOfWeek, command: command, user: user)
            await refresh()
        } catch {
            self.error = "Failed to update task: \(error.localizedDescription)"
        }
    }

    func deleteTask(_ task: CronTask) async {
        error = nil

        do {
            try await sshManager.deleteCronTask(task)
            await refresh()
        } catch {
            self.error = "Failed to delete task: \(error.localizedDescription)"
        }
    }

    func toggleTask(_ task: CronTask) async {
        error = nil

        do {
            try await sshManager.toggleCronTask(task)
            await refresh()
        } catch {
            self.error = "Failed to toggle task: \(error.localizedDescription)"
        }
    }
}
