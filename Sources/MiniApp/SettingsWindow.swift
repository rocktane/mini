import AppKit

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private static var shared: SettingsWindow?

    private let window: NSWindow
    private let textField: NSTextField
    private let statusLabel: NSTextField

    static func show() {
        if let s = shared {
            s.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        shared = SettingsWindow()
        shared?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mini — Settings"
        window.center()
        window.isReleasedWhenClosed = false

        textField = NSTextField(frame: NSRect(x: 20, y: 140, width: 380, height: 24))
        textField.placeholderString = "mini, bg, run"
        textField.stringValue = AliasInstaller.currentAliases().joined(separator: ", ")

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 60, width: 380, height: 40)
        statusLabel.isEditable = false
        statusLabel.drawsBackground = false
        statusLabel.isBordered = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping

        let header = NSTextField(labelWithString: "Aliases (comma-separated):")
        header.frame = NSRect(x: 20, y: 175, width: 380, height: 18)

        super.init()

        let installButton = NSButton(
            frame: NSRect(x: 20, y: 20, width: 180, height: 28)
        )
        installButton.title = "Install / Update Aliases"
        installButton.bezelStyle = .rounded
        installButton.target = self
        installButton.action = #selector(installAction)

        let closeButton = NSButton(
            frame: NSRect(x: 320, y: 20, width: 80, height: 28)
        )
        closeButton.title = "Done"
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.target = self
        closeButton.action = #selector(closeAction)

        let content = NSView(frame: window.contentLayoutRect)
        content.addSubview(header)
        content.addSubview(textField)
        content.addSubview(statusLabel)
        content.addSubview(installButton)
        content.addSubview(closeButton)
        window.contentView = content
        window.delegate = self

        refreshStatus()
    }

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
        // Remove any old aliases that are no longer wanted.
        for old in previous where !aliases.contains(old) {
            _ = AliasInstaller.uninstallAlias(old)
        }
        if AliasInstaller.installAliases(aliases) {
            AliasInstaller.saveAliases(aliases)
        }
        refreshStatus()
    }

    @objc private func closeAction() {
        window.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { SettingsWindow.shared = nil }
    }
}
