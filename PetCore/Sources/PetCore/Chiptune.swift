import Foundation

/// Pure, synthesizer-agnostic description of the pet's chiptune motifs. The App's
/// `ChiptuneSynth` renders these note sequences into PCM at runtime — no bundled
/// audio. Frequencies are equal-tempered; `frequency == 0` is a rest.
public enum ChiptuneWaveform: String, Equatable {
    case square
    case triangle
}

public struct ChiptuneNote: Equatable {
    public let frequency: Double
    public let durationMs: Int
    public let waveform: ChiptuneWaveform

    public init(frequency: Double, durationMs: Int, waveform: ChiptuneWaveform) {
        self.frequency = frequency
        self.durationMs = durationMs
        self.waveform = waveform
    }

    public var isRest: Bool { frequency <= 0 }
}

public struct ChiptuneMotif: Equatable {
    public let notes: [ChiptuneNote]
    public init(_ notes: [ChiptuneNote]) { self.notes = notes }
    public var totalDurationMs: Int { notes.reduce(0) { $0 + $1.durationMs } }
}

public enum ChiptuneEvent: String, CaseIterable, Equatable {
    case sessionStart
    case taskComplete
    case permission
    case levelUp
    case petChirp
    case petCrunch
    case petSparkle
    case petTick
}

public enum ChiptuneLibrary {
    // Equal-tempered pitches used by the motifs.
    enum Pitch {
        static let c5 = 523.25, e5 = 659.25, g5 = 783.99, a5 = 880.0, b5 = 987.77
        static let c6 = 1046.50, e6 = 1318.51, g6 = 1567.98
    }

    public static func motif(for event: ChiptuneEvent) -> ChiptuneMotif {
        switch event {
        case .sessionStart:
            // Rising two-note blip.
            return ChiptuneMotif([
                note(Pitch.c5, 55, .square),
                note(Pitch.g5, 75, .square),
            ])
        case .taskComplete:
            // Cheerful ascending C-major arpeggio.
            return ChiptuneMotif([
                note(Pitch.c5, 70, .triangle),
                note(Pitch.e5, 70, .triangle),
                note(Pitch.g5, 110, .triangle),
            ])
        case .permission:
            // Attention two-tone (descending doorbell), gapped for a knock feel.
            return ChiptuneMotif([
                note(Pitch.e6, 95, .square),
                rest(35),
                note(Pitch.b5, 130, .square),
            ])
        case .levelUp:
            // Longer fanfare: ascending arpeggio settling on the octave.
            return ChiptuneMotif([
                note(Pitch.c5, 70, .square),
                note(Pitch.e5, 70, .square),
                note(Pitch.g5, 70, .square),
                note(Pitch.c6, 95, .triangle),
                note(Pitch.g5, 65, .square),
                note(Pitch.c6, 180, .triangle),
            ])
        case .petChirp:
            // Soft affectionate two-note rise for a heart spawn.
            return ChiptuneMotif([
                note(Pitch.g5, 70, .triangle),
                note(Pitch.c6, 60, .triangle),
            ])
        case .petCrunch:
            // Low descending bite for a crumb burst.
            return ChiptuneMotif([
                note(196.00, 45, .square),
                note(146.83, 55, .square),
            ])
        case .petSparkle:
            // Bright quick shimmer for falling confetti.
            return ChiptuneMotif([
                note(Pitch.e6, 55, .triangle),
                note(Pitch.g6, 60, .triangle),
            ])
        case .petTick:
            // Tiny keystroke tick.
            return ChiptuneMotif([
                note(Pitch.b5, 30, .square),
            ])
        }
    }

    static func note(_ freq: Double, _ ms: Int, _ wave: ChiptuneWaveform) -> ChiptuneNote {
        ChiptuneNote(frequency: freq, durationMs: ms, waveform: wave)
    }
    static func rest(_ ms: Int) -> ChiptuneNote {
        ChiptuneNote(frequency: 0, durationMs: ms, waveform: .square)
    }
}

/// Pure per-key rate limiter: `shouldFire` passes at most once per `minGapMs` per
/// key, recording the accepted time; the caller injects the clock so it's testable.
public struct CooldownGate<Key: Hashable> {
    private var lastFireMs: [Key: Int64] = [:]

    public init() {}

    public mutating func shouldFire(_ key: Key, nowMs: Int64, minGapMs: Int64) -> Bool {
        if let last = lastFireMs[key], nowMs - last < minGapMs { return false }
        lastFireMs[key] = nowMs
        return true
    }
}
