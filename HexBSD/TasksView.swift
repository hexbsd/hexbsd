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
        if schedule == "* * * * *" {
            return "Every minute"
        } else if schedule == "0 * * * *" {
            return "Every hour"
        } else if schedule == "0 0 * * *" {
            return "Daily at midnight"
        } else if schedule == "0 0 * * 0" {
            return "Weekly on Sunday"
        } else if schedule == "0 0 1 * *" {
            return "Monthly on the 1st"
        } else if minute == "*" && hour == "*" {
            return "Every minute"
        } else if minute != "*" && hour == "*" {
            return "Every hour at :\(minute)"
        } else if hour != "*" && minute != "*" {
            return "Daily at \(hour):\(minute)"
        }
        return schedule
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(originalLine)
    }

    static func == (lhs: CronTask, rhs: CronTask) -> Bool {
        lhs.originalLine == rhs.originalLine
    }
}

// MARK: - Main View

struct TasksContentView: View {
    @StateObject private var viewModel = TasksViewModel()
    @State private var showAddTask = false
    @State private var selectedTask: CronTask?
    @State private var showError = false

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

                Button(action: {
                    Task {
                        await viewModel.refresh()
                    }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
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

                    TableColumn("Command") { task in
                        Text(task.command)
                            .font(.system(size: 11))
                            .lineLimit(2)
                            .help(task.command)
                    }
                    .width(min: 200, ideal: 300)

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

    @State private var selectedTab = 0
    @State private var command: String
    @State private var user: String

    // Simple mode
    @State private var frequency = 0 // 0=hourly, 1=daily, 2=weekly, 3=monthly
    @State private var selectedMinute = 0
    @State private var selectedHour = 0
    @State private var selectedDayOfWeek = 0
    @State private var selectedDayOfMonth = 1

    // Advanced mode
    @State private var minute: String
    @State private var hour: String
    @State private var dayOfMonth: String
    @State private var month: String
    @State private var dayOfWeek: String

    init(task: CronTask?, onSave: @escaping (String, String, String, String, String, String, String) -> Void) {
        self.task = task
        self.onSave = onSave

        if let task = task {
            _minute = State(initialValue: task.minute)
            _hour = State(initialValue: task.hour)
            _dayOfMonth = State(initialValue: task.dayOfMonth)
            _month = State(initialValue: task.month)
            _dayOfWeek = State(initialValue: task.dayOfWeek)
            _command = State(initialValue: task.command)
            _user = State(initialValue: task.user)
            _selectedTab = State(initialValue: 1) // Default to advanced for editing
        } else {
            _minute = State(initialValue: "*")
            _hour = State(initialValue: "*")
            _dayOfMonth = State(initialValue: "*")
            _month = State(initialValue: "*")
            _dayOfWeek = State(initialValue: "*")
            _command = State(initialValue: "")
            _user = State(initialValue: "root")
        }
    }

    var computedCronSchedule: (String, String, String, String, String) {
        if selectedTab == 0 {
            // Simple mode
            switch frequency {
            case 0: // Hourly
                return ("\(selectedMinute)", "*", "*", "*", "*")
            case 1: // Daily
                return ("\(selectedMinute)", "\(selectedHour)", "*", "*", "*")
            case 2: // Weekly
                return ("\(selectedMinute)", "\(selectedHour)", "*", "*", "\(selectedDayOfWeek)")
            case 3: // Monthly
                return ("\(selectedMinute)", "\(selectedHour)", "\(selectedDayOfMonth)", "*", "*")
            default:
                return ("*", "*", "*", "*", "*")
            }
        } else {
            // Advanced mode
            return (minute, hour, dayOfMonth, month, dayOfWeek)
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

            // Tab selector
            Picker("", selection: $selectedTab) {
                Text("Simple").tag(0)
                Text("Advanced").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if selectedTab == 0 {
                        // Simple mode
                        simpleScheduleView
                    } else {
                        // Advanced mode
                        advancedScheduleView
                    }

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
                Text("Hourly").tag(0)
                Text("Daily").tag(1)
                Text("Weekly").tag(2)
                Text("Monthly").tag(3)
            }
            .pickerStyle(.radioGroup)

            // Time settings based on frequency
            VStack(alignment: .leading, spacing: 12) {
                if frequency >= 1 {
                    HStack {
                        Text("At time:")
                            .frame(width: 80, alignment: .trailing)
                        Picker("Hour", selection: $selectedHour) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(String(format: "%02d:00", hour)).tag(hour)
                            }
                        }
                        .frame(width: 100)

                        Text(":")

                        Picker("Minute", selection: $selectedMinute) {
                            ForEach([0, 15, 30, 45], id: \.self) { min in
                                Text(String(format: "%02d", min)).tag(min)
                            }
                        }
                        .frame(width: 80)
                    }
                } else {
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

                if frequency == 2 {
                    HStack {
                        Text("On day:")
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

                if frequency == 3 {
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

    var advancedScheduleView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cron Expression")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    cronField("Minute", value: $minute, placeholder: "*", help: "0-59")
                    cronField("Hour", value: $hour, placeholder: "*", help: "0-23")
                    cronField("Day", value: $dayOfMonth, placeholder: "*", help: "1-31")
                    cronField("Month", value: $month, placeholder: "*", help: "1-12")
                    cronField("Weekday", value: $dayOfWeek, placeholder: "*", help: "0-6")
                }

                Text("Use * for any value, or specific numbers/ranges")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    func cronField(_ label: String, value: Binding<String>, placeholder: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            TextField(placeholder, text: value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Text(help)
                .font(.caption2)
                .foregroundColor(.secondary)
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

    private let sshManager = SSHConnectionManager.shared

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
                    let taskCmdPrefix = String(task.command.prefix(30))
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
