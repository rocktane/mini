import AppKit
import Foundation
import SwiftTerm

enum OutputSignal {
    case error
    case warning
    case input

    var emoji: String {
        switch self {
        case .error: return "❌"
        case .warning: return "⚠️"
        case .input: return "❓"
        }
    }

    var label: String {
        switch self {
        case .error: return "Error"
        case .warning: return "Warning"
        case .input: return "Input needed"
        }
    }
}

/// Periodically samples newly-produced terminal lines for each running job,
/// classifies them, and hands interesting ones to the notifier.
@MainActor
final class OutputMonitor {
    private weak var store: JobStore?
    private var timer: Timer?
    /// Snapshot of the previous tick's visible rows per job.
    private var lastSnapshot: [UUID: [String]] = [:]

    init(store: JobStore) {
        self.store = store
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let store = store else { return }
        for job in store.jobs where job.status == .running {
            scan(job: job)
        }
    }

    private func scan(job: Job) {
        let terminal = job.terminalView.getTerminal()
        let rowCount = terminal.rows
        var current: [String] = []
        current.reserveCapacity(rowCount)
        for r in 0..<rowCount {
            let text = terminal.getLine(row: r)?.translateToString(trimRight: true) ?? ""
            current.append(text)
        }

        let previous = lastSnapshot[job.id]
        lastSnapshot[job.id] = current

        // Baseline pass: don't notify on lines that were already on screen when we started.
        guard let previous = previous else { return }

        for (i, line) in current.enumerated() {
            if i < previous.count && previous[i] == line { continue }
            if line.isEmpty { continue }
            if let signal = classify(line) {
                let hash = line.hashValue
                if hash != job.lastNotifiedLineHash {
                    job.lastNotifiedLineHash = hash
                    job.unseenSignalCount += 1
                    Notifier.shared.notify(job: job, signal: signal, text: line)
                    return
                }
            }
        }
    }

    /// Returns the detected signal category for a line, or nil if nothing interesting.
    func classify(_ raw: String) -> OutputSignal? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.count >= 3 else { return nil }
        let lower = line.lowercased()

        // Interactive prompts: these generally end the line without a newline, but by the
        // time we scan it the line is in the buffer. Check common shapes.
        let inputPatterns = [
            "(y/n)", "(y/n)?", "[y/n]", "(yes/no)", "[yes/no]",
            "password:", "passphrase", "passphrase:",
            "continue?", "overwrite?", "proceed?",
            "are you sure", "press any key",
            "waiting for", "paste the code",
        ]
        for p in inputPatterns where lower.contains(p) { return .input }
        if lower.hasSuffix("? ") || lower.hasSuffix(" ?") { return .input }

        // Error markers. Stay conservative — avoid triggering on things like "error handling".
        let errorPatterns = [
            "error:", "error ", " error", "failed:", "failure:",
            "fatal:", "panic:", "traceback (most recent", "uncaught",
            "✖", "✗", "❌",
        ]
        for p in errorPatterns where lower.contains(p) { return .error }

        // Warnings.
        let warnPatterns = ["warning:", "warn:", "deprecated:", "⚠"]
        for p in warnPatterns where lower.contains(p) { return .warning }

        return nil
    }
}
