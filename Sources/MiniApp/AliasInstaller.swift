import AppKit
import Foundation

@MainActor
enum AliasInstaller {
    static let configDir: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Mini"
    }()

    static var configPath: String { "\(configDir)/config.json" }

    /// Path to the bundled `mini-cli` binary inside the .app.
    static var bundledCLIPath: String? {
        Bundle.main.url(forResource: "mini-cli", withExtension: nil)?.path
    }

    /// Reads the configured alias names. Defaults to `["mini"]`.
    static func currentAliases() -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let aliases = dict["aliases"] as? [String] else {
            return ["mini"]
        }
        let valid = aliases.filter(isValidAlias)
        return valid.isEmpty ? ["mini"] : valid
    }

    static func saveAliases(_ aliases: [String]) {
        try? FileManager.default.createDirectory(
            atPath: configDir, withIntermediateDirectories: true
        )
        let dict = ["aliases": aliases]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    /// Returns true if any alias resolves to a symlink pointing at the current bundled CLI.
    static func isInstalled() -> Bool {
        guard let bundled = bundledCLIPath else { return false }
        for alias in currentAliases() {
            let target = "/usr/local/bin/\(alias)"
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: target),
               dest == bundled {
                return true
            }
        }
        return false
    }

    /// Installs all configured aliases as symlinks in /usr/local/bin pointing to the bundled CLI.
    /// Uses AppleScript with admin privileges so a non-root user can write to /usr/local/bin.
    @discardableResult
    static func installAliases(_ aliases: [String]) -> Bool {
        guard let bundled = bundledCLIPath else {
            showError("Bundled mini-cli binary not found in app bundle.")
            return false
        }

        // Build a script: ensure /usr/local/bin exists, then ln -sfn for each alias.
        // Both the alias name and target stay shell-quoted; aliases are also
        // validated so a crafted name can never break out of the admin shell.
        let safeTarget = shellQuote(bundled)
        var lines = ["mkdir -p /usr/local/bin"]
        for alias in aliases where isValidAlias(alias) {
            lines.append("ln -sfn \(safeTarget) /usr/local/bin/\(shellQuote(alias))")
        }
        let script = lines.joined(separator: "; ")

        let osascriptArg = "do shell script \"\(script.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", osascriptArg]
        let errPipe = Pipe()
        task.standardError = errPipe
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                return true
            } else {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                showError("Failed to install: \(err)")
                return false
            }
        } catch {
            showError("Failed to run installer: \(error.localizedDescription)")
            return false
        }
    }

    /// Removes a single alias symlink. Returns true on success.
    @discardableResult
    static func uninstallAlias(_ alias: String) -> Bool {
        guard isValidAlias(alias) else { return false }
        let script = "rm -f /usr/local/bin/\(shellQuote(alias))"
        let osascriptArg = "do shell script \"\(script)\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", osascriptArg]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func promptInstallIfNeeded() {
        guard !isInstalled() else { return }
        let alert = NSAlert()
        alert.messageText = "Install the mini command?"
        alert.informativeText = "Mini will create /usr/local/bin/mini so you can run `mini <command>` from any terminal. You will be asked for your admin password."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not now")
        if alert.runModal() == .alertFirstButtonReturn {
            installAliases(currentAliases())
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Mini"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Alias names become both a filename in /usr/local/bin and a token in an
    /// admin-privileged `do shell script`. Restrict them to safe identifiers so
    /// a crafted config.json or text field cannot inject shell commands.
    private static func isValidAlias(_ alias: String) -> Bool {
        guard (1...32).contains(alias.count) else { return false }
        return alias.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
