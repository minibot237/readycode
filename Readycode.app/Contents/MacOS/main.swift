import SwiftUI
import Foundation
import Darwin
import WebKit

// MARK: - Auto-Responses
// Pattern → response table for interactive prompts CC throws at us.
// Each entry: a substring to match in the raw PTY output, and what to send back.
// Checked in order — first match wins. Grow this list as we discover new prompts.

struct AutoResponse {
    let name: String           // human-readable label for logging
    let pattern: String        // substring to match in raw output (ANSI-stripped)
    let response: String       // what to write back to the PTY
    let delay: TimeInterval    // seconds to wait before responding (lets CC settle)
}

let autoResponses: [AutoResponse] = [
    AutoResponse(
        name: "trust-folder",
        pattern: "trust this folder",
        response: "\r",          // Enter key to confirm the default selection
        delay: 0.5
    ),
    // Add new patterns here as we discover them:
    // AutoResponse(
    //     name: "example-prompt",
    //     pattern: "some text CC shows",
    //     response: "our answer\r",
    //     delay: 0.5
    // ),
]

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // PTY cleanup happens via AppState.stop()
    }

    func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Readycode", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Readycode", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (enables copy/paste/select all)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - State

@Observable
class AppState {
    // Setup
    var workingFolder: String = "/Users/minibot/projects/readycode-project1"
    var taskText: String = "List all files in this repository and give a one-line description of each."
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

    // Orchestration state
    var implementerResponding = false   // true once implementer starts working
    var implementerOutputBuffer = ""    // accumulates implementer response text
    var lastImplementerActivity = Date()  // for idle detection
    var thinkerBusy = false             // true while thinker -p call is running

    // Terminal WebView coordinators (feed raw PTY output to xterm.js)
    var thinkerTerminalCoordinator = TerminalWebViewCoordinator()
    var implementerTerminalCoordinator = TerminalWebViewCoordinator()

    // Sessions — thinker uses -p mode (Process), implementer uses PTY
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

        // Spawn implementer (PTY — interactive, needs tools)
        addLog(.system, "Starting implementer session...")
        implementerSession = PTYSession(label: "implementer", workingDirectory: workingFolder, logger: diskLogger)
        implementerSession?.onOutput = { [weak self] text in
            self?.handleImplementerOutput(text)
        }
        implementerSession?.onAutoResponse = { [weak self] name, _ in
            self?.addLog(.system, "Auto-responded to '\(name)' (implementer)")
        }
        implementerSession?.spawn()

        // Send initial prompt to thinker (-p mode, no PTY needed)
        addLog(.system, "Sending task to thinker...")
        sendThinkerPrompt(buildInitialPrompt(task: task))
    }

    func stop() {
        runState = .idle
        runTimer?.invalidate()
        runTimer = nil
        implementerSession?.terminate()
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
            // Feed the answer back to the thinker via -p mode
            let answer = blockedAnswer
            addLog(.system, "Answering blocked question: \(answer)")
            blockedQuestion = nil
            blockedAnswer = ""
            sendThinkerPrompt("The user answered the blocked question: \(answer)\n\nContinue with the plan. Output the next <<<IMPL_PROMPT>>>...<<<END_IMPL_PROMPT>>> block or ALL_COMPLETE.")
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

    func buildInitialPrompt(task: String) -> String {
        var prompt = """
        You are the THINKER in a two-agent system called readycode. Your job is to plan and coordinate long-running work on a codebase.

        IMPORTANT RESPONSE FORMAT:

        1. First, output a numbered todo list. Each line must start with exactly "TODO: " followed by the number:
        TODO: 1. First step description
        TODO: 2. Second step description

        2. Then output the first implementation prompt between these exact markers (on their own lines):
        <<<IMPL_PROMPT>>>
        (your detailed prompt for the implementer goes here)
        <<<END_IMPL_PROMPT>>>

        3. When you receive results back from the implementer, respond with:
        - DONE: [n] to mark todo item n as complete
        - Another <<<IMPL_PROMPT>>>...<<<END_IMPL_PROMPT>>> block for the next task
        - BLOCKED: [question] if you need human input
        - ALL_COMPLETE when everything is done

        RULES:
        - The implementer is a separate Claude Code session pointed at \(workingFolder). It can read files, write files, run commands.
        - Give the implementer clear, specific, self-contained prompts. It has no memory of previous prompts.
        - Do NOT write code yourself. Just tell the implementer what to do.

        THE TASK:
        \(task)
        """

        if !additionalInstructions.isEmpty {
            prompt += "\n\nADDITIONAL INSTRUCTIONS:\n\(additionalInstructions)"
        }
        return prompt
    }

    // MARK: - Thinker (-p mode)

    func sendThinkerPrompt(_ prompt: String) {
        guard runState == .running else { return }
        guard !thinkerBusy else {
            addLog(.system, "Thinker busy, skipping")
            return
        }
        thinkerBusy = true
        addLog(.thinker, "Sending prompt (\(prompt.count) chars)")
        diskLogger?.log(source: "thinker-input", text: prompt)

        // Find claude binary
        let possiblePaths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            NSString(string: "~/.claude/bin/claude").expandingTildeInPath
        ]
        guard let claudePath = possiblePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            addLog(.system, "ERROR: claude binary not found")
            thinkerBusy = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = ["-p", "--dangerously-skip-permissions", "--output-format", "json", prompt]
            process.currentDirectoryURL = URL(fileURLWithPath: self.workingFolder)

            // Clear nesting detection
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CLAUDECODE")
            env.removeValue(forKey: "CLAUDE_CODE_SESSION")
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self.addLog(.system, "Thinker process error: \(error.localizedDescription)")
                    self.thinkerBusy = false
                }
                return
            }

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8) ?? ""
            let errOutput = String(data: errData, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                self.thinkerBusy = false
                self.diskLogger?.log(source: "thinker-output", text: output)
                if !errOutput.isEmpty {
                    self.diskLogger?.log(source: "thinker-stderr", text: errOutput)
                }

                // Feed to terminal webview for display
                self.thinkerTerminalCoordinator.writeToTerminal(output + "\n")

                // Parse the JSON response to get the result text
                var resultText = output
                if let data = output.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = json["result"] as? String {
                    resultText = result
                }

                self.addLog(.thinker, String(resultText.prefix(200)))
                self.parseThinkerResponse(resultText)
            }
        }
    }

    func parseThinkerResponse(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("TODO:") {
                let item = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                let cleaned = item.replacingOccurrences(of: #"^\d+\.\s*"#, with: "", options: .regularExpression)
                if !cleaned.isEmpty && !self.todoItems.contains(where: { $0.title == cleaned }) {
                    self.todoItems.append(TodoItem(title: cleaned))
                    self.addLog(.system, "Todo: \(cleaned)")
                }
            }

            if trimmed.hasPrefix("DONE:") {
                let numStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let num = Int(numStr), num > 0, num <= self.todoItems.count, !self.todoItems[num - 1].isComplete {
                    self.todoItems[num - 1].isComplete = true
                    self.addLog(.system, "Completed: \(self.todoItems[num - 1].title)")
                }
            }

            if trimmed.hasPrefix("BLOCKED:") {
                let question = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                if self.runState != .blocked {
                    self.blockedQuestion = question
                    self.runState = .blocked
                    self.addLog(.system, "BLOCKED: \(question)")
                    self.sendTelegramNotification("🚨 Readycode blocked: \(question)")
                }
            }

            if trimmed == "ALL_COMPLETE" && self.runState != .complete {
                self.runState = .complete
                self.addLog(.system, "All tasks complete!")
                let runtime = self.formatElapsed(self.elapsedSeconds)
                let done = self.todoItems.filter(\.isComplete).count
                let total = self.todoItems.count
                self.sendTelegramNotification("✅ Readycode complete! \(done)/\(total) tasks in \(runtime)")
            }
        }

        // Extract implementation prompt
        if text.contains("<<<IMPL_PROMPT>>>") && text.contains("<<<END_IMPL_PROMPT>>>") {
            if let range = text.range(of: "<<<IMPL_PROMPT>>>"),
               let endRange = text.range(of: "<<<END_IMPL_PROMPT>>>"),
               range.upperBound < endRange.lowerBound {
                let prompt = String(text[range.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !prompt.isEmpty && self.runState == .running {
                    self.addLog(.system, "Sending to implementer (\(prompt.count) chars): \(String(prompt.prefix(100)))...")
                    self.implementerResponding = false
                    self.implementerOutputBuffer = ""
                    self.implementerSession?.write(prompt + "\n")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.implementerSession?.write("\r")
                    }
                }
            }
        }
    }

    func stripAnsi(_ text: String) -> String {
        let esc = "\u{1B}"
        return text.replacingOccurrences(of: "\(esc)\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\(esc)\\].*?\u{07}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\(esc)[^\\[\\]]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{07}", with: "")
    }

    func handleImplementerOutput(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Log raw output
            self.diskLogger?.log(source: "implementer", text: text)

            // Feed raw output to xterm.js terminal
            self.implementerTerminalCoordinator.writeToTerminal(text)

            let stripped = self.stripAnsi(text)

            // Detect when implementer starts working (spinner)
            let spinnerChars: Set<Character> = ["✻", "✳", "✶", "✢", "✽", "·", "⏺"]
            if !self.implementerResponding {
                for ch in stripped {
                    if spinnerChars.contains(ch) {
                        self.implementerResponding = true
                        self.addLog(.system, "Implementer is working...")
                        break
                    }
                }
            }

            // Accumulate output for feeding back to thinker
            if self.implementerResponding {
                self.implementerOutputBuffer += stripped
                // Cap buffer
                if self.implementerOutputBuffer.count > 50_000 {
                    self.implementerOutputBuffer = String(self.implementerOutputBuffer.suffix(40_000))
                }
                self.lastImplementerActivity = Date()
            }

            // Idle detection: look for the ❯ prompt after implementer has been responding
            // This means CC finished and is waiting for the next input
            if self.implementerResponding && stripped.contains("❯") {
                // Debounce — wait 3 seconds of quiet to confirm idle
                let checkTime = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self,
                          self.implementerResponding,
                          self.runState == .running,
                          self.lastImplementerActivity <= checkTime else { return }

                    // Implementer is idle — feed results back to thinker
                    self.implementerResponding = false
                    self.addLog(.system, "Implementer idle — sending results to thinker")

                    // Summarize the implementer's output (take last 4KB to stay within context)
                    let result = String(self.implementerOutputBuffer.suffix(4000))
                    let feedback = """
                    The implementer has completed the task. Here is its output (last 4KB):

                    ---
                    \(result)
                    ---

                    Based on this output, decide what to do next:
                    - Mark completed items with DONE: [n]
                    - Send the next task with <<<IMPL_PROMPT>>>...<<<END_IMPL_PROMPT>>>
                    - Or output ALL_COMPLETE if everything is done.
                    """

                    self.implementerOutputBuffer = ""
                    self.sendThinkerPrompt(feedback)
                }
            }

            // Add summarized entry to visible log
            let summary = self.summarizeOutput(text, maxLength: 200)
            if !summary.isEmpty {
                self.addLog(.implementer, summary)
            }
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
        let esc = "\u{1B}"
        let stripped = text.replacingOccurrences(of: "\(esc)\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\(esc)\\].*?\u{07}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\(esc)[^\\[\\]]", with: "", options: .regularExpression)
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
    var onAutoResponse: ((String, String) -> Void)?  // (name, response) for logging
    var buffer = Data()
    var recentOutput: String = ""  // rolling window for pattern matching

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

            // Clear CC's nesting detection so it doesn't refuse to launch
            unsetenv("CLAUDECODE")
            unsetenv("CLAUDE_CODE_SESSION")

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
                    self.checkAutoResponses(text)
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

    func checkAutoResponses(_ text: String) {
        // Strip ANSI escape codes — \u{1B} is ESC in Swift strings
        let esc = "\u{1B}"
        let stripped = text.replacingOccurrences(of: "\(esc)\\[[0-9;]*[a-zA-Z]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\(esc)\\].*?\u{07}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\(esc)[^\\[\\]]", with: "", options: .regularExpression)

        // Debug: log what we see after stripping
        let preview = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty {
            logger?.log(source: "\(label)-stripped", text: preview)
        }

        // Append to rolling window (keep last 2KB for matching across chunks)
        recentOutput += stripped
        if recentOutput.count > 2048 {
            recentOutput = String(recentOutput.suffix(1024))
        }

        for ar in autoResponses {
            if recentOutput.contains(ar.pattern) {
                // Clear the match so we don't fire again
                recentOutput = ""
                logger?.log(source: "\(label)-auto", text: "Matched '\(ar.name)' — sending response after \(ar.delay)s")
                onAutoResponse?(ar.name, ar.response)

                DispatchQueue.global().asyncAfter(deadline: .now() + ar.delay) { [weak self] in
                    self?.write(ar.response)
                }
                break  // one match per chunk
            }
        }
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

            // Terminal windows
            Button("Thinker") {
                TerminalWindowManager.shared.showWindow(
                    title: "Thinker",
                    coordinator: state.thinkerTerminalCoordinator
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button("Implementer") {
                TerminalWindowManager.shared.showWindow(
                    title: "Implementer",
                    coordinator: state.implementerTerminalCoordinator
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 4)

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
                    panel.canCreateDirectories = true
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

// MARK: - Terminal Window Manager

class TerminalWindowManager {
    static let shared = TerminalWindowManager()
    private var windows: [String: NSWindow] = [:]
    private var webViews: [String: WKWebView] = [:]

    func showWindow(title: String, coordinator: TerminalWebViewCoordinator) {
        // If window already exists, just bring it forward
        if let existing = windows[title], existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Create WKWebView for this terminal
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let webView = WKWebView(frame: .zero, configuration: config)
        let navDelegate = TerminalNavDelegate(coordinator: coordinator)
        webView.navigationDelegate = navDelegate
        // Hold a strong ref to the delegate
        objc_setAssociatedObject(webView, "navDelegate", navDelegate, .OBJC_ASSOCIATION_RETAIN)

        // Point coordinator at this webview
        coordinator.webView = webView
        coordinator.isReady = false

        webView.loadHTMLString(xtermHTML, baseURL: nil)

        // Create window
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let windowWidth: CGFloat = 700
        let windowHeight: CGFloat = 500

        // Position: thinker top-right, implementer bottom-right
        let x: CGFloat
        let y: CGFloat
        if title == "Thinker" {
            x = screenFrame.maxX - windowWidth - 20
            y = screenFrame.maxY - windowHeight - 20
        } else {
            x = screenFrame.maxX - windowWidth - 20
            y = screenFrame.minY + 20
        }

        let window = NSWindow(
            contentRect: NSRect(x: x, y: y, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Readycode — \(title)"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        windows[title] = window
        webViews[title] = webView
    }
}

class TerminalNavDelegate: NSObject, WKNavigationDelegate {
    let coordinator: TerminalWebViewCoordinator
    init(coordinator: TerminalWebViewCoordinator) { self.coordinator = coordinator }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        coordinator.isReady = true
        coordinator.flush()
    }
}

// MARK: - xterm.js Terminal View

let xtermHTML = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  html, body { margin: 0; padding: 0; height: 100%; overflow: hidden; background: #1e1e1e; }
  #terminal { height: 100%; }
</style>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.min.css">
<script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.min.js"></script>
</head>
<body>
<div id="terminal"></div>
<script>
  const term = new window.Terminal({
    fontSize: 14,
    fontFamily: 'Menlo, Monaco, monospace',
    theme: { background: '#1e1e1e', foreground: '#d4d4d4' },
    scrollback: 10000,
    convertEol: false,
    cursorBlink: false,
    disableStdin: true
  });
  const fitAddon = new window.FitAddon.FitAddon();
  term.loadAddon(fitAddon);
  term.open(document.getElementById('terminal'));
  fitAddon.fit();

  window.addEventListener('resize', () => fitAddon.fit());
  new ResizeObserver(() => fitAddon.fit()).observe(document.getElementById('terminal'));

  // Called from Swift to write data
  function writeData(base64) {
    const bytes = atob(base64);
    term.write(bytes);
  }

  function clearTerminal() {
    term.clear();
  }
</script>
</body>
</html>
"""

class TerminalWebViewCoordinator {
    var webView: WKWebView?
    var pendingChunks: [String] = []
    var isReady = false

    func writeToTerminal(_ rawText: String) {
        // Base64 encode to safely pass through JS
        guard let data = rawText.data(using: .utf8) else { return }
        let b64 = data.base64EncodedString()
        let js = "writeData('\(b64)');"

        if isReady, let wv = webView {
            wv.evaluateJavaScript(js, completionHandler: nil)
        } else {
            pendingChunks.append(js)
        }
    }

    func flush() {
        guard isReady, let wv = webView else { return }
        for js in pendingChunks {
            wv.evaluateJavaScript(js, completionHandler: nil)
        }
        pendingChunks.removeAll()
    }
}

struct TerminalWebViewRepresentable: NSViewRepresentable {
    let coordinator: TerminalWebViewCoordinator

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        coordinator.webView = wv
        wv.loadHTMLString(xtermHTML, baseURL: nil)
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> NavDelegate {
        NavDelegate(terminal: coordinator)
    }

    class NavDelegate: NSObject, WKNavigationDelegate {
        let terminal: TerminalWebViewCoordinator
        init(terminal: TerminalWebViewCoordinator) { self.terminal = terminal }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            terminal.isReady = true
            terminal.flush()
        }
    }
}

struct TerminalView: View {
    @Environment(AppState.self) var state
    let source: LogSource

    var coordinator: TerminalWebViewCoordinator {
        switch source {
        case .thinker: return state.thinkerTerminalCoordinator
        case .implementer: return state.implementerTerminalCoordinator
        default: return state.thinkerTerminalCoordinator
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Clear") {
                    coordinator.webView?.evaluateJavaScript("clearTerminal();", completionHandler: nil)
                }
                .font(.system(size: 12))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            TerminalWebViewRepresentable(coordinator: coordinator)
        }
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
        }
        .textSelection(.enabled)
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
