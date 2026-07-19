import Foundation
import PetCore

@MainActor
final class ClaudeUsageDriver: ObservableObject {
    @Published private(set) var usage: ClaudeUsage?

    private let client: ClaudeUsageClient
    private let interval: TimeInterval
    private var timer: Timer?
    private var inFlight = false

    init(client: ClaudeUsageClient = ClaudeUsageClient(), interval: TimeInterval = 300) {
        self.client = client
        self.interval = interval
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
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

    private func fetch() {
        guard !inFlight else { return }
        inFlight = true
        Task { [client] in
            let result = await client.fetch()
            await MainActor.run {
                self.inFlight = false
                if let result { self.usage = result }
            }
        }
    }
}
