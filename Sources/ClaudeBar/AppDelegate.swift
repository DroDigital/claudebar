import AppKit

/// Wires everything together:
///  - hook events arrive over the unix socket and update session state
///  - the Touch Bar takes over only while a terminal is frontmost AND
///    at least one Claude Code session is alive ("Claude mode")
///  - a small menu bar item for status, config and quitting
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// A session with no hook activity and no transcript writes for this
    /// long is assumed dead (crashed, terminal closed without SessionEnd).
    /// Any later event from it brings it straight back.
    private static let staleSessionAge: TimeInterval = 6 * 60 * 60

    private struct Session {
        var transcriptPath: String?
        var lastSeen: Date
    }

    private var config: Config
    private var configError: String?
    private let usageTracker = UsageTracker()
    private lazy var touchBarController = TouchBarController(config: config, usageTracker: usageTracker)

    private var socketServer: HookSocketServer?
    private var statusItem: NSStatusItem?
    private var pruneTimer: Timer?

    /// Live Claude Code sessions, keyed by session id.
    private var sessions: [String: Session] = [:]
    /// Sessions currently mid-turn (Claude is thinking or running tools).
    private var workingSessions: Set<String> = []
    /// The session whose usage the Touch Bar shows: whichever spoke last.
    private var focusedSessionID: String?
    /// The permission prompt we're currently showing buttons for, if any.
    private var pendingPermission: (sessionID: String?, message: String)?
    private var terminalIsFrontmost = false

    override init() {
        let loaded = Config.load()
        config = loaded.config
        configError = loaded.error
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMenuBarItem()
        KeySender.ensureTrusted()

        touchBarController.onPermissionAnswered = { [weak self] in
            self?.pendingPermission = nil
            self?.refreshTouchBar()
        }

        try? FileManager.default.createDirectory(at: Config.directory,
                                                 withIntermediateDirectories: true)
        let server = HookSocketServer(path: Config.socketPath) { [weak self] data in
            DispatchQueue.main.async { self?.handleHookPayload(data) }
        }
        do {
            try server.start()
            socketServer = server
        } catch {
            NSLog("ClaudeBar: could not open hook socket — \(error.localizedDescription)")
        }

        // Track which app is frontmost so we only own the Touch Bar
        // while you're actually looking at your terminal.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self,
                           selector: #selector(frontmostAppChanged(_:)),
                           name: NSWorkspace.didActivateApplicationNotification,
                           object: nil)
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            terminalIsFrontmost = isTerminal(frontmost)
        }

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            self?.refreshTouchBar()
        }
    }

    // MARK: - Hook events

    private func handleHookPayload(_ data: Data) {
        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            return
        }
        let id = event.sessionId

        if event.hookEventName == "SessionEnd" {
            if let id = id { endSession(id) }
            refreshTouchBar()
            return
        }

        // Any event proves the session is alive — including sessions that
        // started before ClaudeBar did and never sent us a SessionStart.
        if let id = id {
            let transcript = event.transcriptPath ?? sessions[id]?.transcriptPath
            sessions[id] = Session(transcriptPath: transcript, lastSeen: Date())
            focusedSessionID = id
            if let transcript = transcript {
                usageTracker.watch(transcriptPath: transcript)
            }
        }

        switch event.hookEventName {
        case "UserPromptSubmit", "PostToolUse":
            // You typed something / a tool ran — so any prompt we were
            // showing buttons for has been answered, maybe at the keyboard.
            clearPendingPermission(for: id)
            if let id = id { workingSessions.insert(id) }

        case "Stop":
            clearPendingPermission(for: id)
            if let id = id { workingSessions.remove(id) }

        case "Notification":
            if event.isPermissionRequest {
                pendingPermission = (id, event.message ?? "Claude needs your permission")
                if let id = id { workingSessions.remove(id) }
            } else if event.notificationType == "idle_prompt" {
                if let id = id { workingSessions.remove(id) }
            }

        default:
            break
        }

        refreshTouchBar()
    }

    private func clearPendingPermission(for sessionID: String?) {
        guard let pending = pendingPermission else { return }
        // Don't let one session's activity hide another session's prompt.
        if pending.sessionID == nil || sessionID == nil || pending.sessionID == sessionID {
            pendingPermission = nil
        }
    }

    private func endSession(_ id: String) {
        if let transcript = sessions[id]?.transcriptPath {
            usageTracker.forget(transcriptPath: transcript)
        }
        sessions[id] = nil
        workingSessions.remove(id)
        if pendingPermission?.sessionID == id { pendingPermission = nil }
        if focusedSessionID == id {
            focusOnMostRecentSession()
        }
    }

    private func focusOnMostRecentSession() {
        let next = sessions.max { $0.value.lastSeen < $1.value.lastSeen }
        focusedSessionID = next?.key
        if let transcript = next?.value.transcriptPath {
            usageTracker.watch(transcriptPath: transcript)
        } else {
            usageTracker.stop()
        }
    }

    private func pruneStaleSessions() {
        let cutoff = Date().addingTimeInterval(-Self.staleSessionAge)
        for (id, session) in sessions where lastActivity(of: session) < cutoff {
            endSession(id)
        }
    }

    private func lastActivity(of session: Session) -> Date {
        guard let path = session.transcriptPath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date else {
            return session.lastSeen
        }
        return max(session.lastSeen, modified)
    }

    // MARK: - Frontmost app tracking

    @objc private func frontmostAppChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        terminalIsFrontmost = isTerminal(app)
        refreshTouchBar()
    }

    private func isTerminal(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        return config.terminalBundleIDs.contains(bundleID)
    }

    // MARK: - Touch Bar state

    private func refreshTouchBar() {
        pruneStaleSessions()
        statusItem?.button?.appearsDisabled = sessions.isEmpty
        touchBarController.isWorking = !workingSessions.isEmpty

        let claudeMode = !sessions.isEmpty && terminalIsFrontmost
        guard claudeMode else {
            touchBarController.dismiss()
            return
        }
        if let pending = pendingPermission {
            touchBarController.show(.permission(message: pending.message))
        } else {
            touchBarController.show(.idle)
        }
    }

    // MARK: - Menu bar

    private func setUpMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "✳"
        item.button?.appearsDisabled = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt every time it opens, so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        pruneStaleSessions()
        menu.removeAllItems()

        menu.addItem(disabledItem(sessionStatusText()))
        if !AXIsProcessTrusted() {
            menu.addItem(actionItem("Grant Accessibility Access…", #selector(openAccessibilitySettings)))
        }
        if !SystemModalTouchBar.isSupported {
            menu.addItem(disabledItem("⚠︎ This Mac can't show ClaudeBar on the Touch Bar"))
        }
        if let error = configError {
            menu.addItem(disabledItem("⚠︎ \(error)"))
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("Reload Config", #selector(reloadConfig), key: "r"))
        menu.addItem(actionItem("Open Config Folder", #selector(openConfigFolder)))
        if !sessions.isEmpty {
            menu.addItem(actionItem("Forget Sessions", #selector(forgetSessions)))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClaudeBar",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func sessionStatusText() -> String {
        switch sessions.count {
        case 0: return "Waiting for a Claude Code session"
        case 1: return workingSessions.isEmpty ? "1 session · waiting for you" : "1 session · Claude is working"
        default:
            let working = workingSessions.count
            return "\(sessions.count) sessions · \(working) working"
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func reloadConfig() {
        let loaded = Config.load()
        config = loaded.config
        configError = loaded.error
        touchBarController.apply(config)
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            terminalIsFrontmost = isTerminal(frontmost)
        }
        refreshTouchBar()
    }

    @objc private func openConfigFolder() {
        NSWorkspace.shared.open(Config.directory)
    }

    @objc private func openAccessibilitySettings() {
        KeySender.ensureTrusted()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The escape hatch if a session vanished without saying goodbye.
    @objc private func forgetSessions() {
        sessions.removeAll()
        workingSessions.removeAll()
        pendingPermission = nil
        focusedSessionID = nil
        usageTracker.stop()
        refreshTouchBar()
    }
}
