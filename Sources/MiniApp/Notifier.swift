import AppKit
import UserNotifications

@MainActor
final class Notifier {
    static let shared = Notifier()

    private var authorized = false

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.authorized = granted
            }
        }
    }

    func notify(job: Job, signal: OutputSignal, text: String) {
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(signal.emoji) \(signal.label) · \(job.displayCwd)"
        content.subtitle = job.displayCommand
        content.body = truncate(text, to: 180)
        content.sound = signal == .error ? .defaultCritical : .default
        content.userInfo = ["jobId": job.id.uuidString]

        let request = UNNotificationRequest(
            identifier: "mini.\(job.id.uuidString).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func truncate(_ s: String, to max: Int) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max - 1)) + "…"
    }
}
