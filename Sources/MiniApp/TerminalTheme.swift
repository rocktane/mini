import AppKit
import Foundation
import SwiftTerm

/// An 8-bit-per-channel color, persisted in the theme file.
struct RGB: Codable, Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// SwiftTerm uses 16-bit channels; scale 8-bit up by 257 (0xFF -> 0xFFFF).
    var swiftTermColor: SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }

    init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }

    /// Parses "#rrggbb" or "rrggbb".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        r = UInt8((value >> 16) & 0xFF)
        g = UInt8((value >> 8) & 0xFF)
        b = UInt8(value & 0xFF)
    }

    /// Parses iTerm2 plist components (0...1 doubles).
    init?(components d: [String: Any]) {
        guard let rc = d["Red Component"] as? Double,
              let gc = d["Green Component"] as? Double,
              let bc = d["Blue Component"] as? Double else { return nil }
        r = UInt8((max(0, min(1, rc)) * 255).rounded())
        g = UInt8((max(0, min(1, gc)) * 255).rounded())
        b = UInt8((max(0, min(1, bc)) * 255).rounded())
    }
}

/// A terminal color scheme: 16 ANSI colors plus background/foreground/cursor/selection.
struct TerminalTheme: Codable, Equatable {
    var name: String
    var ansi: [RGB] // exactly 16
    var background: RGB
    var foreground: RGB
    var cursor: RGB?
    var selection: RGB?

    // MARK: Parsers

    /// Parses an iTerm2 `.itermcolors` plist.
    static func parseITerm(_ url: URL) -> TerminalTheme? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else { return nil }

        func color(_ key: String) -> RGB? {
            (dict[key] as? [String: Any]).flatMap(RGB.init(components:))
        }

        var ansi: [RGB] = []
        for i in 0..<16 {
            guard let c = color("Ansi \(i) Color") else { return nil }
            ansi.append(c)
        }
        guard let bg = color("Background Color"), let fg = color("Foreground Color") else { return nil }
        return TerminalTheme(name: url.deletingPathExtension().lastPathComponent,
                             ansi: ansi, background: bg, foreground: fg,
                             cursor: color("Cursor Color"), selection: color("Selection Color"))
    }

    /// Parses a Ghostty theme/config file (`palette = N=#hex`, `background = #hex`, …).
    static func parseGhostty(_ url: URL) -> TerminalTheme? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var ansi = [RGB?](repeating: nil, count: 16)
        var bg: RGB?, fg: RGB?, cursor: RGB?, selection: RGB?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "palette":
                guard let inner = value.firstIndex(of: "=") else { continue }
                let idx = Int(value[..<inner].trimmingCharacters(in: .whitespaces))
                let hex = String(value[value.index(after: inner)...]).trimmingCharacters(in: .whitespaces)
                if let idx, idx >= 0, idx < 16, let c = RGB(hex: hex) { ansi[idx] = c }
            case "background": bg = RGB(hex: value)
            case "foreground": fg = RGB(hex: value)
            case "cursor-color": cursor = RGB(hex: value)
            case "selection-background": selection = RGB(hex: value)
            default: break
            }
        }

        let resolved = ansi.compactMap { $0 }
        guard resolved.count == 16, let bg, let fg else { return nil }
        return TerminalTheme(name: url.deletingPathExtension().lastPathComponent,
                             ansi: resolved, background: bg, foreground: fg,
                             cursor: cursor, selection: selection)
    }
}

/// Holds the active terminal theme, persists it, and applies it to terminal views.
@MainActor
final class ThemeManager {
    static let shared = ThemeManager()

    private(set) var current: TerminalTheme?
    private let fileURL: URL

    /// Called after the theme changes so open terminals can be re-skinned.
    var onChange: (() -> Void)?

    init() {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mini", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("theme.json")
        if let data = try? Data(contentsOf: fileURL),
           let theme = try? JSONDecoder().decode(TerminalTheme.self, from: data) {
            current = theme
        }
    }

    func setTheme(_ theme: TerminalTheme?) {
        current = theme
        if let theme, let data = try? JSONEncoder().encode(theme) {
            try? data.write(to: fileURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: fileURL)
        }
        onChange?()
    }

    /// Skins a terminal view with the active theme. No-op when no custom theme is set.
    func apply(to view: LocalProcessTerminalView) {
        guard let theme = current else { return }
        view.installColors(theme.ansi.map { $0.swiftTermColor })
        view.nativeBackgroundColor = theme.background.nsColor
        view.nativeForegroundColor = theme.foreground.nsColor
        if let cursor = theme.cursor { view.caretColor = cursor.nsColor }
        if let selection = theme.selection { view.selectedTextBackgroundColor = selection.nsColor }
    }
}
