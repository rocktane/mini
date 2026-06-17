import AppKit
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let store = JobStore()
    private var server: SocketServer!
    private var monitor: OutputMonitor!
    private var cancellables = Set<AnyCancellable>()
    private var estimatedMenuWidth: CGFloat = 320

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        startServer()
        rebuildMenu()

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateIcon()
                    self?.rebuildMenu()
                }
            }
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

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let running = store.jobs.filter { $0.status == .running }
        let stopped = store.jobs.filter { $0.status != .running }

        if running.isEmpty && stopped.isEmpty {
            let item = NSMenuItem(title: "No jobs", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if !running.isEmpty {
            let header = NSMenuItem(title: "Running", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for job in running {
                menu.addItem(makeJobItem(job, running: true))
            }
        }

        if !stopped.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Stopped", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for job in stopped {
                menu.addItem(makeJobItem(job, running: false))
            }
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Mini", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        estimatedMenuWidth = Self.estimateMenuWidth(menu)
    }

    /// Estimates the rendered width of the main menu by measuring the widest item's title.
    /// Used to position the hover preview to the left of the menu's left edge.
    private static func estimateMenuWidth(_ menu: NSMenu) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        var widest: CGFloat = 0
        for item in menu.items {
            let title = item.title
            if title.isEmpty { continue }
            let w = (title as NSString).size(withAttributes: [.font: font]).width
            widest = max(widest, w)
        }
        // Margins + submenu chevron. Tighter estimate so the preview sits closer to the menu.
        return max(140, widest + 32)
    }

    private func makeJobItem(_ job: Job, running: Bool) -> NSMenuItem {
        let title: String
        if running {
            title = job.displayCommand
        } else if case let .stopped(code) = job.status {
            title = "\(job.displayCommand)  ·  exit \(code)"
        } else {
            title = job.displayCommand
        }

        let item = NSMenuItem(title: title, action: #selector(openJob(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = job.id

        let submenu = NSMenu()
        submenu.delegate = self
        let openItem = NSMenuItem(title: "Open Window", action: #selector(openJob(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = job.id
        submenu.addItem(openItem)

        if running {
            let stopItem = NSMenuItem(title: "Stop", action: #selector(stopJob(_:)), keyEquivalent: "")
            stopItem.target = self
            stopItem.representedObject = job.id
            submenu.addItem(stopItem)
        } else {
            let restartItem = NSMenuItem(title: "Restart", action: #selector(restartJob(_:)), keyEquivalent: "")
            restartItem.target = self
            restartItem.representedObject = job.id
            submenu.addItem(restartItem)
        }

        let revealItem = NSMenuItem(title: "Reveal cwd in Finder", action: #selector(revealJob(_:)), keyEquivalent: "")
        revealItem.target = self
        revealItem.representedObject = job.id
        submenu.addItem(revealItem)

        submenu.addItem(.separator())

        let removeItem = NSMenuItem(title: running ? "Stop & Remove" : "Remove", action: #selector(removeJob(_:)), keyEquivalent: "")
        removeItem.target = self
        removeItem.representedObject = job.id
        submenu.addItem(removeItem)

        item.submenu = submenu
        return item
    }

    // MARK: - NSMenuDelegate

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            if menu === self.statusItem.menu {
                rebuildMenu()
            }
        }
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            // Only hide when the root menu actually closes (submenus close on their own).
            if menu === self.statusItem.menu {
                JobPreviewWindow.shared.hide()
            }
        }
    }

    nonisolated func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        MainActor.assumeIsolated {
            updatePreview(for: menu, highlighted: item)
        }
    }

    private func updatePreview(for menu: NSMenu, highlighted: NSMenuItem?) {
        // Resolve the top-level job item even when hovering inside its submenu.
        let mainMenu = statusItem.menu
        let topItem: NSMenuItem?
        if menu === mainMenu {
            topItem = highlighted
        } else if let parent = menu.supermenu {
            let idx = parent.indexOfItem(withSubmenu: menu)
            topItem = idx >= 0 ? parent.item(at: idx) : nil
        } else {
            topItem = nil
        }

        guard let item = topItem,
              let id = item.representedObject as? UUID,
              let job = store.job(id: id),
              let mainMenu = mainMenu else {
            JobPreviewWindow.shared.hide()
            return
        }
        let index = mainMenu.index(of: item)
        JobPreviewWindow.shared.show(job: job, anchor: previewAnchor(forItemAt: index))
    }

    /// Approximate height of a standard NSMenu row in the system menu font.
    /// Separators are shorter (~11pt) but we treat them as full rows; the small drift
    /// is imperceptible given the preview is a large window.
    private static let menuRowHeight: CGFloat = 22

    /// Anchor = the point where the preview's top-right corner should land.
    /// Placed just to the LEFT of the submenu (which opens leftward from the main menu),
    /// aligned vertically with the hovered row.
    private func previewAnchor(forItemAt index: Int) -> NSPoint {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            if let screen = NSScreen.main {
                return NSPoint(x: screen.visibleFrame.maxX, y: screen.visibleFrame.maxY)
            }
            return .zero
        }
        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        let mainMenuLeft = buttonFrame.maxX - estimatedMenuWidth
        let rowTopY = buttonFrame.minY - CGFloat(max(0, index)) * Self.menuRowHeight
        // Anchor preview's right edge flush with the main menu's left edge.
        return NSPoint(x: mainMenuLeft, y: rowTopY)
    }

    // MARK: - Actions

    @objc private func openJob(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let job = store.job(id: id) else { return }
        job.unseenSignalCount = 0
        TerminalWindow.show(job: job)
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
            if let idString = idString, let id = UUID(uuidString: idString),
               let job = self?.store.job(id: id) {
                job.unseenSignalCount = 0
                TerminalWindow.show(job: job)
            }
            completionHandler()
        }
    }

    @objc private func stopJob(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let job = store.job(id: id) else { return }
        let pid = job.terminalView.process.shellPid
        if pid > 0 { kill(pid, SIGTERM) }
    }

    @objc private func restartJob(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        store.restart(id: id)
    }

    @objc private func revealJob(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let job = store.job(id: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.cwd)])
    }

    @objc private func removeJob(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        store.remove(id: id)
    }

    @objc private func openSettings() {
        SettingsWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
