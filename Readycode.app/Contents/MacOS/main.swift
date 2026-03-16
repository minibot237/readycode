import SwiftUI
import Foundation
import Darwin

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // PTY cleanup happens via AppState.stop()
    }
}

// MARK: - State

@Observable
class AppState {
    // Setup
    var workingFolder: String = ""
    var taskText: String = ""
    var taskFilePath: String = ""
    var useTaskFile: Bool = false
    var additionalInstructions: String = ""

    // Run state
    var runState: RunState = .idle
    var todoItems: [TodoItem] = []
    var logEntries: [LogEntry] = []
    var elapsedSeconds: Int = 0
    var blockedQuestion: String? = nil
    var blockedAnswer: String = ""

    // Sessions
    var thinkerSession: PTYSession?
    var implementerSession: PTYSession?

    // Logging
    var diskLogger: DiskLogger?

    // Timer
    var runTimer: Timer?
    var startTime: Date?

    // MARK: - Actions

    func start() {
        guard runState == .idle || runState == .complete || runState == .error else { return }
        guard !workingFolder.isEmpty else {
            addLog(.system, "No working folder set")
            return
        }

        let task = resolveTask()
        guard !task.isEmpty else {
            addLog(.system, "No task provided")
            return
        }

        // Reset state
        todoItems = []
        logEntries = []
        elapsedSeconds = 0
        blockedQuestion = nil
        runState = .running
        startTime = Date()

        // Start disk logger
        let logDir = logsDirectory()
        diskLogger = DiskLogger(directory: logDir)
        addLog(.system, "Logging to \(logDir)")

        // Start elapsed timer
        runTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.startTime else { return }
            self.elapsedSeconds = Int(Date().timeIntervalSince(start))
        }

        // Spawn sessions
        addLog(.system, "Starting thinker session...")
        thinkerSession = PTYSession(label: "thinker", workingDirectory: workingFolder, logger: diskLogger)
        thinkerSession?.onOutput = { [weak self] text in
            self?.handleThinkerOutput(text)
        }
        thinkerSession?.spawn()

        addLog(.system, "Starting implementer session...")
        implementerSession = PTYSession(label: "implementer", workingDirectory: workingFolder, logger: diskLogger)
        implementerSession?.onOutput = { [weak self] text in
            self?.handleImplementerOutput(text)
        }
        implementerSession?.spawn()

        // Send the initial prompt to the thinker after a delay (let CC boot)
        addLog(.system, "Waiting for sessions to initialize...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, self.runState == .running else { return }
            self.sendInitialPrompt(task: task)
        }
    }

    func stop() {
        runState = .idle
        runTimer?.invalidate()
        runTimer = nil
        thinkerSession?.terminate()
        implementerSession?.terminate()
        thinkerSession = nil
        implementerSession = nil
        addLog(.system, "Stopped")
    }

    func pause() {
        guard runState == .running else { return }
        runState = .paused
        addLog(.system, "Paused — will finish current step before stopping")
    }

    func resume() {
        guard runState == .paused || runState == .blocked else { return }
        if runState == .blocked, !blockedAnswer.isEmpty {
            // Feed the answer back to the thinker
            addLog(.system, "Answering blocked question: \(blockedAnswer)")
            thinkerSession?.write(blockedAnswer + "\n")
            blockedQuestion = nil
            blockedAnswer = ""
        }
        runState = .running
        addLog(.system, "Resumed")
    }

    // MARK: - Task Resolution

    func resolveTask() -> String {
        if useTaskFile && !taskFilePath.isEmpty {
            do {
                return try String(contentsOfFile: taskFilePath, encoding: .utf8)
            } catch {
                addLog(.system, "Failed to read task file: \(error.localizedDescription)")
                return ""
            }
        } else if !taskText.isEmpty {
            // Write to a file for persistence
            let taskDir = workingFolder + "/.readycode"
            try? FileManager.default.createDirectory(atPath: taskDir, withIntermediateDirectories: true)
            let taskFile = taskDir + "/task.md"
            try? taskText.write(toFile: taskFile, atomically: true, encoding: .utf8)
            addLog(.system, "Task saved to \(taskFile)")
            return taskText
        }
        return ""
    }

    // MARK: - Orchestration

    func sendInitialPrompt(task: String) {
        var prompt = """
        You are the THINKER in a two-agent system called readycode. Your job is to plan and coordinate long-running work on a codebase.

        IMPORTANT: Your first response must be a numbered todo list of all the steps needed to complete this task. Format each item as:
        TODO: 1. [description]
        TODO: 2. [description]
        etc.

        After the todo list, output the first implementation prompt, wrapped in these markers:
        <<<IMPL_PROMPT>>>
        [your prompt for the implementer]
        <<<END_IMPL_PROMPT>>>

        When you receive results back, evaluate progress and either:
        - Output DONE: [n] to mark todo item n as complete
        - Output the next <<<IMPL_PROMPT>>>...<<<END_IMPL_PROMPT>>> block
        - Output BLOCKED: [question] if you need human input
        - Output ALL_COMPLETE when everything is done

        THE TASK:
        \(task)
        """

        if !additionalInstructions.isEmpty {
            prompt += "\n\nADDITIONAL INSTRUCTIONS:\n\(additionalInstructions)"
        }

        addLog(.thinker, "Sending initial prompt with task")
        thinkerSession?.write(prompt + "\n")
    }

    func handleThinkerOutput(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Log raw output
            self.diskLogger?.log(source: "thinker", text: text)

            // Parse for our markers
            let lines = text.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Todo items
                if trimmed.hasPrefix("TODO:") {
                    let item = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    // Strip leading number + dot
                    let cleaned = item.replacingOccurrences(of: #"^\d+\.\s*"#, with: "", options: .regularExpression)
                    if !cleaned.isEmpty {
                        self.todoItems.append(TodoItem(title: cleaned))
                    }
                }

                // Done markers
                if trimmed.hasPrefix("DONE:") {
                    let numStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if let num = Int(numStr), num > 0, num <= self.todoItems.count {
                        self.todoItems[num - 1].isComplete = true
                        self.addLog(.system, "Completed: \(self.todoItems[num - 1].title)")
                    }
                }

                // Blocked
                if trimmed.hasPrefix("BLOCKED:") {
                    let question = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                    self.blockedQuestion = question
                    self.runState = .blocked
                    self.addLog(.system, "BLOCKED: \(question)")
                    self.sendTelegramNotification("🚨 Readycode blocked: \(question)")
                }

                // All complete
                if trimmed == "ALL_COMPLETE" {
                    self.runState = .complete
                    self.addLog(.system, "All tasks complete!")
                    let runtime = self.formatElapsed(self.elapsedSeconds)
                    let done = self.todoItems.filter(\.isComplete).count
                    let total = self.todoItems.count
                    self.sendTelegramNotification("✅ Readycode complete! \(done)/\(total) tasks in \(runtime)")
                }
            }

            // Check for implementation prompt
            if text.contains("<<<IMPL_PROMPT>>>"), text.contains("<<<END_IMPL_PROMPT>>>") {
                if let range = text.range(of: "<<<IMPL_PROMPT>>>"),
                   let endRange = text.range(of: "<<<END_IMPL_PROMPT>>>") {
                    let prompt = String(text[range.upperBound..<endRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !prompt.isEmpty && self.runState == .running {
                        self.addLog(.system, "Sending prompt to implementer (\(prompt.count) chars)")
                        self.implementerSession?.write(prompt + "\n")
                    }
                }
            }

            // Add summarized entry to visible log
            let summary = self.summarizeOutput(text, maxLength: 200)
            if !summary.isEmpty {
                self.addLog(.thinker, summary)
            }
        }
    }

    func handleImplementerOutput(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Log raw output
            self.diskLogger?.log(source: "implementer", text: text)

            // Add summarized entry to visible log
            let summary = self.summarizeOutput(text, maxLength: 200)
            if !summary.isEmpty {
                self.addLog(.implementer, summary)
            }

            // TODO: Idle detection — this is the big unknown.
            // For now we need to learn what CC's output looks like when it's done.
            // The raw disk logs will help us figure this out.
            // Once we know the pattern, we feed results back to the thinker here.
        }
    }

    // MARK: - Logging

    func addLog(_ source: LogSource, _ message: String) {
        let entry = LogEntry(timestamp: Date(), source: source, message: message)
        logEntries.append(entry)
        // Keep log manageable
        if logEntries.count > 5000 {
            logEntries.removeFirst(1000)
        }
    }

    func summarizeOutput(_ text: String, maxLength: Int) -> String {
        // Strip ANSI escape codes
        let stripped = text.replacingOccurrences(of: #"\x1B\[[0-9;]*[a-zA-Z]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return "" }
        if stripped.count <= maxLength { return stripped }
        return String(stripped.prefix(maxLength)) + "..."
    }

    func logsDirectory() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        let timestamp = formatter.string(from: Date())
        let dir = workingFolder + "/.readycode/logs/\(timestamp)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Telegram

    func sendTelegramNotification(_ message: String) {
        // TODO: Wire up Telegram bot token + chat ID (stored in config)
        // For now, just log it
        addLog(.system, "Telegram (not configured): \(message)")
    }

    // MARK: - Helpers

    func formatElapsed(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    var completedCount: Int { todoItems.filter(\.isComplete).count }
    var totalCount: Int { todoItems.count }
    var progressFraction: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }
}

enum RunState: String {
    case idle = "Idle"
    case running = "Running"
    case paused = "Paused"
    case blocked = "Blocked"
    case complete = "Complete"
    case error = "Error"

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .running: return .green
        case .paused: return .yellow
        case .blocked: return .red
        case .complete: return .blue
        case .error: return .red
        }
    }
}

struct TodoItem: Identifiable {
    let id = UUID()
    var title: String
    var isComplete: Bool = false
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let source: LogSource
    let message: String
}

enum LogSource: String {
    case thinker = "Thinker"
    case implementer = "Impl"
    case system = "System"

    var color: Color {
        switch self {
        case .thinker: return .purple
        case .implementer: return .cyan
        case .system: return .secondary
        }
    }
}

// MARK: - PTY Session

class PTYSession {
    let label: String
    let workingDirectory: String
    let logger: DiskLogger?

    var masterFD: Int32 = -1
    var childPID: pid_t = 0
    var readSource: DispatchSourceRead?
    var onOutput: ((String) -> Void)?
    var buffer = Data()

    init(label: String, workingDirectory: String, logger: DiskLogger?) {
        self.label = label
        self.workingDirectory = workingDirectory
        self.logger = logger
    }

    func spawn() {
        var winSize = winsize(ws_row: 50, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)

        childPID = forkpty(&masterFD, nil, nil, &winSize)

        if childPID == 0 {
            // Child process
            chdir(workingDirectory)

            // Set up environment
            setenv("TERM", "xterm-256color", 1)
            setenv("COLUMNS", "120", 1)
            setenv("LINES", "50", 1)

            // Find claude binary
            let possiblePaths = [
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
                NSString(string: "~/.claude/bin/claude").expandingTildeInPath
            ]

            var claudePath: String?
            for path in possiblePaths {
                if FileManager.default.fileExists(atPath: path) {
                    claudePath = path
                    break
                }
            }

            guard let path = claudePath else {
                let msg = "ERROR: claude not found\n"
                msg.withCString { ptr in _ = Darwin.write(STDOUT_FILENO, ptr, Int(strlen(ptr))) }
                _exit(1)
            }

            // Exec claude with --dangerously-skip-permissions
            let args = ["claude", "--dangerously-skip-permissions"]
            let cArgs = args.map { strdup($0) } + [nil]
            execv(path, cArgs)
            _exit(1)
        }

        guard childPID > 0 else {
            logger?.log(source: label, text: "ERROR: forkpty failed")
            return
        }

        // Parent — set up async read
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(self.masterFD, &buf, buf.count)
            if n > 0 {
                let data = Data(buf[..<n])
                if let text = String(data: data, encoding: .utf8) {
                    self.onOutput?(text)
                }
            } else if n <= 0 {
                source.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.masterFD >= 0 {
                close(self.masterFD)
                self.masterFD = -1
            }
        }
        source.resume()
        readSource = source
    }

    func write(_ text: String) {
        guard masterFD >= 0 else { return }
        logger?.log(source: "\(label)-input", text: text)
        let data = Array(text.utf8)
        Darwin.write(masterFD, data, data.count)
    }

    func terminate() {
        readSource?.cancel()
        readSource = nil
        if childPID > 0 {
            kill(childPID, SIGTERM)
            childPID = 0
        }
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }
}

// MARK: - Disk Logger

class DiskLogger {
    let directory: String
    private let queue = DispatchQueue(label: "com.readycode.logger")
    private var handles: [String: FileHandle] = [:]
    private let formatter: DateFormatter

    init(directory: String) {
        self.directory = directory
        self.formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
    }

    func log(source: String, text: String) {
        queue.async { [self] in
            let handle = self.fileHandle(for: source)
            let timestamp = self.formatter.string(from: Date())
            let line = "[\(timestamp)] \(text)\n"
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
        }
    }

    private func fileHandle(for source: String) -> FileHandle {
        if let existing = handles[source] { return existing }
        let path = "\(directory)/\(source).log"
        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handles[source] = handle
        return handle
    }
}

// MARK: - Views

struct ContentView: View {
    @Environment(AppState.self) var state

    var body: some View {
        VStack(spacing: 0) {
            ControlBar()
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    SetupPanel()
                    Divider()
                    ProgressPanel()
                }
                .frame(minWidth: 320, idealWidth: 380)
                LogPanel()
                    .frame(minWidth: 400)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ControlBar: View {
    @Environment(AppState.self) var state

    var body: some View {
        HStack(spacing: 16) {
            // Run state badge
            HStack(spacing: 6) {
                Circle()
                    .fill(state.runState.color)
                    .frame(width: 10, height: 10)
                Text(state.runState.rawValue)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
            }

            // Elapsed time
            Text(state.formatElapsed(state.elapsedSeconds))
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)

            // Progress
            if state.totalCount > 0 {
                Text("\(state.completedCount)/\(state.totalCount)")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.secondary)
                ProgressView(value: state.progressFraction)
                    .frame(width: 120)
            }

            Spacer()

            // Controls
            switch state.runState {
            case .idle, .complete, .error:
                Button("Start") { state.start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            case .running:
                Button("Pause") { state.pause() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button("Stop") { state.stop() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.red)
            case .paused:
                Button("Resume") { state.resume() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Stop") { state.stop() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.red)
            case .blocked:
                Button("Stop") { state.stop() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct SetupPanel: View {
    @Environment(AppState.self) var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            // Working folder
            HStack {
                Text("Folder")
                    .frame(width: 60, alignment: .trailing)
                    .font(.system(size: 13))
                TextField("/path/to/codebase", text: $state.workingFolder)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                Button("Browse") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        state.workingFolder = url.path
                    }
                }
            }

            // Task source toggle
            HStack {
                Text("Task")
                    .frame(width: 60, alignment: .trailing)
                    .font(.system(size: 13))
                Picker("", selection: $state.useTaskFile) {
                    Text("Text").tag(false)
                    Text("File").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                Spacer()
            }

            // Task input
            if state.useTaskFile {
                HStack {
                    Text("")
                        .frame(width: 60)
                    TextField("/path/to/task.md", text: $state.taskFilePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowedContentTypes = [.plainText, .text]
                        if panel.runModal() == .OK, let url = panel.url {
                            state.taskFilePath = url.path
                        }
                    }
                }
            } else {
                HStack(alignment: .top) {
                    Text("")
                        .frame(width: 60)
                    TextEditor(text: $state.taskText)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 60, maxHeight: 100)
                        .border(Color.secondary.opacity(0.3))
                        .scrollContentBackground(.hidden)
                }
            }

            // Additional instructions
            HStack(alignment: .top) {
                Text("Extra")
                    .frame(width: 60, alignment: .trailing)
                    .font(.system(size: 13))
                TextEditor(text: $state.additionalInstructions)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 40, maxHeight: 60)
                    .border(Color.secondary.opacity(0.3))
                    .scrollContentBackground(.hidden)
            }
        }
        .padding(12)
        .disabled(state.runState == .running || state.runState == .paused || state.runState == .blocked)
    }
}

struct ProgressPanel: View {
    @Environment(AppState.self) var state

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Progress")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.totalCount > 0 {
                    Text("\(state.completedCount)/\(state.totalCount)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Blocked question
            if let question = state.blockedQuestion {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("Blocked")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    Text(question)
                        .font(.system(size: 13))
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                    HStack {
                        TextField("Your answer...", text: $state.blockedAnswer)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                        Button("Send") { state.resume() }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.blockedAnswer.isEmpty)
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.05))
                .cornerRadius(8)
            }

            // Todo list
            if state.todoItems.isEmpty {
                Text(state.runState == .idle ? "Start a run to see the plan" : "Waiting for thinker to generate plan...")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(state.todoItems.enumerated()), id: \.element.id) { index, item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.isComplete ? .green : .secondary)
                                    .font(.system(size: 14))
                                Text("\(index + 1). \(item.title)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(item.isComplete ? .secondary : .primary)
                                    .strikethrough(item.isComplete)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(12)
    }
}

struct LogPanel: View {
    @Environment(AppState.self) var state
    @State private var filter: LogSource? = nil
    @State private var autoScroll = true

    var filteredEntries: [LogEntry] {
        guard let filter else { return state.logEntries }
        return state.logEntries.filter { $0.source == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack {
                Text("Log")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $filter) {
                    Text("All").tag(Optional<LogSource>.none)
                    Text("Thinker").tag(Optional<LogSource>.some(.thinker))
                    Text("Impl").tag(Optional<LogSource>.some(.implementer))
                    Text("System").tag(Optional<LogSource>.some(.system))
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .font(.system(size: 12))
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Log entries
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredEntries) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .onChange(of: state.logEntries.count) {
                    if autoScroll, let last = filteredEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

struct LogEntryRow: View {
    let entry: LogEntry
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.formatter.string(from: entry.timestamp))
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)
            Text(entry.source.rawValue)
                .foregroundStyle(entry.source.color)
                .frame(width: 55, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Main

@main
struct ReadycodeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        let state = AppState()
        let contentView = ContentView().environment(state)
        let hostingView = NSHostingView(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Readycode"
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        app.run()
    }
}
