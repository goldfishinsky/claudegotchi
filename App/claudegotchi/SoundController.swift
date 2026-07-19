import Foundation
import PetCore

/// Gates and fires the pet's chiptune motifs. Real events pass through `fire`,
/// which honours the master toggle, the per-event toggle, and quiet scenes;
/// completion / permission callers additionally only reach here when the island
/// reveal itself was not suppressed. Previews bypass the gates so the settings ▶
/// always demonstrates a sound.
@MainActor
final class SoundController {
    private let synth = ChiptuneSynth()
    private let settings: SettingsStore

    private var knownSessions: Set<String>?
    private var lastLevel: Int?
    private var lastPermissionSession: String?

    init(settings: SettingsStore) { self.settings = settings }

    @discardableResult
    func preview(_ event: ChiptuneEvent) -> Bool {
        synth.play(ChiptuneLibrary.motif(for: event), volume: max(0.15, settings.soundVolume))
    }

    private func fire(_ event: ChiptuneEvent) {
        guard settings.soundEnabled, settings.isSoundEnabled(for: event) else { return }
        guard !QuietSceneInspector.isActive(settings: settings) else { return }
        synth.play(ChiptuneLibrary.motif(for: event), volume: settings.soundVolume)
    }

    func taskComplete() { fire(.taskComplete) }

    /// Newly-appeared filtered sessions chirp once. The first observation primes a
    /// baseline so sessions already running at launch stay silent.
    func observeSessions(_ ids: [String]) {
        let current = Set(ids)
        defer { knownSessions = current }
        guard let known = knownSessions else { return }
        if !current.subtracting(known).isEmpty { fire(.sessionStart) }
    }

    /// Fires the fanfare when the pet's level increases; primes on first read.
    func observeLevel(_ level: Int) {
        defer { lastLevel = level }
        guard let last = lastLevel else { return }
        if level > last { fire(.levelUp) }
    }

    /// Called by the island only when an unsuppressed permission strip appears;
    /// dedupes so one request sounds once. Cleared when nothing is pending.
    func permissionAppeared(sessionId: String) {
        guard sessionId != lastPermissionSession else { return }
        lastPermissionSession = sessionId
        fire(.permission)
    }

    func permissionCleared() { lastPermissionSession = nil }
}
