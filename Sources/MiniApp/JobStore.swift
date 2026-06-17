import AppKit
import Combine
import Foundation
import SwiftTerm

@MainActor
final class JobStore: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published private(set) var jobs: [Job] = []

    /// Spawns a new job, returns its id immediately.
    func spawn(argv: [String], cwd: String, env: [String: String], cols: Int, rows: Int) -> UUID {
        let job = Job(id: UUID(), argv: argv, cwd: cwd, env: env, cols: cols, rows: rows)
        job.terminalView.processDelegate = self

        // Run inside the user's login+interactive shell so aliases, nvm, pyenv, oh-my-zsh, etc.
        // are available. We pass cwd + argv as positional parameters to avoid shell-escaping.
        let userShell = env["SHELL"] ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (userShell as NSString).lastPathComponent
        let useLoginInteractive = ["zsh", "bash", "fish"].contains(shellName)
        let script = #"cd "$1" || exit 127; shift; exec "$@""#
        var shellArgs: [String] = []
        if useLoginInteractive { shellArgs += ["-l", "-i"] }
        shellArgs += ["-c", script, "_", cwd] + argv
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        jobs.append(job)
        // Defer to ensure the view has measured cols/rows from its frame.
        DispatchQueue.main.async {
            job.terminalView.startProcess(
                executable: userShell,
                args: shellArgs,
                environment: envPairs,
                execName: nil
            )
        }
        return job.id
    }

    func job(for view: LocalProcessTerminalView) -> Job? {
        jobs.first { $0.terminalView === view }
    }

    func job(id: UUID) -> Job? {
        jobs.first { $0.id == id }
    }

    func remove(id: UUID) {
        if let job = job(id: id) {
            terminate(job)
            job.window?.close()
        }
        jobs.removeAll { $0.id == id }
        objectWillChange.send()
    }

    func restart(id: UUID) {
        guard let old = job(id: id) else { return }
        let cols = max(80, Int(old.terminalView.frame.width) / 8)
        let rows = max(24, Int(old.terminalView.frame.height) / 16)
        remove(id: id)
        _ = spawn(argv: old.argv, cwd: old.cwd, env: old.env, cols: cols, rows: rows)
    }

    func terminateAll() {
        for job in jobs where job.status == .running {
            terminate(job)
        }
    }

    private func terminate(_ job: Job) {
        let pid = job.terminalView.process.shellPid
        if pid > 0 {
            kill(pid, SIGTERM)
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            guard let view = source as? LocalProcessTerminalView,
                  let job = job(for: view) else { return }
            job.status = .stopped(exitCode: exitCode ?? -1)
            job.stoppedAt = Date()
            objectWillChange.send()
        }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated {
            if let job = job(for: source) {
                job.window?.title = title.isEmpty ? job.displayCommand : title
            }
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
