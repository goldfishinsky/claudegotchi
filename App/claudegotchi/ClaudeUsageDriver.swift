import Foundation
import SwiftUI
import PetCore

@MainActor
final class ClaudeUsageDriver: ObservableObject {
    @Published private(set) var usage: ClaudeUsage?

    private let client: ClaudeUsageClient
    private let interval: TimeInterval
    private var timer: Timer?
    private var inFlight = false

    /// Gates every keychain-touching path. Default `false` means a fresh launch
    /// reads nothing until the user opts into 「显示订阅用量」.
    var isEnabled: () -> Bool = { false }

    init(client: ClaudeUsageClient = ClaudeUsageClient(), interval: TimeInterval = 300) {
        self.client = client
        self.interval = interval
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard isEnabled(), timer == nil else { return }
        fetch()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetch() }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Turned off in settings: stop polling and drop any last reading so the strip
    /// disappears immediately.
    func stopAndClear() {
        stop()
        if usage != nil { withAnimation(.snappy(duration: 0.25)) { usage = nil } }
    }

    private func fetch() {
        guard isEnabled(), !inFlight else { return }
        inFlight = true
        Task { [client] in
            let result = await client.fetch()
            await MainActor.run {
                self.inFlight = false
                if let result { withAnimation(.snappy(duration: 0.25)) { self.usage = result } }
            }
        }
    }
}
