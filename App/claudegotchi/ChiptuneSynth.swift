import AVFoundation
import PetCore

/// Runtime chiptune renderer: turns a pure `ChiptuneMotif` into PCM via square /
/// triangle oscillators and plays it through a lazily-started AVAudioEngine. No
/// bundled audio assets. Short click-free envelopes keep the blips clean.
@MainActor
final class ChiptuneSynth {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private let format: AVAudioFormat

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    @discardableResult
    func play(_ motif: ChiptuneMotif, volume: Double) -> Bool {
        guard let buffer = render(motif), ensureRunning() else { return false }
        engine.mainMixerNode.outputVolume = Float(max(0, min(1, volume)))
        player.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
        if !player.isPlaying { player.play() }
        return true
    }

    private func ensureRunning() -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            NSLog("claudegotchi: audio engine start failed: \(error.localizedDescription)")
            return false
        }
    }

    private func render(_ motif: ChiptuneMotif) -> AVAudioPCMBuffer? {
        let counts = motif.notes.map { samples(forMs: $0.durationMs) }
        let total = counts.reduce(0, +)
        guard total > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(total)

        let amp: Float = 0.22
        var idx = 0
        for (note, n) in zip(motif.notes, counts) where n > 0 {
            let ramp = max(1, min(n / 8, Int(0.006 * sampleRate)))
            for i in 0..<n {
                var s: Float = 0
                if !note.isRest {
                    let phase = Double(i) / sampleRate * note.frequency
                    s = Float(wave(note.waveform, phase)) * amp
                    if i < ramp { s *= Float(i) / Float(ramp) }
                    else if i >= n - ramp { s *= Float(n - i) / Float(ramp) }
                }
                channel[idx] = s
                idx += 1
            }
        }
        return buffer
    }

    private func samples(forMs ms: Int) -> Int { Int(Double(ms) / 1000.0 * sampleRate) }

    private func wave(_ w: ChiptuneWaveform, _ phase: Double) -> Double {
        let frac = phase - floor(phase)
        switch w {
        case .square: return frac < 0.5 ? 1.0 : -1.0
        case .triangle: return 4.0 * abs(frac - 0.5) - 1.0
        }
    }
}
