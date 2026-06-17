import AppKit
import SwiftTerm

@MainActor
enum TerminalWindow {
    static func show(job: Job) {
        if let existing = job.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = job.displayCommand
        window.isReleasedWhenClosed = false
        window.center()

        let host = NSView(frame: window.contentLayoutRect)
        host.autoresizingMask = [.width, .height]

        // Pull the terminal view out of any prior superview and re-parent it.
        job.terminalView.removeFromSuperview()
        job.terminalView.frame = host.bounds
        job.terminalView.autoresizingMask = [.width, .height]
        host.addSubview(job.terminalView)

        window.contentView = host
        job.window = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            // Detach the terminal view so it survives window release; the job stays alive.
            MainActor.assumeIsolated {
                job.terminalView.removeFromSuperview()
                job.window = nil
            }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
