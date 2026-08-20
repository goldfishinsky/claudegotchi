import XCTest
@testable import PetCore

final class BehaviorActionsTests: XCTestCase {
    private let stages = ["baby", "child", "adult"]

    private func base(_ def: PixelSpeciesDef, _ stage: String) -> PixelFrame {
        def.frames["\(stage)/idle"]![0]
    }

    private func lit(_ frame: PixelFrame, row: Int, col: Int) -> Bool {
        guard row >= 0, row < frame.count, col >= 0, col < frame[row].count else { return false }
        return frame[row][col] != 0
    }

    /// A 16-space anchor cell plus a one-cell halo, in 32-grid pixels.
    private func litNear(_ frame: PixelFrame, _ p: GridPoint) -> Bool {
        let u = frame.count / 16
        for r in (p.row * u - u)...(p.row * u + 2 * u - 1) {
            for c in (p.col * u - u)...(p.col * u + 2 * u - 1) where lit(frame, row: r, col: c) {
                return true
            }
        }
        return false
    }

    // MARK: anchor table

    func testEveryStageOfEverySpeciesDeclaresAnchors() {
        for def in PixelSpeciesCatalog.all {
            XCTAssertEqual(Set(def.anchors.keys), Set(stages), "\(def.id) anchor stages")
            for stage in stages {
                let a = def.anchors[stage]!
                for (name, p) in [("mouth", a.mouth), ("pawL", a.pawL), ("pawR", a.pawR),
                                  ("cheekL", a.cheekL), ("cheekR", a.cheekR)] {
                    XCTAssertTrue((0...15).contains(p.row), "\(def.id)/\(stage) \(name) row")
                    XCTAssertTrue((0...15).contains(p.col), "\(def.id)/\(stage) \(name) col")
                }
                XCTAssertTrue((0...15).contains(a.feetRow), "\(def.id)/\(stage) feetRow")
                XCTAssertLessThan(a.cheekL.col, a.cheekR.col, "\(def.id)/\(stage) cheeks ordered")
                XCTAssertLessThan(a.pawL.col, a.pawR.col, "\(def.id)/\(stage) paws ordered")
            }
        }
    }

    func testEveryAnchorSitsOnDrawnPixels() {
        for def in PixelSpeciesCatalog.all {
            for stage in stages {
                let a = def.anchors[stage]!, frame = base(def, stage)
                for (name, p) in [("mouth", a.mouth), ("pawL", a.pawL), ("pawR", a.pawR),
                                  ("cheekL", a.cheekL), ("cheekR", a.cheekR)] {
                    XCTAssertTrue(litNear(frame, p), "\(def.id)/\(stage) \(name) floats off the body")
                }
            }
        }
    }

    func testFeetRowBandHasGroundedPixelsOnBothSides() {
        for def in PixelSpeciesCatalog.all {
            for stage in stages {
                let a = def.anchors[stage]!, frame = base(def, stage)
                let u = frame.count / 16, n = frame.count
                let band = (a.feetRow * u - u)...(a.feetRow * u + u - 1)
                var left = false, right = false
                for r in band {
                    for c in 0..<(n / 2) where lit(frame, row: r, col: c) { left = true }
                    for c in (n / 2)..<n where lit(frame, row: r, col: c) { right = true }
                }
                XCTAssertTrue(left && right, "\(def.id)/\(stage) feetRow \(a.feetRow) has no footing")
            }
        }
    }

    /// An aura — the goldfish's bubble — hangs below the body without standing on
    /// anything, so the walk cycle measures the body's own bottom row.
    func testFeetRowIsTheBottomOfTheBody() {
        for def in PixelSpeciesCatalog.all {
            for stage in stages {
                let a = def.anchors[stage]!, frame = base(def, stage)
                let bottom = frame.lastIndex { row in
                    row.contains { $0 != 0 && $0 != PixelSpeciesCatalog.slotAccent }
                }!
                XCTAssertEqual(a.feetRow, bottom / 2, "\(def.id)/\(stage) feetRow vs silhouette")
            }
        }
    }

    // MARK: generators

    private var probe: [String] {
        var g = Array(repeating: String(repeating: ".", count: 32), count: 32)
        for r in 8..<28 {
            g[r] = String(repeating: ".", count: 6) + String(repeating: "O", count: 20)
                + String(repeating: ".", count: 6)
        }
        g[10] = String(g[10].enumerated().map { $0.offset == 10 || $0.offset == 20 ? "w" : $0.element })
        g[11] = String(g[11].enumerated().map { $0.offset == 10 || $0.offset == 20 ? "x" : $0.element })
        return g
    }

    private let anchors = SpriteAnchors(
        mouth: GridPoint(7, 8), pawL: GridPoint(12, 4), pawR: GridPoint(12, 11),
        feetRow: 13, cheekL: GridPoint(6, 4), cheekR: GridPoint(6, 11))

    private func rectangular(_ g: [String], _ label: String) {
        XCTAssertEqual(g.count, 32, "\(label) row count")
        for row in g { XCTAssertEqual(row.count, 32, "\(label) col count") }
    }

    func testGeneratorsAreDeterministic() {
        XCTAssertEqual(BehaviorActions.eat(probe, anchors), BehaviorActions.eat(probe, anchors))
        XCTAssertEqual(BehaviorActions.work(probe, anchors), BehaviorActions.work(probe, anchors))
        XCTAssertEqual(BehaviorActions.walk(probe, anchors), BehaviorActions.walk(probe, anchors))
        XCTAssertEqual(BehaviorActions.cheer(probe, anchors), BehaviorActions.cheer(probe, anchors))
        XCTAssertEqual(BehaviorActions.wave(probe, anchors), BehaviorActions.wave(probe, anchors))
        XCTAssertEqual(BehaviorActions.petting(probe, anchors), BehaviorActions.petting(probe, anchors))
        XCTAssertEqual(BehaviorActions.nap(probe), BehaviorActions.nap(probe))
    }

    func testPatchesClampToTheGridFromAnyAnchor() {
        for p in [GridPoint(0, 0), GridPoint(15, 15), GridPoint(0, 15), GridPoint(15, 0)] {
            let a = SpriteAnchors(mouth: p, pawL: p, pawR: p, feetRow: p.row, cheekL: p, cheekR: p)
            for (i, g) in BehaviorActions.eat(probe, a).enumerated() { rectangular(g, "eat \(i)") }
            for (i, g) in BehaviorActions.work(probe, a).enumerated() { rectangular(g, "work \(i)") }
            for (i, g) in BehaviorActions.walk(probe, a).enumerated() { rectangular(g, "walk \(i)") }
            for (i, g) in BehaviorActions.cheer(probe, a).enumerated() { rectangular(g, "cheer \(i)") }
            for (i, g) in BehaviorActions.wave(probe, a).enumerated() { rectangular(g, "wave \(i)") }
        }
    }

    func testMouthOpensDownwardAndStaysOnTheBody() {
        let frames = BehaviorActions.eat(probe, anchors)
        XCTAssertEqual(frames.count, BehaviorRhythm.chew.count)
        XCTAssertEqual(frames[0], probe, "shut mouth is the untouched base")
        func dark(_ g: [String]) -> Int { g.reduce(0) { $0 + $1.filter { $0 == "#" }.count } }
        XCTAssertGreaterThan(dark(frames[1]), 0, "ajar cuts an opening")
        XCTAssertGreaterThan(dark(frames[2]), dark(frames[1]), "wide is wider than ajar")
        XCTAssertTrue(frames[2].contains { $0.contains("*") }, "wide shows a tongue")
        for g in frames {
            for (r, row) in g.enumerated() {
                for (c, ch) in row.enumerated() where ch != "." {
                    XCTAssertNotEqual(Array(probe[r])[c], ".", "mouth patch spilled off the body at \(r),\(c)")
                }
            }
        }
    }

    func testTypingDipsPawTipsBehindTheLidCorners() {
        let frames = BehaviorActions.work(probe, anchors)
        XCTAssertEqual(frames.count, BehaviorRhythm.typing.count)
        func pawRows(_ g: [String], leftHalf: Bool) -> [Int] {
            g.indices.filter { r in
                Array(g[r]).enumerated().contains {
                    $0.element == "+" && (leftHalf ? $0.offset < 16 : $0.offset >= 16)
                }
            }
        }
        let l0 = pawRows(frames[0], leftHalf: true), r0 = pawRows(frames[0], leftHalf: false)
        let l2 = pawRows(frames[2], leftHalf: true), r2 = pawRows(frames[2], leftHalf: false)
        XCTAssertFalse(l0.isEmpty)
        XCTAssertGreaterThan(l0.max()!, r0.max()!, "frame 0 strikes with the left paw")
        XCTAssertGreaterThan(r2.max()!, l2.max()!, "frame 2 strikes with the right paw")
        XCTAssertEqual(pawRows(frames[1], leftHalf: true), l2, "lifted tips rest at one height")
        XCTAssertEqual(l0.max()! - l2.max()!, 2, "a strike travels one authored pixel")
        XCTAssertEqual(BehaviorActions.deskRow(probe), 23, "laptop lid line on the 32-grid")
        XCTAssertEqual(BehaviorActions.lidSpan(probe), 10...21, "lid top edge columns")
    }

    func testWorkDropsTheGazeWhereTheEyeAllowsIt() {
        var dropped = 0
        for def in PixelSpeciesCatalog.all {
            for stage in stages {
                func pupilBottom(_ f: PixelFrame) -> Int? { f.lastIndex { $0.contains(3) } }
                guard let a = pupilBottom(base(def, stage)),
                      let b = pupilBottom(def.frames["\(stage)/work"]![0]) else { continue }
                XCTAssertGreaterThanOrEqual(b, a, "\(def.id)/\(stage) gaze rose instead of dropping")
                XCTAssertLessThanOrEqual(b - a, 1, "\(def.id)/\(stage) gaze dropped past a pixel")
                if b > a { dropped += 1 }
            }
        }
        XCTAssertGreaterThan(dropped, 20, "the focused stare should reach most of the catalogue")
    }

    func testScreenSpillStaysOnTheBodyWithinTheLidsReach() {
        let span = BehaviorActions.lidSpan(probe), line = BehaviorActions.deskRow(probe)
        for def in PixelSpeciesCatalog.all {
            for stage in stages {
                let idle = base(def, stage)
                for f in def.frames["\(stage)/work"]! {
                    for (r, row) in f.enumerated() {
                        for (c, px) in row.enumerated() where px == 21 || px == 39 {
                            XCTAssertLessThan(r, line, "\(def.id)/\(stage) spill under the lid")
                            XCTAssertTrue(span.contains(c), "\(def.id)/\(stage) spill past the screen")
                            XCTAssertNotEqual(idle[r][c], 0, "\(def.id)/\(stage) spill off the body")
                        }
                    }
                }
            }
        }
    }

    func testScreenSpillPulsesWithTheStrikeAndTouchesNoOtherPose() {
        func count(_ f: PixelFrame, _ idx: UInt8) -> Int {
            f.reduce(0) { $0 + $1.filter { $0 == idx }.count }
        }
        for def in PixelSpeciesCatalog.all {
            for stage in stages {
                let frames = def.frames["\(stage)/work"]!
                for (i, f) in frames.enumerated() where i % 2 == 0 {
                    XCTAssertGreaterThan(count(f, 21), 0, "\(def.id)/\(stage) strike \(i) unlit")
                    XCTAssertGreaterThan(count(f, 39), 0, "\(def.id)/\(stage) strike \(i) has no falloff")
                }
                for (i, f) in frames.enumerated() where i % 2 == 1 {
                    XCTAssertEqual(count(f, 21), 0, "\(def.id)/\(stage) off-beat \(i) still burns hot")
                    XCTAssertGreaterThan(count(f, 39), 0, "\(def.id)/\(stage) off-beat \(i) went black")
                }
            }
            for (key, frames) in def.frames where !key.hasSuffix("work") {
                for f in frames {
                    XCTAssertEqual(count(f, 21) + count(f, 39), 0, "\(def.id)/\(key) leaks screen spill")
                }
            }
        }
    }

    func testWalkLiftsOneFootAtATime() {
        let frames = BehaviorActions.walk(probe, anchors)
        XCTAssertEqual(frames.count, BehaviorRhythm.step.count)
        func bottomLit(_ g: [String], leftHalf: Bool) -> Int {
            g.lastIndex { row in
                Array(row).enumerated().contains {
                    $0.element != "." && (leftHalf ? $0.offset < 16 : $0.offset >= 16)
                }
            } ?? 0
        }
        XCTAssertLessThan(bottomLit(frames[0], leftHalf: true), bottomLit(frames[0], leftHalf: false))
        XCTAssertGreaterThan(bottomLit(frames[1], leftHalf: true), bottomLit(frames[1], leftHalf: false))
        XCTAssertNotEqual(frames[0], frames[1])
    }

    func testRaisedPawsBreakTheSilhouette() {
        let cheer = BehaviorActions.cheer(probe, anchors)
        func width(_ g: [String], row: Int) -> Int { g[row].filter { $0 != "." }.count }
        let raised = cheer[0]
        let widened = (0..<32).contains { width(raised, row: $0) > width(probe, row: $0) }
        XCTAssertTrue(widened, "arms reach past the body outline")
        XCTAssertEqual(cheer.count, BehaviorRhythm.cheer.count)
    }

    func testWaveMovesOnlyTheRightPaw() {
        let frames = BehaviorActions.wave(probe, anchors)
        XCTAssertEqual(frames.count, BehaviorRhythm.wave.count)
        for g in frames {
            for r in 0..<32 {
                let leftAdded = Array(g[r]).prefix(16).enumerated().contains {
                    $0.element != "." && Array(probe[r])[$0.offset] == "."
                }
                XCTAssertFalse(leftAdded, "wave touched the left side at row \(r)")
            }
        }
        XCTAssertNotEqual(frames[0], frames[2], "the paw travels across the wave")
    }

    func testPettingHalfLidsTheEyesAndKeepsBlush() {
        let happy = PixelSpeciesCatalog.def("cat")!.frames["adult/happy"]![1]
        let petting = PixelSpeciesCatalog.def("cat")!.frames["adult/petting"]![0]
        func count(_ f: PixelFrame, _ idx: UInt8) -> Int { f.reduce(0) { $0 + $1.filter { $0 == idx }.count } }
        XCTAssertLessThan(count(petting, 3), count(happy, 3), "lids cover part of each pupil")
        XCTAssertGreaterThan(count(petting, 3), 0, "eyes stay half open, not shut")
        XCTAssertEqual(count(petting, 4), count(happy, 4), "blush carries over")
    }

    // MARK: rhythm

    func testRhythmTableValues() {
        XCTAssertEqual(BehaviorRhythm.chew.frameMs, 180)
        XCTAssertEqual(BehaviorRhythm.typing.frameMs, 120)
        XCTAssertEqual(BehaviorRhythm.step.frameMs, 140)
        XCTAssertEqual(BehaviorRhythm.breath.frameMs, 450)
        XCTAssertEqual(BehaviorRhythm.cheer.frameMs, 160)
        XCTAssertEqual(BehaviorRhythm.wave.frameMs, 150)
        XCTAssertEqual(BehaviorRhythm.nuzzle.frameMs, 220)
        XCTAssertEqual(Set(BehaviorRhythm.all.map(\.key)).count, BehaviorRhythm.all.count)
    }

    func testEveryActionKeyIsDrawnForEveryStageAndSpecies() {
        for def in PixelSpeciesCatalog.all {
            for cadence in BehaviorRhythm.all {
                for stage in stages {
                    let frames = def.frames["\(stage)/\(cadence.key)"]
                    XCTAssertEqual(frames?.count, cadence.count,
                                   "\(def.id)/\(stage)/\(cadence.key) frame count")
                }
                XCTAssertEqual(def.frames[cadence.key]?.count, cadence.count,
                               "\(def.id) top-level \(cadence.key)")
            }
        }
    }

    func testActionFrameIndexIsLoopPeriodic() {
        for cadence in BehaviorRhythm.all {
            XCTAssertEqual(BehaviorRhythm.frame(cadence, loopPos: 0), 0)
            XCTAssertEqual(BehaviorRhythm.frame(cadence, loopPos: cadence.cycleMs), 0)
            XCTAssertEqual(BehaviorRhythm.frame(cadence, loopPos: cadence.frameMs - 1), 0)
            XCTAssertEqual(BehaviorRhythm.frame(cadence, loopPos: cadence.frameMs), 1 % cadence.count)
        }
    }

    func testBehaviourLoopsHoldWholeActionCycles() {
        let byBehavior: [TheaterBehavior: BehaviorRhythm.Cadence] = [
            .eat: BehaviorRhythm.chew, .work: BehaviorRhythm.typing,
            .stroll: BehaviorRhythm.step, .beg: BehaviorRhythm.step,
            .nap: BehaviorRhythm.breath, .celebrate: BehaviorRhythm.cheer,
            .greet: BehaviorRhythm.wave, .petting: BehaviorRhythm.nuzzle,
        ]
        for (kind, cadence) in byBehavior {
            let loop = PetTheater.loopMs(kind, signals: signalsFor(kind))
            XCTAssertEqual(loop % cadence.cycleMs, 0,
                           "\(kind) loop \(loop) is not a whole number of \(cadence.key) cycles")
        }
    }

    // MARK: scene wiring

    func testActionKeysOnlyReplaceFramesWhereDeclared() {
        XCTAssertEqual(PetTheater.scene(signals: TheaterSignals(), timeMs: 0).frameKey, "idle")
        XCTAssertEqual(PetTheater.scene(signals: TheaterSignals(sick: true), timeMs: 0).frameKey, "sick")
        XCTAssertEqual(PetTheater.scene(signals: signalsFor(.work), timeMs: 0).frameKey, "work")
        XCTAssertEqual(PetTheater.scene(signals: signalsFor(.eat), timeMs: 0).frameKey, "eat")
        XCTAssertEqual(PetTheater.scene(signals: signalsFor(.nap), timeMs: 0).frameKey, "nap")
    }

    func testChewCyclesThroughEveryMouthStateEachLoop() {
        let sig = signalsFor(.eat)
        var seen = Set<Int>()
        for t in stride(from: Int64(0), to: PetTheater.loopMs(.eat, signals: sig), by: 60) {
            let scene = PetTheater.scene(signals: sig, timeMs: t)
            if scene.frameKey == "eat" { seen.insert(scene.frame) }
        }
        XCTAssertEqual(seen, Set(0..<BehaviorRhythm.chew.count))
    }

    func testFoodTierDropsOnTheBeatTheJawShuts() {
        let sig = signalsFor(.eat)
        let loop = PetTheater.loopMs(.eat, signals: sig)
        var previous = PetTheater.scene(signals: sig, timeMs: 0).props.map(\.sprite)
        var drops = 0
        for t in stride(from: Int64(1), to: loop, by: 1) {
            let scene = PetTheater.scene(signals: sig, timeMs: t)
            let now = scene.props.map(\.sprite)
            if now != previous {
                drops += 1
                XCTAssertEqual(scene.frame, 0, "food changed at \(t)ms with an open mouth")
                XCTAssertEqual(BehaviorActions.chewDip(loopPos: t), 0.5, accuracy: 0.02,
                               "the head is at the bottom of its bob when the food drops")
            }
            previous = now
        }
        XCTAssertEqual(drops, 3, "bento → onigiri → small → gone")
    }

    func testChewDipRidesEveryChewAndRestsMidCycle() {
        XCTAssertEqual(BehaviorActions.chewDip(loopPos: 0), 0.5, accuracy: 0.001)
        XCTAssertEqual(BehaviorActions.chewDip(loopPos: BehaviorRhythm.chew.cycleMs / 2), 0,
                       accuracy: 0.001)
        XCTAssertEqual(BehaviorActions.chewDip(loopPos: BehaviorRhythm.chew.cycleMs), 0.5,
                       accuracy: 0.001)
        for t in stride(from: Int64(0), to: Int64(4320), by: 7) {
            let d = BehaviorActions.chewDip(loopPos: t)
            XCTAssertGreaterThanOrEqual(d, 0)
            XCTAssertLessThanOrEqual(d, 0.5)
        }
    }

    func testLidTopEdgeFlaresOnEveryKeystrokeAndGoesDarkBetween() {
        let sig = signalsFor(.work)
        var lit = 0, dark = 0
        for t in stride(from: Int64(0), to: PetTheater.loopMs(.work, signals: sig), by: 20) {
            let scene = PetTheater.scene(signals: sig, timeMs: t)
            let sprites = scene.props.map(\.sprite)
            if sprites.contains(.laptopLit) {
                lit += 1
                XCTAssertEqual(scene.frame % 2, 0, "lid flared off a strike frame")
            } else {
                dark += 1
                XCTAssertTrue(sprites.contains(.laptop))
            }
        }
        XCTAssertGreaterThan(lit, 0)
        XCTAssertGreaterThan(dark, 0)
        let plain = PixelProps.matrix(.laptop), flared = PixelProps.matrix(.laptopLit)
        XCTAssertEqual(PixelProps.size(.laptopLit).width, PixelProps.size(.laptop).width)
        XCTAssertEqual(PixelProps.size(.laptopLit).height, PixelProps.size(.laptop).height)
        XCTAssertEqual(Array(plain.dropFirst()), Array(flared.dropFirst()),
                       "only the top edge answers a keystroke")
        XCTAssertTrue(flared[0].allSatisfy { $0 == 0 || $0 == 21 }, "the flare is screen light")
        XCTAssertFalse(plain[0].contains(21), "the dark lid keeps its top edge unlit")
    }

    func testSparksFireOnTheSameFramesAsTheStrike() {
        let sig = signalsFor(.work)
        for t in stride(from: Int64(0), to: PetTheater.loopMs(.work, signals: sig), by: 10) {
            let scene = PetTheater.scene(signals: sig, timeMs: t)
            let fresh = scene.emissions.filter { $0.kind == .keystrokeSparks && $0.ageMs < 10 }
            if !fresh.isEmpty {
                XCTAssertEqual(scene.frame % 2, 0, "spark at \(t)ms missed the strike frame")
            }
        }
    }

    func testWalkPlaysOnlyWhileTheStrollIsMoving() {
        let sig = signalsFor(.stroll)
        let loop = PetTheater.loopMs(.stroll, signals: sig)
        var walking = 0, standing = 0
        for t in stride(from: Int64(0), to: loop - 40, by: 40) {
            let a = PetTheater.scene(signals: sig, timeMs: t)
            let b = PetTheater.scene(signals: sig, timeMs: t + 40)
            if a.frameKey == "walk" { walking += 1 } else {
                standing += 1
                XCTAssertEqual(a.petOffsetX, b.petOffsetX, accuracy: 0.001,
                               "still frame at \(t)ms is drifting")
            }
        }
        XCTAssertGreaterThan(walking, 0)
        XCTAssertGreaterThan(standing, 0)
    }

    func testNapBreathesOnTheSlowClock() {
        let sig = signalsFor(.nap)
        XCTAssertEqual(PetTheater.scene(signals: sig, timeMs: 0).frame, 0)
        XCTAssertEqual(PetTheater.scene(signals: sig, timeMs: 449).frame, 0)
        XCTAssertEqual(PetTheater.scene(signals: sig, timeMs: 450).frame, 1)
        for t in stride(from: Int64(0), to: PetTheater.loopMs(.nap, signals: sig), by: 50) {
            let scene = PetTheater.scene(signals: sig, timeMs: t)
            XCTAssertGreaterThan(scene.squash, 0.98, "breathing replaced the body squash")
            XCTAssertLessThanOrEqual(scene.squash, 1.0)
        }
    }

    func testPersonalitySpeedScalesTheActionClock() {
        let sig = signalsFor(.work)
        let fast = TheaterPersonality(motionSpeed: 2)
        XCTAssertEqual(PetTheater.scene(signals: sig, timeMs: 60, personality: fast).frame,
                       PetTheater.scene(signals: sig, timeMs: 120).frame)
        XCTAssertEqual(PetTheater.scene(signals: sig, timeMs: 120, personality: .neutral).frame,
                       PetTheater.scene(signals: sig, timeMs: 120).frame)
    }

    private func signalsFor(_ k: TheaterBehavior) -> TheaterSignals {
        switch k {
        case .eat: return TheaterSignals(recentTokenDrop: TokenDrop(tokens: 9000, ageMs: 100))
        case .work: return TheaterSignals(workingAgentCount: 1)
        case .stroll: return TheaterSignals(idleSeconds: 40)
        case .beg: return TheaterSignals(hungrySinceSeconds: 200)
        case .nap: return TheaterSignals(hibernating: true)
        case .celebrate: return TheaterSignals(prCelebration: true)
        case .greet: return TheaterSignals(recentClickAgeMs: 200)
        case .petting: return TheaterSignals(pettingActive: true)
        default: return TheaterSignals()
        }
    }
}
