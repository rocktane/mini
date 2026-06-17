import AppKit
import Foundation
import SwiftTerm

enum JobStatus: Equatable {
    case running
    case stopped(exitCode: Int32)
}

@MainActor
final class Job {
    let id: UUID
    let argv: [String]
    let cwd: String
    let env: [String: String]
    let startedAt: Date
    var status: JobStatus = .running
    var stoppedAt: Date?

    /// Live terminal view that owns the PTY and rendered scrollback.
    /// Created once at spawn, kept alive even when not the selected job.
    let terminalView: LocalProcessTerminalView

    /// Latest OS-reported terminal title (from the running program), if any.
    var terminalTitle: String?

    /// A local server address detected in the job's output (e.g. "http://localhost:3000"),
    /// surfaced as an "open in browser" affordance. Set once, on first detection.
    var detectedURL: String?
    /// Human-facing form of `detectedURL` for the row pill (e.g. "localhost:3000").
    var detectedHostPort: String?

    /// Next scroll-invariant row to scan for monitor signals (errors, prompts).
    var nextScanRow: Int = 0
    /// Hash of the last line that produced a notification; used to dedupe.
    var lastNotifiedLineHash: Int = 0
    /// Number of unseen signals (errors/prompts) since the window was last opened.
    var unseenSignalCount: Int = 0

    init(id: UUID, argv: [String], cwd: String, env: [String: String], cols: Int, rows: Int) {
        self.id = id
        self.argv = argv
        self.cwd = cwd
        self.env = env
        self.startedAt = Date()

        // Initial frame sized for the requested cols/rows; SwiftTerm will reflow on resize.
        let frame = NSRect(x: 0, y: 0, width: max(cols, 80) * 8, height: max(rows, 24) * 16)
        self.terminalView = LocalProcessTerminalView(frame: frame)
        Self.hideScrollers(in: self.terminalView)
    }

    /// SwiftTerm adds a private `NSScroller` subview; hide it so the preview and window render flush.
    private static func hideScrollers(in view: NSView) {
        for subview in view.subviews where subview is NSScroller {
            subview.isHidden = true
        }
    }

    var displayCommand: String {
        argv.joined(separator: " ")
    }

    var displayCwd: String {
        let url = URL(fileURLWithPath: cwd)
        return url.lastPathComponent.isEmpty ? cwd : url.lastPathComponent
    }

    var ageDescription: String {
        let endpoint = stoppedAt ?? Date()
        let seconds = Int(endpoint.timeIntervalSince(startedAt))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
    }
}
