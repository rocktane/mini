import AppKit
import SwiftTerm

@MainActor
final class JobPreviewWindow {
    static let shared = JobPreviewWindow()

    private let size = NSSize(width: 720, height: 440)
    private var panel: NSPanel?
    private var host: NSView?
    private var imageView: NSImageView?
    private weak var currentJob: Job?

    private init() {}

    func show(job: Job, anchor: NSPoint) {
        if panel == nil { build() }
        guard let panel = panel, let host = host, let imageView = imageView else { return }

        // Anchor is the top-right corner where the preview should butt up against.
        let origin = NSPoint(x: anchor.x - size.width - 8, y: anchor.y - size.height)
        panel.setFrame(NSRect(origin: clampedOrigin(origin), size: size), display: false)

        // If we're swapping jobs, detach the previous job's terminal view.
        if currentJob !== job, let prev = currentJob, prev.window == nil {
            prev.terminalView.removeFromSuperview()
        }
        currentJob = job

        if job.window == nil {
            // Live embed: re-parent the terminal view into the preview host.
            imageView.image = nil
            imageView.isHidden = true
            job.terminalView.removeFromSuperview()
            job.terminalView.frame = host.bounds
            job.terminalView.autoresizingMask = [.width, .height]
            host.addSubview(job.terminalView)
        } else {
            // Window is open elsewhere — show a static snapshot of the live view.
            imageView.isHidden = false
            imageView.image = snapshot(of: job.terminalView)
        }

        panel.orderFrontRegardless()
    }

    func hide() {
        // Leave the live terminal view parented to the preview host even when hidden;
        // it has no visible parent now but will be reattached on the next show()
        // or when the user opens a real window.
        panel?.orderOut(nil)
    }

    private func build() {
        let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.level = .popUpMenu
        p.hasShadow = true
        // Transparent panel so the rounded host view defines the visible shape.
        p.isOpaque = false
        p.backgroundColor = .clear

        let h = NSView(frame: NSRect(origin: .zero, size: size))
        h.wantsLayer = true
        h.layer?.backgroundColor = NSColor.black.cgColor
        h.layer?.cornerRadius = 10
        h.layer?.masksToBounds = true
        h.layer?.borderWidth = 0.5
        h.layer?.borderColor = NSColor.separatorColor.cgColor

        let img = NSImageView(frame: h.bounds)
        img.autoresizingMask = [.width, .height]
        img.imageScaling = .scaleProportionallyUpOrDown
        img.imageAlignment = .alignTopLeft
        img.isHidden = true
        h.addSubview(img)

        p.contentView = h
        panel = p
        host = h
        imageView = img
    }

    private func snapshot(of view: NSView) -> NSImage? {
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func clampedOrigin(_ origin: NSPoint) -> NSPoint {
        guard let screen = NSScreen.main else { return origin }
        var p = origin
        let f = screen.visibleFrame
        if p.x < f.minX + 8 { p.x = f.minX + 8 }
        if p.y < f.minY + 8 { p.y = f.minY + 8 }
        if p.x + size.width > f.maxX - 8 { p.x = f.maxX - size.width - 8 }
        if p.y + size.height > f.maxY - 8 { p.y = f.maxY - size.height - 8 }
        return p
    }
}
