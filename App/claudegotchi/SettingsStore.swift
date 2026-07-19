import Foundation
import ServiceManagement
import PetCore

/// Single source of truth for the P0 agent-manager preferences. Persists to
/// UserDefaults, publishes for live SwiftUI binding, and hands PetCore a plain
/// `SessionFilter`. `onChange` lets the (non-SwiftUI) island controller re-apply
/// immediately without a restart.
@MainActor
final class SettingsStore: ObservableObject {
    static let hoverDelayDefault = 0.25
    static let dwellRange = 3...10

    var onChange: (() -> Void)?

    @Published var hoverDelay: Double { didSet { persist(hoverDelay, .hoverDelay); notify() } }
    @Published var autoCollapseOnLeave: Bool { didSet { persist(autoCollapseOnLeave, .autoCollapse); notify() } }
    @Published var autoHideWhenNoSessions: Bool { didSet { persist(autoHideWhenNoSessions, .autoHide); notify() } }
    @Published var completionRevealEnabled: Bool { didSet { persist(completionRevealEnabled, .completionReveal); notify() } }
    @Published var completionDwellSeconds: Int { didSet { persist(completionDwellSeconds, .completionDwell); notify() } }
    @Published var focusSuppressionEnabled: Bool { didSet { persist(focusSuppressionEnabled, .focusSuppression); notify() } }

    @Published var presetEnabled: [String: Bool] { didSet { persistJSON(presetEnabled, .presetEnabled); notify() } }
    @Published var userDirectoryPatterns: [String] { didSet { persistJSON(userDirectoryPatterns, .userDirs); notify() } }
    @Published var userPromptPrefixPatterns: [String] { didSet { persistJSON(userPromptPrefixPatterns, .userPrompts); notify() } }

    @Published private(set) var launchAtLogin: Bool

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hoverDelay = Self.readDouble(defaults, .hoverDelay, Self.hoverDelayDefault, clamp: 0.1...1.0)
        autoCollapseOnLeave = Self.readBool(defaults, .autoCollapse, true)
        autoHideWhenNoSessions = Self.readBool(defaults, .autoHide, false)
        completionRevealEnabled = Self.readBool(defaults, .completionReveal, true)
        completionDwellSeconds = Self.readInt(defaults, .completionDwell, 5, clamp: Self.dwellRange)
        focusSuppressionEnabled = Self.readBool(defaults, .focusSuppression, true)
        presetEnabled = Self.readJSON(defaults, .presetEnabled) ?? [:]
        userDirectoryPatterns = Self.readJSON(defaults, .userDirs) ?? []
        userPromptPrefixPatterns = Self.readJSON(defaults, .userPrompts) ?? []
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: derived

    var sessionFilter: SessionFilter {
        var dirs: [String] = []
        var prompts: [String] = []
        for p in SessionFilterPresets.all where isPresetEnabled(p.id) {
            switch p.kind {
            case .directory: dirs.append(p.pattern)
            case .promptPrefix: prompts.append(p.pattern)
            }
        }
        return SessionFilter(
            directoryPatterns: dirs + userDirectoryPatterns,
            promptPrefixPatterns: prompts + userPromptPrefixPatterns)
    }

    func isPresetEnabled(_ id: String) -> Bool { presetEnabled[id] ?? true }

    func setPreset(_ id: String, _ enabled: Bool) {
        var next = presetEnabled
        next[id] = enabled
        presetEnabled = next
    }

    func addUserPattern(_ raw: String, kind: SessionFilterPreset.Kind) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch kind {
        case .directory:
            guard !userDirectoryPatterns.contains(trimmed) else { return }
            userDirectoryPatterns.append(trimmed)
        case .promptPrefix:
            guard !userPromptPrefixPatterns.contains(trimmed) else { return }
            userPromptPrefixPatterns.append(trimmed)
        }
    }

    func removeUserPattern(_ pattern: String, kind: SessionFilterPreset.Kind) {
        switch kind {
        case .directory: userDirectoryPatterns.removeAll { $0 == pattern }
        case .promptPrefix: userPromptPrefixPatterns.removeAll { $0 == pattern }
        }
    }

    // MARK: launch at login

    func refreshLaunchAtLogin() { launchAtLogin = SMAppService.mainApp.status == .enabled }

    @discardableResult
    func setLaunchAtLogin(_ value: Bool) -> Bool {
        do {
            if value { try SMAppService.mainApp.register() }
            else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("claudegotchi: launch-at-login toggle failed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        return launchAtLogin
    }

    // MARK: persistence

    private enum Key: String {
        case hoverDelay = "claudegotchi.settings.hoverDelay"
        case autoCollapse = "claudegotchi.settings.autoCollapse"
        case autoHide = "claudegotchi.settings.autoHide"
        case completionReveal = "claudegotchi.settings.completionReveal"
        case completionDwell = "claudegotchi.settings.completionDwell"
        case focusSuppression = "claudegotchi.settings.focusSuppression"
        case presetEnabled = "claudegotchi.settings.presetEnabled"
        case userDirs = "claudegotchi.settings.userDirectoryPatterns"
        case userPrompts = "claudegotchi.settings.userPromptPrefixPatterns"
    }

    private func notify() { onChange?() }
    private func persist(_ v: Double, _ k: Key) { defaults.set(v, forKey: k.rawValue) }
    private func persist(_ v: Bool, _ k: Key) { defaults.set(v, forKey: k.rawValue) }
    private func persist(_ v: Int, _ k: Key) { defaults.set(v, forKey: k.rawValue) }
    private func persistJSON<T: Encodable>(_ v: T, _ k: Key) {
        if let data = try? JSONEncoder().encode(v) { defaults.set(data, forKey: k.rawValue) }
    }

    private static func readBool(_ d: UserDefaults, _ k: Key, _ fallback: Bool) -> Bool {
        d.object(forKey: k.rawValue) == nil ? fallback : d.bool(forKey: k.rawValue)
    }
    private static func readInt(_ d: UserDefaults, _ k: Key, _ fallback: Int, clamp: ClosedRange<Int>) -> Int {
        let v = d.object(forKey: k.rawValue) == nil ? fallback : d.integer(forKey: k.rawValue)
        return min(clamp.upperBound, max(clamp.lowerBound, v))
    }
    private static func readDouble(_ d: UserDefaults, _ k: Key, _ fallback: Double, clamp: ClosedRange<Double>) -> Double {
        let v = d.object(forKey: k.rawValue) == nil ? fallback : d.double(forKey: k.rawValue)
        return min(clamp.upperBound, max(clamp.lowerBound, v))
    }
    private static func readJSON<T: Decodable>(_ d: UserDefaults, _ k: Key) -> T? {
        guard let data = d.data(forKey: k.rawValue) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
