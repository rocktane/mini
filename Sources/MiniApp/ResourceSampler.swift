import Foundation

/// Periodically samples CPU% and resident memory for each running job's process tree.
/// Active only while the panel is visible, to avoid spawning `ps` when nothing is shown.
@MainActor
final class ResourceSampler {
    private weak var store: JobStore?
    private var timer: Timer?

    /// Called on the main actor after each sample updates the jobs.
    var onUpdate: (() -> Void)?

    init(store: JobStore) {
        self.store = store
    }

    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            sampleNow()
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleNow() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func sampleNow() {
        guard let store, store.jobs.contains(where: { $0.status == .running }) else { return }
        DispatchQueue.global(qos: .utility).async {
            let snapshot = ResourceSampler.psSnapshot()
            let children = ResourceSampler.childrenMap(snapshot)
            DispatchQueue.main.async { [weak self] in
                guard let self, let store = self.store else { return }
                for job in store.jobs where job.status == .running {
                    let pid = job.terminalView.process.shellPid
                    guard pid > 0 else { continue }
                    let (cpu, rss) = ResourceSampler.sumSubtree(root: pid, snapshot: snapshot, children: children)
                    job.cpuPercent = cpu
                    job.memBytes = rss
                }
                self.onUpdate?()
            }
        }
    }

    private struct ProcInfo {
        let ppid: Int32
        let cpu: Double
        let rss: UInt64
    }

    /// Runs `ps` once and returns pid -> (ppid, %cpu, rss-bytes).
    private nonisolated static func psSnapshot() -> [Int32: ProcInfo] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,%cpu=,rss="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }

        var map: [Int32: ProcInfo] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let cpu = Double(parts[2]),
                  let rssKB = UInt64(parts[3]) else { continue }
            map[pid] = ProcInfo(ppid: ppid, cpu: cpu, rss: rssKB * 1024)
        }
        return map
    }

    private nonisolated static func childrenMap(_ snapshot: [Int32: ProcInfo]) -> [Int32: [Int32]] {
        var map: [Int32: [Int32]] = [:]
        for (pid, info) in snapshot {
            map[info.ppid, default: []].append(pid)
        }
        return map
    }

    /// Sums CPU and memory across the process subtree rooted at `root`.
    private nonisolated static func sumSubtree(root: Int32, snapshot: [Int32: ProcInfo], children: [Int32: [Int32]]) -> (Double, UInt64) {
        var cpu = 0.0
        var rss: UInt64 = 0
        var stack = [root]
        var visited = Set<Int32>()
        while let pid = stack.popLast() {
            guard visited.insert(pid).inserted else { continue }
            if let info = snapshot[pid] {
                cpu += info.cpu
                rss += info.rss
            }
            if let kids = children[pid] { stack.append(contentsOf: kids) }
        }
        return (cpu, rss)
    }
}
