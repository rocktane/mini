import AppKit
import Carbon.HIToolbox
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let store = JobStore()
    private let history = HistoryStore()
    private var server: SocketServer!
    private var monitor: OutputMonitor!
    private var mainWindow: MainWindowController!
    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        // Left-click toggles the dropdown; right-click shows a small fallback menu.
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        store.history = history
        mainWindow = MainWindowController(store: store, history: history)

        startServer()

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)

        // First-launch alias install prompt.
        DispatchQueue.main.async {
            AliasInstaller.promptInstallIfNeeded()
        }

        // Notifications + output monitor.
        UNUserNotificationCenter.current().delegate = self
        Notifier.shared.requestAuthorization()
        monitor = OutputMonitor(store: store)
        monitor.start()

        // Global hotkey (configurable in Settings) toggles the panel from anywhere.
        registerHotKey()
        NotificationCenter.default.addObserver(forName: .miniHotKeyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKey() }
        }
    }

    private func registerHotKey() {
        let config = HotKeyConfig.load()
        hotKey = nil // release the previous registration before creating the new one
        hotKey = GlobalHotKey(keyCode: config.keyCode, modifiers: config.carbonModifiers) { [weak self] in
            MainActor.assumeIsolated { self?.toggleFromHotKey() }
        }
    }

    private func toggleFromHotKey() {
        guard let button = statusItem.button else { return }
        mainWindow.toggle(relativeTo: button)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.terminateAll()
        server?.stop()
    }

    private func startServer() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = "\(home)/Library/Application Support/Mini/mini.sock"
        server = SocketServer(path: path)
        server.onRequest = { [weak self] req in
            self?.handleRequest(req) ?? ["status": "error", "error": "no app"]
        }
        do {
            try server.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Mini failed to start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func handleRequest(_ req: [String: Any]) -> [String: Any] {
        guard let argv = req["argv"] as? [String], !argv.isEmpty else {
            return ["status": "error", "error": "missing argv"]
        }
        let cwd = (req["cwd"] as? String) ?? FileManager.default.currentDirectoryPath
        let env = (req["env"] as? [String: String]) ?? [:]
        let cols = (req["cols"] as? Int) ?? 120
        let rows = (req["rows"] as? Int) ?? 30
        let id = store.spawn(argv: argv, cwd: cwd, env: env, cols: cols, rows: rows)
        return ["status": "started", "jobId": id.uuidString]
    }

    // MARK: - Status item

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let runningCount = store.jobs.filter { $0.status == .running }.count
        let symbol = runningCount > 0 ? "terminal.fill" : "terminal"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mini")
        button.title = runningCount > 0 ? " \(runningCount)" : ""
        button.imagePosition = .imageLeading
    }

    // MARK: - Actions

    @objc private func statusButtonClicked() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu(button)
        } else {
            mainWindow.toggle(relativeTo: button)
        }
    }

    /// Right-click fallback menu. Assigned transiently so left-click keeps firing the action.
    private func showStatusMenu(_ button: NSStatusBarButton) {
        let menu = NSMenu()

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Mini", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        SettingsWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let idString = userInfo["jobId"] as? String
        DispatchQueue.main.async { [weak self] in
            if let self = self, let idString = idString, let id = UUID(uuidString: idString),
               let job = self.store.job(id: id), let button = self.statusItem.button {
                self.mainWindow.show(relativeTo: button, selecting: job)
            }
            completionHandler()
        }
    }
}
