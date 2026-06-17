import AppKit

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static var shared: SettingsWindow?

    private let window: NSWindow
    private let textField: NSTextField
    private let statusLabel: NSTextField
    private let themeLabel: NSTextField
    private let shortcutButton: NSButton
    private var recordMonitor: Any?

    static func show() {
        if let existing = shared {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let settings = SettingsWindow()
        shared = settings
        settings.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private override init() {
        let height: CGFloat = 470
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mini — Settings"
        window.center()
        window.isReleasedWhenClosed = false
        // Sit just above the floating dropdown panel so Settings is never hidden behind it.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

        textField = NSTextField()
        textField.placeholderString = "mini, bg, run"
        textField.stringValue = AliasInstaller.currentAliases().joined(separator: ", ")

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.isEditable = false
        statusLabel.drawsBackground = false
        statusLabel.isBordered = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byWordWrapping

        themeLabel = NSTextField(labelWithString: "")
        themeLabel.textColor = .secondaryLabelColor
        themeLabel.font = .systemFont(ofSize: 12)

        shortcutButton = NSButton(title: "", target: nil, action: nil)
        shortcutButton.bezelStyle = .rounded

        super.init()

        shortcutButton.target = self
        shortcutButton.action = #selector(recordShortcut)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: height))
        let top = height - 16

        // MARK: Aliases
        let aliasHeader = Self.header("Aliases (comma-separated)")
        aliasHeader.frame = NSRect(x: 20, y: top - 18, width: 420, height: 18)
        content.addSubview(aliasHeader)

        textField.frame = NSRect(x: 20, y: top - 48, width: 420, height: 24)
        content.addSubview(textField)

        let installButton = NSButton(title: "Install / Update Aliases", target: self, action: #selector(installAction))
        installButton.bezelStyle = .rounded
        installButton.frame = NSRect(x: 18, y: top - 84, width: 200, height: 28)
        content.addSubview(installButton)

        statusLabel.frame = NSRect(x: 20, y: top - 116, width: 420, height: 28)
        content.addSubview(statusLabel)

        content.addSubview(Self.separator(y: top - 136))

        // MARK: Global shortcut
        let shortcutHeader = Self.header("Global Shortcut")
        shortcutHeader.frame = NSRect(x: 20, y: top - 164, width: 420, height: 18)
        content.addSubview(shortcutHeader)

        let shortcutHelp = NSTextField(labelWithString: "Toggle the panel from anywhere. Click, then press the keys.")
        shortcutHelp.font = .systemFont(ofSize: 11)
        shortcutHelp.textColor = .secondaryLabelColor
        shortcutHelp.frame = NSRect(x: 20, y: top - 186, width: 420, height: 16)
        content.addSubview(shortcutHelp)

        let shortcutLabel = NSTextField(labelWithString: "Shortcut:")
        shortcutLabel.font = .systemFont(ofSize: 12)
        shortcutLabel.frame = NSRect(x: 20, y: top - 217, width: 70, height: 18)
        content.addSubview(shortcutLabel)

        shortcutButton.frame = NSRect(x: 92, y: top - 221, width: 160, height: 26)
        content.addSubview(shortcutButton)

        content.addSubview(Self.separator(y: top - 244))

        // MARK: Terminal theme
        let themeHeader = Self.header("Terminal Theme")
        themeHeader.frame = NSRect(x: 20, y: top - 272, width: 420, height: 18)
        content.addSubview(themeHeader)

        let themeHelp = NSTextField(labelWithString: "Import a color scheme from iTerm2 or Ghostty for the terminal previews.")
        themeHelp.font = .systemFont(ofSize: 11)
        themeHelp.textColor = .secondaryLabelColor
        themeHelp.frame = NSRect(x: 20, y: top - 294, width: 420, height: 16)
        content.addSubview(themeHelp)

        themeLabel.frame = NSRect(x: 20, y: top - 322, width: 420, height: 18)
        content.addSubview(themeLabel)

        let iterm = NSButton(title: "Import iTerm2…", target: self, action: #selector(importITerm))
        iterm.bezelStyle = .rounded
        iterm.frame = NSRect(x: 18, y: top - 360, width: 140, height: 28)
        content.addSubview(iterm)

        let ghostty = NSButton(title: "Import Ghostty…", target: self, action: #selector(importGhostty))
        ghostty.bezelStyle = .rounded
        ghostty.frame = NSRect(x: 164, y: top - 360, width: 140, height: 28)
        content.addSubview(ghostty)

        let reset = NSButton(title: "Reset", target: self, action: #selector(resetTheme))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 310, y: top - 360, width: 90, height: 28)
        content.addSubview(reset)

        // MARK: Done
        let doneButton = NSButton(title: "Done", target: self, action: #selector(closeAction))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.frame = NSRect(x: 360, y: 16, width: 80, height: 28)
        content.addSubview(doneButton)

        window.contentView = content
        window.delegate = self

        refreshStatus()
        refreshTheme()
        refreshShortcut()
    }

    private static func separator(y: CGFloat) -> NSBox {
        let box = NSBox(frame: NSRect(x: 20, y: y, width: 420, height: 1))
        box.boxType = .separator
        return box
    }

    private static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    // MARK: - Aliases

    private func parseAliases() -> [String] {
        textField.stringValue
            .split(whereSeparator: { ",\n\t ".contains($0) })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func refreshStatus() {
        let installed = AliasInstaller.isInstalled()
        let aliases = AliasInstaller.currentAliases()
        if installed {
            statusLabel.stringValue = "Currently installed: \(aliases.joined(separator: ", "))"
        } else {
            statusLabel.stringValue = "Not yet installed in /usr/local/bin."
        }
    }

    @objc private func installAction() {
        let aliases = parseAliases()
        guard !aliases.isEmpty else { return }
        let previous = AliasInstaller.currentAliases()
        for old in previous where !aliases.contains(old) {
            _ = AliasInstaller.uninstallAlias(old)
        }
        if AliasInstaller.installAliases(aliases) {
            AliasInstaller.saveAliases(aliases)
        }
        refreshStatus()
    }

    // MARK: - Theme

    private func refreshTheme() {
        themeLabel.stringValue = "Current: " + (ThemeManager.shared.current?.name ?? "Default")
    }

    @objc private func importITerm() {
        guard let url = openPanel(message: "Choose an iTerm2 .itermcolors file",
                                  directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) else { return }
        if let theme = TerminalTheme.parseITerm(url) {
            ThemeManager.shared.setTheme(theme)
            refreshTheme()
        } else {
            showError("That doesn't look like a valid .itermcolors file.")
        }
    }

    @objc private func importGhostty() {
        let candidates = [
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
            NSHomeDirectory() + "/.config/ghostty/themes",
            NSHomeDirectory() + "/.config/ghostty",
        ]
        let dir = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }).map { URL(fileURLWithPath: $0) }
        guard let url = openPanel(message: "Choose a Ghostty theme file", directory: dir) else { return }
        if let theme = TerminalTheme.parseGhostty(url) {
            ThemeManager.shared.setTheme(theme)
            refreshTheme()
        } else {
            showError("That doesn't look like a Ghostty theme (needs palette/background/foreground).")
        }
    }

    @objc private func resetTheme() {
        ThemeManager.shared.setTheme(nil)
        refreshTheme()
    }

    private func openPanel(message: String, directory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = true
        if let directory { panel.directoryURL = directory }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Import failed"
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Shortcut

    private func refreshShortcut() {
        shortcutButton.title = HotKeyConfig.load().display
    }

    @objc private func recordShortcut() {
        guard recordMonitor == nil else { return }
        shortcutButton.title = "Press keys…"
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape cancels
                self.endRecording()
                return nil
            }
            guard let config = HotKeyConfig.from(event: event) else {
                NSSound.beep() // needs a control/option/command modifier
                return nil
            }
            config.save()
            NotificationCenter.default.post(name: .miniHotKeyChanged, object: nil)
            self.endRecording()
            return nil
        }
    }

    private func endRecording() {
        if let monitor = recordMonitor {
            NSEvent.removeMonitor(monitor)
            recordMonitor = nil
        }
        refreshShortcut()
    }

    @objc private func closeAction() {
        window.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            endRecording()
            SettingsWindow.shared = nil
        }
    }
}
