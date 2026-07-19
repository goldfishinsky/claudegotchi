import Foundation
import UserNotifications
import PetCore

enum ThermalReading {
    static func tier(_ state: ProcessInfo.ThermalState) -> ThermalTier {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}

/// Always-on thermal watch (independent of the dropdown's sampler): feeds the
/// pet's sweat overlay and fires the one-shot "机器过热" notification when the
/// machine first crosses into serious/critical.
@MainActor
final class ThermalMonitor: ObservableObject {
    @Published private(set) var tier: ThermalTier

    private var gate = ThermalNotificationGate()
    private var observer: NSObjectProtocol?
    private let notify: (String, String, String) -> Void

    init(notify: @escaping (String, String, String) -> Void = UserNotifier.deliver) {
        self.notify = notify
        tier = ThermalReading.tier(ProcessInfo.processInfo.thermalState)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        UserNotifier.requestAuthorization()
        evaluate()
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func evaluate() {
        let current = ThermalReading.tier(ProcessInfo.processInfo.thermalState)
        tier = current
        if gate.shouldNotify(current) {
            notify("thermal-elevated", "机器过热降频中", "考虑歇歇 agent")
        }
    }
}

enum UserNotifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func deliver(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
