import Foundation

/// A previously launched command, deduplicated by (argv, cwd) and ranked by recency.
struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let argv: [String]
    let cwd: String
    var lastRun: Date
    var runCount: Int

    var command: String { argv.joined(separator: " ") }

    var displayCwd: String {
        let url = URL(fileURLWithPath: cwd)
        return url.lastPathComponent.isEmpty ? cwd : url.lastPathComponent
    }
}

/// Persistent, most-recent-first log of every command launched through Mini.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL
    private let maxEntries = 100

    init() {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mini", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("history.json")
        load()
    }

    /// Records a launch: bumps an existing (argv, cwd) entry to the top, or inserts a new one.
    func record(argv: [String], cwd: String) {
        guard !argv.isEmpty else { return }
        if let idx = entries.firstIndex(where: { $0.argv == argv && $0.cwd == cwd }) {
            var entry = entries.remove(at: idx)
            entry.lastRun = Date()
            entry.runCount += 1
            entries.insert(entry, at: 0)
        } else {
            entries.insert(HistoryEntry(id: UUID(), argv: argv, cwd: cwd, lastRun: Date(), runCount: 1), at: 0)
        }
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
