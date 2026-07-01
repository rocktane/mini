import AppKit
import Combine
import SwiftTerm

/// The single, fully-managed interface: a chromeless panel that drops down from the
/// menu-bar status item, with a live terminal pane on the left and a job list on the
/// right. Replaces the old per-job floating windows and the menu-bar hover preview —
/// every job lives inside this one panel.
enum SidebarMode {
    case jobs
    case history
}

@MainActor
final class MainWindowController: NSObject {
    private let store: JobStore
    private let history: HistoryStore
    private var mode: SidebarMode = .jobs
    private let panel: KeyablePanel

    private let terminalHost: NSView
    private let emptyLabel: NSTextField
    private let sidebar: JobSidebar
    /// Hairline between the terminal pane and the menu; hidden when the terminal collapses.
    private let divider: NSView

    /// Terminal-style header above the terminal grid: working directory + command.
    private let terminalHeader: NSView
    private let headerLabel: NSTextField
    private static let headerHeight: CGFloat = 30

    /// The terminal view currently parented into `terminalHost`, tracked by identity
    /// so we can detach it even after its job has left the store.
    private var shownView: LocalProcessTerminalView?
    private var selectedJobId: UUID?

    private var isPanelOpen = false
    private var globalMonitor: Any?
    /// Screen point of the panel's top-right corner (under the status item). The panel grows /
    /// shrinks toward this anchor so its right edge stays put across collapse/expand.
    private var anchorTopRight: NSPoint?

    private var cancellables = Set<AnyCancellable>()

    private static let sidebarWidth: CGFloat = 264
    private static let panelSize = NSSize(width: 960, height: 560)
    /// Breathing room around the terminal grid so glyphs never touch the panel edge or divider.
    private static let terminalInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 10)

    private var refreshTimer: Timer?
    private var keyMonitor: Any?
    private var resourceSampler: ResourceSampler!
    private var searchText = ""

    init(store: JobStore, history: HistoryStore) {
        self.store = store
        self.history = history

        let initial = NSRect(origin: .zero, size: Self.panelSize)
        panel = KeyablePanel(
            contentRect: initial,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Allow the panel to shrink to just the menu (a visible resizable window otherwise
        // refuses to go below its min size, leaving the terminal's black strip behind).
        panel.minSize = NSSize(width: Self.sidebarWidth, height: 100)
        panel.maxSize = NSSize(width: Self.panelSize.width, height: 10_000)

        // Rounded container that defines the dropdown's visible shape and clips both panes. Its
        // background is the menu color (not black): when the terminal collapses, a thin sliver of
        // this container can remain exposed on the left, so painting it the menu color keeps it
        // seamless instead of leaving a black band. Adaptive so it tracks light/dark mode.
        let container = AdaptiveBackgroundView(frame: initial)
        container.backgroundColor = .windowBackgroundColor
        container.cornerRadius = 10
        container.borderWidth = 0.5
        container.borderColor = .separatorColor

        // Terminal pane (left, flexible).
        let host = NSView(frame: NSRect(x: 0, y: 0,
                                        width: initial.width - Self.sidebarWidth,
                                        height: initial.height))
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        terminalHost = host

        let empty = NSTextField(labelWithString: "No job selected")
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 13)
        empty.sizeToFit()
        empty.frame.origin = NSPoint(x: (host.bounds.width - empty.frame.width) / 2,
                                     y: (host.bounds.height - empty.frame.height) / 2)
        empty.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        host.addSubview(empty)
        emptyLabel = empty

        // Terminal-style header (cwd + command) pinned to the top of the terminal pane.
        let header = NSView(frame: NSRect(x: 0, y: host.bounds.height - Self.headerHeight,
                                          width: host.bounds.width, height: Self.headerHeight))
        header.autoresizingMask = [.width, .minYMargin]
        header.wantsLayer = true
        header.isHidden = true
        let headerBorder = NSBox(frame: NSRect(x: 0, y: 0, width: host.bounds.width, height: 1))
        headerBorder.boxType = .custom
        headerBorder.borderWidth = 0
        headerBorder.fillColor = NSColor.white.withAlphaComponent(0.08)
        headerBorder.autoresizingMask = [.width]
        header.addSubview(headerBorder)
        let hLabel = NSTextField(labelWithString: "")
        hLabel.frame = NSRect(x: 14, y: (Self.headerHeight - 16) / 2 + 1, width: host.bounds.width - 28, height: 16)
        hLabel.autoresizingMask = [.width]
        hLabel.lineBreakMode = .byTruncatingMiddle
        hLabel.cell?.usesSingleLineMode = true
        header.addSubview(hLabel)
        host.addSubview(header)
        terminalHeader = header
        headerLabel = hLabel

        // Sidebar (right, fixed width).
        let bar = JobSidebar(frame: NSRect(x: initial.width - Self.sidebarWidth, y: 0,
                                           width: Self.sidebarWidth, height: initial.height))
        bar.autoresizingMask = [.minXMargin, .height]
        sidebar = bar

        // Hairline divider flush with the sidebar's left edge.
        let sep = NSBox(frame: NSRect(x: initial.width - Self.sidebarWidth - 1, y: 0,
                                      width: 1, height: initial.height))
        sep.boxType = .custom
        sep.borderWidth = 0
        sep.fillColor = .separatorColor
        sep.autoresizingMask = [.minXMargin, .height]
        divider = sep

        container.addSubview(host)
        container.addSubview(sep)
        container.addSubview(bar)
        panel.contentView = container

        super.init()

        sidebar.onSelect = { [weak self] id in self?.userSelected(id) }
        sidebar.onJobAction = { [weak self] id, action in self?.performJobAction(id, action) }
        sidebar.onSettings = { SettingsWindow.show() }
        sidebar.onQuit = { NSApp.terminate(nil) }
        sidebar.onModeChange = { [weak self] newMode in self?.setMode(newMode) }
        sidebar.onRunHistory = { [weak self] entry in self?.runFromHistory(entry) }
        sidebar.historyMenuProvider = { [weak self] id in self?.historyContextMenu(for: id) }
        sidebar.onSearch = { [weak self] text in self?.applySearch(text) }
        sidebar.onNewCommand = { [weak self] in self?.quickLaunch() }
        sidebar.onClearHistory = { [weak self] in self?.clearHistory() }
        sidebar.onEmptyClick = { [weak self] in self?.deselect() }

        setupHeaderControls()

        resourceSampler = ResourceSampler(store: store)
        resourceSampler.onUpdate = { [weak self] in
            guard let self, self.mode == .jobs else { return }
            self.sidebar.refreshDynamic(jobs: self.store.jobs)
        }

        // Cmd-Up / Cmd-Down cycle through jobs while the panel is open.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPanelOpen, event.modifierFlags.contains(.command) else { return event }
            switch event.keyCode {
            case 125: self.cycleSelection(forward: true); return nil
            case 126: self.cycleSelection(forward: false); return nil
            default: return event
            }
        }

        // Re-skin every open terminal when the theme changes from Settings.
        ThemeManager.shared.onChange = { [weak self] in self?.applyThemeToAll() }

        // Dismiss the dropdown when the user clicks in another app (menu-bar behavior).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isPanelOpen else { return }
            self.hide()
        }

        // Dismiss when the user switches to another app entirely (e.g. Cmd-Tab).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPanelOpen else { return }
                self.hide()
            }
        }

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        history.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.mode == .history else { return }
                self.reloadSidebar()
            }
            .store(in: &cancellables)

        rebuild()
    }

    // MARK: - Showing

    /// Click the status item: open the dropdown if closed, close it if already open.
    func toggle(relativeTo button: NSStatusBarButton) {
        if isPanelOpen { hide() } else { show(relativeTo: button) }
    }

    func show(relativeTo button: NSStatusBarButton) {
        updateLayout()
        position(below: button)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let view = shownView { panel.makeFirstResponder(view) }
        isPanelOpen = true
        reloadSidebar()
        startRefreshTimer()
        resourceSampler.setActive(true)
    }

    func show(relativeTo button: NSStatusBarButton, selecting job: Job) {
        show(relativeTo: button)
        userSelected(job.id)
    }

    func hide() {
        panel.orderOut(nil)
        isPanelOpen = false
        stopRefreshTimer()
        resourceSampler.setActive(false)
    }

    /// Reveals the terminal pane (full-width panel) when a job is selected, or collapses the
    /// panel down to just the menu when nothing is active. The menu stays anchored under the
    /// status item; its now-exposed left corners are rounded by the container's clip.
    private func updateLayout() {
        let collapsed = (shownView == nil)
        terminalHost.isHidden = collapsed
        divider.isHidden = collapsed

        let targetWidth = collapsed ? Self.sidebarWidth : Self.panelSize.width
        guard panel.frame.width != targetWidth else { return }

        // Keep the right edge (under the status item) fixed while the width changes. Anchor to the
        // stored top-right rather than the live frame, so repeated collapse/expand can't drift.
        var frame = panel.frame
        let right = anchorTopRight?.x ?? frame.maxX
        frame.size.width = targetWidth
        frame.origin.x = right - targetWidth
        if isPanelOpen, let visible = (panel.screen ?? NSScreen.main)?.visibleFrame,
           frame.origin.x < visible.minX + 8 {
            frame.origin.x = visible.minX + 8
        }
        panel.setFrame(frame, display: isPanelOpen)
        // A transparent, borderless window keeps the shadow of its previous (larger) frame after
        // shrinking; recompute it so no ghost outline lingers beside the collapsed menu.
        panel.invalidateShadow()
    }

    /// Keeps time-based sidebar fields (job age, live status) ticking while the panel is visible.
    /// Event-driven reloads cover add/remove/status; this covers fields that change with the clock.
    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sidebar.refreshDynamic(jobs: self.store.jobs)
            }
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private static func insetRect(_ rect: NSRect, by insets: NSEdgeInsets) -> NSRect {
        NSRect(x: rect.minX + insets.left,
               y: rect.minY + insets.bottom,
               width: max(0, rect.width - insets.left - insets.right),
               height: max(0, rect.height - insets.top - insets.bottom))
    }

    /// Anchors the panel just below the status item, right-aligned to it and clamped on screen.
    private func position(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let screen = buttonWindow.screen ?? NSScreen.main
        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        let size = panel.frame.size
        var origin = NSPoint(x: buttonFrame.maxX - size.width, y: buttonFrame.minY - size.height - 6)
        if let visible = screen?.visibleFrame {
            if origin.x < visible.minX + 8 { origin.x = visible.minX + 8 }
            if origin.x + size.width > visible.maxX - 8 { origin.x = visible.maxX - size.width - 8 }
            if origin.y < visible.minY + 8 { origin.y = visible.minY + 8 }
        }
        panel.setFrameOrigin(origin)
        anchorTopRight = NSPoint(x: origin.x + size.width, y: origin.y + size.height)
    }

    // MARK: - Selection

    /// Re-parents the selected job's live terminal view into the host, detaching the previous one.
    private func applySelection(_ job: Job?) {
        if shownView !== job?.terminalView {
            shownView?.removeFromSuperview()
        }
        shownView = job?.terminalView
        selectedJobId = job?.id
        // Expand to reveal the terminal pane (or collapse to just the menu) before laying out
        // the view, so it sizes against the final host bounds.
        updateLayout()
        if let job, let view = shownView {
            view.removeFromSuperview()
            // Terminal grid sits below the header, inset on all sides.
            let b = terminalHost.bounds
            let area = NSRect(x: b.minX, y: b.minY, width: b.width, height: b.height - Self.headerHeight)
            view.frame = Self.insetRect(area, by: Self.terminalInsets)
            // Fixed margins on all four edges keep the inset constant as the panel resizes.
            view.autoresizingMask = [.width, .height]
            terminalHost.addSubview(view, positioned: .below, relativeTo: terminalHeader)
            // Match the padding margin (and header) to the terminal's own background so the inset
            // reads as breathing room, not a border.
            let bg = view.nativeBackgroundColor
            terminalHost.layer?.backgroundColor = bg.cgColor
            terminalHeader.layer?.backgroundColor = bg.cgColor
            headerLabel.attributedStringValue = Self.headerText(for: job)
            terminalHeader.isHidden = false
            emptyLabel.isHidden = true
            panel.makeFirstResponder(view)
        } else {
            emptyLabel.isHidden = false
            terminalHeader.isHidden = true
        }
        updateTitle()
    }

    /// Prompt-style header: a green ➜, the working directory (dimmed), then the command (bright).
    private static func headerText(for job: Job) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "➜  ", attributes: [
            .font: font, .foregroundColor: NSColor.systemGreen,
        ]))
        result.append(NSAttributedString(string: displayPath(job.cwd), attributes: [
            .font: font, .foregroundColor: NSColor.systemTeal.withAlphaComponent(0.9),
        ]))
        result.append(NSAttributedString(string: "  \(job.displayCommand)", attributes: [
            .font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]))
        return result
    }

    /// Abbreviates the user's home directory to `~`, like a shell prompt.
    private static func displayPath(_ cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }

    private func userSelected(_ id: UUID) {
        guard let job = store.job(id: id) else { return }
        job.unseenSignalCount = 0
        applySelection(job)
        reloadSidebar()
    }

    /// Clicking empty space in the menu clears the selection and collapses the terminal pane.
    private func deselect() {
        guard selectedJobId != nil else { return }
        applySelection(nil)
        reloadSidebar()
    }

    /// Reconciles selection with the current job list, then redraws the sidebar.
    private func rebuild() {
        let jobs = store.jobs
        let selectionValid = selectedJobId.map { store.job(id: $0) != nil } ?? false
        if !selectionValid {
            // No valid selection — surface the newest *running* job, or stay collapsed on just the
            // menu when nothing is active (no running command, or no commands at all). A stopped
            // job is only shown when the user explicitly clicks it.
            applySelection(jobs.last(where: { $0.status == .running }))
        }
        reloadSidebar()
    }

    private func reloadSidebar() {
        let query = searchText.lowercased()
        switch mode {
        case .jobs:
            let jobs = query.isEmpty ? store.jobs : store.jobs.filter {
                $0.displayCommand.lowercased().contains(query) || $0.displayCwd.lowercased().contains(query)
            }
            sidebar.showJobs(jobs, selectedId: selectedJobId)
        case .history:
            let entries = query.isEmpty ? history.entries : history.entries.filter {
                $0.command.lowercased().contains(query) || $0.displayCwd.lowercased().contains(query)
            }
            sidebar.showHistory(entries)
        }
    }

    private func setMode(_ newMode: SidebarMode) {
        mode = newMode
        sidebar.setSelectedMode(newMode)
        reloadSidebar()
    }

    private func applySearch(_ text: String) {
        searchText = text
        reloadSidebar()
    }

    /// Cmd-Up / Cmd-Down: move selection to the next/previous job, wrapping around.
    private func cycleSelection(forward: Bool) {
        let jobs = store.jobs
        guard !jobs.isEmpty else { return }
        let current = selectedJobId.flatMap { id in jobs.firstIndex(where: { $0.id == id }) }
        let next: Int
        if let current {
            next = forward ? (current + 1) % jobs.count : (current - 1 + jobs.count) % jobs.count
        } else {
            next = forward ? 0 : jobs.count - 1
        }
        if mode != .jobs { setMode(.jobs) }
        userSelected(jobs[next].id)
    }

    /// Re-launches a past command in its original directory, then returns to the jobs view on it.
    private func runFromHistory(_ entry: HistoryEntry) {
        let id = store.spawn(argv: entry.argv,
                             cwd: entry.cwd,
                             env: ProcessInfo.processInfo.environment,
                             cols: 120,
                             rows: 30)
        setMode(.jobs)
        userSelected(id)
    }

    private func historyContextMenu(for id: UUID) -> NSMenu? {
        guard let entry = history.entries.first(where: { $0.id == id }) else { return nil }
        let menu = NSMenu()

        func add(_ title: String, _ action: Selector, represented: Any) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = represented
            menu.addItem(item)
        }

        add("Run Again", #selector(runHistoryItem(_:)), represented: entry)
        add("Edit & Run…", #selector(editHistoryItem(_:)), represented: entry)
        add(entry.pinned ? "Unpin" : "Pin", #selector(pinHistoryItem(_:)), represented: id as NSUUID)
        add("Reveal cwd in Finder", #selector(revealHistoryItem(_:)), represented: entry)
        menu.addItem(.separator())
        add("Remove from History", #selector(removeHistoryItem(_:)), represented: id as NSUUID)
        return menu
    }

    @objc private func runHistoryItem(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HistoryEntry else { return }
        runFromHistory(entry)
    }

    @objc private func editHistoryItem(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HistoryEntry else { return }
        runCommandDialog(title: "Edit & Run", command: entry.command, cwd: entry.cwd)
    }

    @objc private func pinHistoryItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? NSUUID else { return }
        history.togglePin(id: id as UUID)
    }

    @objc private func revealHistoryItem(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? HistoryEntry else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.cwd)])
    }

    @objc private func removeHistoryItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? NSUUID else { return }
        history.remove(id: id as UUID)
    }

    // MARK: - Quick launch / clear

    private func quickLaunch() {
        runCommandDialog(title: "New Command", command: "",
                         cwd: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// Prompts for a command + working directory, then spawns it. Used by quick-launch and edit-&-run.
    private func runCommandDialog(title: String, command: String, cwd: String) {
        let alert = NSAlert()
        alert.messageText = title

        let cmdField = NSTextField(frame: NSRect(x: 0, y: 30, width: 340, height: 24))
        cmdField.placeholderString = "e.g. npm run dev"
        cmdField.stringValue = command
        let dirField = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        dirField.placeholderString = "working directory"
        dirField.stringValue = cwd
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 58))
        accessory.addSubview(cmdField)
        accessory.addSubview(dirField)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = cmdField

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let line = cmdField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        let argv = line.split(separator: " ").map(String.init)
        let dir = dirField.stringValue.trimmingCharacters(in: .whitespaces)
        let id = store.spawn(argv: argv,
                             cwd: dir.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : dir,
                             env: ProcessInfo.processInfo.environment, cols: 120, rows: 30)
        if !searchText.isEmpty { searchText = ""; sidebar.clearSearch() }
        setMode(.jobs)
        userSelected(id)
    }

    private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear command history?"
        alert.informativeText = "This removes all recorded commands. Pinned commands are removed too."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        history.clear()
        reloadSidebar()
    }

    // MARK: - Copy (terminal output tools)

    private var selectedJob: Job? { selectedJobId.flatMap { store.job(id: $0) } }

    private func setupHeaderControls() {
        let copy = NSButton(title: "Copy ▾", target: self, action: #selector(copyMenu(_:)))
        copy.isBordered = false
        copy.attributedTitle = NSAttributedString(string: "Copy ▾", attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.65),
            .font: NSFont.systemFont(ofSize: 11),
        ])
        copy.sizeToFit()
        let width = copy.frame.width + 6
        copy.frame = NSRect(x: terminalHeader.bounds.width - width - 8,
                            y: (Self.headerHeight - 18) / 2, width: width, height: 18)
        copy.autoresizingMask = [.minXMargin]
        copy.toolTip = "Copy command / output"
        terminalHeader.addSubview(copy)
        headerLabel.frame.size.width = copy.frame.minX - headerLabel.frame.minX - 8
    }

    @objc private func copyMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let items: [(String, Selector)] = [
            ("Copy command", #selector(copyCommand)),
            ("Copy output", #selector(copyOutput)),
            ("Copy command + output", #selector(copyCommandAndOutput)),
        ]
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func copyCommand() {
        guard let job = selectedJob else { return }
        setClipboard(job.displayCommand)
    }

    @objc private func copyOutput() {
        guard let job = selectedJob else { return }
        setClipboard(Self.terminalText(job))
    }

    @objc private func copyCommandAndOutput() {
        guard let job = selectedJob else { return }
        setClipboard(job.displayCommand + "\n\n" + Self.terminalText(job))
    }

    private static func terminalText(_ job: Job) -> String {
        let data = job.terminalView.getTerminal().getBufferAsData()
        var text = String(data: data, encoding: .utf8) ?? ""
        while let last = text.last, last == "\n" || last == " " || last == "\t" { text.removeLast() }
        return text
    }

    private func setClipboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Re-applies the active theme to every open terminal and refreshes the pane chrome.
    private func applyThemeToAll() {
        for job in store.jobs { ThemeManager.shared.apply(to: job.terminalView) }
        if let view = shownView {
            terminalHost.layer?.backgroundColor = view.nativeBackgroundColor.cgColor
            terminalHeader.layer?.backgroundColor = view.nativeBackgroundColor.cgColor
        }
    }

    private func updateTitle() {
        if let id = selectedJobId, let job = store.job(id: id) {
            let title = job.terminalTitle?.trimmingCharacters(in: .whitespaces)
            panel.title = (title?.isEmpty == false) ? title! : job.displayCommand
        } else {
            panel.title = "Mini"
        }
    }

    // MARK: - Per-job actions (inline row buttons)

    private func performJobAction(_ id: UUID, _ action: JobRowAction) {
        guard let job = store.job(id: id) else { return }
        switch action {
        case .stop:
            let pid = job.terminalView.process.shellPid
            if pid > 0 { kill(pid, SIGTERM) }
        case .restart:
            store.restart(id: id)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.cwd)])
        case .remove:
            store.remove(id: id)
        }
    }
}

// MARK: - Sidebar

/// Inline row actions, shown as a button strip on the selected job row.
enum JobRowAction: Int {
    case stop, restart, reveal, remove
}

/// Shared layout metrics + height computation for sidebar rows, so the command title can wrap
/// to two lines (more readable) and the sidebar can size each row to its content.
enum RowMetrics {
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let textX: CGFloat = 32
    static let rightPad: CGFloat = 12
    static let topPad: CGFloat = 10
    static let bottomPad: CGFloat = 10
    static let subtitleHeight: CGFloat = 15
    static let lineGap: CGFloat = 2
    static let maxTitleLines = 2
    static let actionStripHeight: CGFloat = 32

    static var titleLineHeight: CGFloat {
        ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
    }

    /// Height the (possibly wrapped, max 2-line) title needs within `width`.
    static func titleHeight(_ text: String, width: CGFloat) -> CGFloat {
        guard width > 0 else { return titleLineHeight }
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleFont])
        let lines = max(1, min(maxTitleLines, Int(ceil(rect.height / titleLineHeight - 0.02))))
        return titleLineHeight * CGFloat(lines)
    }

    static func rowHeight(titleWidth: CGFloat, title: String, showActions: Bool) -> CGFloat {
        let base = topPad + titleHeight(title, width: titleWidth) + lineGap + subtitleHeight + bottomPad
        return showActions ? base + actionStripHeight : base
    }
}

/// Right-hand job list: section headers, selectable rows with status + unseen-signal badges,
/// inline action buttons on the selected row, and a footer with Settings / Quit.
@MainActor
final class JobSidebar: NSView, NSSearchFieldDelegate {
    var onSelect: ((UUID) -> Void)?
    var onJobAction: ((UUID, JobRowAction) -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onModeChange: ((SidebarMode) -> Void)?
    var onRunHistory: ((HistoryEntry) -> Void)?
    var historyMenuProvider: ((UUID) -> NSMenu?)?
    var onSearch: ((String) -> Void)?
    var onNewCommand: (() -> Void)?
    var onClearHistory: (() -> Void)?
    /// Fired when the user clicks empty space in the menu (not on a row or control).
    var onEmptyClick: (() -> Void)?

    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private let segmented = NSSegmentedControl(labels: ["Jobs", "History"],
                                               trackingMode: .selectOne, target: nil, action: nil)
    private let searchField = NSSearchField()
    private let clearButton = NSButton()
    private var rowsById: [UUID: JobRowView] = [:]

    private static let headerHeight: CGFloat = 26
    private static let footerHeight: CGFloat = 40
    private static let topBarHeight: CGFloat = 40
    private static let searchBarHeight: CGFloat = 36

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Footer (Settings / Quit) pinned to the bottom.
        let footer = NSView(frame: NSRect(x: 0, y: 0, width: frameRect.width, height: Self.footerHeight))
        footer.autoresizingMask = [.width]

        let border = NSBox(frame: NSRect(x: 0, y: Self.footerHeight - 1, width: frameRect.width, height: 1))
        border.boxType = .custom
        border.borderWidth = 0
        border.fillColor = .separatorColor
        border.autoresizingMask = [.width, .minYMargin]
        footer.addSubview(border)

        let settings = NSButton(title: "Settings…", target: self, action: #selector(settingsClicked))
        settings.isBordered = false
        settings.font = .systemFont(ofSize: 12)
        settings.frame = NSRect(x: 8, y: 7, width: 90, height: 26)
        footer.addSubview(settings)

        let quit = NSButton(title: "Quit", target: self, action: #selector(quitClicked))
        quit.isBordered = false
        quit.font = .systemFont(ofSize: 12)
        quit.frame = NSRect(x: frameRect.width - 60, y: 7, width: 52, height: 26)
        quit.autoresizingMask = [.minXMargin]
        footer.addSubview(quit)

        addSubview(footer)

        // Top bar: Jobs / History toggle + "new command" button, pinned to the top.
        let topBar = NSView(frame: NSRect(x: 0, y: frameRect.height - Self.topBarHeight,
                                          width: frameRect.width, height: Self.topBarHeight))
        topBar.autoresizingMask = [.width, .minYMargin]

        segmented.segmentStyle = .automatic
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(segmentChanged)
        segmented.frame = NSRect(x: 10, y: (Self.topBarHeight - 24) / 2,
                                 width: frameRect.width - 56, height: 24)
        segmented.autoresizingMask = [.width]
        topBar.addSubview(segmented)

        let newButton = NSButton(title: "＋", target: self, action: #selector(newClicked))
        newButton.isBordered = false
        newButton.font = .systemFont(ofSize: 17, weight: .regular)
        newButton.frame = NSRect(x: frameRect.width - 38, y: (Self.topBarHeight - 26) / 2, width: 28, height: 26)
        newButton.autoresizingMask = [.minXMargin]
        newButton.toolTip = "New command"
        topBar.addSubview(newButton)

        let topBorder = NSBox(frame: NSRect(x: 0, y: 0, width: frameRect.width, height: 1))
        topBorder.boxType = .custom
        topBorder.borderWidth = 0
        topBorder.fillColor = .separatorColor
        topBorder.autoresizingMask = [.width]
        topBar.addSubview(topBorder)
        addSubview(topBar)

        // Search bar with a Clear button (Clear shown only in History mode).
        let searchBarY = frameRect.height - Self.topBarHeight - Self.searchBarHeight
        let searchBar = NSView(frame: NSRect(x: 0, y: searchBarY, width: frameRect.width, height: Self.searchBarHeight))
        searchBar.autoresizingMask = [.width, .minYMargin]

        clearButton.title = "Clear"
        clearButton.isBordered = false
        clearButton.font = .systemFont(ofSize: 11)
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        clearButton.sizeToFit()
        clearButton.frame = NSRect(x: frameRect.width - clearButton.frame.width - 10,
                                   y: (Self.searchBarHeight - 20) / 2,
                                   width: clearButton.frame.width, height: 20)
        clearButton.autoresizingMask = [.minXMargin]
        clearButton.isHidden = true
        searchBar.addSubview(clearButton)

        searchField.placeholderString = "Filter…"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.frame = NSRect(x: 10, y: (Self.searchBarHeight - 22) / 2,
                                   width: frameRect.width - 20, height: 22)
        searchField.autoresizingMask = [.width]
        searchBar.addSubview(searchField)
        addSubview(searchBar)

        // Scrollable list between the search bar and the footer.
        scrollView.frame = NSRect(x: 0, y: Self.footerHeight,
                                  width: frameRect.width,
                                  height: frameRect.height - Self.footerHeight - Self.topBarHeight - Self.searchBarHeight)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.documentView = listView
        listView.onBackgroundClick = { [weak self] in self?.onEmptyClick?() }
        addSubview(scrollView)
    }

    // Resolve the background through `updateLayer` rather than a one-time `layer.backgroundColor`
    // assignment, so it re-resolves whenever the system flips between light and dark mode (a raw
    // cgColor would stay frozen at its launch-time value and turn unreadable after the switch).
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    /// Clicks landing on the sidebar's own background (margins, top/search bars) count as
    /// empty-space clicks; rows and controls consume their own clicks before reaching here.
    override func mouseDown(with event: NSEvent) {
        onEmptyClick?()
    }

    @objc private func segmentChanged() {
        onModeChange?(segmented.selectedSegment == 0 ? .jobs : .history)
    }

    @objc private func newClicked() { onNewCommand?() }
    @objc private func clearClicked() { onClearHistory?() }

    func controlTextDidChange(_ obj: Notification) {
        onSearch?(searchField.stringValue)
    }

    func clearSearch() {
        searchField.stringValue = ""
        onSearch?("")
    }

    func setSelectedMode(_ mode: SidebarMode) {
        segmented.selectedSegment = (mode == .jobs) ? 0 : 1
        let isHistory = (mode == .history)
        clearButton.isHidden = !isHistory
        let rightInset: CGFloat = isHistory ? (clearButton.frame.width + 18) : 10
        searchField.frame.size.width = bounds.width - 10 - rightInset
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showJobs(_ jobs: [Job], selectedId: UUID?) {
        listView.subviews.forEach { $0.removeFromSuperview() }
        rowsById.removeAll()
        let width = bounds.width
        let running = jobs.filter { $0.status == .running }
        let stopped = jobs.filter { $0.status != .running }

        var y: CGFloat = 8

        func addHeader(_ text: String) {
            listView.addSubview(Self.makeHeader(text, width: width, y: y))
            y += Self.headerHeight
        }
        func addRows(_ list: [Job]) {
            for job in list {
                let selected = job.id == selectedId
                let h = JobRowView.height(for: job, width: width, selected: selected)
                let row = JobRowView(job: job, selected: selected, width: width, y: y, height: h)
                row.onSelect = { [weak self] in self?.onSelect?(job.id) }
                row.onAction = { [weak self] action in self?.onJobAction?(job.id, action) }
                listView.addSubview(row)
                rowsById[job.id] = row
                y += h
            }
        }

        if running.isEmpty && stopped.isEmpty {
            listView.addSubview(Self.makeHeader("No jobs", width: width, y: y))
            y += Self.headerHeight
        }
        if !running.isEmpty {
            addHeader("RUNNING")
            addRows(running)
        }
        if !stopped.isEmpty {
            if !running.isEmpty { y += 8 }
            addHeader("STOPPED")
            addRows(stopped)
        }

        let visibleHeight = scrollView.contentView.bounds.height
        listView.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, visibleHeight))
    }

    /// Lightweight per-second update of time-based fields (job age) without rebuilding rows,
    /// so transient affordances like the "open in browser" pill stay clickable.
    func refreshDynamic(jobs: [Job]) {
        for job in jobs { rowsById[job.id]?.updateDynamic(job: job) }
    }

    func showHistory(_ entries: [HistoryEntry]) {
        listView.subviews.forEach { $0.removeFromSuperview() }
        rowsById.removeAll()
        let width = bounds.width
        var y: CGFloat = 8

        func addSection(_ title: String, _ list: [HistoryEntry]) {
            guard !list.isEmpty else { return }
            listView.addSubview(Self.makeHeader(title, width: width, y: y))
            y += Self.headerHeight
            for entry in list {
                let h = HistoryRowView.height(for: entry, width: width)
                let row = HistoryRowView(entry: entry, pinned: entry.pinned, width: width, y: y, height: h)
                row.onRun = { [weak self] in self?.onRunHistory?(entry) }
                row.contextMenuProvider = { [weak self] in self?.historyMenuProvider?(entry.id) }
                listView.addSubview(row)
                y += h
            }
        }

        if entries.isEmpty {
            listView.addSubview(Self.makeHeader("No history yet", width: width, y: y))
            y += Self.headerHeight
        } else {
            let pinned = entries.filter { $0.pinned }
            let recent = entries.filter { !$0.pinned }
            addSection("Pinned", pinned)
            if !pinned.isEmpty && !recent.isEmpty { y += 8 }
            addSection("Recent", recent)
        }

        let visibleHeight = scrollView.contentView.bounds.height
        listView.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, visibleHeight))
    }

    private static func makeHeader(_ text: String, width: CGFloat, y: CGFloat) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: y, width: width, height: headerHeight))
        container.autoresizingMask = [.width]
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: 14, y: 5, width: width - 28, height: 14)
        label.autoresizingMask = [.width]
        container.addSubview(label)
        return container
    }

    @objc private func settingsClicked() { onSettings?() }
    @objc private func quitClicked() { onQuit?() }
}

/// One job row: status dot, command (up to two lines), context subtitle (cwd · age), an
/// unseen-signal badge, a clickable "open in browser" pill, and — on the selected row — an
/// inline action button strip (Stop/Restart · Reveal · Remove) that replaces the context menu.
@MainActor
final class JobRowView: NSView {
    var onSelect: (() -> Void)?
    var onAction: ((JobRowAction) -> Void)?

    private let subtitleLabel: NSTextField
    private var openURL: String?

    /// Total height this job needs at `width`, including a two-line title and (if selected) actions.
    static func height(for job: Job, width: CGFloat, selected: Bool) -> CGFloat {
        RowMetrics.rowHeight(titleWidth: titleWidth(for: job, width: width),
                             title: job.displayCommand,
                             showActions: selected)
    }

    private static func titleWidth(for job: Job, width: CGFloat) -> CGFloat {
        let badgeWidth: CGFloat = job.unseenSignalCount > 0 ? 28 : 0
        return max(40, width - RowMetrics.textX - RowMetrics.rightPad - badgeWidth)
    }

    init(job: Job, selected: Bool, width: CGFloat, y: CGFloat, height: CGFloat) {
        subtitleLabel = NSTextField(labelWithString: Self.subtitle(for: job))
        super.init(frame: NSRect(x: 0, y: y, width: width, height: height))
        autoresizingMask = [.width]
        wantsLayer = true

        if selected {
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).cgColor
            let accent = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: height))
            accent.wantsLayer = true
            accent.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            accent.autoresizingMask = [.height]
            addSubview(accent)
        }

        let titleW = Self.titleWidth(for: job, width: width)
        let actionH: CGFloat = selected ? RowMetrics.actionStripHeight : 0
        let titleH = height - RowMetrics.topPad - RowMetrics.lineGap - RowMetrics.subtitleHeight - RowMetrics.bottomPad - actionH
        let titleMaxY = height - RowMetrics.topPad
        let firstLineCenter = titleMaxY - RowMetrics.titleLineHeight / 2

        let dot = NSView(frame: NSRect(x: 14, y: firstLineCenter - 4, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = Self.dotColor(for: job).cgColor
        addSubview(dot)

        let title = NSTextField(wrappingLabelWithString: job.displayCommand)
        title.font = RowMetrics.titleFont
        title.maximumNumberOfLines = RowMetrics.maxTitleLines
        title.cell?.truncatesLastVisibleLine = true
        title.isSelectable = false
        title.frame = NSRect(x: RowMetrics.textX, y: titleMaxY - titleH, width: titleW, height: titleH)
        addSubview(title)

        if job.unseenSignalCount > 0 {
            let badge = Self.makeBadge(count: job.unseenSignalCount)
            badge.frame.origin = NSPoint(x: width - badge.frame.width - 12, y: firstLineCenter - badge.frame.height / 2)
            badge.autoresizingMask = [.minXMargin]
            addSubview(badge)
        }

        let subtitleMaxY = titleMaxY - titleH - RowMetrics.lineGap
        var subtitleRight = width - 12
        if job.status == .running, let url = job.detectedURL, let display = job.detectedHostPort {
            openURL = url
            let pill = makePill(display: display)
            pill.sizeToFit()
            let pillWidth = pill.frame.width
            pill.frame = NSRect(x: width - pillWidth - 12,
                                y: subtitleMaxY - RowMetrics.subtitleHeight - 1,
                                width: pillWidth, height: 17)
            pill.autoresizingMask = [.minXMargin]
            addSubview(pill)
            subtitleRight = pill.frame.minX - 6
        }

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.frame = NSRect(x: RowMetrics.textX, y: subtitleMaxY - RowMetrics.subtitleHeight,
                                     width: max(40, subtitleRight - RowMetrics.textX), height: RowMetrics.subtitleHeight)
        addSubview(subtitleLabel)

        if selected {
            addActionStrip(for: job)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Updates only time-dependent fields (the cwd · age subtitle) in place.
    func updateDynamic(job: Job) {
        subtitleLabel.stringValue = Self.subtitle(for: job)
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    // MARK: Inline actions

    private func addActionStrip(for job: Job) {
        let running = job.status == .running
        let items: [(String, JobRowAction, NSColor?)] = running
            ? [("Stop", .stop, nil), ("Reveal", .reveal, nil), ("Remove", .remove, .systemRed)]
            : [("Restart", .restart, nil), ("Reveal", .reveal, nil), ("Remove", .remove, .systemRed)]

        var x = RowMetrics.textX - 2
        for (label, action, tint) in items {
            let button = makeActionButton(label, action: action, tint: tint)
            button.frame = NSRect(x: x, y: 7, width: button.frame.width, height: 22)
            addSubview(button)
            x += button.frame.width + 4
        }
    }

    private func makeActionButton(_ label: String, action: JobRowAction, tint: NSColor?) -> NSButton {
        let button = NSButton(title: label, target: self, action: #selector(actionButtonTapped(_:)))
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.tag = action.rawValue
        if let tint {
            button.attributedTitle = NSAttributedString(
                string: label,
                attributes: [.foregroundColor: tint, .font: NSFont.systemFont(ofSize: 11)])
        }
        button.sizeToFit()
        button.frame.size.width += 10
        return button
    }

    @objc private func actionButtonTapped(_ sender: NSButton) {
        if let action = JobRowAction(rawValue: sender.tag) { onAction?(action) }
    }

    private func makePill(display: String) -> NSButton {
        let pill = NSButton(title: "↗ \(display)", target: self, action: #selector(openURLClicked))
        pill.bezelStyle = .inline
        pill.controlSize = .small
        pill.font = .systemFont(ofSize: 10, weight: .medium)
        pill.contentTintColor = .controlAccentColor
        pill.toolTip = "Open \(display) in your browser"
        return pill
    }

    @objc private func openURLClicked() {
        guard let urlString = openURL, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func dotColor(for job: Job) -> NSColor {
        switch job.status {
        case .running: return .systemGreen
        case .stopped(let code): return code == 0 ? .systemGray : .systemRed
        }
    }

    private static func subtitle(for job: Job) -> String {
        switch job.status {
        case .running:
            // Drop the cwd when resources are shown — the cwd already lives in the terminal header.
            if let cpu = job.cpuPercent, let mem = job.memBytes {
                return "\(Int(cpu.rounded()))% · \(formatBytes(mem)) · \(job.ageDescription)"
            }
            return "\(job.displayCwd) · \(job.ageDescription)"
        case .stopped(let code):
            return code == 0 ? "\(job.displayCwd) · exited" : "\(job.displayCwd) · exit \(code)"
        }
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return "\(Int(mb.rounded())) MB"
    }

    private static func makeBadge(count: Int) -> NSView {
        let label = NSTextField(labelWithString: count > 99 ? "99+" : "\(count)")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()
        let width = max(18, label.frame.width + 10)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 18))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.systemRed.cgColor
        container.layer?.cornerRadius = 9
        label.frame = NSRect(x: 0, y: (18 - label.frame.height) / 2, width: width, height: label.frame.height)
        container.addSubview(label)
        return container
    }
}

/// One history row: command (up to two lines) + "cwd · <relative last run>". Click anywhere to re-run.
@MainActor
final class HistoryRowView: NSView {
    var onRun: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    private var tracking: NSTrackingArea?

    static func height(for entry: HistoryEntry, width: CGFloat) -> CGFloat {
        RowMetrics.rowHeight(titleWidth: titleWidth(width), title: entry.command, showActions: false)
    }

    private static func titleWidth(_ width: CGFloat) -> CGFloat {
        max(40, width - RowMetrics.textX - RowMetrics.rightPad)
    }

    init(entry: HistoryEntry, pinned: Bool, width: CGFloat, y: CGFloat, height: CGFloat) {
        super.init(frame: NSRect(x: 0, y: y, width: width, height: height))
        autoresizingMask = [.width]
        wantsLayer = true

        let titleW = Self.titleWidth(width)
        let titleH = height - RowMetrics.topPad - RowMetrics.lineGap - RowMetrics.subtitleHeight - RowMetrics.bottomPad
        let titleMaxY = height - RowMetrics.topPad
        let firstLineCenter = titleMaxY - RowMetrics.titleLineHeight / 2

        let icon = NSImageView(frame: NSRect(x: 12, y: firstLineCenter - 7, width: 14, height: 14))
        icon.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "arrow.clockwise",
                             accessibilityDescription: pinned ? "Pinned" : "Run again")
        icon.contentTintColor = pinned ? .controlAccentColor : .tertiaryLabelColor
        addSubview(icon)

        let title = NSTextField(wrappingLabelWithString: entry.command)
        title.font = RowMetrics.titleFont
        title.maximumNumberOfLines = RowMetrics.maxTitleLines
        title.cell?.truncatesLastVisibleLine = true
        title.isSelectable = false
        title.frame = NSRect(x: RowMetrics.textX, y: titleMaxY - titleH, width: titleW, height: titleH)
        addSubview(title)

        let subtitle = NSTextField(labelWithString: Self.subtitle(for: entry))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: RowMetrics.textX, y: titleMaxY - titleH - RowMetrics.lineGap - RowMetrics.subtitleHeight,
                                width: titleW, height: RowMetrics.subtitleHeight)
        addSubview(subtitle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { onRun?() }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    private static func subtitle(for entry: HistoryEntry) -> String {
        "\(entry.displayCwd) · \(relativeTime(entry.lastRun))"
    }

    private static func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

/// Top-down list coordinates so rows lay out from the top of the scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    /// Forwarded when the user clicks the empty area below the rows.
    var onBackgroundClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onBackgroundClick?() }
}

/// A borderless panel that can still become key, so the embedded terminal receives keystrokes.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// A layer-backed view whose background, border, and corner radius re-resolve on every appearance
/// change. Assigning `layer.backgroundColor = nsColor.cgColor` directly freezes the color at the
/// appearance active when it ran, so the view would stay light after the system switches to dark
/// mode (and vice-versa); driving it through `updateLayer` keeps it correct across the switch.
final class AdaptiveBackgroundView: NSView {
    var backgroundColor: NSColor = .clear { didSet { needsDisplay = true } }
    var borderColor: NSColor? { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 0 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = backgroundColor.cgColor
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = cornerRadius > 0
        layer.borderWidth = borderWidth
        layer.borderColor = borderColor?.cgColor
    }
}
