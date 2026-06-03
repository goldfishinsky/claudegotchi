# claudegotchi Pet Status & Stats UI + Hook Ingestion Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the pet real and visible — feed Claude Code usage in via hooks, hatch + decay the pet, and show its status + token usage in the menu-bar dropdown and a 680px stats window, with the existing PR view folded in as a 工作台 tab.

**Architecture:** Extend the existing `AppServices` composition root (shared `DatabaseQueue` + `EventApplier`). New PetCore pure units (time/decay tick, stats queries, hooks installer, pixel-species catalog, mood) + a v3 migration; new App drivers (`TickDriver`, menu-bar icon redraw) and SwiftUI surfaces (`PetPanelView`, `StatsWindow` tabs). All times are unix **milliseconds**; all I/O behind protocols or injected paths/clocks so PetCore stays `swift test`-able.

**Tech Stack:** Swift 5.9, AppKit + SwiftUI (`Canvas`), GRDB 6, Yams, XCTest, xcodegen. No new deps. Pixel art generated in code.

**Spec:** `docs/specs/2026-06-03-pet-stats-ui-design.md` (read first; this plan implements it).

---

## §0. File Structure & Locked Interfaces

Signatures are **locked** — every chunk uses them verbatim. Phase tags `[Q0]..[Q3]`.

### Create (PetCore — pure / DAO; `swift test`)
```
PetCore/Sources/PetCore/
  PetNotification.swift [Q0] Notification.Name.claudegotchiPetDidChange (in PetCore so ApplyTransaction can post it; App observes)
  LocalDay.swift        [Q0] shared local-day key + day index
  ModelUsage.swift      [Q0] record + upsert/all DAO
  PixelSpecies.swift    [Q0] PixelSpeciesCatalog + PixelFrame + palette
  PetMood.swift         [Q0] pure visual-state derivation
  TickCheckpoint.swift  [Q0] pure decay/hibernation checkpoint (ms)
  StatsQueries.swift    [Q0] dashboard DAO (now+tz injected)
  HooksInstaller.swift  [Q0] settings.json mutation (path+now injected)
  HatchService.swift    [Q0] hatch-if-none logic
  PetClick.swift        [Q0] pure cooldown predicate
PetCore/Tests/PetCoreTests/   [Q0] one test file per unit above + amended Event/ApplyTransaction/Database/EventApplier tests
```
### Modify (PetCore + Hook)
```
Pet.swift            [Q0] add lastEventAt (column last_event_at)
Event.swift          [Q0] add EventType.petClick
EventApplier.swift   [Q0] petClick arm; sessionStart wake re-anchors lastTickAt = event.ts
ApplyTransaction.swift[Q0] use LocalDay.key; update last_event_at + model_usage (after dedup short-circuit); add process(event:) already exists — reuse; post petDidChange AFTER write
Database.swift       [Q0] register v3_pet_stats migration (after v2)
SpeciesRoulette.swift[Q0] add pure overload pick(fromIds:using:)
HookHelper/ClaudegotchiHook.swift [Q0] read stdin payload; always exit 0; reject pet_/pr_ prefixes
```
### Create (App — SwiftUI + timers; not swift-testable)
```
App/claudegotchi/
  TickDriver.swift       [Q1] ms-clock timer → TickCheckpoint → persist + post
  PixelPetView.swift     [Q1] Canvas renderer + renderToNSImage(size:)
  PetPanelModel.swift     [Q1] ObservableObject reading shared DB
  PetPanelView.swift     [Q1] pixel pet + 4 bars + level + today + activity
  StatsWindow.swift      [Q2] NSWindow host + TabView root
  OverviewTab.swift      [Q2] 8 metric cards
  HeatmapView.swift      [Q2] contribution heatmap
  ModelsTab.swift        [Q2] per-model usage
  GrowthHistoryTab.swift [Q2] 成长史 timeline + memorial
  HooksInstallView.swift [Q3] install/uninstall button + status
```
### Modify (App + project)
```
claudegotchiApp.swift [Q1/Q2] AppServices: hatch + tick + onDeath=ensureAlive; menu-bar NSImage driver (replace 🐤); unified dropdown (pet panel + WorkPanelView capped + pinned footer); StatsWindow host (open on 打开统计, not auto); observe petDidChange
WorkPanelView.swift   [Q1] remove internal 打开工作台 button (lines ~90-94)
PRTabView.swift       [Q2] refactor body into a tab content view (eager subscribe)
App/project.yml       [Q3] add claudegotchi-hook dependency + Copy-Files into Contents/Helpers; ensure signing
```

### Locked interfaces (Swift)
```swift
// LocalDay.swift [Q0]
public enum LocalDay {
    public static func key(unixMs: Int64, timeZone: TimeZone) -> String   // "yyyy-MM-dd", en_US_POSIX
    public static func dayIndex(unixMs: Int64, timeZone: TimeZone) -> Int  // contiguous integer day number
}

// ModelUsage.swift [Q0]
public struct ModelUsage: Codable, FetchableRecord, PersistableRecord, Equatable {
    public var model: String; public var tokensIn: Int64; public var tokensOut: Int64; public var calls: Int64
}
public enum ModelUsageStore {
    public static func bump(model: String, tokensIn: Int, tokensOut: Int, in db: GRDB.Database) throws  // += counters
    public static func all(in db: DatabaseQueue) throws -> [ModelUsage]                                  // tokens desc
}

// PixelSpecies.swift [Q0] — code constants, NO YAML/registry at runtime
public typealias PixelFrame = [[UInt8]]   // grid of palette indices, 0 = transparent
public struct PixelSpeciesDef: Equatable {
    public let id: String; public let nameZh: String
    public let stages: [(id: String, minXp: Int)]
    public let frames: [String: [PixelFrame]]   // "idle"/"happy"/"sick"/"sleeping"
}
public enum PixelSpeciesCatalog {
    public static let palette: [UInt32]                    // ARGB; index 0 transparent
    public static let all: [PixelSpeciesDef]               // frog, slime, cat, dragon
    public static var ids: [String] { all.map(\.id) }
    public static func def(_ id: String) -> PixelSpeciesDef?  // nil → caller uses generic fallback
    public static func stage(id: String, xp: Int64) -> String // current stage id by minXp
}
// SpeciesRoulette.swift [Q0] add:
extension SpeciesRoulette { public static func pick<G: RandomNumberGenerator>(fromIds ids: [String], using gen: inout G) -> String }

// PetMood.swift [Q0]
public enum PetAnimation: String, Equatable { case idle, happy, sick, sleeping }
public enum PetOverlay: String, Equatable { case none, focus, sweat }
public struct PetVisual: Equatable { public let stage: String; public let animation: PetAnimation; public let overlay: PetOverlay }
public enum PetMood {   // pure; NO transient 'happy' here (App-side animation)
    public static func derive(pet: Pet, pressure: PressureTier) -> PetVisual
}

// TickCheckpoint.swift [Q0] — unix ms in/out
public enum TickEmit: String, Equatable { case hibernateStart, hibernateEnd }
public struct TickResult: Equatable { public let pet: Pet; public let emit: TickEmit? }
public enum TickCheckpoint {
    public static func run(pet: Pet, nowMs: Int64, lastEventMs: Int64, config: ConfigYAML) -> TickResult
}

// StatsQueries.swift [Q0] — now+tz injected; deterministic over seeded DB
public struct TodayTotals: Equatable { public let tokens: Int64; public let sessions: Int; public let tools: Int }
public struct GrowthEntry: Equatable { public let species: String; public let name: String?; public let bornMs: Int64; public let diedMs: Int64?; public let xp: Int64 }
public enum StatsQueries {
    public static func lifetimeTokens(_ db: DatabaseQueue) throws -> Int64
    public static func todayTotals(_ db: DatabaseQueue, nowMs: Int64, tz: TimeZone) throws -> TodayTotals
    public static func activeStreakDays(_ db: DatabaseQueue, nowMs: Int64, tz: TimeZone) throws -> Int
    public static func peakDayTokens(_ db: DatabaseQueue) throws -> Int64
    public static func heatmapSeries(_ db: DatabaseQueue, weeks: Int, nowMs: Int64, tz: TimeZone) throws -> [(day: String, tokens: Int64)]
    public static func modelUsage(_ db: DatabaseQueue) throws -> [ModelUsage]
    public static func petAgeDays(_ db: DatabaseQueue, nowMs: Int64) throws -> Int
    public static func growthHistory(_ db: DatabaseQueue, limit: Int) throws -> [GrowthEntry]
}

// HooksInstaller.swift [Q0] — injected settings path + now (for backup suffix)
public enum HookInstallStatus: String, Equatable { case notInstalled, installed, partiallyInstalled }
public enum HooksInstaller {
    public static func install(settingsPath: URL, hookBinaryPath: String, nowISO: String) throws
    public static func uninstall(settingsPath: URL) throws
    public static func status(settingsPath: URL) throws -> HookInstallStatus
    // matcher-group JSON; leaf tag "_claudegotchi": true; atomic temp+rename; backup before rename; shell-quoted command
}

// HatchService.swift [Q0]
public enum HatchService {
    @discardableResult public static func ensureAlive(_ db: DatabaseQueue, nowMs: Int64) throws -> Pet  // no-op if alive
}

// PetClick.swift [Q0]
public enum PetClick { public static func allowed(lastClickMs: Int64?, nowMs: Int64, cooldownSeconds: Int) -> Bool }

// PetNotification.swift [PetCore, Q0]
extension Notification.Name { public static let claudegotchiPetDidChange = Notification.Name("claudegotchi.petDidChange") }
// public func postPetDidChange()  — callers (ApplyTransaction, TickDriver, MidnightDriver) MUST call it AFTER db.write returns, never inside the closure
```

### Conventions (every chunk follows)
- **Times are unix ms** everywhere (`Pet.lastTickAt`/`lastEventAt`/`hibernationSince`, `event.ts`). Convert ms→s only at `Decay.apply`/`Hibernation.shouldEnter` boundaries (`/1000`).
- **Tests:** XCTest, `@testable import PetCore`; DB tests use `Database.open(at: NSTemporaryDirectory()+UUID)` and `db.write/read`. `StatsQueries`/`TickCheckpoint`/`PetClick` tests inject `nowMs` + `TimeZone(identifier:"UTC")` / fixed ms — never `Date()`. `HooksInstaller` tests use a temp settings path + fixed `nowISO`; NEVER touch real `~/.claude`.
- **Migration:** add `m.registerMigration("v3_pet_stats")` AFTER `v2_pr_watch`; never edit v1/v2.
- **petDidChange:** post ONLY after `db.write(...)` returns (GRDB queue is non-reentrant); observers hop to main, never synchronously re-query on the notification thread.
- **App views:** PetCore units get full TDD with code; App SwiftUI/timer tasks are file-level (responsibilities + acceptance + manual check) — not swift-testable. The `claude`/`gh`/hook exec + signing are verified live in Q3.
- **Commits:** one per task; NO AI attribution.

---
<!-- CHUNK-MARKER: phase chunks inserted below -->


## Chunk Q0: Backend (PetCore + HookHelper)

Implements spec §11 Q0. All units are PetCore/HookHelper (pure / DAO / hook), fully `swift test`-able. Type signatures are taken **verbatim** from plan §0 LOCKED INTERFACES; all times are unix **milliseconds** (convert ms→s only at `Decay.apply`/`Hibernation.shouldEnter` via `/1000.0`). Follow §0 conventions (XCTest, `@testable import PetCore`, DB tests open a temp `Database.open(at:)`, inject `nowMs` + `TimeZone(identifier: "UTC")`, never `Date()`; `petDidChange` posted only AFTER `db.write` returns; commits carry NO AI attribution). Run all commands from the `PetCore` package dir.

The v3 migration (`last_event_at` column + `model_usage` table) is RED-driven and owned by **exactly one** task (Task 2). Task 1 adds only the `Pet.lastEventAt` Swift field; its DB round-trip test stays RED until Task 2's migration lands, so every task starts RED → GREEN.

---

### Task 1: Pet.lastEventAt Swift field + record mapping

Files:
- modify `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/Pet.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/PetTests.swift`

- [ ] **Step 1: Write failing tests.** Append to `PetTests.swift`. `testFreshSetsLastEventAtToTs` is a pure-struct assertion (passes as soon as the field + `fresh` exist). `testLastEventAtRoundTrips` additionally depends on the v3 `last_event_at` DB column — that column is **owned by Task 2**, so this round-trip test is deliberately RED until Task 2's migration lands. Both are written now so Task 2's migration is what flips the round-trip GREEN.

```swift
func testFreshSetsLastEventAtToTs() {
    let pet = Pet.fresh(species: "frog", at: 12345)
    XCTAssertEqual(pet.lastEventAt, 12345)
}

func testLastEventAtRoundTrips() throws {
    // Requires the v3 `last_event_at` column (added by Task 2's migration).
    let dbPath = NSTemporaryDirectory() + "pet-lea-\(UUID()).sqlite"
    defer { try? FileManager.default.removeItem(atPath: dbPath) }
    let db = try Database.open(at: dbPath)
    var pet = try Pet.insert(.fresh(species: "frog", at: 1000), into: db)
    XCTAssertEqual(pet.lastEventAt, 1000)
    pet.lastEventAt = 9999
    try Pet.update(pet, in: db)
    let fetched = try Pet.fetchAlive(from: db)!
    XCTAssertEqual(fetched.lastEventAt, 9999)
}
```

- [ ] **Step 2: Run — expect FAIL (whole-target compile error).** `swift test --filter PetTests`. Because the test file and `PetCore` compile as one target, this is a **compile failure of the `PetCoreTests` target**, not a per-test runtime failure: `value of type 'Pet' has no member 'lastEventAt'` (the field is referenced before it exists). No test runs until the field is added.

- [ ] **Step 3: Minimal impl — add field + CodingKey + set in `fresh` (Swift only; NO migration here).** Edit `Pet.swift`. Do **not** touch `Database.swift` — the v3 column is Task 2's.

```swift
// Pet.swift — add after `public var deathWindowState: String`
    public var lastEventAt: Int64
```
```swift
// CodingKeys — add the snake_case mapping next to deathWindowState
        case deathWindowState = "death_window_state"
        case lastEventAt = "last_event_at"
```
```swift
// Pet.fresh — add lastEventAt (= ts) as the final initializer argument
    public static func fresh(species: String, at ts: Int64) -> Pet {
        Pet(
            id: nil, species: species, name: nil,
            birthday: ts, deathAt: nil,
            fullness: 100, stamina: 100, intimacy: 50,
            xp: 0, lastTickAt: ts, lastAppliedEventId: 0,
            hibernationSince: nil, deathWindowState: "[]",
            lastEventAt: ts
        )
    }
```

- [ ] **Step 4: Run — expect PARTIAL.** `swift test --filter PetTests`. The target now **compiles**. `testFreshSetsLastEventAtToTs` PASSES. `testLastEventAtRoundTrips` still **FAILS at runtime** with `SQLite error: no such column: last_event_at` (the column does not exist yet — Task 2 adds it). This is the expected RED state for the column; it is owned and turned GREEN by Task 2.

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/Pet.swift PetCore/Tests/PetCoreTests/PetTests.swift && git commit -m "Add Pet.lastEventAt Swift field + record mapping"`

---

### Task 2: v3_pet_stats migration (drives last_event_at column + model_usage table)

Files:
- modify `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/Database.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/DatabaseTests.swift`

- [ ] **Step 1: Write failing migration tests.** Create/append `DatabaseTests.swift`. These assert the v3 column + table exist and that the migration is idempotent. They FAIL now because the migration is not registered.

```swift
import XCTest
import GRDB
@testable import PetCore

final class DatabaseTests: XCTestCase {
    private func petColumns(_ db: DatabaseQueue) throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT name FROM pragma_table_info('pet')") }
    }

    func testV3AddsLastEventAtColumn() throws {
        let dbPath = NSTemporaryDirectory() + "dbtest-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try Database.open(at: dbPath)
        XCTAssertTrue(try petColumns(db).contains("last_event_at"))
    }

    func testV3CreatesModelUsageTable() throws {
        let dbPath = NSTemporaryDirectory() + "dbtest-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try Database.open(at: dbPath)
        let tables = try db.read { try $0.tableNames() }
        XCTAssertTrue(tables.contains("model_usage"))
    }

    func testV3MigrationIdempotentAcrossReopen() throws {
        let dbPath = NSTemporaryDirectory() + "dbtest-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        _ = try Database.open(at: dbPath)
        let db2 = try Database.open(at: dbPath)
        let tables = try db2.read { try $0.tableNames() }
        XCTAssertTrue(tables.contains("model_usage"))
        XCTAssertEqual(try petColumns(db2).filter { $0 == "last_event_at" }.count, 1)
    }
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter DatabaseTests` fails: `XCTAssertTrue failed` (column `last_event_at` absent / `model_usage` not in `tableNames()`) — the v3 migration is not registered yet.

- [ ] **Step 3: Minimal impl — register the v3 migration.** Edit `Database.swift`: insert AFTER the `m.registerMigration("v2_pr_watch")` block closes, BEFORE `return m`. SQL is verbatim from spec §B6.

```swift
        m.registerMigration("v3_pet_stats") { db in
            try db.execute(sql: "ALTER TABLE pet ADD COLUMN last_event_at INTEGER NOT NULL DEFAULT 0;")
            try db.execute(sql: """
                CREATE TABLE model_usage (
                  model TEXT PRIMARY KEY,
                  tokens_in INTEGER NOT NULL DEFAULT 0,
                  tokens_out INTEGER NOT NULL DEFAULT 0,
                  calls INTEGER NOT NULL DEFAULT 0
                );
                """)
        }
```

- [ ] **Step 4: Run — expect PASS (this task + Task 1's deferred test).** `swift test --filter DatabaseTests` passes. Then re-run `swift test --filter PetTests`: `testLastEventAtRoundTrips` now goes GREEN transitively (the column it required exists). The RED → GREEN boundary for the `last_event_at` column is owned entirely by this task.

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/Database.swift PetCore/Tests/PetCoreTests/DatabaseTests.swift && git commit -m "Add v3_pet_stats migration: last_event_at column + model_usage table"`

---

### Task 3: PetNotification (name + postPetDidChange)

Files:
- create `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/PetNotification.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/PetNotificationTests.swift`

- [ ] **Step 1: Write failing test.**

```swift
import XCTest
@testable import PetCore

final class PetNotificationTests: XCTestCase {
    func testNameIsStable() {
        XCTAssertEqual(Notification.Name.claudegotchiPetDidChange.rawValue, "claudegotchi.petDidChange")
    }

    func testPostPetDidChangeDeliversToObserver() {
        let exp = expectation(forNotification: .claudegotchiPetDidChange, object: nil, handler: nil)
        postPetDidChange()
        wait(for: [exp], timeout: 1.0)
    }
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter PetNotificationTests` fails to compile (`PetCoreTests` target): `type 'Notification.Name' has no member 'claudegotchiPetDidChange'` / `cannot find 'postPetDidChange' in scope`.

- [ ] **Step 3: Minimal impl.** Create `PetNotification.swift`.

```swift
import Foundation

extension Notification.Name {
    public static let claudegotchiPetDidChange = Notification.Name("claudegotchi.petDidChange")
}

// Callers (ApplyTransaction, TickDriver, MidnightDriver) MUST call this AFTER
// db.write(...) returns — never inside the closure (GRDB queue is non-reentrant).
public func postPetDidChange() {
    NotificationCenter.default.post(name: .claudegotchiPetDidChange, object: nil)
}
```

- [ ] **Step 4: Run — expect PASS.** `swift test --filter PetNotificationTests`.

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/PetNotification.swift PetCore/Tests/PetCoreTests/PetNotificationTests.swift && git commit -m "Add claudegotchiPetDidChange notification + postPetDidChange"`

---

### Task 4: LocalDay (key + dayIndex) + ApplyTransaction refactor

Files:
- create `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/LocalDay.swift`
- modify `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/ApplyTransaction.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/LocalDayTests.swift`

- [ ] **Step 1: Write failing test.** Covers key format, dayIndex adjacency, and the spec §8 invariant (today-key == rollup key a same-day event wrote).

```swift
import XCTest
import GRDB
@testable import PetCore

final class LocalDayTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    func testKeyFormatUTC() {
        // 2026-06-03T00:00:00Z = 1780444800000 ms
        XCTAssertEqual(LocalDay.key(unixMs: 1_780_444_800_000, timeZone: utc), "2026-06-03")
    }

    func testDayIndexIsContiguous() {
        let d0 = LocalDay.dayIndex(unixMs: 1_780_444_800_000, timeZone: utc)               // 2026-06-03
        let d1 = LocalDay.dayIndex(unixMs: 1_780_444_800_000 + 86_400_000, timeZone: utc)  // next day
        XCTAssertEqual(d1, d0 + 1)
    }

    func testTodayKeyMatchesRollupKeyForSameDayEvent() throws {
        let dbPath = NSTemporaryDirectory() + "localday-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: dbPath) }
        let db = try Database.open(at: dbPath)
        _ = try Pet.insert(.fresh(species: "frog", at: 0), into: db)
        let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
        let ts: Int64 = 1_780_490_000_000
        let line = #"{"schema_version":1,"event_id":"01H0000000000000000000000A","ts":\#(ts),"type":"session_start","session_id":"s"}"#
        try atx.process(jsonLine: line)
        let rollupKey = try db.read { try String.fetchOne($0, sql: "SELECT date FROM daily_rollup") }!
        XCTAssertEqual(rollupKey, LocalDay.key(unixMs: ts, timeZone: TimeZone.current))
    }
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter LocalDayTests` fails to compile (`PetCoreTests` target): `cannot find 'LocalDay' in scope`.

- [ ] **Step 3: Minimal impl — create LocalDay, refactor ApplyTransaction.**

```swift
// LocalDay.swift
import Foundation

public enum LocalDay {
    public static func key(unixMs: Int64, timeZone: TimeZone) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000.0)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        return f.string(from: date)
    }

    public static func dayIndex(unixMs: Int64, timeZone: TimeZone) -> Int {
        let date = Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000.0)
        let offsetMs = Int64(timeZone.secondsFromGMT(for: date)) * 1000
        return Int((unixMs + offsetMs) / 86_400_000)
    }
}
```
Edit `ApplyTransaction.swift` — replace the private `localDate(fromUnixMs:)` method body so it routes through `LocalDay.key` (same key output, single source of truth):

```swift
    private func localDate(fromUnixMs ts: Int64) -> String {
        LocalDay.key(unixMs: ts, timeZone: TimeZone.current)
    }
```

- [ ] **Step 4: Run — expect PASS (and existing rollup tests stay green).** `swift test --filter LocalDayTests`, then `swift test --filter DailyRollupTests` and `swift test --filter ApplyTransactionTests` (verify the refactor did not change keys).

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/LocalDay.swift PetCore/Sources/PetCore/ApplyTransaction.swift PetCore/Tests/PetCoreTests/LocalDayTests.swift && git commit -m "Extract LocalDay.key/dayIndex; route ApplyTransaction through it"`

---

### Task 5: ModelUsage record + store (DAO)

Files:
- create `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/ModelUsage.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/ModelUsageTests.swift`

- [ ] **Step 1: Write failing test.** Upsert/accumulate + sort-by-tokens-desc.

```swift
import XCTest
import GRDB
@testable import PetCore

final class ModelUsageTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "musage-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testBumpInsertsThenAccumulates() throws {
        try db.write { try ModelUsageStore.bump(model: "opus", tokensIn: 100, tokensOut: 50, in: $0) }
        try db.write { try ModelUsageStore.bump(model: "opus", tokensIn: 10, tokensOut: 5, in: $0) }
        let all = try ModelUsageStore.all(in: db)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0], ModelUsage(model: "opus", tokensIn: 110, tokensOut: 55, calls: 2))
    }

    func testAllSortedByTokensDesc() throws {
        try db.write { try ModelUsageStore.bump(model: "small", tokensIn: 1, tokensOut: 1, in: $0) }
        try db.write { try ModelUsageStore.bump(model: "big", tokensIn: 500, tokensOut: 500, in: $0) }
        let all = try ModelUsageStore.all(in: db)
        XCTAssertEqual(all.map(\.model), ["big", "small"])
    }
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter ModelUsageTests` fails to compile: `cannot find 'ModelUsageStore' in scope`.

- [ ] **Step 3: Minimal impl.** (The `model_usage` table already exists from Task 2's v3 migration.)

```swift
// ModelUsage.swift
import Foundation
import GRDB

public struct ModelUsage: Codable, FetchableRecord, PersistableRecord, Equatable {
    public var model: String
    public var tokensIn: Int64
    public var tokensOut: Int64
    public var calls: Int64

    public init(model: String, tokensIn: Int64, tokensOut: Int64, calls: Int64) {
        self.model = model
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.calls = calls
    }

    public static let databaseTableName = "model_usage"

    enum CodingKeys: String, CodingKey {
        case model
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case calls
    }
}

public enum ModelUsageStore {
    public static func bump(model: String, tokensIn: Int, tokensOut: Int, in db: GRDB.Database) throws {
        try db.execute(sql: """
            INSERT INTO model_usage (model, tokens_in, tokens_out, calls)
            VALUES (?, ?, ?, 1)
            ON CONFLICT(model) DO UPDATE SET
              tokens_in = tokens_in + excluded.tokens_in,
              tokens_out = tokens_out + excluded.tokens_out,
              calls = calls + 1
            """, arguments: [model, tokensIn, tokensOut])
    }

    public static func all(in db: DatabaseQueue) throws -> [ModelUsage] {
        try db.read { conn in
            try ModelUsage.order(sql: "tokens_in + tokens_out DESC, model ASC").fetchAll(conn)
        }
    }
}
```

- [ ] **Step 4: Run — expect PASS.** `swift test --filter ModelUsageTests`.

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/ModelUsage.swift PetCore/Tests/PetCoreTests/ModelUsageTests.swift && git commit -m "Add ModelUsage record + ModelUsageStore bump/all"`

---

### Task 6: ApplyTransaction wires last_event_at + model_usage + petDidChange

Files:
- modify `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/ApplyTransaction.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/ApplyTransactionTests.swift`

- [ ] **Step 1: Write failing tests.** Append to `ApplyTransactionTests.swift`: double-process banks model_usage once; `last_event_at` advances and never regresses; missing `model` skips model_usage; synthetic `process(event:)` skips both; `petDidChange` posts once after a real spool-line write; and a duplicate spool line does **not** post a second `petDidChange` (the post is gated on a did-apply flag — see Step 3). Reuse this file's existing `eventJSON(...)`/`prEvent(...)` helpers (the suite already uses them) and its `db` fixture.

```swift
func testProcessJsonLineBumpsModelUsageOnce() throws {
    let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
    let line = #"{"schema_version":1,"event_id":"01H0000000000000000000000A","ts":1714500000123,"type":"post_tool_use","session_id":"s","tool":"Bash","tokens_in":100,"tokens_out":200,"model":"opus"}"#
    try atx.process(jsonLine: line)
    try atx.process(jsonLine: line) // duplicate: dedup short-circuit → must NOT double-bank
    let all = try ModelUsageStore.all(in: db)
    XCTAssertEqual(all, [ModelUsage(model: "opus", tokensIn: 100, tokensOut: 200, calls: 1)])
}

func testProcessJsonLineAdvancesLastEventAt() throws {
    let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
    try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000A", ts: 5000))
    XCTAssertEqual(try Pet.fetchAlive(from: db)!.lastEventAt, 5000)
    // An older event must NOT move last_event_at backward (MAX semantics).
    try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000B", ts: 3000))
    XCTAssertEqual(try Pet.fetchAlive(from: db)!.lastEventAt, 5000)
}

func testPostToolUseWithoutModelSkipsModelUsage() throws {
    let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
    try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000A"))
    XCTAssertEqual(try ModelUsageStore.all(in: db).count, 0)
}

func testSyntheticEventSkipsModelUsageAndLastEventAt() throws {
    let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
    try atx.process(event: prEvent(eventId: "pr:o/r#1:approved:1000", type: .prApproved))
    XCTAssertEqual(try ModelUsageStore.all(in: db).count, 0)
    XCTAssertEqual(try Pet.fetchAlive(from: db)!.lastEventAt, 0, "synthetic events do not advance last_event_at")
}

func testProcessJsonLinePostsPetDidChangeOnApply() throws {
    let exp = expectation(forNotification: .claudegotchiPetDidChange, object: nil, handler: nil)
    let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
    try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000A"))
    wait(for: [exp], timeout: 1.0)
}

func testDuplicateSpoolLineDoesNotPostPetDidChange() throws {
    let atx = ApplyTransaction(db: db, applier: EventApplier(config: .defaults), paused: false)
    try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000A")) // first apply
    let exp = expectation(forNotification: .claudegotchiPetDidChange, object: nil, handler: nil)
    exp.isInverted = true
    try atx.process(jsonLine: eventJSON(eventId: "01H0000000000000000000000A")) // dedup → no post
    wait(for: [exp], timeout: 0.5)
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter ApplyTransactionTests` fails: model_usage rows absent / `lastEventAt` still 0 / `petDidChange` never delivered (logic not yet wired). (`testDuplicateSpoolLineDoesNotPostPetDidChange` is the inverted-expectation guard for the dedup-path post; it only becomes meaningful once posting is gated on did-apply in Step 3.)

- [ ] **Step 3: Minimal impl.** Wire the v3 effects inside `process(jsonLine:)` AFTER the dedup short-circuit (same position as `daily_rollup`, per spec §B6), and gate the `petDidChange` post on whether the write actually applied — so a duplicate/replayed line (which `return`s out of the `db.write` closure) does **not** post. Have `db.write { ... }` return a `Bool` did-apply flag; post only when `true`. `process(event:)` (synthetic) is untouched: it neither advances `last_event_at`, bumps `model_usage`, nor posts.

```swift
    public func process(jsonLine: String) throws {
        let event = try Event.parse(jsonLine)

        let didApply: Bool = try db.write { conn in
            var pet = try aliveOrThrow(in: conn)

            do {
                try conn.execute(sql: """
                    INSERT INTO event (helper_event_id, ts, type, pet_id, payload, session_id, cwd)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                    event.eventId,
                    event.ts,
                    event.type.rawValue,
                    pet.id!,
                    jsonLine,
                    event.sessionId,
                    event.cwd
                ])
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                return false
            }

            try conn.execute(
                sql: "UPDATE pet SET last_event_at = MAX(last_event_at, ?) WHERE id = ?",
                arguments: [event.ts, pet.id!]
            )
            if event.type == .postToolUse, let model = event.model {
                try ModelUsageStore.bump(
                    model: model,
                    tokensIn: event.tokensIn ?? 0,
                    tokensOut: event.tokensOut ?? 0,
                    in: conn
                )
            }

            let date = localDate(fromUnixMs: event.ts)
            try DailyRollup.upsert(
                eventDate: date, type: event.type,
                tokensIn: event.tokensIn ?? 0,
                tokensOut: event.tokensOut ?? 0,
                tool: event.tool, in: conn
            )

            if !paused {
                pet = applier.apply(event: event, to: pet)
                try pet.update(conn)
            }

            let eventDbId = try Int64.fetchOne(conn, sql: "SELECT MAX(id) FROM event")!
            try conn.execute(
                sql: "UPDATE pet SET last_applied_event_id = ? WHERE id = ?",
                arguments: [eventDbId, pet.id!]
            )
            return true
        }

        if didApply { postPetDidChange() }
    }
```
Note: `last_event_at` is updated before the `pet.update(conn)` write; the `applier.apply` path does not touch `last_event_at`, and the trailing `last_applied_event_id` UPDATE is independent, so the two UPDATEs do not clobber each other. (`DatabaseError` is already in scope via `import GRDB`.)

- [ ] **Step 4: Run — expect PASS.** `swift test --filter ApplyTransactionTests`.

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/ApplyTransaction.swift PetCore/Tests/PetCoreTests/ApplyTransactionTests.swift && git commit -m "ApplyTransaction: advance last_event_at, bump model_usage, post petDidChange on apply only"`

---

### Task 7: EventType.petClick + EventApplier arms (petClick + sessionStart re-anchor)

Files:
- modify `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/Event.swift`
- modify `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/EventApplier.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/EventApplierTests.swift`

- [ ] **Step 1: Write failing tests.** Append to `EventApplierTests.swift`: petClick adds clamped intimacy; sessionStart wake re-anchors `lastTickAt = event.ts`. Reuse the file's existing `applier`/`cfg`/`evt(...)` helpers.

```swift
func testPetClickAddsIntimacyClamped() {
    var pet = Pet.fresh(species: "frog", at: 0)
    pet.intimacy = 10
    let next = applier.apply(event: evt(.petClick), to: pet)
    XCTAssertEqual(next.intimacy, 10 + cfg.eventCosts.petClickIntimacy, accuracy: 1e-9)
}

func testPetClickClampsAt100() {
    var pet = Pet.fresh(species: "frog", at: 0)
    pet.intimacy = 99.5
    let next = applier.apply(event: evt(.petClick), to: pet)
    XCTAssertEqual(next.intimacy, 100)
}

func testSessionStartWakeReanchorsLastTickAt() {
    var pet = Pet.fresh(species: "frog", at: 0)
    pet.hibernationSince = 100
    pet.lastTickAt = 100
    let next = applier.apply(event: evt(.sessionStart, ts: 5_000_000), to: pet)
    XCTAssertNil(next.hibernationSince)
    XCTAssertEqual(next.lastTickAt, 5_000_000, "wake re-anchors lastTickAt to event.ts")
}

func testSessionStartWhenAwakeDoesNotReanchor() {
    var pet = Pet.fresh(species: "frog", at: 0)
    pet.hibernationSince = nil
    pet.lastTickAt = 100
    let next = applier.apply(event: evt(.sessionStart, ts: 5_000_000), to: pet)
    XCTAssertEqual(next.lastTickAt, 100, "no wake → lastTickAt untouched")
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter EventApplierTests` fails to compile: `type 'Event.EventType' has no member 'petClick'`.

- [ ] **Step 3: Minimal impl.** Add the case to `Event.swift`:

```swift
// Event.EventType — add after `case notification`
        case petClick = "pet_click"
```
The `EventApplier.apply` switch has no `default`, so the new case forces a compile error until armed (spec §B7). Edit `EventApplier.swift`:

```swift
// sessionStart arm — re-anchor lastTickAt to event.ts on wake
        case .sessionStart:
            if let sid = event.sessionId {
                sessionStarts[sid] = SessionStart(startedMs: event.ts)
            }
            if p.hibernationSince != nil {
                p.hibernationSince = nil
                p.lastTickAt = event.ts
            }
```
```swift
// new arm — place after the `.stop` case
        case .petClick:
            p.intimacy = clamp(p.intimacy + config.eventCosts.petClickIntimacy)
```

- [ ] **Step 4: Run — expect PASS.** `swift test --filter EventApplierTests`.

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/Event.swift PetCore/Sources/PetCore/EventApplier.swift PetCore/Tests/PetCoreTests/EventApplierTests.swift && git commit -m "Add EventType.petClick arm + sessionStart wake re-anchor of lastTickAt"`

---

### Task 8: ClaudegotchiHook — pure run(args:stdin:) + parsePayload + always-exit-0 + pet_/pr_ reject

Files:
- modify `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/HookHelper/ClaudegotchiHook.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/HookHelperTests/HookTypeGuardTests.swift`

To make the previously-untested control flow (always-exit-0, empty-stdin, reject) assertable without spawning the `@main` binary, factor `main()` into a pure `run(args:stdin:) -> Int32` helper that returns the intended exit code; `main()` just calls `exit(run(...))`. The exit-code/stdin-read behavior is now unit-tested here (Q3 e2e still spawns the real binary end-to-end).

- [ ] **Step 1: Write failing tests.** Add: `pet_`/`pr_` reject; `tool_name`→`tool` mapping; empty/malformed payload → empty map; and `run(args:stdin:)` returns `0` on reject, on empty stdin (type-only event still spooled), and on a normal payload — proving the control flow exits 0 in all branches.

```swift
func testRejectsPetAndPrPrefixRawType() {
    XCTAssertTrue(ClaudegotchiHook.rejectsRawType("pet_click"))
    XCTAssertTrue(ClaudegotchiHook.rejectsRawType("pet_anything"))
    XCTAssertTrue(ClaudegotchiHook.rejectsRawType("pr_approved"))
    XCTAssertFalse(ClaudegotchiHook.rejectsRawType("session_start"))
}

func testParsePayloadMapsToolNameToTool() {
    let p = ClaudegotchiHook.parsePayload(#"{"session_id":"s","cwd":"/w","tool_name":"Bash","model":"opus","tokens_in":10,"tokens_out":20}"#)
    XCTAssertEqual(p["session_id"] as? String, "s")
    XCTAssertEqual(p["cwd"] as? String, "/w")
    XCTAssertEqual(p["tool"] as? String, "Bash")
    XCTAssertEqual(p["model"] as? String, "opus")
    XCTAssertEqual(p["tokens_in"] as? Int, 10)
    XCTAssertEqual(p["tokens_out"] as? Int, 20)
}

func testParsePayloadEmptyOnNilOrMalformed() {
    XCTAssertTrue(ClaudegotchiHook.parsePayload(nil).isEmpty)
    XCTAssertTrue(ClaudegotchiHook.parsePayload("not json").isEmpty)
}

func testRunRejectsAppInternalTypeWithExitZero() {
    let spool = ClaudegotchiHook.spoolURLForTesting()
    try? FileManager.default.removeItem(at: spool)
    let code = ClaudegotchiHook.run(args: ["claudegotchi-hook", "pet_click"], stdin: nil)
    XCTAssertEqual(code, 0, "app-internal type must never block a tool call")
    XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path), "rejected type must not be spooled")
}

func testRunEmptyStdinSpoolsTypeOnlyEventExitZero() throws {
    let spool = ClaudegotchiHook.spoolURLForTesting()
    try? FileManager.default.removeItem(at: spool)
    let code = ClaudegotchiHook.run(args: ["claudegotchi-hook", "session_start"], stdin: nil)
    XCTAssertEqual(code, 0)
    let lines = try String(contentsOf: spool).split(separator: "\n")
    XCTAssertEqual(lines.count, 1, "empty stdin still emits one type-only event")
    XCTAssertTrue(lines[0].contains("session_start"))
}

func testRunWithPayloadExitZero() {
    let spool = ClaudegotchiHook.spoolURLForTesting()
    try? FileManager.default.removeItem(at: spool)
    let code = ClaudegotchiHook.run(
        args: ["claudegotchi-hook", "post_tool_use"],
        stdin: #"{"tool_name":"Bash","model":"opus","tokens_in":1,"tokens_out":2}"#
    )
    XCTAssertEqual(code, 0)
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter HookTypeGuardTests` fails to compile / assert: `pr_`-only `rejectsRawType` (so `pet_click` returns false), `cannot find 'parsePayload'`, `cannot find member 'run'`, `cannot find 'spoolURLForTesting'`.

- [ ] **Step 3: Minimal impl.** Rewrite `ClaudegotchiHook.swift`: extend the reject to `pet_`; add the pure `parsePayload` (centralized `tool_name`→`tool` mapping); add a pure `run(args:stdin:) -> Int32` that reads the payload from `--json` arg or the injected stdin, builds the event, spools it, and **always returns 0** (a stale registration must never block a Claude tool call — spec §B1); `main()` reads real stdin and calls `exit(run(...))`. Expose `spoolURLForTesting()` so tests can target the real spool path deterministically. Delete the old `parseExtras` (only `cwdFromPayload`/`main` used it).

```swift
import Foundation
import PetCore

@main
struct ClaudegotchiHook {
    static func main() {
        var stdin: String? = nil
        let raw = FileHandle.standardInput.readDataToEndOfFile()
        if !raw.isEmpty { stdin = String(data: raw, encoding: .utf8) }
        exit(run(args: CommandLine.arguments, stdin: stdin))
    }

    static func run(args: [String], stdin: String?) -> Int32 {
        guard args.count >= 2 else { return 0 }
        let type = args[1]
        if rejectsRawType(type) { return 0 }

        var rawJSON = stdin
        if let i = args.firstIndex(of: "--json"), i + 1 < args.count {
            rawJSON = args[i + 1]
        }

        let extras = parsePayload(rawJSON)
        let event = Event(
            schemaVersion: 1,
            eventId: ULID.generate(),
            ts: Int64(Date().timeIntervalSince1970 * 1000),
            type: Event.EventType(rawValue: type) ?? .notification,
            sessionId: extras["session_id"] as? String,
            tool: extras["tool"] as? String,
            tokensIn: extras["tokens_in"] as? Int,
            tokensOut: extras["tokens_out"] as? Int,
            model: extras["model"] as? String,
            cwd: extras["cwd"] as? String
        )

        if let line = try? event.encodeJSON() {
            try? HookSpool.append(line, to: spoolURL())
        }
        return 0
    }

    static func parsePayload(_ raw: String?) -> [String: Any] {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: Any] = [:]
        if let v = obj["session_id"] { out["session_id"] = v }
        if let v = obj["cwd"] { out["cwd"] = v }
        if let v = obj["tool_name"] ?? obj["tool"] { out["tool"] = v }
        if let v = obj["model"] { out["model"] = v }
        if let v = obj["tokens_in"] { out["tokens_in"] = v }
        if let v = obj["tokens_out"] { out["tokens_out"] = v }
        return out
    }

    static func cwdFromPayload(_ raw: String?) -> String? {
        parsePayload(raw)["cwd"] as? String
    }

    static func rejectsRawType(_ type: String) -> Bool {
        type.hasPrefix("pr_") || type.hasPrefix("pet_")
    }

    static func spoolURLForTesting() -> URL { spoolURL() }

    private static func spoolURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("claudegotchi")
        return support.appendingPathComponent("spool.jsonl")
    }
}
```

- [ ] **Step 4: Run — expect PASS.** `swift test --filter HookTypeGuardTests` (and `swift test --filter HookSpoolTests` to confirm the spool helper still links).

- [ ] **Step 5: Commit.** `git add PetCore/Sources/HookHelper/ClaudegotchiHook.swift PetCore/Tests/HookHelperTests/HookTypeGuardTests.swift && git commit -m "Hook: extract pure run(args:stdin:), map tool_name, always exit 0, reject pet_/pr_"`

---

### Task 9: SpeciesRoulette.pick(fromIds:using:) pure overload

Files:
- modify `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/SpeciesRoulette.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/SpeciesRouletteTests.swift`

- [ ] **Step 1: Write failing test.** Append to `SpeciesRouletteTests.swift` (reuses the file's existing `SeededRNG`).

```swift
func testPickFromIdsDeterministicWithSeed() {
    let ids = ["frog", "slime", "cat", "dragon"]
    var a = SeededRNG(seed: 7)
    var b = SeededRNG(seed: 7)
    let pa = SpeciesRoulette.pick(fromIds: ids, using: &a)
    let pb = SpeciesRoulette.pick(fromIds: ids, using: &b)
    XCTAssertEqual(pa, pb, "same seed → same id")
    XCTAssertTrue(ids.contains(pa))
}

func testPickFromIdsSingleton() {
    var rng = SeededRNG(seed: 1)
    XCTAssertEqual(SpeciesRoulette.pick(fromIds: ["only"], using: &rng), "only")
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter SpeciesRouletteTests` fails to compile: `incorrect argument label in call (have 'fromIds:using:', expected 'from:using:')` — only the `SpeciesRegistry` overload exists.

- [ ] **Step 3: Minimal impl.** Append an extension to `SpeciesRoulette.swift`.

```swift
extension SpeciesRoulette {
    public static func pick<G: RandomNumberGenerator>(fromIds ids: [String], using gen: inout G) -> String {
        precondition(!ids.isEmpty, "pick(fromIds:) requires a non-empty id list")
        let idx = Int.random(in: 0..<ids.count, using: &gen)
        return ids[idx]
    }
}
```

- [ ] **Step 4: Run — expect PASS.** `swift test --filter SpeciesRouletteTests`.

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/SpeciesRoulette.swift PetCore/Tests/PetCoreTests/SpeciesRouletteTests.swift && git commit -m "Add SpeciesRoulette.pick(fromIds:using:) pure id-only overload"`

---

### Task 10: PixelSpecies catalog + sprite frames

Files:
- create `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/PixelSpecies.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/PixelSpriteTests.swift`

- [ ] **Step 1: Write failing test.** Invariants: 4 ids, each animation key present with ≥1 frame, every frame 16×16, palette indices in `0..<palette.count`, stage thresholds, unknown-id nil.

```swift
import XCTest
@testable import PetCore

final class PixelSpriteTests: XCTestCase {
    let anims = ["idle", "happy", "sick", "sleeping"]

    func testCatalogHasFourKnownIds() {
        XCTAssertEqual(Set(PixelSpeciesCatalog.ids), ["frog", "slime", "cat", "dragon"])
    }

    func testEveryDefHasAllAnimationsWithFrames() {
        for def in PixelSpeciesCatalog.all {
            for anim in anims {
                let frames = def.frames[anim]
                XCTAssertNotNil(frames, "\(def.id) missing \(anim)")
                XCTAssertGreaterThanOrEqual(frames?.count ?? 0, 1)
            }
        }
    }

    func testEveryFrameIs16x16WithInRangeIndices() {
        let count = UInt8(PixelSpeciesCatalog.palette.count)
        for def in PixelSpeciesCatalog.all {
            for (_, frames) in def.frames {
                for frame in frames {
                    XCTAssertEqual(frame.count, 16)
                    for row in frame {
                        XCTAssertEqual(row.count, 16)
                        for px in row { XCTAssertLessThan(px, count) }
                    }
                }
            }
        }
    }

    func testPaletteIndexZeroIsTransparent() {
        XCTAssertEqual(PixelSpeciesCatalog.palette[0] & 0xFF00_0000, 0, "index 0 alpha = 0")
    }

    func testDefLookupAndUnknownNil() {
        XCTAssertEqual(PixelSpeciesCatalog.def("frog")?.id, "frog")
        XCTAssertNil(PixelSpeciesCatalog.def("unicorn"))
    }

    func testStageThresholds() {
        let firstStage = PixelSpeciesCatalog.def("frog")!.stages.first!.id
        XCTAssertEqual(PixelSpeciesCatalog.stage(id: "frog", xp: 0), firstStage)
        XCTAssertEqual(PixelSpeciesCatalog.stage(id: "unicorn", xp: 0), "unknown", "fallback stage for unknown id")
    }

    func testStageAdvancesWithXp() {
        let def = PixelSpeciesCatalog.def("frog")!
        guard def.stages.count >= 2 else { return }
        let secondMin = def.stages[1].minXp
        XCTAssertEqual(PixelSpeciesCatalog.stage(id: "frog", xp: Int64(secondMin)), def.stages[1].id)
    }
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter PixelSpriteTests` fails to compile: `cannot find 'PixelSpeciesCatalog' in scope`.

- [ ] **Step 3: Minimal impl.** Create `PixelSpecies.swift`. Frames are 16×16 grids of palette indices; palette is ARGB with index 0 transparent.

```swift
// PixelSpecies.swift
import Foundation

public typealias PixelFrame = [[UInt8]]

public struct PixelSpeciesDef: Equatable {
    public let id: String
    public let nameZh: String
    public let stages: [(id: String, minXp: Int)]
    public let frames: [String: [PixelFrame]]

    public static func == (lhs: PixelSpeciesDef, rhs: PixelSpeciesDef) -> Bool {
        lhs.id == rhs.id && lhs.nameZh == rhs.nameZh
            && lhs.stages.map(\.id) == rhs.stages.map(\.id)
            && lhs.stages.map(\.minXp) == rhs.stages.map(\.minXp)
            && lhs.frames == rhs.frames
    }
}

public enum PixelSpeciesCatalog {
    public static let palette: [UInt32] = [
        0x0000_0000, // 0 transparent
        0xFF1B_1B1B, // 1 outline
        0xFF4C_AF50, // 2 frog green
        0xFF2E_7D32, // 3 frog dark green
        0xFF9C_CC65, // 4 slime light
        0xFFFF_B74D, // 5 cat orange
        0xFFB0_71F0, // 6 dragon purple
        0xFFFF_FFFF, // 7 eye white
        0xFFE5_7373, // 8 sick flush / cheek
    ]

    public static let all: [PixelSpeciesDef] = [
        def(id: "frog",   nameZh: "小青蛙", body: 2, dark: 3),
        def(id: "slime",  nameZh: "史莱姆", body: 4, dark: 2),
        def(id: "cat",    nameZh: "小猫",   body: 5, dark: 1),
        def(id: "dragon", nameZh: "小龙",   body: 6, dark: 1),
    ]

    public static var ids: [String] { all.map(\.id) }

    public static func def(_ id: String) -> PixelSpeciesDef? {
        all.first { $0.id == id }
    }

    public static func stage(id: String, xp: Int64) -> String {
        guard let d = def(id) else { return "unknown" }
        var current = d.stages.first?.id ?? "unknown"
        for s in d.stages where Int64(s.minXp) <= xp { current = s.id }
        return current
    }

    // MARK: - construction

    private static func def(id: String, nameZh: String, body: UInt8, dark: UInt8) -> PixelSpeciesDef {
        let idle = blob(body: body, dark: dark, eye: 7)
        let happy = blob(body: body, dark: dark, eye: 7, cheek: 8)
        let sick = blob(body: 8, dark: dark, eye: 7)
        let sleeping = blobClosedEyes(body: body, dark: dark)
        return PixelSpeciesDef(
            id: id, nameZh: nameZh,
            stages: [("baby", 0), ("child", 100), ("adult", 400)],
            frames: [
                "idle": [idle, shift(idle)],
                "happy": [happy, shift(happy)],
                "sick": [sick],
                "sleeping": [sleeping],
            ]
        )
    }

    private static func blank() -> PixelFrame {
        Array(repeating: Array(repeating: UInt8(0), count: 16), count: 16)
    }

    private static func blob(body: UInt8, dark: UInt8, eye: UInt8, cheek: UInt8? = nil) -> PixelFrame {
        var g = blank()
        for r in 3...13 {
            for c in 3...12 {
                let edge = (r == 3 || r == 13 || c == 3 || c == 12)
                g[r][c] = edge ? 1 : body
            }
        }
        for c in 4...11 { g[12][c] = dark }
        g[6][5] = eye; g[6][6] = 1
        g[6][9] = eye; g[6][10] = 1
        if let cheek {
            g[8][4] = cheek; g[8][11] = cheek
        }
        return g
    }

    private static func blobClosedEyes(body: UInt8, dark: UInt8) -> PixelFrame {
        var g = blob(body: body, dark: dark, eye: 1)
        g[6][5] = 1; g[6][6] = 1; g[6][9] = 1; g[6][10] = 1
        return g
    }

    private static func shift(_ frame: PixelFrame) -> PixelFrame {
        var g = blank()
        for r in 1..<16 { g[r] = frame[r - 1] }
        return g
    }
}
```

- [ ] **Step 4: Run — expect PASS.** `swift test --filter PixelSpriteTests`.

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/PixelSpecies.swift PetCore/Tests/PetCoreTests/PixelSpriteTests.swift && git commit -m "Add PixelSpeciesCatalog (palette + frog/slime/cat/dragon frames + stages)"`

---

### Task 11: PetMood pure derivation

Files:
- create `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/PetMood.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/PetMoodTests.swift`

- [ ] **Step 1: Write failing test.** Table: sleeping (hibernating) > sick (2-of-3 low via `DeathWindow.isLowDay` with default thresholds) > idle; stage from xp; overlay from pressure; NO transient happy.

```swift
import XCTest
@testable import PetCore

final class PetMoodTests: XCTestCase {
    private func pet(fullness: Double = 100, stamina: Double = 100, intimacy: Double = 100,
                     xp: Int64 = 0, hibernating: Bool = false) -> Pet {
        var p = Pet.fresh(species: "frog", at: 0)
        p.fullness = fullness; p.stamina = stamina; p.intimacy = intimacy; p.xp = xp
        p.hibernationSince = hibernating ? 1 : nil
        return p
    }

    func testHibernatingIsSleeping() {
        XCTAssertEqual(PetMood.derive(pet: pet(hibernating: true), pressure: .calm).animation, .sleeping)
    }

    func testTwoOfThreeLowIsSick() {
        XCTAssertEqual(PetMood.derive(pet: pet(fullness: 10, stamina: 10), pressure: .calm).animation, .sick)
    }

    func testOneLowIsIdle() {
        XCTAssertEqual(PetMood.derive(pet: pet(fullness: 10), pressure: .calm).animation, .idle)
    }

    func testSleepingBeatsSick() {
        let v = PetMood.derive(pet: pet(fullness: 10, stamina: 10, hibernating: true), pressure: .calm)
        XCTAssertEqual(v.animation, .sleeping)
    }

    func testStageFromXp() {
        XCTAssertEqual(PetMood.derive(pet: pet(xp: 0), pressure: .calm).stage,
                       PixelSpeciesCatalog.stage(id: "frog", xp: 0))
    }

    func testOverlayFromPressure() {
        XCTAssertEqual(PetMood.derive(pet: pet(), pressure: .calm).overlay, PetOverlay.none)
        XCTAssertEqual(PetMood.derive(pet: pet(), pressure: .busy).overlay, .focus)
        XCTAssertEqual(PetMood.derive(pet: pet(), pressure: .stressed).overlay, .sweat)
    }
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter PetMoodTests` fails to compile: `cannot find 'PetMood' in scope`.

- [ ] **Step 3: Minimal impl.** Create `PetMood.swift`. Use the same low-day rule as `DeathWindow.isLowDay` with `ConfigYAML.defaults` thresholds (the locked `derive` signature has no config injection).

```swift
// PetMood.swift
import Foundation

public enum PetAnimation: String, Equatable { case idle, happy, sick, sleeping }
public enum PetOverlay: String, Equatable { case none, focus, sweat }

public struct PetVisual: Equatable {
    public let stage: String
    public let animation: PetAnimation
    public let overlay: PetOverlay
    public init(stage: String, animation: PetAnimation, overlay: PetOverlay) {
        self.stage = stage
        self.animation = animation
        self.overlay = overlay
    }
}

public enum PetMood {
    public static func derive(pet: Pet, pressure: PressureTier) -> PetVisual {
        let stage = PixelSpeciesCatalog.stage(id: pet.species, xp: pet.xp)
        let overlay: PetOverlay
        switch pressure {
        case .calm: overlay = .none
        case .busy: overlay = .focus
        case .stressed: overlay = .sweat
        }

        let animation: PetAnimation
        if pet.hibernationSince != nil {
            animation = .sleeping
        } else if DeathWindow.isLowDay(
            pet: pet,
            threshold: ConfigYAML.defaults.thresholds.deathStatLow,
            requiredCount: ConfigYAML.defaults.thresholds.deathLowStatsRequired
        ) {
            animation = .sick
        } else {
            animation = .idle
        }
        return PetVisual(stage: stage, animation: animation, overlay: overlay)
    }
}
```

- [ ] **Step 4: Run — expect PASS.** `swift test --filter PetMoodTests`.

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/PetMood.swift PetCore/Tests/PetCoreTests/PetMoodTests.swift && git commit -m "Add PetMood.derive (sleeping/sick/idle + pressure overlay)"`

---

### Task 12: TickCheckpoint (pure, ms contract)

Files:
- create `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/TickCheckpoint.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/TickCheckpointTests.swift`

- [ ] **Step 1: Write failing test.** Per spec §B5: elapsed<0 clamp (no decay), normal decay, hibernate-enter boundary (emit `.hibernateStart`, no decay), wake re-anchor (newer event → emit `.hibernateEnd`, clear `hibernationSince`, `lastTickAt = nowMs`), still-asleep no-newer-event stays frozen. Always sets `lastTickAt = nowMs`.

```swift
import XCTest
@testable import PetCore

final class TickCheckpointTests: XCTestCase {
    let cfg = ConfigYAML.defaults

    private func pet(lastTickAt: Int64, hibernating: Int64? = nil) -> Pet {
        var p = Pet.fresh(species: "frog", at: 0)
        p.fullness = 50; p.stamina = 50; p.intimacy = 50
        p.lastTickAt = lastTickAt
        p.hibernationSince = hibernating
        return p
    }

    func testClockSkewClampsNoDecay() {
        let p = pet(lastTickAt: 10_000)
        let r = TickCheckpoint.run(pet: p, nowMs: 5_000, lastEventMs: 10_000, config: cfg)
        XCTAssertEqual(r.pet.fullness, 50, "elapsed<0 → no decay")
        XCTAssertEqual(r.pet.lastTickAt, 5_000)
        XCTAssertNil(r.emit)
    }

    func testNormalDecayAwake() {
        let p = pet(lastTickAt: 0)
        let r = TickCheckpoint.run(pet: p, nowMs: 10_000, lastEventMs: 9_000, config: cfg)
        let expected = Decay.apply(pet: p, elapsedSeconds: 10.0, config: cfg).fullness
        XCTAssertEqual(r.pet.fullness, expected, accuracy: 1e-9)
        XCTAssertEqual(r.pet.lastTickAt, 10_000)
        XCTAssertNil(r.emit)
    }

    func testHibernateEnterBoundaryEmitsAndSkipsDecay() {
        let thresholdMs = Int64(cfg.thresholds.hibernationAfterSeconds) * 1000
        let nowMs: Int64 = 1_000_000_000
        let lastEventMs = nowMs - thresholdMs // exactly at threshold → shouldEnter true
        let p = pet(lastTickAt: lastEventMs)
        let r = TickCheckpoint.run(pet: p, nowMs: nowMs, lastEventMs: lastEventMs, config: cfg)
        XCTAssertEqual(r.emit, .hibernateStart)
        XCTAssertEqual(r.pet.hibernationSince, nowMs)
        XCTAssertEqual(r.pet.fullness, 50, "no decay on hibernate-enter")
        XCTAssertEqual(r.pet.lastTickAt, nowMs)
    }

    func testWakeReanchorEmitsEnd() {
        let p = pet(lastTickAt: 1_000, hibernating: 5_000)
        let r = TickCheckpoint.run(pet: p, nowMs: 20_000, lastEventMs: 9_000, config: cfg)
        XCTAssertEqual(r.emit, .hibernateEnd)
        XCTAssertNil(r.pet.hibernationSince)
        XCTAssertEqual(r.pet.lastTickAt, 20_000)
        XCTAssertEqual(r.pet.fullness, 50, "wake does not replay sleep span")
    }

    func testStillHibernatingNoNewerEventStaysAsleep() {
        let p = pet(lastTickAt: 1_000, hibernating: 5_000)
        let r = TickCheckpoint.run(pet: p, nowMs: 20_000, lastEventMs: 4_000, config: cfg)
        XCTAssertNil(r.emit)
        XCTAssertEqual(r.pet.hibernationSince, 5_000)
        XCTAssertEqual(r.pet.fullness, 50, "asleep → frozen")
        XCTAssertEqual(r.pet.lastTickAt, 20_000)
    }
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter TickCheckpointTests` fails to compile: `cannot find 'TickCheckpoint' in scope`.

- [ ] **Step 3: Minimal impl.** Create `TickCheckpoint.swift` implementing the spec §B5 rule order exactly.

```swift
// TickCheckpoint.swift
import Foundation

public enum TickEmit: String, Equatable { case hibernateStart, hibernateEnd }

public struct TickResult: Equatable {
    public let pet: Pet
    public let emit: TickEmit?
    public init(pet: Pet, emit: TickEmit?) {
        self.pet = pet
        self.emit = emit
    }
}

public enum TickCheckpoint {
    public static func run(pet: Pet, nowMs: Int64, lastEventMs: Int64, config: ConfigYAML) -> TickResult {
        var p = pet
        let elapsedSeconds = max(0, Double(nowMs - pet.lastTickAt)) / 1000.0
        var emit: TickEmit? = nil

        if pet.hibernationSince == nil {
            if Hibernation.shouldEnter(
                nowSeconds: Double(nowMs) / 1000.0,
                lastEventSeconds: Double(lastEventMs) / 1000.0,
                config: config
            ) {
                p.hibernationSince = nowMs
                emit = .hibernateStart
            } else {
                p = Decay.apply(pet: p, elapsedSeconds: elapsedSeconds, config: config)
            }
        } else if lastEventMs > pet.hibernationSince! {
            p.hibernationSince = nil
            emit = .hibernateEnd
        }

        p.lastTickAt = nowMs
        return TickResult(pet: p, emit: emit)
    }
}
```

- [ ] **Step 4: Run — expect PASS.** `swift test --filter TickCheckpointTests`. (If `Hibernation.shouldEnter`'s parameter labels differ from `nowSeconds:`/`lastEventSeconds:`, adjust the call to match the existing `Hibernation` signature — do not change `Hibernation`.)

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/TickCheckpoint.swift PetCore/Tests/PetCoreTests/TickCheckpointTests.swift && git commit -m "Add TickCheckpoint pure ms decay/hibernation driver"`

---

### Task 13: PetClick cooldown predicate

Files:
- create `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/PetClick.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/PetClickTests.swift`

- [ ] **Step 1: Write failing test.**

```swift
import XCTest
@testable import PetCore

final class PetClickTests: XCTestCase {
    func testAllowedWhenNeverClicked() {
        XCTAssertTrue(PetClick.allowed(lastClickMs: nil, nowMs: 1000, cooldownSeconds: 60))
    }

    func testBlockedWithinCooldown() {
        XCTAssertFalse(PetClick.allowed(lastClickMs: 0, nowMs: 30_000, cooldownSeconds: 60))
    }

    func testAllowedAtBoundary() {
        XCTAssertTrue(PetClick.allowed(lastClickMs: 0, nowMs: 60_000, cooldownSeconds: 60))
    }

    func testAllowedAfterCooldown() {
        XCTAssertTrue(PetClick.allowed(lastClickMs: 0, nowMs: 61_000, cooldownSeconds: 60))
    }

    func testClockSkewBlocks() {
        XCTAssertFalse(PetClick.allowed(lastClickMs: 100_000, nowMs: 50_000, cooldownSeconds: 60))
    }
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter PetClickTests` fails to compile: `cannot find 'PetClick' in scope`.

- [ ] **Step 3: Minimal impl.**

```swift
// PetClick.swift
import Foundation

public enum PetClick {
    public static func allowed(lastClickMs: Int64?, nowMs: Int64, cooldownSeconds: Int) -> Bool {
        guard let last = lastClickMs else { return true }
        return nowMs - last >= Int64(cooldownSeconds) * 1000
    }
}
```

- [ ] **Step 4: Run — expect PASS.** `swift test --filter PetClickTests`.

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/PetClick.swift PetCore/Tests/PetCoreTests/PetClickTests.swift && git commit -m "Add PetClick.allowed cooldown predicate"`

---

### Task 14: HatchService (hatch-if-none)

Files:
- create `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/HatchService.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/HatchServiceTests.swift`

- [ ] **Step 1: Write failing test.** Hatch when empty (species ∈ catalog ids, `lastTickAt`/`lastEventAt` = now); no-op when alive (returns existing, count stays 1).

```swift
import XCTest
import GRDB
@testable import PetCore

final class HatchServiceTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "hatch-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testHatchesWhenEmpty() throws {
        let pet = try HatchService.ensureAlive(db, nowMs: 7777)
        XCTAssertTrue(PixelSpeciesCatalog.ids.contains(pet.species))
        XCTAssertEqual(pet.lastTickAt, 7777)
        XCTAssertEqual(pet.lastEventAt, 7777)
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pet") }
        XCTAssertEqual(count, 1)
    }

    func testNoOpWhenAlive() throws {
        let existing = try Pet.insert(.fresh(species: "frog", at: 100), into: db)
        let returned = try HatchService.ensureAlive(db, nowMs: 9999)
        XCTAssertEqual(returned.id, existing.id)
        XCTAssertEqual(returned.lastTickAt, 100, "existing pet untouched")
        let count = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pet") }
        XCTAssertEqual(count, 1)
    }
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter HatchServiceTests` fails to compile: `cannot find 'HatchService' in scope`.

- [ ] **Step 3: Minimal impl.** Create `HatchService.swift`. Hatch from `PixelSpeciesCatalog.ids` via the id-only `pick(fromIds:using:)` (Task 9) with the system RNG.

```swift
// HatchService.swift
import Foundation
import GRDB

public enum HatchService {
    @discardableResult
    public static func ensureAlive(_ db: DatabaseQueue, nowMs: Int64) throws -> Pet {
        if let alive = try Pet.fetchAlive(from: db) { return alive }
        var rng = SystemRandomNumberGenerator()
        let species = SpeciesRoulette.pick(fromIds: PixelSpeciesCatalog.ids, using: &rng)
        return try Pet.insert(.fresh(species: species, at: nowMs), into: db)
    }
}
```

- [ ] **Step 4: Run — expect PASS.** `swift test --filter HatchServiceTests`.

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/HatchService.swift PetCore/Tests/PetCoreTests/HatchServiceTests.swift && git commit -m "Add HatchService.ensureAlive (catalog-id hatch, no-op if alive)"`

---

### Task 15: StatsQueries (dashboard DAO)

Files:
- create `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/StatsQueries.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/StatsQueriesTests.swift`

- [ ] **Step 1: Write failing test.** Seed a DB with UTC + fixed nowMs. Cover lifetime, today (+zero-row), streak (consecutive ending today, with a gap), peak, heatmap, modelUsage, age, history. Seed `daily_rollup` rows directly, one model_usage row, two dead pets. (Dead-pet locals are `let` — `markDead` writes via SQL using the id; the locals are only read for `.id!`, so `var` would warn `never mutated`.)

```swift
import XCTest
import GRDB
@testable import PetCore

final class StatsQueriesTests: XCTestCase {
    var db: DatabaseQueue!
    var dbPath: String!
    let utc = TimeZone(identifier: "UTC")!
    // 2026-06-03T12:00:00Z
    let nowMs: Int64 = 1_780_488_000_000

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "stats-\(UUID()).sqlite"
        db = try Database.open(at: dbPath)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func seedRollup(_ date: String, sessions: Int = 0, tools: Int = 0,
                            tokensIn: Int = 0, tokensOut: Int = 0) throws {
        try db.write {
            try $0.execute(sql: """
                INSERT INTO daily_rollup (date, sessions, messages, tokens_in, tokens_out, tools_used)
                VALUES (?, ?, 0, ?, ?, ?)
                """, arguments: [date, sessions, tokensIn, tokensOut, tools])
        }
    }

    func testLifetimeTokens() throws {
        try seedRollup("2026-06-01", tokensIn: 100, tokensOut: 200)
        try seedRollup("2026-06-02", tokensIn: 10, tokensOut: 5)
        XCTAssertEqual(try StatsQueries.lifetimeTokens(db), 315)
    }

    func testTodayTotalsZeroRow() throws {
        let t = try StatsQueries.todayTotals(db, nowMs: nowMs, tz: utc)
        XCTAssertEqual(t, TodayTotals(tokens: 0, sessions: 0, tools: 0))
    }

    func testTodayTotalsPopulated() throws {
        try seedRollup("2026-06-03", sessions: 2, tools: 4, tokensIn: 30, tokensOut: 70)
        let t = try StatsQueries.todayTotals(db, nowMs: nowMs, tz: utc)
        XCTAssertEqual(t, TodayTotals(tokens: 100, sessions: 2, tools: 4))
    }

    func testActiveStreakWithGap() throws {
        // today + yesterday present; gap on 06-01 → streak = 2.
        try seedRollup("2026-06-03", sessions: 1)
        try seedRollup("2026-06-02", sessions: 1)
        try seedRollup("2026-05-31", sessions: 1)
        XCTAssertEqual(try StatsQueries.activeStreakDays(db, nowMs: nowMs, tz: utc), 2)
    }

    func testActiveStreakZeroWhenTodayMissing() throws {
        try seedRollup("2026-06-02", sessions: 1)
        XCTAssertEqual(try StatsQueries.activeStreakDays(db, nowMs: nowMs, tz: utc), 0)
    }

    func testPeakDayTokens() throws {
        try seedRollup("2026-06-01", tokensIn: 100, tokensOut: 100) // 200
        try seedRollup("2026-06-02", tokensIn: 500, tokensOut: 1)   // 501
        XCTAssertEqual(try StatsQueries.peakDayTokens(db), 501)
    }

    func testHeatmapSeriesLengthAndKnownDay() throws {
        try seedRollup("2026-06-03", tokensIn: 1, tokensOut: 2)
        let series = try StatsQueries.heatmapSeries(db, weeks: 2, nowMs: nowMs, tz: utc)
        XCTAssertEqual(series.count, 14)
        XCTAssertEqual(series.last?.day, "2026-06-03")
        XCTAssertEqual(series.last?.tokens, 3)
        XCTAssertTrue(series.dropLast().allSatisfy { $0.tokens == 0 }, "absent days are zero, not missing")
    }

    func testModelUsage() throws {
        try db.write { try ModelUsageStore.bump(model: "opus", tokensIn: 5, tokensOut: 5, in: $0) }
        XCTAssertEqual(try StatsQueries.modelUsage(db).map(\.model), ["opus"])
    }

    func testPetAgeDays() throws {
        let born = nowMs - 3 * 86_400_000
        _ = try Pet.insert(.fresh(species: "frog", at: born), into: db)
        XCTAssertEqual(try StatsQueries.petAgeDays(db, nowMs: nowMs), 3)
    }

    func testGrowthHistoryNewestFirst() throws {
        let dead1 = try Pet.insert(.fresh(species: "frog", at: 1000), into: db)
        try Pet.markDead(id: dead1.id!, at: 2000, in: db)
        let dead2 = try Pet.insert(.fresh(species: "cat", at: 3000), into: db)
        try Pet.markDead(id: dead2.id!, at: 4000, in: db)
        let hist = try StatsQueries.growthHistory(db, limit: 10)
        XCTAssertEqual(hist.map(\.species), ["cat", "frog"], "newest death first")
        XCTAssertEqual(hist.first?.diedMs, 4000)
    }
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter StatsQueriesTests` fails to compile: `cannot find 'StatsQueries' in scope`.

- [ ] **Step 3: Minimal impl.** Create `StatsQueries.swift`. Day keys via `LocalDay.key`; streak via `LocalDay.dayIndex` over present rollup dates (parse each `yyyy-MM-dd` back to a `dayIndex` at local noon to avoid DST edges, then count the run ending at today).

```swift
// StatsQueries.swift
import Foundation
import GRDB

public struct TodayTotals: Equatable {
    public let tokens: Int64
    public let sessions: Int
    public let tools: Int
    public init(tokens: Int64, sessions: Int, tools: Int) {
        self.tokens = tokens; self.sessions = sessions; self.tools = tools
    }
}

public struct GrowthEntry: Equatable {
    public let species: String
    public let name: String?
    public let bornMs: Int64
    public let diedMs: Int64?
    public let xp: Int64
    public init(species: String, name: String?, bornMs: Int64, diedMs: Int64?, xp: Int64) {
        self.species = species; self.name = name
        self.bornMs = bornMs; self.diedMs = diedMs; self.xp = xp
    }
}

public enum StatsQueries {
    public static func lifetimeTokens(_ db: DatabaseQueue) throws -> Int64 {
        try db.read {
            try Int64.fetchOne($0, sql: "SELECT COALESCE(SUM(tokens_in + tokens_out), 0) FROM daily_rollup") ?? 0
        }
    }

    public static func todayTotals(_ db: DatabaseQueue, nowMs: Int64, tz: TimeZone) throws -> TodayTotals {
        let key = LocalDay.key(unixMs: nowMs, timeZone: tz)
        return try db.read { conn in
            guard let row = try Row.fetchOne(conn, sql: """
                SELECT tokens_in, tokens_out, sessions, tools_used
                FROM daily_rollup WHERE date = ?
                """, arguments: [key]) else {
                return TodayTotals(tokens: 0, sessions: 0, tools: 0)
            }
            let tin: Int64 = row["tokens_in"]
            let tout: Int64 = row["tokens_out"]
            return TodayTotals(tokens: tin + tout, sessions: row["sessions"], tools: row["tools_used"])
        }
    }

    public static func activeStreakDays(_ db: DatabaseQueue, nowMs: Int64, tz: TimeZone) throws -> Int {
        let dates = try db.read { try String.fetchAll($0, sql: "SELECT date FROM daily_rollup") }
        let present = Set(dates.map { dayIndexFromKey($0, tz: tz) })
        var idx = LocalDay.dayIndex(unixMs: nowMs, timeZone: tz)
        var streak = 0
        while present.contains(idx) {
            streak += 1
            idx -= 1
        }
        return streak
    }

    public static func peakDayTokens(_ db: DatabaseQueue) throws -> Int64 {
        try db.read {
            try Int64.fetchOne($0, sql: "SELECT COALESCE(MAX(tokens_in + tokens_out), 0) FROM daily_rollup") ?? 0
        }
    }

    public static func heatmapSeries(_ db: DatabaseQueue, weeks: Int, nowMs: Int64, tz: TimeZone) throws -> [(day: String, tokens: Int64)] {
        let totalDays = weeks * 7
        let byKey: [String: Int64] = try db.read { conn in
            var acc: [String: Int64] = [:]
            let cursor = try Row.fetchCursor(conn, sql: "SELECT date, tokens_in + tokens_out AS t FROM daily_rollup")
            while let r = try cursor.next() {
                acc[r["date"]] = r["t"]
            }
            return acc
        }
        var out: [(day: String, tokens: Int64)] = []
        for offset in stride(from: totalDays - 1, through: 0, by: -1) {
            let ms = nowMs - Int64(offset) * 86_400_000
            let key = LocalDay.key(unixMs: ms, timeZone: tz)
            out.append((day: key, tokens: byKey[key] ?? 0))
        }
        return out
    }

    public static func modelUsage(_ db: DatabaseQueue) throws -> [ModelUsage] {
        try ModelUsageStore.all(in: db)
    }

    public static func petAgeDays(_ db: DatabaseQueue, nowMs: Int64) throws -> Int {
        guard let pet = try Pet.fetchAlive(from: db) else { return 0 }
        return Int((nowMs - pet.birthday) / 86_400_000)
    }

    public static func growthHistory(_ db: DatabaseQueue, limit: Int) throws -> [GrowthEntry] {
        try db.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT species, name, birthday, death_at, xp
                FROM pet WHERE death_at IS NOT NULL
                ORDER BY death_at DESC LIMIT ?
                """, arguments: [limit])
            return rows.map {
                GrowthEntry(
                    species: $0["species"], name: $0["name"],
                    bornMs: $0["birthday"], diedMs: $0["death_at"], xp: $0["xp"]
                )
            }
        }
    }

    private static func dayIndexFromKey(_ key: String, tz: TimeZone) -> Int {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        guard let date = f.date(from: key) else { return Int.min }
        // Anchor at local noon so a DST shift never bumps the index.
        let noonMs = Int64(date.timeIntervalSince1970 * 1000) + 12 * 3_600_000
        return LocalDay.dayIndex(unixMs: noonMs, timeZone: tz)
    }
}
```

- [ ] **Step 4: Run — expect PASS.** `swift test --filter StatsQueriesTests` (clean compile — no `never mutated` warnings from the dead-pet `let` locals).

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/StatsQueries.swift PetCore/Tests/PetCoreTests/StatsQueriesTests.swift && git commit -m "Add StatsQueries dashboard DAO (lifetime/today/streak/peak/heatmap/usage/age/history)"`

---

### Task 16: HooksInstaller (install / uninstall / status, atomic + merge-safe)

Files:
- create `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/HooksInstaller.swift`
- test `/Users/jalen/Documents/code/claudegotchi/PetCore/Tests/PetCoreTests/HooksInstallerTests.swift`

- [ ] **Step 1: Write failing test.** Use a temp settings path + fixed `nowISO`; NEVER touch real `~/.claude`. Cover: fresh install (5 tagged leaves, matcher `*` on Pre/Post, matcher-group shape); merge into existing file (foreign keys/groups preserved); corrupt JSON refused (file intact); idempotent; reinstall with changed path updates command in place; uninstall prune (shared group + sibling foreign group untouched, untagged-same-path NOT removed); space-in-path command single-quoted; status transitions.

```swift
import XCTest
@testable import PetCore

final class HooksInstallerTests: XCTestCase {
    var dir: URL!
    var settings: URL!
    let nowISO = "2026-06-03T00:00:00Z"
    let bin = "/Users/jalen/Library/Application Support/claudegotchi/bin/claudegotchi-hook"

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hooks-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = dir.appendingPathComponent("settings.json")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func loadJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: settings)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func hooks() throws -> [String: Any] {
        (try loadJSON())["hooks"] as! [String: Any]
    }

    private func taggedLeafCount(_ root: [String: Any]) -> Int {
        guard let hooks = root["hooks"] as? [String: Any] else { return 0 }
        var n = 0
        for (_, v) in hooks {
            guard let groups = v as? [[String: Any]] else { continue }
            for g in groups {
                for leaf in (g["hooks"] as? [[String: Any]]) ?? [] where leaf["_claudegotchi"] as? Bool == true {
                    n += 1
                }
            }
        }
        return n
    }

    func testFreshInstallWritesFiveTaggedLeaves() throws {
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        XCTAssertEqual(taggedLeafCount(try loadJSON()), 5)
        let h = try hooks()
        for key in ["PreToolUse", "PostToolUse", "SessionStart", "Stop", "Notification"] {
            XCTAssertNotNil(h[key], "missing \(key)")
        }
        let pre = (h["PreToolUse"] as! [[String: Any]]).first!
        XCTAssertEqual(pre["matcher"] as? String, "*")
        let ss = (h["SessionStart"] as! [[String: Any]]).first!
        XCTAssertNil(ss["matcher"])
    }

    func testCommandReParsesWithSpaceInPath() throws {
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        let leaf = ((try hooks()["SessionStart"] as! [[String: Any]]).first!["hooks"] as! [[String: Any]]).first!
        let cmd = leaf["command"] as! String
        XCTAssertTrue(cmd.contains("session_start"))
        XCTAssertTrue(cmd.hasPrefix("'\(bin)'"), "path must be single-quoted: \(cmd)")
    }

    func testMergePreservesForeignKeysAndGroups() throws {
        let existing = """
        {"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/bin/foreign"}]}]}}
        """
        try existing.data(using: .utf8)!.write(to: settings)
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        let root = try loadJSON()
        XCTAssertEqual(root["model"] as? String, "opus", "foreign top-level key kept")
        let pre = (try hooks())["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(pre.count, 2, "foreign group kept; ours appended")
        XCTAssertEqual(taggedLeafCount(root), 5)
    }

    func testCorruptJSONRefused() throws {
        try "{ not json".data(using: .utf8)!.write(to: settings)
        XCTAssertThrowsError(try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO))
        let raw = try String(contentsOf: settings)
        XCTAssertEqual(raw, "{ not json", "corrupt file left intact")
    }

    func testIdempotentNoDuplicate() throws {
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        XCTAssertEqual(taggedLeafCount(try loadJSON()), 5, "second install must not duplicate")
    }

    func testReinstallUpdatesCommandInPlace() throws {
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        let newBin = "/new/path/claudegotchi-hook"
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: newBin, nowISO: nowISO)
        XCTAssertEqual(taggedLeafCount(try loadJSON()), 5)
        let leaf = (((try hooks())["Stop"] as! [[String: Any]]).first!["hooks"] as! [[String: Any]]).first!
        XCTAssertTrue((leaf["command"] as! String).hasPrefix("'\(newBin)'"))
    }

    func testStatusTransitions() throws {
        XCTAssertEqual(try HooksInstaller.status(settingsPath: settings), .notInstalled)
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        XCTAssertEqual(try HooksInstaller.status(settingsPath: settings), .installed)
        try HooksInstaller.uninstall(settingsPath: settings)
        XCTAssertEqual(try HooksInstaller.status(settingsPath: settings), .notInstalled)
    }

    func testUninstallSharedGroupAndForeignSiblingAndUntaggedSamePath() throws {
        let existing = """
        {"hooks":{"PreToolUse":[
          {"matcher":"Bash","hooks":[{"type":"command","command":"/usr/bin/foreign"}]},
          {"matcher":"*","hooks":[
            {"type":"command","command":"/other/tool"},
            {"type":"command","command":"'\(bin)' pre_tool_use"}
          ]}
        ]}}
        """
        try existing.data(using: .utf8)!.write(to: settings)
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        try HooksInstaller.uninstall(settingsPath: settings)
        let pre = (try hooks())["PreToolUse"] as! [[String: Any]]
        let allLeafCommands = pre.flatMap { ($0["hooks"] as! [[String: Any]]).map { $0["command"] as! String } }
        XCTAssertTrue(allLeafCommands.contains("/usr/bin/foreign"))
        XCTAssertTrue(allLeafCommands.contains("/other/tool"))
        XCTAssertTrue(allLeafCommands.contains("'\(bin)' pre_tool_use"), "untagged same-path leaf must NOT be removed")
        XCTAssertEqual(taggedLeafCount(try loadJSON()), 0, "all tagged leaves removed")
    }

    func testWrittenJSONParsesAsMatcherGroupShape() throws {
        try HooksInstaller.install(settingsPath: settings, hookBinaryPath: bin, nowISO: nowISO)
        for (_, v) in try hooks() {
            let groups = v as! [[String: Any]]
            for g in groups {
                for leaf in (g["hooks"] as! [[String: Any]]) {
                    XCTAssertEqual(leaf["type"] as? String, "command")
                    XCTAssertNotNil(leaf["command"] as? String)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run — expect FAIL.** `swift test --filter HooksInstallerTests` fails to compile: `cannot find 'HooksInstaller' in scope`.

- [ ] **Step 3: Minimal impl.** Create `HooksInstaller.swift`. Model the file as nested `[String: Any]` (preserve foreign keys); tag leaves with `_claudegotchi`; single-quote the path; atomic temp+rename with a `.bak-<nowISO>` backup before rename.

```swift
// HooksInstaller.swift
import Foundation

public enum HookInstallStatus: String, Equatable {
    case notInstalled, installed, partiallyInstalled
}

public enum HooksInstallerError: Error, Equatable {
    case corruptSettings
}

public enum HooksInstaller {
    private static let tagKey = "_claudegotchi"
    private static let matcherEvents = ["PreToolUse", "PostToolUse"]
    private static let eventArg: [(event: String, arg: String)] = [
        ("PreToolUse", "pre_tool_use"),
        ("PostToolUse", "post_tool_use"),
        ("SessionStart", "session_start"),
        ("Stop", "stop"),
        ("Notification", "notification"),
    ]

    public static func install(settingsPath: URL, hookBinaryPath: String, nowISO: String) throws {
        var root = try readRoot(settingsPath)
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let command = shellQuoted(hookBinaryPath)

        for (event, arg) in eventArg {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            let fullCommand = "\(command) \(arg)"
            let wantsMatcher = matcherEvents.contains(event)

            if let gi = indexOfTaggedGroup(in: groups) {
                var group = groups[gi]
                var leaves = (group["hooks"] as? [[String: Any]]) ?? []
                if let li = leaves.firstIndex(where: { $0[tagKey] as? Bool == true }) {
                    leaves[li]["command"] = fullCommand
                } else {
                    leaves.append(taggedLeaf(fullCommand))
                }
                group["hooks"] = leaves
                groups[gi] = group
            } else {
                var group: [String: Any] = ["hooks": [taggedLeaf(fullCommand)]]
                if wantsMatcher { group["matcher"] = "*" }
                groups.append(group)
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try writeAtomically(root, to: settingsPath, nowISO: nowISO)
    }

    public static func uninstall(settingsPath: URL) throws {
        var root = try readRoot(settingsPath)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for event in eventArg.map(\.event) {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            for gi in groups.indices {
                var leaves = (groups[gi]["hooks"] as? [[String: Any]]) ?? []
                leaves.removeAll { $0[tagKey] as? Bool == true }
                groups[gi]["hooks"] = leaves
            }
            groups.removeAll { (($0["hooks"] as? [[String: Any]]) ?? []).isEmpty }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeAtomically(root, to: settingsPath, nowISO: ISO8601DateFormatter().string(from: Date()))
    }

    public static func status(settingsPath: URL) throws -> HookInstallStatus {
        guard FileManager.default.fileExists(atPath: settingsPath.path) else { return .notInstalled }
        let root = try readRoot(settingsPath)
        let hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var found = 0
        for event in eventArg.map(\.event) {
            for g in (hooks[event] as? [[String: Any]]) ?? [] {
                if ((g["hooks"] as? [[String: Any]]) ?? []).contains(where: { $0[tagKey] as? Bool == true }) {
                    found += 1
                }
            }
        }
        if found == 0 { return .notInstalled }
        if found == eventArg.count { return .installed }
        return .partiallyInstalled
    }

    // MARK: - helpers

    private static func indexOfTaggedGroup(in groups: [[String: Any]]) -> Int? {
        groups.firstIndex { g in
            ((g["hooks"] as? [[String: Any]]) ?? []).contains { $0[tagKey] as? Bool == true }
        }
    }

    private static func taggedLeaf(_ command: String) -> [String: Any] {
        ["type": "command", "command": command, tagKey: true]
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func readRoot(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            throw HooksInstallerError.corruptSettings
        }
        return dict
    }

    private static func writeAtomically(_ root: [String: Any], to url: URL, nowISO: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak-\(nowISO)")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
```

- [ ] **Step 4: Run — expect PASS.** `swift test --filter HooksInstallerTests`.

- [ ] **Step 5: Commit.** `git add PetCore/Sources/PetCore/HooksInstaller.swift PetCore/Tests/PetCoreTests/HooksInstallerTests.swift && git commit -m "Add HooksInstaller (atomic merge-safe install/uninstall/status, leaf-tagged)"`

---

### Task 17: Full suite green

Files: (none — verification only)

- [ ] **Step 1: Run the full suite.** `swift test` from the `PetCore` package directory. Expect ALL targets GREEN (`PetCoreTests` + `HookHelperTests`), including the pre-existing `DailyRollupTests`/`ApplyTransactionTests`/`EventApplierTests`/`SpeciesRouletteTests` that this chunk touched, and confirm Task 1's `testLastEventAtRoundTrips` (RED until Task 2) is now GREEN. If any pre-existing test regressed (e.g. a key-format change in the `LocalDay` refactor), fix the impl — never weaken an existing assertion.

- [ ] **Step 2: Commit only if a fix was required** (otherwise skip). `git add -A && git commit -m "Fix Q0 backend regression surfaced by full suite"`


## Chunk Q1: Pet dropdown + drivers

> **Implementer note (working-tree reality):** the COMMITTED `claudegotchiApp.swift`
> does NOT auto-open a window and does NOT call `NSApp.setActivationPolicy` —
> `applicationDidFinishLaunching` is just `services.start(); installMenuBar(services)`.
> Ignore any plan reference to "removing the auto-open call" or "removing
> setActivationPolicy" / specific line numbers (143, 202-226) — those were drafted
> against a temporary demo edit since reverted. Read the real file and adapt.
> `showWorkbench(_:)` exists (~line 200) and is the dropdown's current open path;
> Q1 keeps it (footer `[打开统计]` opens it for now), Q2 replaces it (see Q2 note).

> App layer only — SwiftUI/timer files, NOT `swift test`-able. Tasks are file-level: each lists the file, responsibilities, the precise interface implemented, acceptance criteria, and a manual/prose check. Consumes the Q0-locked PetCore units (`TickCheckpoint`, `PixelSpeciesCatalog`, `PetMood`, `PetClick`, `Pet.lastEventAt`, `Notification.Name.claudegotchiPetDidChange`, `HatchService`, `SpeciesRoulette.pick(fromIds:using:)`) verbatim per §0. All times are unix **milliseconds**. Commits carry NO AI attribution. After every code task, run a typecheck only (`swift build` of PetCore for the consumed symbols; the App target is xcodegen/Xcode and is NOT built here beyond confirming PetCore compiles) — do NOT run `xcodebuild`.

### Task 1: TickDriver.swift — ms-clock decay/hibernation timer

Files:
- create: `/Users/jalen/Documents/code/claudegotchi/App/claudegotchi/TickDriver.swift`

Responsibilities:
- A `@MainActor final class TickDriver` owning a ~60s repeating `Timer` (high `tolerance`, e.g. 10s) added to `RunLoop.main` in `.common`; reuses the shared `DatabaseQueue` + `EventApplier` (never opens its own — §3 shared-instance invariant), the shared `ConfigYAML`, and the same `pausedProvider: () -> Bool` instance the watchers read.
- On each tick (and once immediately on `start()`): read `nowMs` from the **injected unix-epoch-ms provider** (default `Int64(Date().timeIntervalSince1970 * 1000)`), NOT `MachClock` (§B5: `MachClock.nowSeconds()` is uptime, not epoch, and would corrupt `lastTickAt`).
- Fetch the alive pet via `Pet.fetchAlive(from:)`; if `nil`, no-op (HatchService owns hatching).
- **Paused branch:** if `pausedProvider()` is true, do NOT decay — re-anchor `lastTickAt = nowMs` on the pet and persist via `Pet.update(_:in:)`, then post `petDidChange` after the write returns. (ApplyTransaction's paused gate does not cover direct tick writes — §B5.)
- **Awake branch:** read `lastEventMs = pet.lastEventAt`; call `TickCheckpoint.run(pet:, nowMs:, lastEventMs:, config:)`; persist the returned `result.pet` via `Pet.update(_:in:)`.
- If `result.emit != nil`, build a synthetic `Event` of type `.hibernateStart`/`.hibernateEnd` with `eventId = "tick:\(petId):\(emit.rawValue):\(nowMs)"` (the `nowMs` component prevents same-day UNIQUE-collision drops — §B5) and `ts = nowMs`, and route it through `ApplyTransaction(db:applier:paused:).process(event:)`.
- **Post `petDidChange` AFTER `db.write(...)` returns** — never inside a write closure (GRDB queue is non-reentrant — §B6). All DB writes here go through `Pet.update` / `ApplyTransaction.process(event:)`, both of which return before the post.

Precise interface implemented:
```swift
@MainActor
final class TickDriver {
    init(
        db: DatabaseQueue,
        applier: EventApplier,
        config: ConfigYAML,
        pausedProvider: @escaping () -> Bool,
        nowMsProvider: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    )
    func start()   // runs one tick immediately, then schedules the ~60s timer
    func stop()    // invalidates the timer
}
```

- [ ] **Step 1: Read `Event.swift` first, then write the file.** Read `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/Event.swift` to confirm the initializer (it is `init(schemaVersion: Int, eventId: String, ts: Int64, type: EventType, sessionId: String?, tool: String?, tokensIn: Int?, tokensOut: Int?, model: String?, cwd: String? = nil)` — `schemaVersion` has NO default and `EventType` is nested, so from this file it must be spelled `Event.EventType`). The code below is already correct against that signature (mirrors `PRSync.swift` lines 83/94: `schemaVersion: 1` first, canonical param order). Implement exactly:
```swift
import Foundation
import GRDB
import PetCore

@MainActor
final class TickDriver {
    private nonisolated let db: DatabaseQueue
    private nonisolated let applier: EventApplier
    private nonisolated let config: ConfigYAML
    private nonisolated let pausedProvider: () -> Bool
    private nonisolated let nowMsProvider: () -> Int64
    private var timer: Timer?

    init(
        db: DatabaseQueue,
        applier: EventApplier,
        config: ConfigYAML,
        pausedProvider: @escaping () -> Bool,
        nowMsProvider: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.db = db
        self.applier = applier
        self.config = config
        self.pausedProvider = pausedProvider
        self.nowMsProvider = nowMsProvider
    }

    func start() {
        tick()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let nowMs = nowMsProvider()
        guard let pet = try? Pet.fetchAlive(from: db), let petId = pet.id else { return }

        if pausedProvider() {
            var reanchored = pet
            reanchored.lastTickAt = nowMs
            try? Pet.update(reanchored, in: db)
            postPetDidChange()
            return
        }

        let result = TickCheckpoint.run(
            pet: pet, nowMs: nowMs, lastEventMs: pet.lastEventAt, config: config
        )
        try? Pet.update(result.pet, in: db)

        if let emit = result.emit {
            let type: Event.EventType = (emit == .hibernateStart) ? .hibernateStart : .hibernateEnd
            let event = Event(
                schemaVersion: 1,
                eventId: "tick:\(petId):\(emit.rawValue):\(nowMs)",
                ts: nowMs,
                type: type,
                sessionId: nil,
                tool: nil,
                tokensIn: nil,
                tokensOut: nil,
                model: nil
            )
            try? ApplyTransaction(db: db, applier: applier, paused: false).process(event: event)
        }

        postPetDidChange()
    }
}
```
  `postPetDidChange()` is the Q0 free function in `PetNotification.swift`. Note: `result.emit` is the `TickCheckpoint` emit enum whose cases align with `.hibernateStart`/`.hibernateEnd` — confirm the enum's case names against `TickCheckpoint` before relying on `emit == .hibernateStart`; do NOT invent `Event` fields.

- [ ] **Step 2: Typecheck consumed PetCore symbols.** Run `swift build --package-path /Users/jalen/Documents/code/claudegotchi/PetCore` and confirm `TickCheckpoint.run`, `Pet.lastEventAt`, `Pet.update`, `postPetDidChange`, `Event.init(schemaVersion:…)`, and `Event.EventType.hibernateStart/.hibernateEnd` all compile in PetCore. Expected: build succeeds (this file is App-side and is compiled by Xcode, not here; this step only guards that the symbols it imports exist).

- [ ] **Step 3: Commit.**
```
git add App/claudegotchi/TickDriver.swift && git commit -m "Add TickDriver: ms-clock decay/hibernation tick over shared DB"
```

Acceptance:
- With a real session, after ~60s of inactivity the pet's stats drift downward (decay applied once per tick, billed against `lastTickAt`); after the hibernation threshold a single `hibernate_start` synthetic event appears in `event` and the panel shows 💤.
- While the pause toggle is ON, no decay accrues across many ticks and `lastTickAt` keeps advancing (re-anchored), so toggling pause OFF does not produce a decay spike.
- No duplicate `hibernate_start`/`hibernate_end` rows accumulate across repeated ticks within the same day (the `:<nowMs>` id keeps each emit unique, and `TickCheckpoint` only emits on a state transition).

Manual check (prose): launch the app, open the popover, leave Claude idle; watch the 饱食/体力 bars tick down ~once a minute; flip pause and confirm the bars freeze and `last_tick_at` (inspect `pet.sqlite`) still advances.

---

### Task 2: PixelPetView.swift — Canvas renderer + menu-bar NSImage + tap→pet_click

Files:
- create: `/Users/jalen/Documents/code/claudegotchi/App/claudegotchi/PixelPetView.swift`

Responsibilities:
- A SwiftUI `Canvas`-based `PixelPetView` that draws the current `PixelFrame` (a `[[UInt8]]` grid of palette indices, 0 = transparent) as filled rects, mapping each index through `PixelSpeciesCatalog.palette` (ARGB `UInt32`). Cell size = `floor(min(width,height) / gridSize)`; the grid is centered.
- Resolves frames from `PixelSpeciesCatalog.def(species)?.frames[animation.rawValue]` for the supplied `PetVisual` (computed App-side from `PetMood.derive(pet:pressure:)`); unknown species → generic single-color block (the §A1 stated fallback). The transient `happy` animation is App-side only (not in `PetMood.derive`) — accept a `PetVisual` whose animation may have been overridden to `.happy` by the caller.
- Frame timer ~800ms (idle cadence) advancing the frame index modulo the current animation's frame count; pin to frame 0 if a single-frame animation.
- **Overlay reduction:** when the rendered size is small (≤ ~22px, the menu-bar case), draw the mood overlay (`focus`/`sweat`) as a single corner dot (like the PR attention badge), NOT the full overlay art; at panel size (~96px) draw the fuller corner glyph. `overlay == .none` draws nothing.
- `renderToNSImage(size:) -> NSImage`: render the current frame (color, default ~18px) to an `NSImage` for the status item, off the SwiftUI tree, using the same palette mapping (e.g. `NSImage(size:)` + `lockFocus`/`CGContext` filling per-cell rects, or `ImageRenderer` over a sized `Canvas`). Must be callable from the AppDelegate timer independent of the popover being shown.
- Tap gesture → emit `pet_click`: gated by `PetClick.allowed(lastClickMs:nowMs:cooldownSeconds:)` where `lastClickMs` comes from the DB (`SELECT MAX(ts) FROM event WHERE type='pet_click'` for the alive pet — source of truth survives relaunch, §B7), `nowMs` is the observed clock, `cooldownSeconds = config.thresholds.petClickCooldownSeconds`. When allowed, route a synthetic `pet_click` `Event` (id e.g. `click:<petId>:<nowMs>`) via `ApplyTransaction.process(event:)`, then post `petDidChange` after the write returns; optionally flip the App-side animation to `.happy` briefly. The `Event` initializer must pass `schemaVersion: 1` first in the canonical param order (see Task 1).

Precise interface implemented:
```swift
struct PixelPetView: View {
    init(visual: PetVisual, species: String, onTap: (() -> Void)? = nil)
    // body: Canvas drawing frames via PixelSpeciesCatalog.palette; ~800ms frame timer; overlay corner dot at small sizes
}

enum PixelPetRenderer {
    static func renderToNSImage(visual: PetVisual, species: String, size: CGFloat = 18) -> NSImage
}

// click gating helper (uses DB MAX(ts) + PetClick.allowed); lives here or in PetPanelModel — keep one owner
enum PetClickGate {
    static func lastClickMs(_ db: DatabaseQueue) throws -> Int64?   // SELECT MAX(ts) WHERE type='pet_click'
}
```

- [ ] **Step 1: Write the file.** Implement `PixelPetView` (Canvas + 800ms `TimelineView`/`Timer` frame advance + palette-mapped rects + small-size corner-dot overlay), `PixelPetRenderer.renderToNSImage(visual:species:size:)`, and `PetClickGate.lastClickMs`. Map `UInt32` ARGB → `Color`/`NSColor` via `(a,r,g,b)` byte extraction; skip cells whose palette index is 0 (transparent). For the generic fallback when `PixelSpeciesCatalog.def(species) == nil`, draw a solid rounded block in palette index 1's color (or a fixed gray). Read `/Users/jalen/Documents/code/claudegotchi/PetCore/Sources/PetCore/Event.swift` first to match the `Event` initializer (`schemaVersion:` first, no default) and the `EventType.petClick` raw value before constructing the click event.

- [ ] **Step 2: Typecheck consumed PetCore symbols.** `swift build --package-path /Users/jalen/Documents/code/claudegotchi/PetCore` to confirm `PixelSpeciesCatalog.palette`, `.def(_:)`, `PetVisual`, `PetOverlay`, `PetClick.allowed`, and `EventType.petClick` exist and compile. Expected: succeeds.

- [ ] **Step 3: Commit.**
```
git add App/claudegotchi/PixelPetView.swift && git commit -m "Add PixelPetView: Canvas pixel renderer, menu-bar NSImage, pet_click tap"
```

Acceptance:
- A frog/slime/cat/dragon renders as recognizable filled-rect pixel art from `PixelSpeciesCatalog`; transparent cells (index 0) show through.
- `renderToNSImage(size: 18)` returns a non-nil colored `NSImage` whose pixel content changes when the animation/overlay changes.
- At menu-bar size the overlay is a single corner dot, not full art.
- Tapping the pet within the cooldown window does nothing; after `petClickCooldownSeconds` a tap raises 亲密 (intimacy) and the change survives an app relaunch (cooldown read from DB, not memory).

Manual check (prose): open the popover, tap the pet rapidly — intimacy bumps once then is rate-limited; quit and relaunch within the cooldown and confirm an immediate tap is still blocked (DB-sourced `lastClickMs`).

---

### Task 3: PetPanelModel.swift — ObservableObject reading shared DB

Files:
- create: `/Users/jalen/Documents/code/claudegotchi/App/claudegotchi/PetPanelModel.swift`

Responsibilities:
- A `@MainActor final class PetPanelModel: ObservableObject` reading the shared `DatabaseQueue` + `ConfigYAML` (never opening its own).
- `refresh()` populates published state. **Note on "one read pass":** this means a single `refresh()` invocation, NOT a single SQL transaction. Several DAOs here open their own reads independently:
  - `pet: Pet?` via `Pet.fetchAlive(from:)` (opens its own `DatabaseQueue` read).
  - today's `DailyRollup` row — `DailyRollup.fetch(date:from:)` takes a **`GRDB.Database` connection**, not a `DatabaseQueue`, so it MUST be wrapped: `let rollup = try? db.read { conn in try DailyRollup.fetch(date: dayKey, from: conn) }`, with `dayKey = LocalDay.key(unixMs: nowMs, timeZone: .current)`. When absent → `0/0/0` zero-state.
  - `activeSessions` via `SessionTracker.activeSessions(db:nowMs:windowMs:repoPaths:)` (takes a `DatabaseQueue`, opens its own read; reuse the 15-min window + watched-repo paths exactly as `WorkPanelModel.refresh` does — read `WorkPanelView.swift` for the repoPaths derivation). For the activity line, pick the **most-recently-active** session: `activeSessions.max(by: { $0.lastActivityMs < $1.lastActivityMs })?.lastTool` — NOT `.first` (oldest-started) or `.last` (newest-started); `activeSessions(...)` returns sessions sorted by `startedAtMs` ascending, which is start-order, not activity-recency.
  - `tier: PressureTier` via `WorkPressure.tier(prs, config:)` over `PRStore.allPRs` (for the mood overlay passed into `PixelPetView`).
  - derive `PetVisual` via `PetMood.derive(pet:pressure:)` and expose it (plus `species`) for the view.
- **Token width/unit:** `DailyRollup` exposes `tokensIn` and `tokensOut` as `Int`, so `todayTokens = Int64(rollup.tokensIn + rollup.tokensOut)`. The view (Task 4) casts it back down for the formatter: `tokenLabel(Int(todayTokens))` — be deliberate about the `Int64`↔`Int` round-trip so the implementer doesn't trip on the width mismatch.
- Activity precedence (§6): `pet.hibernationSince != nil` → `💤 休眠中`; else an active session with a `lastTool` → `Claude 正在 <tool>…`; else `空闲`. Sourced from the most-recently-active `ActiveSession.lastTool` + the hibernation flag — NOT `EventApplier.pending`.
- Stat display values: 饱食 = `pet.fullness`, 体力 = `pet.stamina`, 亲密 = `pet.intimacy` (all 0–100); 智慧 = `Level.compute(xp:)` for `Lv N` plus xp-to-next via `Level.xpForLevel(level+1)` minus `pet.xp`.
- Observe `Notification.Name.claudegotchiPetDidChange` (hop to main, call `refresh()`, never synchronously re-query on the notification thread — the observer block `MainActor`-hops); a 5s fallback timer also calls `refresh()` (the AppDelegate already owns a 5s timer — this model piggybacks on a `refresh()` call driven from there; keep ONE 5s cadence, do not double-schedule).

Precise interface implemented:
```swift
@MainActor
final class PetPanelModel: ObservableObject {
    @Published private(set) var visual: PetVisual?
    @Published private(set) var species: String
    @Published private(set) var fullness: Double
    @Published private(set) var stamina: Double
    @Published private(set) var intimacy: Double
    @Published private(set) var level: Int
    @Published private(set) var xpToNext: Int64
    @Published private(set) var todayTokens: Int64
    @Published private(set) var todaySessions: Int
    @Published private(set) var todayTools: Int
    @Published private(set) var activity: String           // 💤休眠中 / Claude 正在 <tool>… / 空闲
    @Published private(set) var hasPet: Bool

    init(db: DatabaseQueue, config: ConfigYAML)
    func refresh()                                          // one refresh() invocation; safe to call from main on petDidChange + 5s fallback
    func handlePetClick()                                   // PetClickGate.lastClickMs + PetClick.allowed → process(event:) pet_click, then refresh
}
```

- [ ] **Step 1: Write the file.** Implement the model. For `xpToNext`, compute `let lv = Level.compute(xp: pet.xp); xpToNext = Int64(max(0, Level.xpForLevel(lv + 1) - pet.xp))`. For today's row, wrap the fetch in `db.read { conn in try DailyRollup.fetch(date: dayKey, from: conn) }` (the API takes `GRDB.Database`, verified in `DailyRollupTests`); map `今日会话 = rollup.sessions`, `今日工具 = rollup.toolsUsed`, `todayTokens = Int64(rollup.tokensIn + rollup.tokensOut)`. Register the `claudegotchiPetDidChange` observer in `init` storing the token; deregister in `deinit`. The observer closure must `Task { @MainActor in self?.refresh() }` (or `MainActor.assumeIsolated` only if already guaranteed main) — never touch the DB on the posting thread.

- [ ] **Step 2: Typecheck consumed PetCore symbols.** `swift build --package-path /Users/jalen/Documents/code/claudegotchi/PetCore` confirming `LocalDay.key`, `DailyRollup.fetch(date:from:)`, `DailyRollup.tokensIn/.tokensOut/.sessions/.toolsUsed`, `SessionTracker.activeSessions`, `ActiveSession.lastActivityMs/.lastTool`, `WorkPressure.tier`, `PetMood.derive`, `Level.compute/.xpForLevel`, `PetClick.allowed`, `Notification.Name.claudegotchiPetDidChange` compile. Expected: succeeds.

- [ ] **Step 3: Commit.**
```
git add App/claudegotchi/PetPanelModel.swift && git commit -m "Add PetPanelModel: shared-DB read of pet, today, activity, mood"
```

Acceptance:
- On fresh install (pet just hatched, no rollup) the model reports `0/0/0` today and `空闲` activity without throwing.
- After a real `post_tool_use`, `todayTokens/Tools` increase on the next `petDidChange` and `activity` shows `Claude 正在 <tool>…` for the most-recently-active session's tool.
- When hibernating, `activity == "💤 休眠中"` regardless of session state.
- Calling `refresh()` repeatedly from main never deadlocks the shared queue (no re-query inside any write closure; the rollup read uses `db.read`, not `db.write`).

Manual check (prose): observe the panel update within ~1s of a tool call (via `petDidChange`) and within 5s in the worst case (fallback timer); with two concurrent sessions, the activity line tracks the one with the newest `lastActivityMs`.

---

### Task 4: PetPanelView.swift — pixel pet + 4 bars + level + today + activity

Files:
- create: `/Users/jalen/Documents/code/claudegotchi/App/claudegotchi/PetPanelView.swift`

Responsibilities (§6 layout budget; total ≤ ~244px so the panel + work section + footer fit in 460):
- `struct PetPanelView: View` observing a `PetPanelModel`. Top: `PixelPetView(visual:species:onTap:)` (~96px, tappable → `model.handlePetClick()`); pass the model's `visual`/`species`.
- 4 stat bars (~80px): 饱食 🍞 / 体力 💪 / 亲密 💖 as 0–100 horizontal bars (tint → red when low, e.g. < 25), and 智慧 🌟 rendered as `Lv N` + a thin xp-to-next progress (label `还需 <xpToNext> xp`). Cap any user-facing big count with `99+`-style formatting where applicable; bars must clamp 0…100.
- Level/species line (~24px): `Lv N · <nameZh>` where `nameZh = PixelSpeciesCatalog.def(species)?.nameZh ?? species` (raw id fallback).
- Today row (~22px): `今日 <tokens compact> · 会话 <99+> · 工具 <99+>`. Tokens compact via the existing `PRTabFormat.tokenLabel(_ tokens: Int?)` (PRTabView.swift:69) — pass `tokenLabel(Int(model.todayTokens))` (`Int64`→`Int` round-trip per Task 3). **Reuse it AS-IS; do NOT add a new compact-token helper** (global rule). Be aware of two real properties of that formatter, which this row inherits verbatim:
  - It returns a `k`-only compact form (`>= 1000 → "%.1fk tok"`) with **NO megabyte branch** — a 1.2M total renders as `1234.5k tok`. The spec's `M` form is added in Q2's StatsWindow work (spec §6 line 351-352: Overview reuses `PRTabFormat.tokenLabel` with `k`/`M`); **Q1 ships the `k`-only form and consumes `tokenLabel` unchanged.** When Q2 extends `tokenLabel` with an `M` branch, this row inherits `1.2M` for free with no Q1 change.
  - It appends a ` tok` suffix, so the rendered row reads `今日 12.3k tok · 会话 … · 工具 …` (the suffix is accepted; it diverges from the spec's bare `12.3k` mock-up but reuses the single canonical formatter rather than forking one).
  - Empty input (`0`/`nil`) returns `""`; render the zero-state token cell as a literal `0` (e.g. `let tok = PRTabFormat.tokenLabel(Int(model.todayTokens)); Text(tok.isEmpty ? "0" : tok)`) so the row reads `今日 0 · 会话 0 · 工具 0`.
  - Counts capped `99+` via `PRTabFormat.cappedCount` (reuse; defined PRTabView.swift:24).
- Activity line (~22px): `model.activity` with `.lineLimit(1)` + `.truncationMode(.middle)` for long/MCP tool names.
- Empty/loading: when `model.hasPet == false`, render a compact placeholder (e.g. `🥚 孵化中…`) rather than blank.

Precise interface implemented:
```swift
struct PetPanelView: View {
    @ObservedObject var model: PetPanelModel
    init(model: PetPanelModel)
    // body: pixel pet (tappable) + 4 bars + level/species line + today row + activity line; fixed width 276
}
```

- [ ] **Step 1: Write the file.** Build the `VStack(spacing:)` per the budget; width 276 to match the popover. Reuse `PRTabFormat.cappedCount` and `PRTabFormat.tokenLabel(_:)` (both confirmed in `PRTabView.swift` — `tokenLabel` at line 69, `cappedCount` at line 24); do NOT define new formatters. Stat bar = a `GeometryReader`/`Capsule` overlay or `ProgressView(value:)` clamped to `0...100`; low-tint threshold a single private constant. No comments unless a non-obvious invariant.

- [ ] **Step 2: Typecheck consumed symbols.** `swift build --package-path /Users/jalen/Documents/code/claudegotchi/PetCore` for `PixelSpeciesCatalog.def(_:).nameZh`. (The `PRTabFormat.tokenLabel`/`PRTabFormat.cappedCount` reuse is App-side and verified by Xcode, not here.) Expected: succeeds.

- [ ] **Step 3: Commit.**
```
git add App/claudegotchi/PetPanelView.swift && git commit -m "Add PetPanelView: pixel pet, 4 stat bars, level, today, activity"
```

Acceptance (run mentally against §UI edge cases):
- Zero-state: fresh pet → `今日 0 · 会话 0 · 工具 0`, `空闲`, full bars, `Lv 0`.
- Long tool name (e.g. an MCP `mcp__atlassian-jira__searchJiraIssuesUsingJql`) truncates middle on one line, never wraps the panel.
- 3-digit counts render `99+`; large token totals render in the `k`-compact form `PRTabFormat.tokenLabel` produces (e.g. `12.3k tok`). The `1.2M` form is NOT expected in Q1 — it arrives once Q2 extends `tokenLabel` with the `M` branch; this row inherits it then with no Q1 change.
- Low stat (< 25) tints its bar red.
- The whole panel fits ≤ ~244px tall so the 460px popover keeps the footer reachable.

Manual check (prose): resize-proof since the popover is fixed 276×460; visually confirm bar tint, truncation, the `Lv N · nameZh` line, and that a ≥1000 token total shows `…k tok` (not raw digits) against the spec.

---

### Task 5: WorkPanelView.swift — remove internal 打开工作台 button

Files:
- modify: `/Users/jalen/Documents/code/claudegotchi/App/claudegotchi/WorkPanelView.swift`

Responsibilities:
- Delete the internal `打开工作台` `Button` (lines ~90–94) from `WorkPanelView.body` — it duplicates the unified footer's single open affordance (§6). The footer (Task 6) becomes the sole entry point.
- Remove the now-unused `onOpenWorktable` parameter from `WorkPanelView` and its call site in `WorkPanelRoot` (`claudegotchiApp.swift`) so the view no longer carries a dead closure. (The footer in Task 6 owns the open action directly.)

- [ ] **Step 1: Remove the button.** Edit `WorkPanelView.body` to delete:
```swift
            Button(action: onOpenWorktable) {
                Text("打开工作台").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
```
  and remove the `var onOpenWorktable: () -> Void` stored property from `WorkPanelView`.

- [ ] **Step 2: Confirm no dangling references.** `grep -rn "onOpenWorktable" /Users/jalen/Documents/code/claudegotchi/App` — every remaining hit must be re-pointed (the `WorkPanelView(model:onOpenWorktable:)` call site in `claudegotchiApp.swift` is rewired in Task 6, where `WorkPanelRoot` is replaced by the unified dropdown). Expected after Task 6: zero references to a `WorkPanelView`-level `onOpenWorktable`.

- [ ] **Step 3: Commit.**
```
git add App/claudegotchi/WorkPanelView.swift && git commit -m "Remove duplicate 打开工作台 button from WorkPanelView"
```

Acceptance:
- `WorkPanelView` renders header + content + running line only; no internal open button.
- The work section's intrinsic height drops (no button row), helping it fit the §6 `maxHeight: 140` cap.

Manual check (prose): the work section in the dropdown no longer shows two "open" controls.

---

### Task 6: claudegotchiApp.swift — start ordering, MidnightDriver onDeath+refresh, TickDriver, menu-bar NSImage, unified dropdown + pinned footer

Files:
- modify: `/Users/jalen/Documents/code/claudegotchi/App/claudegotchi/claudegotchiApp.swift`

Responsibilities:

**(a) `AppServices` — construct + start order (§B8):**
- Add `let tick: TickDriver` ivar. Construct `midnight` with an `onDeath` closure that rehatches AND refreshes UI: after `HatchService.ensureAlive(...)` returns, post `petDidChange` so the menu-bar icon + open panels refresh immediately on a mid-run midnight death→rehatch (don't rely solely on the 2-5s icon timer). Spec §B6 lists `MidnightDriver` as a `petDidChange` poster and §B4 promises immediate refresh-on-rehatch; the current `MidnightDriver` itself posts nothing (verified: no `NotificationCenter` usage — it only calls `onDeath()` when `result.died`), so the post is wired HERE inside `onDeath`:
  ```swift
  midnight = MidnightDriver(db: db, config: config, onDeath: { [weak self] in
      guard let self else { return }
      try? HatchService.ensureAlive(self.db, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
      postPetDidChange()
  })
  ```
  (The launch-time death case is incidentally also covered: `midnight.start()` runs inside `start()` before `installMenuBar`'s first `redrawStatusIcon`, which reads the already-rehatched pet.)
- Construct `tick = TickDriver(db: db, applier: applier, config: config, pausedProvider: pausedRef)` (reuse the existing `pausedRef`).
- Rewrite `start()` to the pinned order: `reconcileOnLaunch → HatchService.ensureAlive(db, nowMs:) → spool.pump → spool.startWatching → watcher.start → midnight.start → tick.start`. `HatchService.ensureAlive` runs BEFORE the spool pump so `ApplyTransaction.aliveOrThrow` always finds a pet.
- Add `tick.stop()` to `terminate()` (before/with `midnight.stop()`).

**(b) Menu-bar NSImage driver (replace 🐤):**
- Replace `item.button?.title = "🐤"` with an image-driven status item. Add an AppDelegate-owned `iconTimer: Timer?` (independent of the popover) that periodically (e.g. every 2–5s) and on `petDidChange` reads the alive pet + pressure, derives a `PetVisual` via `PetMood.derive`, and assigns `statusItem?.button?.image = PixelPetRenderer.renderToNSImage(visual:species:size:18)` with `image.isTemplate = false` (color icon). Set `item.button?.title = ""`. This must update while the popover is CLOSED.
- Observe `claudegotchiPetDidChange` in the AppDelegate (main-hop) to redraw the icon immediately on a rehatch/stat change, in addition to the timer. (This same observer drives the `onDeath`-posted refresh from part (a), so a mid-run rehatch repaints the icon without waiting for the timer.)

**(c) Unified dropdown + pinned footer:**
- Grow the popover `contentSize` to `NSSize(width: 276, height: 460)`.
- Replace `WorkPanelRoot` with a unified dropdown view = `PetPanelView(model: petPanelModel)` + `Divider()` + `WorkPanelView(model: workPanelModel)` **wrapped in `.frame(maxHeight: 140)` inside a `ScrollView`** (§6 — its intrinsic ~218px would otherwise be hard-clipped by `NSPopover`). A **pinned footer OUTSIDE the scroll** holds `[打开统计]` (calls `showWorkbench`/the stats opener; in Q1 this still opens the existing `PRTabView` workbench — Q2 swaps in `StatsWindow`) + the pause `Toggle` (binds `services.paused` / `services.setPaused`). Footer height ~40, always reachable.
- Construct a `PetPanelModel` alongside `WorkPanelModel` in `installMenuBar`; store it; have `refreshWorkPanel()` (or a renamed `refreshPanels()`) also call `petPanelModel.refresh()` so the single 5s fallback timer drives both. Observe `petDidChange` to refresh both models + redraw the icon.

Precise interface implemented (App-internal; no public API):
```swift
// AppServices
let tick: TickDriver
// start(): reconcileOnLaunch → ensureAlive → spool.pump → spool.startWatching → watcher.start → midnight.start → tick.start
// midnight constructed with onDeath: { ensureAlive(...); postPetDidChange() }

// AppDelegate
private var petPanelModel: PetPanelModel?
private var iconTimer: Timer?
private func redrawStatusIcon()        // PixelPetRenderer.renderToNSImage → statusItem.button.image
// unified dropdown root: PetPanelView + Divider + ScrollView{ WorkPanelView }.frame(maxHeight:140) + pinned footer([打开统计] + pause Toggle)
```

- [ ] **Step 1: Edit `AppServices`.** Add `let tick: TickDriver`; change the `midnight = MidnightDriver(db:config:)` line to the `onDeath:` closure above (`HatchService.ensureAlive` then `postPetDidChange()`); add the `tick = TickDriver(...)` construction (using the existing `pausedRef`); rewrite `start()` to the §B8 order with `HatchService.ensureAlive(db, nowMs:)` inserted second; add `tick.stop()` to `terminate()`.

- [ ] **Step 2: Edit the menu-bar / dropdown in `AppDelegate`.** In `installMenuBar`: drop the `🐤` title (set `title = ""`), construct + store `petPanelModel`, build the unified dropdown root (new private `UnifiedDropdown` view or inline `WorkPanelRoot` rewrite) with the 276×460 `contentSize`, `PetPanelView` + `Divider` + capped/scrolled `WorkPanelView` + pinned footer; add `iconTimer` + `redrawStatusIcon()`; register the `claudegotchiPetDidChange` observer (main-hop) to call `redrawStatusIcon()` + refresh both models. Update `refreshWorkPanel()` to also refresh `petPanelModel`. Replace `WorkPanelRoot`'s `WorkPanelView(model:onOpenWorktable:)` usage with `WorkPanelView(model:)` (Task 5 removed the param) and move the open action into the footer button. Invalidate `iconTimer` in `applicationWillTerminate`.

- [ ] **Step 3: Typecheck consumed PetCore symbols.** `swift build --package-path /Users/jalen/Documents/code/claudegotchi/PetCore` for `HatchService.ensureAlive`, `PetMood.derive`, `postPetDidChange`, `Notification.Name.claudegotchiPetDidChange`. Expected: succeeds. (App target compiles in Xcode, not here.)

- [ ] **Step 4: Confirm no dangling `WorkPanelRoot`/`onOpenWorktable`.** `grep -rn "WorkPanelRoot\|onOpenWorktable" /Users/jalen/Documents/code/claudegotchi/App` — expect zero stale references (either removed or fully rewired into the footer).

- [ ] **Step 5: Commit.**
```
git add App/claudegotchi/claudegotchiApp.swift && git commit -m "Wire hatch+tick+onDeath rehatch+refresh, menu-bar pixel icon, unified pet dropdown with pinned footer"
```

Acceptance (§6/§10):
- The menu-bar item shows the code-drawn pixel pet (color NSImage), and it updates while the popover is CLOSED (icon timer + `petDidChange`).
- A mid-run midnight death→rehatch refreshes the menu-bar icon AND any open panel **immediately** (the `onDeath` closure posts `petDidChange` after `ensureAlive`), not only after the next 2-5s icon tick; the launch-time death is covered by `start()` ordering (midnight before the first icon draw).
- Opening the popover shows, top-to-bottom: pet panel, divider, a scrollable work section capped at 140px, and a pinned footer (`[打开统计]` + pause toggle) that is **hit-testable at the full 460px height with a fully-populated work section** (footer is outside the scroll).
- `start()` runs in the §B8 order; at launch with no pet, `ensureAlive` hatches before the spool pump so no `ApplyTransaction.noAlivePet` is thrown.
- The pause toggle still gates coupling and the tick re-anchors `lastTickAt` while paused.

Manual check (prose): launch with an empty DB → a pet hatches and its icon appears in the menu bar; trigger a tool call → both the icon and the open panel refresh within ~1s; force a midnight-death rehatch (or simulate via `onDeath`) and confirm the icon + open panel repaint immediately, not on the next icon tick; scroll the work section with many PRs and confirm `[打开统计]`/pause stay pinned and clickable; toggle pause and confirm decay halts.


## Chunk Q2: Stats Window (TabView host + Overview/Models/成长史/工作台)

> **Implementer note (compile-ordering, MAJOR):** do NOT delete `showWorkbench(_:)`
> in an early Q2 task while the dropdown footer still references it — that leaves
> intermediate commits non-compiling. Delete `showWorkbench` (and its
> `PRTabView`-as-standalone-window path) in the SAME task that repoints the footer
> closure to `openStats` (Task 7). Earlier Q2 tasks only ADD `StatsWindow` /
> `openStats` / the selection holder. Also: the committed tree has no auto-open
> call to remove (see Q1 note) — ignore stale line numbers (143, 202-226) and read
> the real file.

> App SwiftUI/host files only — not `swift test`-able. Tasks are file-level: each gives the file, responsibilities, the precise §0 interface it consumes, acceptance criteria, and a manual/XCUITest-in-prose check (no fabricated XCUITest code). All §0 LOCKED INTERFACES are consumed verbatim (`StatsQueries`, `PixelSpeciesCatalog`, `Level`, `PRTabFormat`); all times are unix **milliseconds**. Per §0 conventions App tasks carry no failing-test step. Commits carry NO AI attribution. Depends on Q0 (`StatsQueries`, `PixelSpeciesCatalog`, `LocalDay`, `model_usage`, `.claudegotchiPetDidChange`) and Q1 (folded `WorkPanelView` + pinned 打开统计 footer) already merged. **Task ordering is load-bearing:** Task 0 (shared `TokenFormat`) is created before its first consumer (Task 2); Task 1 (host + deterministic selection holder) before the tab views; Task 7 (wiring) reads Q1's actual output first and renames whatever open-closure Q1 left — it does NOT hard-code a presumed Q1 symbol.

### Task 0: `TokenFormat` — shared k/M compact-token helper

**Files:**
- create `App/claudegotchi/TokenFormat.swift`

This is the single shared formatting utility consumed by `OverviewTab` (Task 2), `HeatmapView` (Task 3), `ModelsTab` (Task 4), and `GrowthHistoryTab` (Task 5). It MUST exist before any of them compile — create it first. The locked `PRTabFormat.tokenLabel` (PRTabView.swift) emits **only** a `k` suffix and has no `M` branch; the spec (§Overview, line 352) requires `k`/`M`. So `compact` reuses `tokenLabel` verbatim for `0 < tokens < 1_000_000` (honoring the "reuse `PRTabFormat.tokenLabel`" wording) and adds the `M` branch itself for `tokens >= 1_000_000`. It returns a bare number string (no `" tok"` suffix); callers that want the unit append `" tok"` themselves.

- [ ] **Step 1: Write `TokenFormat.swift`.**

  ```swift
  import Foundation
  import PetCore

  enum TokenFormat {
      /// Compact token count without a unit suffix: "0", "12.3k", "1.2M".
      /// Reuses PRTabFormat.tokenLabel for the sub-million range (k); adds the
      /// M branch itself since tokenLabel has no M.
      static func compact(_ tokens: Int64) -> String {
          if tokens <= 0 { return "0" }
          if tokens >= 1_000_000 {
              return String(format: "%.1fM", Double(tokens) / 1_000_000)
          }
          let label = PRTabFormat.tokenLabel(Int(min(tokens, Int64(Int.max))))
          return label.isEmpty ? "0" : label.replacingOccurrences(of: " tok", with: "")
      }

      static func compactXP(_ xp: Int64) -> String {
          if xp >= 1_000_000 { return String(format: "%.1fM", Double(xp) / 1_000_000) }
          if xp >= 1_000 { return String(format: "%.1fk", Double(xp) / 1_000) }
          return "\(xp)"
      }
  }
  ```

  **Acceptance:** `compact(0) == "0"`, `compact(12_345) == "12.3k"`, `compact(1_234_567) == "1.2M"`, `compact(999_999) == "999.9k"`. `compactXP` follows the same k/M ladder. No `" tok"` suffix is embedded.
  **Manual (prose):** This is exercised transitively by the consuming tabs' manual checks (Task 2 asserts `12.3k`/`1.2M` cards, Task 4 asserts a 7-digit model token renders with `M`). No standalone window.

- [ ] **Step 2: Commit.**
  `git add App/claudegotchi/TokenFormat.swift && git commit -m "Add TokenFormat: shared k/M compact-token helper (k via tokenLabel, M added)"`

---

### Task 1: `StatsWindow` host + `StatsWindowView` TabView root (deterministic selection)

**Files:**
- create `App/claudegotchi/StatsWindow.swift`
- modify `App/claudegotchi/claudegotchiApp.swift`

- [ ] **Step 1: Write `StatsWindow.swift` — selection holder + deps-distributing root.**
  Tab reselection on window reuse is driven by an `@ObservedObject` selection holder (`StatsSelection: ObservableObject` with `@Published var tab: StatsTab`) **owned by `AppDelegate`** and injected into `StatsWindowView`. This is THE design — there is no `@State` seed / "may or may not re-pick up on reuse" branch. SwiftUI owns `@State` storage after first render, so mutating a stale copy of the root view would NOT update an installed view; an `ObservableObject` is the only deterministic path. On reuse the AppDelegate sets `holder.tab = tab` and SwiftUI re-drives `TabView(selection:)` via the published change.
  `StatsWindowView` distributes deps per §7: 工作台 gets `watcher`/`coordinator`/`db`/`config`; the other three get `db`. All four tab views are constructed up-front inside the `TabView` body (not lazily on `.tag`), so every tab's `.onAppear`/eager-subscribe fires on window-create regardless of `selection` (Task 6's eager-subscribe contract, §7).

  ```swift
  import SwiftUI
  import AppKit
  import GRDB
  import PetCore

  enum StatsTab: Hashable {
      case overview, models, growth, work
  }

  final class StatsSelection: ObservableObject {
      @Published var tab: StatsTab
      init(_ tab: StatsTab) { self.tab = tab }
  }

  struct StatsWindowView: View {
      @ObservedObject var selection: StatsSelection
      @ObservedObject var watcher: PRWatcher
      @ObservedObject var coordinator: FixCoordinator
      let db: DatabaseQueue
      let config: ConfigYAML

      var body: some View {
          TabView(selection: $selection.tab) {
              OverviewTab(db: db)
                  .tabItem { Text("Overview") }
                  .tag(StatsTab.overview)

              ModelsTab(db: db)
                  .tabItem { Text("Models") }
                  .tag(StatsTab.models)

              GrowthHistoryTab(db: db)
                  .tabItem { Text("成长史") }
                  .tag(StatsTab.growth)

              PRWorktableTab(watcher: watcher, coordinator: coordinator, db: db, config: config)
                  .tabItem { Text("工作台") }
                  .tag(StatsTab.work)
          }
          .frame(minWidth: 680, minHeight: 560)
          .padding(.top, 4)
      }
  }
  ```

  Note: `TabView` constructs all four tab views when `body` evaluates, so each tab's subscription/`.onAppear` semantics hold per §7. `PRWorktableTab` is the refactored PR content view from Task 6.

- [ ] **Step 2: Add `AppDelegate.openStats` reusing the single `window` ivar; remove the auto-open path.**
  In `claudegotchiApp.swift`: add a `StatsSelection?` ivar and an `openStats(_:select:)` method that lazily builds (or reuses) the single existing `window` ivar (§7 — "single `window` ivar reused"; do NOT add a second window). On reuse, set `selectionHolder?.tab = tab` (deterministic re-drive) then `makeKeyAndOrderFront` + `NSApp.activate`. On first build, construct the holder, host `StatsWindowView`, center, `isReleasedWhenClosed = false`. The window is OPENED only on 打开统计 — never auto-opened.

  ```swift
  // add to AppDelegate's stored properties:
  private var statsSelection: StatsSelection?

  // in AppDelegate
  private func openStats(_ services: AppServices, select tab: StatsTab) {
      if let win = window {
          statsSelection?.tab = tab
          win.makeKeyAndOrderFront(nil)
          NSApp.activate(ignoringOtherApps: true)
          return
      }
      let holder = StatsSelection(tab)
      statsSelection = holder
      let root = StatsWindowView(
          selection: holder,
          watcher: services.watcher,
          coordinator: services.coordinator,
          db: services.db,
          config: services.config
      )
      let win = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
          styleMask: [.titled, .closable, .miniaturizable, .resizable],
          backing: .buffered, defer: false
      )
      win.title = "claudegotchi"
      win.contentView = NSHostingView(rootView: root)
      win.isReleasedWhenClosed = false
      win.center()
      win.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      window = win
  }
  ```

  Then delete the standalone `showWorkbench(_:)` method (lines 202-226) that hosted `PRTabView` directly, and remove its call in `applicationDidFinishLaunching` (line 143). After the edit `applicationDidFinishLaunching` ends with `installMenuBar(services)` then `NSApp.setActivationPolicy(.regular)` and NO `showWorkbench`. The wiring of the footer 打开统计 closure into `openStats` is done in Task 7 (which reads Q1's actual `WorkPanelRoot`/`installMenuBar` shape first).

  Concretely, in `applicationDidFinishLaunching` apply this edit:
  ```swift
  // before:
          installMenuBar(services)
          NSApp.setActivationPolicy(.regular)
          showWorkbench(services)
  // after:
          installMenuBar(services)
          NSApp.setActivationPolicy(.regular)
  ```

  **Acceptance:** App builds. Launch shows the menu-bar item only — no window appears. Invoking 打开统计 (Task 7) opens the 680×560 window with four tabs in order Overview, Models, 成长史, 工作台. Closing then re-opening reuses the same `window` ivar (no leak; `isReleasedWhenClosed = false`). Re-invoking with a different `select:` deterministically switches the active tab via the published holder. Switching tabs is instant. No `showWorkbench` symbol remains.
  **Manual/XCUITest (prose):** Launch → assert no `NSWindow` is key at finish-launching. Invoke open on `.overview` → assert exactly one window titled "claudegotchi" with a 4-item tab bar in order Overview, Models, 成长史, 工作台, Overview selected. Close, invoke open on `.work` → assert window count stays 1 and the 工作台 tab is now selected (holder re-drive proven). Build: grep the target shows zero `showWorkbench` references.

- [ ] **Step 3: Commit.**
  `git add App/claudegotchi/StatsWindow.swift App/claudegotchi/claudegotchiApp.swift && git commit -m "Add StatsWindow host + TabView root with ObservableObject tab selection; drop auto-open"`

---

### Task 2: `OverviewTab` — 8 metric cards + embedded heatmap

**Files:**
- create `App/claudegotchi/OverviewTab.swift`

Consumes the shared `TokenFormat.compact` (Task 0) — do NOT redeclare a local compact helper here, and do NOT route through `tokenLabel` directly (it has no `M` branch). Embeds `HeatmapView` (Task 3).

- [ ] **Step 1: Write `OverviewTab.swift` — 8 cards from `StatsQueries` + `Level`.**
  Responsibilities: a SwiftUI `View` holding `let db: DatabaseQueue` and `@State` for the 8 metric values + heatmap seed. Eager load on `.onAppear` and reload on `.claudegotchiPetDidChange` (`.onReceive` the NotificationCenter publisher, hop to main, never re-query on the notification thread — reads go through `StatsQueries`/`Pet.fetchAlive`, both queue-safe). Capture `nowMs = Int64(Date().timeIntervalSince1970*1000)` and `tz = .current` once per reload and pass them to the heatmap.
  The `today*` values come from a single `try? StatsQueries.todayTotals(...)`; read `totals?.tokens ?? 0` etc. — do NOT construct a `TodayTotals(tokens:sessions:tools:)` literal. `TodayTotals` is a `public struct` whose stored properties are `public let` (§0), so it has NO cross-module public memberwise init; the literal would not compile from the App module. The optional-read form below is the committed, compilable shape.
  The 8 cards (§Overview): 总token = `lifetimeTokens` (compact); 今日token/会话/工具 = `todayTotals` fields (token compact; ints `99+` via `PRTabFormat.cappedCount`); 当前等级 = `Level.compute(xp:)` over the alive pet's xp (0 when none); 活跃天数 = `activeStreakDays`; 单日峰值token = `peakDayTokens` (compact); 宠物年龄(天) = `petAgeDays`. All fresh-install values read 0/`Lv 0`. Below the grid, embed `HeatmapView(db:weeks:nowMs:tz:)` inside the tab's `ScrollView`.

  ```swift
  import SwiftUI
  import GRDB
  import PetCore

  private struct MetricCard: View {
      let title: String
      let value: String
      var body: some View {
          VStack(alignment: .leading, spacing: 4) {
              Text(title).font(.caption).foregroundColor(.secondary)
                  .lineLimit(1).truncationMode(.tail)
              Text(value).font(.title3.monospacedDigit().weight(.semibold))
                  .lineLimit(1).minimumScaleFactor(0.6)
          }
          .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
          .padding(10)
          .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
      }
  }

  struct OverviewTab: View {
      let db: DatabaseQueue

      @State private var lifetime: Int64 = 0
      @State private var todayTokens: Int64 = 0
      @State private var todaySessions: Int = 0
      @State private var todayTools: Int = 0
      @State private var level: Int = 0
      @State private var streak: Int = 0
      @State private var peak: Int64 = 0
      @State private var ageDays: Int = 0
      @State private var heatNowMs: Int64 = 0
      @State private var heatTZ: TimeZone = .current

      private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

      var body: some View {
          ScrollView {
              VStack(alignment: .leading, spacing: 14) {
                  LazyVGrid(columns: columns, spacing: 10) {
                      MetricCard(title: "总token", value: TokenFormat.compact(lifetime))
                      MetricCard(title: "今日token", value: TokenFormat.compact(todayTokens))
                      MetricCard(title: "今日会话", value: PRTabFormat.cappedCount(todaySessions))
                      MetricCard(title: "今日工具", value: PRTabFormat.cappedCount(todayTools))
                      MetricCard(title: "当前等级", value: "Lv \(level)")
                      MetricCard(title: "活跃天数", value: "\(streak)")
                      MetricCard(title: "单日峰值token", value: TokenFormat.compact(peak))
                      MetricCard(title: "宠物年龄(天)", value: "\(ageDays)")
                  }

                  Text("贡献热力图").font(.caption).foregroundColor(.secondary)
                  HeatmapView(db: db, weeks: 53, nowMs: heatNowMs, tz: heatTZ)
              }
              .padding(16)
          }
          .onAppear(perform: reload)
          .onReceive(NotificationCenter.default.publisher(for: .claudegotchiPetDidChange)) { _ in
              DispatchQueue.main.async { reload() }
          }
      }

      private func reload() {
          let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
          let tz = TimeZone.current
          heatNowMs = nowMs
          heatTZ = tz
          lifetime = (try? StatsQueries.lifetimeTokens(db)) ?? 0
          let totals = try? StatsQueries.todayTotals(db, nowMs: nowMs, tz: tz)
          todayTokens = totals?.tokens ?? 0
          todaySessions = totals?.sessions ?? 0
          todayTools = totals?.tools ?? 0
          let xp = (try? Pet.fetchAlive(from: db))??.xp ?? 0
          level = Level.compute(xp: xp)
          streak = (try? StatsQueries.activeStreakDays(db, nowMs: nowMs, tz: tz)) ?? 0
          peak = (try? StatsQueries.peakDayTokens(db)) ?? 0
          ageDays = (try? StatsQueries.petAgeDays(db, nowMs: nowMs)) ?? 0
      }
  }
  ```

  **Acceptance:** On a seeded DB the 8 cards show correct compact tokens with both ranges — a 6-digit value renders `12.3k`, a 7-digit lifetime/peak renders `1.2M` (via `TokenFormat.compact`, NOT the k-only `tokenLabel`) — `99+`-capped today counts, `Lv N`, streak, peak, age. On fresh install every card reads `0`/`Lv 0`. Cards reflow to 4 columns and shrink text (`minimumScaleFactor`) for long token strings without clipping. Heatmap renders below. Code compiles with no `TodayTotals(...)` literal.
  **Manual (prose):** Seed a pet + a `daily_rollup` row for today with 12_345 tokens, 3 sessions, 200 tools, and a lifetime ≥ 2_000_000 → assert 今日token `12.3k`, 今日工具 `99+`, 总token shows `…M`. Wipe DB → assert all `0`/`Lv 0`.

- [ ] **Step 2: Commit.**
  `git add App/claudegotchi/OverviewTab.swift && git commit -m "Add OverviewTab: 8 metric cards from StatsQueries + Level, k/M tokens"`

---

### Task 3: `HeatmapView` — contribution heatmap

**Files:**
- create `App/claudegotchi/HeatmapView.swift`

Consumes the shared `TokenFormat.compact` (Task 0) for its tooltip — there is NO dependency on `OverviewTab`'s internals (the prior cross-file `OverviewTab.compact` coupling is removed). `TokenFormat` is created in Task 0, before this consumer.

- [ ] **Step 1: Write `HeatmapView.swift` — 53×7 grid, width-budgeted with horizontal-scroll fallback.**
  Responsibilities: `let db`, `let weeks: Int`, `let nowMs: Int64`, `let tz: TimeZone`; `@State private var tokensByDay: [String: Int64]` + `maxTokens`, loaded from `StatsQueries.heatmapSeries(db, weeks:, nowMs:, tz:)` on `.onAppear` (eager). Each cell is keyed by `LocalDay.key(unixMs:, timeZone:)` for its column/row date (§7/§8 — day cells keyed by `LocalDay.key`). Layout: ~53 columns × 7 rows; **cell 9×9, gap 2** → grid width `weeks*9 + (weeks-1)*2` ≈ 581, plus ~28px weekday gutter ≈ 609, budgeted against usable tab width ~620 (§Overview). If computed width exceeds measured available width (`GeometryReader`), wrap in a horizontal `ScrollView`; else render inline. Intensity: 4 token buckets (quantized by the seeded non-zero max) + a dim empty bucket (token 0 / absent day). Fresh install (all 0) → all cells dim. Per-cell `.help(...)` = `"<LocalDay.key> · <TokenFormat.compact> tok"`.

  ```swift
  import SwiftUI
  import GRDB
  import PetCore

  struct HeatmapView: View {
      let db: DatabaseQueue
      let weeks: Int
      let nowMs: Int64
      let tz: TimeZone

      private let cell: CGFloat = 9
      private let gap: CGFloat = 2
      private let gutter: CGFloat = 28

      @State private var tokensByDay: [String: Int64] = [:]
      @State private var maxTokens: Int64 = 0

      private var gridWidth: CGFloat {
          CGFloat(weeks) * cell + CGFloat(max(0, weeks - 1)) * gap
      }

      var body: some View {
          GeometryReader { geo in
              let available = geo.size.width - gutter
              if gridWidth <= available {
                  HStack(alignment: .top, spacing: 6) { weekdayGutter; gridBody }
              } else {
                  ScrollView(.horizontal, showsIndicators: true) {
                      HStack(alignment: .top, spacing: 6) { weekdayGutter; gridBody }
                  }
              }
          }
          .frame(height: cell * 7 + gap * 6 + 4)
          .onAppear(perform: reload)
      }

      private var weekdayGutter: some View {
          VStack(spacing: gap) {
              ForEach(0..<7, id: \.self) { row in
                  Text(["日","一","二","三","四","五","六"][row])
                      .font(.system(size: 6)).foregroundColor(.secondary)
                      .frame(width: gutter - 4, height: cell, alignment: .trailing)
              }
          }
      }

      private var gridBody: some View {
          HStack(alignment: .top, spacing: gap) {
              ForEach(0..<weeks, id: \.self) { col in
                  VStack(spacing: gap) {
                      ForEach(0..<7, id: \.self) { row in
                          cellView(weekFromEnd: col, weekday: row)
                      }
                  }
              }
          }
      }

      @ViewBuilder
      private func cellView(weekFromEnd col: Int, weekday row: Int) -> some View {
          let key = dayKey(weekFromEnd: col, weekday: row)
          let tokens = tokensByDay[key] ?? 0
          RoundedRectangle(cornerRadius: 2)
              .fill(color(for: tokens))
              .frame(width: cell, height: cell)
              .help("\(key) · \(TokenFormat.compact(tokens)) tok")
      }

      private func dayKey(weekFromEnd col: Int, weekday row: Int) -> String {
          let todayWeekday = weekdayIndex(nowMs)
          let daysBack = (weeks - 1 - col) * 7 + (todayWeekday - row)
          let ms = nowMs - Int64(daysBack) * 86_400_000
          return LocalDay.key(unixMs: ms, timeZone: tz)
      }

      private func weekdayIndex(_ ms: Int64) -> Int {
          var cal = Calendar(identifier: .gregorian)
          cal.timeZone = tz
          let date = Date(timeIntervalSince1970: Double(ms) / 1000)
          return cal.component(.weekday, from: date) - 1
      }

      private func color(for tokens: Int64) -> Color {
          guard tokens > 0, maxTokens > 0 else { return Color.secondary.opacity(0.12) }
          let q = Double(tokens) / Double(maxTokens)
          switch q {
          case ..<0.25: return Color.green.opacity(0.30)
          case ..<0.50: return Color.green.opacity(0.50)
          case ..<0.75: return Color.green.opacity(0.70)
          default:      return Color.green.opacity(0.95)
          }
      }

      private func reload() {
          let rows = (try? StatsQueries.heatmapSeries(db, weeks: weeks, nowMs: nowMs, tz: tz)) ?? []
          var map: [String: Int64] = [:]
          var mx: Int64 = 0
          for r in rows { map[r.day] = r.tokens; mx = max(mx, r.tokens) }
          tokensByDay = map
          maxTokens = mx
      }
  }
  ```

  **Acceptance:** At usable width ~620 the inline grid fits (no horizontal scroll). Narrowing the window below the grid width swaps to a horizontal `ScrollView` with all 53 columns reachable. Fresh install → every cell dim. Seeded days color into 4 buckets relative to the seeded max. Each tooltip shows its `LocalDay.key` date + a `TokenFormat.compact` token (k/M), with no compile dependency on `OverviewTab`. A same-day seeded event's cell key byte-matches today's column (consistency with the `daily_rollup` key per §8).
  **Manual/XCUITest (prose):** The §10 App check asserts total grid width (`weeks*9 + (weeks-1)*2 + gutter` ≈ 609) ≤ the measured tab content width at 680px (~620). Hover a known seeded day → tooltip date == `LocalDay.key` for that day. Resize narrow → assert the horizontal scroller appears and the rightmost (today) column is reachable.

- [ ] **Step 2: Commit.**
  `git add App/claudegotchi/HeatmapView.swift && git commit -m "Add HeatmapView: 53x7 contribution heatmap with width-budget scroll fallback"`

---

### Task 4: `ModelsTab` — per-model lifetime usage

**Files:**
- create `App/claudegotchi/ModelsTab.swift`

Consumes the shared `TokenFormat.compact` (Task 0) for token labels — not `tokenLabel` directly, so a 7-digit per-model total renders with `M`.

- [ ] **Step 1: Write `ModelsTab.swift` — `StatsQueries.modelUsage` desc, capped + 查看全部.**
  Responsibilities: `let db`; `@State private var rows: [ModelUsage]` from `StatsQueries.modelUsage(db)` (already tokens-desc per §0 `ModelUsageStore.all`), `@State private var showAll = false`. Eager load on `.onAppear` and on `.claudegotchiPetDidChange`. Header labeled **累计(lifetime)**. Each row: model name `lineLimit(1)` + `.truncationMode(.middle)` (ids like `claude-opus-4-8-20260101` are long), compact tokens (`tokensIn + tokensOut` via `TokenFormat.compact`), capped calls (`PRTabFormat.cappedCount`), and a share % of total lifetime tokens. List wrapped in `ScrollView` with `maxHeight 360`; inline cap 20 rows + a 查看全部 toggle revealing the rest. Empty state ("暂无模型数据") when no rows.

  ```swift
  import SwiftUI
  import GRDB
  import PetCore

  struct ModelsTab: View {
      let db: DatabaseQueue

      @State private var rows: [ModelUsage] = []
      @State private var showAll = false

      private let inlineCap = 20

      private var totalTokens: Int64 {
          rows.reduce(0) { $0 + $1.tokensIn + $1.tokensOut }
      }

      var body: some View {
          VStack(alignment: .leading, spacing: 8) {
              HStack {
                  Text("模型用量").font(.headline)
                  Spacer()
                  Text("累计(lifetime)").font(.caption).foregroundColor(.secondary)
              }

              if rows.isEmpty {
                  Text("暂无模型数据").font(.subheadline).foregroundColor(.secondary)
                      .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
              } else {
                  ScrollView {
                      LazyVStack(alignment: .leading, spacing: 8) {
                          ForEach(visibleRows, id: \.model) { row in modelRow(row) }
                          if rows.count > inlineCap {
                              Button(showAll ? "收起" : "查看全部 (\(rows.count))") { showAll.toggle() }
                                  .buttonStyle(.link).font(.caption)
                          }
                      }
                      .padding(.vertical, 4)
                  }
                  .frame(maxHeight: 360)
              }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .onAppear(perform: reload)
          .onReceive(NotificationCenter.default.publisher(for: .claudegotchiPetDidChange)) { _ in
              DispatchQueue.main.async { reload() }
          }
      }

      private var visibleRows: [ModelUsage] {
          showAll ? rows : Array(rows.prefix(inlineCap))
      }

      @ViewBuilder
      private func modelRow(_ row: ModelUsage) -> some View {
          let tokens = row.tokensIn + row.tokensOut
          let share = totalTokens > 0 ? Double(tokens) / Double(totalTokens) * 100 : 0
          VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 8) {
                  Text(row.model).lineLimit(1).truncationMode(.middle)
                  Spacer()
                  Text(TokenFormat.compact(tokens) + " tok")
                      .font(.caption.monospacedDigit()).foregroundColor(.secondary)
              }
              HStack(spacing: 8) {
                  Text("\(PRTabFormat.cappedCount(Int(min(row.calls, Int64(Int.max))))) 次调用")
                      .font(.caption2).foregroundColor(.secondary)
                  Spacer()
                  Text(String(format: "%.1f%%", share))
                      .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
              }
          }
      }

      private func reload() {
          rows = (try? StatsQueries.modelUsage(db)) ?? []
      }
  }
  ```

  **Acceptance:** Rows render tokens-desc; long model ids truncate in the middle (head + tail visible). A model with a 7-digit lifetime total shows `…M tok` (via `TokenFormat.compact`, not k-only). Share % sums to ~100. With >20 models only 20 show until 查看全部 expands. Empty DB → "暂无模型数据". List scrolls within `maxHeight 360`; window stays 680 wide regardless of model count.
  **Manual (prose):** Seed `model_usage` with 25 models of varying tokens (one ≥ 2_000_000) → assert default shows 20 + a "查看全部 (25)" link; tapping reveals all 25; top row is the largest-token model and shows `…M tok`; a 26-char model id shows `claude…0101`-style middle truncation.

- [ ] **Step 2: Commit.**
  `git add App/claudegotchi/ModelsTab.swift && git commit -m "Add ModelsTab: per-model lifetime usage, share %, cap 20 + 查看全部"`

---

### Task 5: `GrowthHistoryTab` — stage progress + memorial

**Files:**
- create `App/claudegotchi/GrowthHistoryTab.swift`

Consumes the shared `TokenFormat.compactXP` (Task 0). **Catalog invariant:** `PixelSpeciesCatalog` stage lists are ascending by `minXp` (the catalog is code-constant per §A1, authored monotonic), so "the first stage whose `minXp > xp`" is the immediate next stage. A guard still rejects any seed where `next <= pet.xp` (shows "已达最终阶段") so the progress bar's `total` is always strictly greater than `value` and never clamps oddly.

- [ ] **Step 1: Write `GrowthHistoryTab.swift` — current-stage progress + memorial from `StatsQueries.growthHistory`.**
  Responsibilities: `let db`; `@State private var alive: Pet?`, `history: [GrowthEntry]`, `showAll`. Eager load on `.onAppear` + `.claudegotchiPetDidChange`. Current section: resolve `PixelSpeciesCatalog.def(species)`; current stage = `PixelSpeciesCatalog.stage(id: species, xp: pet.xp)`; next stage = first `def.stages` entry with `minXp > xp` (`minXp` is `Int` per §0, convert via `Int64`). Render a `xp → next minXp` progress bar ONLY when `next > pet.xp`; otherwise "已达最终阶段". Species label = `def?.nameZh ?? species`. No alive pet → "暂无存活宠物". Memorial: `StatsQueries.growthHistory(db, limit: 20)`, newest first; each entry shows species `nameZh` (raw id for unknown species), optional `name` in quotes, born/died dates (ms→Date via `/1000`), compact xp. Pin per §成长史: inline cap 20, `maxHeight 160`, `ScrollView`, 查看全部 toggle. Empty → "还没有逝去的宠物".

  ```swift
  import SwiftUI
  import GRDB
  import PetCore

  struct GrowthHistoryTab: View {
      let db: DatabaseQueue

      @State private var alive: Pet?
      @State private var history: [GrowthEntry] = []
      @State private var showAll = false

      private let inlineCap = 20

      var body: some View {
          VStack(alignment: .leading, spacing: 12) {
              currentStageSection
              Divider()
              memorialSection
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .onAppear(perform: reload)
          .onReceive(NotificationCenter.default.publisher(for: .claudegotchiPetDidChange)) { _ in
              DispatchQueue.main.async { reload() }
          }
      }

      @ViewBuilder
      private var currentStageSection: some View {
          if let pet = alive {
              let def = PixelSpeciesCatalog.def(pet.species)
              let stageId = PixelSpeciesCatalog.stage(id: pet.species, xp: pet.xp)
              let nextMinXp = def?.stages
                  .first { Int64($0.minXp) > pet.xp }
                  .map { Int64($0.minXp) }
              VStack(alignment: .leading, spacing: 6) {
                  HStack {
                      Text(def?.nameZh ?? pet.species).font(.headline)
                      Text("· \(stageId)").font(.subheadline).foregroundColor(.secondary)
                      Spacer()
                      Text("XP \(TokenFormat.compactXP(pet.xp))").font(.caption).foregroundColor(.secondary)
                  }
                  if let next = nextMinXp, next > pet.xp {
                      ProgressView(value: Double(pet.xp), total: Double(next))
                      Text("距下一阶段 \(TokenFormat.compactXP(next - pet.xp))")
                          .font(.caption2).foregroundColor(.secondary)
                  } else {
                      Text("已达最终阶段").font(.caption).foregroundColor(.secondary)
                  }
              }
          } else {
              Text("暂无存活宠物").font(.subheadline).foregroundColor(.secondary)
          }
      }

      @ViewBuilder
      private var memorialSection: some View {
          Text("成长史").font(.caption.bold()).foregroundColor(.secondary)
          if history.isEmpty {
              Text("还没有逝去的宠物").font(.caption).foregroundColor(.secondary)
          } else {
              ScrollView {
                  LazyVStack(alignment: .leading, spacing: 8) {
                      ForEach(visibleHistory.indices, id: \.self) { i in entryRow(visibleHistory[i]) }
                      if history.count > inlineCap {
                          Button(showAll ? "收起" : "查看全部 (\(history.count))") { showAll.toggle() }
                              .buttonStyle(.link).font(.caption)
                      }
                  }
                  .padding(.vertical, 2)
              }
              .frame(maxHeight: 160)
          }
      }

      private var visibleHistory: [GrowthEntry] {
          showAll ? history : Array(history.prefix(inlineCap))
      }

      @ViewBuilder
      private func entryRow(_ e: GrowthEntry) -> some View {
          let label = PixelSpeciesCatalog.def(e.species)?.nameZh ?? e.species
          HStack(spacing: 8) {
              Text(label).lineLimit(1).truncationMode(.middle)
              if let name = e.name, !name.isEmpty {
                  Text("「\(name)」").font(.caption).foregroundColor(.secondary)
                      .lineLimit(1).truncationMode(.tail)
              }
              Spacer()
              Text(Self.dateLabel(e.bornMs) + (e.diedMs.map { " – " + Self.dateLabel($0) } ?? " – 在世"))
                  .font(.caption2).foregroundColor(.secondary)
              Text("XP \(TokenFormat.compactXP(e.xp))").font(.caption2.monospacedDigit()).foregroundColor(.secondary)
          }
      }

      static func dateLabel(_ ms: Int64) -> String {
          let f = DateFormatter()
          f.dateFormat = "yyyy-MM-dd"
          return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
      }

      private func reload() {
          alive = (try? Pet.fetchAlive(from: db)) ?? nil
          history = (try? StatsQueries.growthHistory(db, limit: inlineCap)) ?? []
      }
  }
  ```

  `PixelSpeciesDef.stages` is `[(id: String, minXp: Int)]` per §0 — `minXp` is `Int`, compared/converted via `Int64($0.minXp)`. The `next > pet.xp` guard keeps `ProgressView`'s `total` strictly greater than `value` for every seed; combined with the ascending-`minXp` catalog invariant, the selected `next` is the immediate next stage and the bar is mathematically valid. `growthHistory(limit:)` caps at the SQL `LIMIT` (here 20), so the 查看全部 link appears only when more than `inlineCap` were fetched; if a deeper memorial is desired later, raise `limit:` while keeping `inlineCap` at 20.

  **Acceptance:** Current stage shows catalog `nameZh` (e.g. 青蛙) + stage id + an `xp → next minXp` progress bar that never overflows (`total > value` guaranteed by the guard); at the top stage shows "已达最终阶段". Memorial lists dead pets newest-first with species `nameZh` (raw id only for unknown species), name in quotes when set, born–died dates, compact XP. No alive pet → "暂无存活宠物". No dead pets → "还没有逝去的宠物". Memorial scrolls within `maxHeight 160`.
  **Manual (prose):** Seed an alive `frog` at xp just below stage-2 `minXp` → assert progress bar near-full and a small "距下一阶段". Seed a `frog` at xp above the largest non-final threshold → assert "已达最终阶段" and NO progress bar. Seed 3 dead pets → assert newest `death_at` first, each labeled by `nameZh`. Seed a pet with an unknown species id → assert it falls back to the raw id.

- [ ] **Step 2: Commit.**
  `git add App/claudegotchi/GrowthHistoryTab.swift && git commit -m "Add GrowthHistoryTab: current-stage progress (guarded) + memorial timeline"`

---

### Task 6: Refactor `PRTabView` body into an embeddable 工作台 tab content view

**Files:**
- modify `App/claudegotchi/PRTabView.swift`

- [ ] **Step 1: Rename `PRTabView` → `PRWorktableTab` (eager subscribe, no standalone-window assumptions).**
  Keep ALL existing PR behavior (`PRStatusChip`, `PRTabFormat`, list/history/log-viewer, `reload`/`reloadHistory`, `startFix`, error banners) unchanged. The current `PRTabView` already subscribes via `.onReceive(watcher.$snapshot)`, `.onReceive(coordinator.$progress)`, and `.onAppear { reload() }` — that IS the eager-subscribe contract (§7); since `StatsWindowView` (Task 1) constructs all four tabs up-front, these fire on window-create regardless of which tab is selected. There are no window-only assumptions in the current body (no `@Environment(\.dismiss)` at the tab root; the `LogViewer` sheet stays). The init still takes `watcher`/`coordinator`/`db`/`config`, so `StatsWindowView` compiles. Keep `extension FixJob: Identifiable {}` and `LogViewer` in this file.

  Concretely, change the declaration (PRTabView.swift line 89):
  ```swift
  // before:
  struct PRTabView: View {
  // after:
  struct PRWorktableTab: View {
  ```
  and update the body's outer frame (currently `.frame(maxWidth: .infinity, alignment: .leading)`, line 117) to fill the tab:
  ```swift
      var body: some View {
          VStack(alignment: .leading, spacing: 8) {
              header
              content
              Divider()
              fixHistorySection
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(16)
          .onReceive(watcher.$snapshot) { _ in reload() }
          .onReceive(coordinator.$progress) { _ in reloadHistory() }
          .onAppear { reload() }
          .sheet(item: $logViewerJob) { job in LogViewer(job: job) }
      }
  ```
  Leave every other member unchanged. The only other `PRTabView` reference (the old `showWorkbench` in `claudegotchiApp.swift`) was already deleted in Task 1.

  **Acceptance:** App builds with no remaining `PRTabView` references. The 工作台 tab shows the full PR list, error banners, fix history, log viewer sheet — identical behavior to before. Because the tab is constructed on window-create, opening on Overview and immediately switching to 工作台 shows already-loaded PRs (no first-selection load lag); `watcher.$snapshot` updates refresh the list while the tab is unselected.
  **Manual/XCUITest (prose):** Open stats on Overview, switch to 工作台 → assert PR rows are already present (no spinner) and a 修复 button is hit-testable. Trigger a `watcher.snapshot` change while on Overview, then switch to 工作台 → assert the list reflects the change (eager subscribe held while unselected).

- [ ] **Step 2: Commit.**
  `git add App/claudegotchi/PRTabView.swift && git commit -m "Refactor PRTabView into embeddable PRWorktableTab for the 工作台 tab"`

---

### Task 7: Wire the 打开统计 footer affordance to `openStats`

**Files:**
- modify `App/claudegotchi/claudegotchiApp.swift`

This task is robust to Q1's actual output and does NOT hard-code a presumed Q1 symbol name. Per §6 the dropdown has a **single** open affordance — the pinned-footer `[打开统计]` button (Q1 removed `WorkPanelView`'s internal `打开工作台` button). The current repo (pre-Q1) still has `onOpenWorktable` calling `showWorkbench`; Q1 reshapes the footer. Step 1 reads whatever Q1 actually produced first, then rewires it.

- [ ] **Step 1: Read the post-Q1 `installMenuBar` + `WorkPanelRoot`, then rewire the open closure to `openStats`.**
  Procedure (do these in order; the exact symbol depends on Q1's merged shape):
  1. Read `claudegotchiApp.swift`'s `installMenuBar(_:)` and `WorkPanelRoot` as they exist after Q1. Identify the single open-affordance closure Q1 left on the pinned footer — it may be named `onOpenStats`, `onOpenWorktable`, `onOpen`, or a footer `Button` action inline in `WorkPanelRoot`. Do NOT assume a particular parameter name.
  2. Route that closure through `self.openStats(services, select: .overview)` (the footer opens on Overview per §6 — "打开统计" → Overview). Close the popover first.
  3. If Q1's closure passes a `StatsTab` argument (i.e. Q1 already defined `onOpenStats: (StatsTab) -> Void`), forward it: `self?.openStats(services, select: $0)`. If Q1 left a zero-arg closure, call with `.overview`.

  - If Q1 left a zero-arg footer closure (e.g. still named `onOpenWorktable`), apply:
    ```swift
    // inside installMenuBar's NSHostingController rootView, the footer open closure:
                onOpenWorktable: { [weak self] in
                    self?.popover?.performClose(nil)
                    self?.openStats(services, select: .overview)
                }
    ```
    and confirm `WorkPanelRoot`'s `var onOpenWorktable: () -> Void` is unchanged (the rename to `onOpenStats` is optional and only needed if Q1 already renamed it).
  - If Q1 already renamed the footer closure to `onOpenStats: (StatsTab) -> Void`, apply:
    ```swift
                onOpenStats: { [weak self] tab in
                    self?.popover?.performClose(nil)
                    self?.openStats(services, select: tab)
                }
    ```
    and pass `.overview` from the footer `[打开统计]` button inside `WorkPanelRoot` (e.g. `Button("打开统计") { onOpenStats(.overview) }`).

  Verify no `showWorkbench` symbol or `PRTabView` reference remains anywhere in the target after the edit (Task 1 removed the method and call; Task 6 renamed the type). Confirm the single `window` ivar is now solely the stats window.

  **Acceptance:** From the menu-bar dropdown, the pinned-footer `[打开统计]` opens the stats window on the Overview tab and closes the popover first. Re-invoking reuses the single window (and re-drives the tab via the `StatsSelection` holder from Task 1). No code path auto-opens the window at launch. Build has no `showWorkbench` symbol and no `PRTabView` reference. The Edit applied is the one matching Q1's actual footer-closure shape (zero-arg vs `StatsTab`-arg) — not a blindly hard-coded block.
  **Manual (prose):** Click the menu-bar item → dropdown appears, no window. Click `[打开统计]` in the footer → window opens on Overview, popover closes. Close window, click `[打开统计]` again → window reopens (single window, no leak). Quit + relaunch → no window auto-appears.

- [ ] **Step 2: Commit.**
  `git add App/claudegotchi/claudegotchiApp.swift && git commit -m "Wire 打开统计 footer to StatsWindow open on Overview"`


## Chunk Q3: Hooks install + e2e

> Depends on Q0 (`HooksInstaller`, `Event.EventType` raw values, the PascalCase→snake_case event map §B1/§B2, **and the §B1 stdin bridge that reads the hook JSON payload from stdin** — the helper currently in the tree (`HookHelper/ClaudegotchiHook.swift`) only reads `--json` argv and drops stdin), Q1 (`AppServices` wired, dropdown shell), and Q2 (`StatsWindow`). All App SwiftUI/script/e2e tasks below are **file-level** (not `swift test`-able per §0 conventions). Type signatures from §0 LOCKED INTERFACES are used verbatim. Times are unix milliseconds. Commits carry NO AI attribution.

### Task 1: Ship the hook helper inside the app bundle (project.yml)

Files:
- modify `/Users/jalen/Documents/code/claudegotchi/App/project.yml`

- [ ] **Step 1: Add the `claudegotchi-hook` product as an app dependency.** In `App/project.yml`, under `targets.claudegotchi.dependencies`, add a second `- package: PetCore` entry with `product: claudegotchi-hook` (the executable product already declared in `PetCore/Package.swift`). This makes xcodegen build the helper as part of the app target's build graph so it is available to copy.

- [ ] **Step 2: Add a Copy-Files build phase into `Contents/Helpers/`.** Under `targets.claudegotchi`, add a `postBuildScripts` run-script phase named `Embed claudegotchi-hook` whose body copies the freshly built helper into the app's `Helpers` dir and code-signs it for the hardened runtime:
  ```yaml
      postBuildScripts:
        - name: Embed claudegotchi-hook
          basedOnDependencyAnalysis: false
          script: |
            set -euo pipefail
            HELPERS="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
            mkdir -p "$HELPERS"
            SRC="${BUILT_PRODUCTS_DIR}/claudegotchi-hook"
            cp -f "$SRC" "$HELPERS/claudegotchi-hook"
            chmod 0755 "$HELPERS/claudegotchi-hook"
            if [ "${ENABLE_HARDENED_RUNTIME:-}" = "YES" ] || [ "${CODE_SIGNING_ALLOWED:-}" = "YES" ]; then
              codesign --force --options runtime \
                --sign "${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}" \
                "$HELPERS/claudegotchi-hook"
            fi
  ```
  Rationale (load-bearing, §B3): the app uses `ENABLE_HARDENED_RUNTIME=true`, so the embedded helper must carry a valid signature with the runtime option, otherwise Claude Code (a *different* process) cannot exec it.

- [ ] **Step 3: Regenerate the Xcode project and build.** Run:
  - `cd /Users/jalen/Documents/code/claudegotchi/App && xcodegen generate`
  - `cd /Users/jalen/Documents/code/claudegotchi/App && xcodebuild -project claudegotchi.xcodeproj -scheme claudegotchi -configuration Debug -derivedDataPath build build`
  - **Acceptance:** build succeeds; the embedded helper exists and is signed:
    - `ls -l "$(find /Users/jalen/Documents/code/claudegotchi/App/build -path '*claudegotchi.app/Contents/Helpers/claudegotchi-hook' -print -quit)"` shows mode `-rwxr-xr-x`.
    - `codesign -dv "$(find /Users/jalen/Documents/code/claudegotchi/App/build -path '*Contents/Helpers/claudegotchi-hook' -print -quit)" 2>&1` prints `flags=0x10000(runtime)` (hardened runtime present) and no "code object is not signed" error.

- [ ] **Step 4: Commit.**
  - `cd /Users/jalen/Documents/code/claudegotchi && git add App/project.yml && git commit -m "Embed code-signed claudegotchi-hook helper into app bundle Contents/Helpers"`

### Task 2: HooksInstallView — install/uninstall button + status (App)

Files:
- create `/Users/jalen/Documents/code/claudegotchi/App/claudegotchi/HooksInstallView.swift`

**Responsibilities.** A SwiftUI view + a small `@MainActor` view-model that drive Q0's `HooksInstaller`. It owns the **stable-path copy** of the helper (the bundle→support-dir staging, chmod, quarantine clear) and surfaces install errors. It is **not** `swift test`-able; it is file-level with manual acceptance. This task creates only the self-contained `HooksInstallView.swift`; **presentation wiring lives in the Q2 chunk** (the 钩子设置 button + `.sheet` host belong with `StatsWindow.swift`), so this task touches no Q2/Q1 file and its commit stages only the new view (plus `project.yml` if a per-file source entry is required — `sources` is folder-based, so normally no change).

**Precise interface implemented.** The view consumes ONLY these locked Q0 signatures (do not re-derive them):
```swift
HooksInstaller.install(settingsPath: URL, hookBinaryPath: String, nowISO: String) throws
HooksInstaller.uninstall(settingsPath: URL) throws
HooksInstaller.status(settingsPath: URL) throws -> HookInstallStatus   // .notInstalled / .installed / .partiallyInstalled
```
Constants the view defines locally:
- `settingsPath` = `~/.claude/settings.json` (`FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")`).
- stable bin path = `~/Library/Application Support/claudegotchi/bin/claudegotchi-hook` (build from `applicationSupportDirectory` + `claudegotchi/bin/claudegotchi-hook`); pass its `.path` as `hookBinaryPath`.
- bundled source = `Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/claudegotchi-hook")` (do NOT use `Bundle.main.url(forResource:)` — the helper lives under `Contents/Helpers`, not `Resources`).
- `nowISO` = `ISO8601DateFormatter().string(from: Date())`.

**Install flow (in the view-model, ordered, §B3):**
1. Guard the bundled source exists (`FileManager.default.fileExists`). If missing → set status label to a disabled-with-reason state ("helper 缺失，请重装 app") and return; the install button is disabled.
2. `mkdir -p` the `…/claudegotchi/bin` dir.
3. Copy bundled helper → stable bin (remove existing first so `copyItem` doesn't throw).
4. `chmod 0755` via `FileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath:)`.
5. Clear quarantine: call `xattr -d com.apple.quarantine <path>` through a `Process` (ignore non-zero exit: the attribute may be absent). This is load-bearing: without it Gatekeeper blocks Claude Code from exec'ing the copied helper, which "always exit 0" does not cover.
6. `HooksInstaller.install(settingsPath:hookBinaryPath:nowISO:)` with the stable bin path.
7. Re-read `HooksInstaller.status(...)` and update the published status.

**Uninstall flow:** `HooksInstaller.uninstall(settingsPath:)` then remove the stable bin file (`try? FileManager.default.removeItem(at:)`), then refresh status.

**Error surfacing (§9):** wrap each flow in `do/catch`; on a thrown error (corrupt settings, etc.) publish the localized message into a status label and keep the file intact (the installer already refuses to write corrupt JSON). If the bundled helper is missing, the **install button is disabled** with the reason shown.

Complete file:
```swift
import SwiftUI
import AppKit
import PetCore

@MainActor
final class HooksInstallModel: ObservableObject {
    @Published private(set) var status: HookInstallStatus = .notInstalled
    @Published private(set) var statusText: String = "未安装"
    @Published private(set) var helperAvailable: Bool = true
    @Published private(set) var lastError: String?

    private let settingsURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    private let stableBinURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("claudegotchi/bin/claudegotchi-hook")

    private var bundledHelperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/claudegotchi-hook")
    }

    func refresh() {
        helperAvailable = FileManager.default.fileExists(atPath: bundledHelperURL.path)
        do {
            status = try HooksInstaller.status(settingsPath: settingsURL)
        } catch {
            status = .notInstalled
            lastError = "读取 settings.json 失败：\(error.localizedDescription)"
        }
        statusText = label(for: status)
        if !helperAvailable { statusText = "helper 缺失，请重装 app" }
    }

    func install() {
        lastError = nil
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundledHelperURL.path) else {
            helperAvailable = false
            statusText = "helper 缺失，请重装 app"
            return
        }
        do {
            try fm.createDirectory(at: stableBinURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: stableBinURL.path) {
                try fm.removeItem(at: stableBinURL)
            }
            try fm.copyItem(at: bundledHelperURL, to: stableBinURL)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stableBinURL.path)
            clearQuarantine(stableBinURL)

            let nowISO = ISO8601DateFormatter().string(from: Date())
            try HooksInstaller.install(settingsPath: settingsURL,
                                       hookBinaryPath: stableBinURL.path,
                                       nowISO: nowISO)
        } catch {
            lastError = "安装失败：\(error.localizedDescription)"
        }
        refresh()
    }

    func uninstall() {
        lastError = nil
        do {
            try HooksInstaller.uninstall(settingsPath: settingsURL)
        } catch {
            lastError = "卸载失败：\(error.localizedDescription)"
        }
        try? FileManager.default.removeItem(at: stableBinURL)
        refresh()
    }

    private func clearQuarantine(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-d", "com.apple.quarantine", url.path]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    private func label(for status: HookInstallStatus) -> String {
        switch status {
        case .installed: return "已安装"
        case .partiallyInstalled: return "部分安装（建议重新安装）"
        case .notInstalled: return "未安装"
        }
    }
}

struct HooksInstallView: View {
    @StateObject private var model = HooksInstallModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Claude Code 钩子")
                    .font(.headline)
                Spacer()
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(model.status == .installed ? .green : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Text("安装后，Claude Code 的使用会喂养宠物。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(model.status == .notInstalled ? "安装钩子" : "重新安装") {
                    model.install()
                }
                .disabled(!model.helperAvailable)

                Button("卸载") { model.uninstall() }
                    .disabled(model.status == .notInstalled)
            }

            if let err = model.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { model.refresh() }
    }
}
```

- [ ] **Step 1: Create the file** at the path above with the complete contents.
- [ ] **Step 2: Regenerate + build.** `cd /Users/jalen/Documents/code/claudegotchi/App && xcodegen generate && xcodebuild -project claudegotchi.xcodeproj -scheme claudegotchi -configuration Debug -derivedDataPath build build`. **Acceptance:** compiles; the view references only the three locked `HooksInstaller` symbols and `HookInstallStatus`.
- [ ] **Step 3: Manual smoke (no real ~/.claude mutation in dev).** Verify visually that the button is disabled when the bundled helper is absent by renaming `Contents/Helpers/claudegotchi-hook` in a built `.app` and relaunching — the status label reads "helper 缺失，请重装 app" and 安装 is disabled. Restore the helper after. (Live install/uninstall against real `~/.claude` is exercised in Task 4.)
- [ ] **Step 4: Commit (self-contained view only — no Q2 file staged here).** Presentation wiring (the 钩子设置 button + `.sheet`) is added in the Q2 chunk alongside `StatsWindow.swift`; this task does not touch it, so the commit stages only the new file (add `App/project.yml` to the `git add` ONLY if Step 2 required a `project.yml` change — with folder-based `sources` it normally does not):
  - `cd /Users/jalen/Documents/code/claudegotchi && git add App/claudegotchi/HooksInstallView.swift && git commit -m "Add HooksInstallView: install/uninstall hooks, stage helper to stable bin, clear quarantine"`

### Task 3: scripts/uninstall.sh

Files:
- create `/Users/jalen/Documents/code/claudegotchi/scripts/uninstall.sh`

**Responsibilities.** Remove the `_claudegotchi`-tagged hook leaves from `~/.claude/settings.json` (3-level prune mirroring `HooksInstaller.uninstall`'s tag semantics — never touch foreign groups/untagged-same-path entries) and remove the support dir. Document a Homebrew cask `zap` note as a comment. Uses only POSIX sh + `python3` (present on macOS) for the JSON prune so it does not require the app binary.

Complete file:
```sh
#!/bin/sh
# claudegotchi uninstaller — removes tagged hooks from ~/.claude/settings.json
# and the support dir. Foreign hook entries are left intact (tag-matched prune).
#
# Homebrew cask note: a cask should additionally `zap trash:` the support dir:
#   zap trash: [
#     "~/Library/Application Support/claudegotchi",
#   ]
# and run this script (or replicate the settings.json prune) in `uninstall script:`.
set -eu

SETTINGS="${HOME}/.claude/settings.json"
SUPPORT="${HOME}/Library/Application Support/claudegotchi"

if [ -f "$SETTINGS" ]; then
  python3 - "$SETTINGS" <<'PY'
import json, sys, os, tempfile
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except (json.JSONDecodeError, OSError):
    sys.exit(0)  # leave a corrupt/missing file intact

hooks = data.get("hooks")
if isinstance(hooks, dict):
    for event in list(hooks.keys()):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        kept_groups = []
        for group in groups:
            leaves = group.get("hooks") if isinstance(group, dict) else None
            if isinstance(leaves, list):
                leaves[:] = [h for h in leaves
                             if not (isinstance(h, dict) and h.get("_claudegotchi") is True)]
                if not leaves:
                    continue  # drop now-empty group
            kept_groups.append(group)
        if kept_groups:
            hooks[event] = kept_groups
        else:
            del hooks[event]
    if not hooks:
        del data["hooks"]

d = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(dir=d)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print("pruned claudegotchi hooks from", path)
PY
else
  echo "no settings.json at $SETTINGS (nothing to prune)"
fi

if [ -d "$SUPPORT" ]; then
  rm -rf "$SUPPORT"
  echo "removed $SUPPORT"
fi

echo "claudegotchi hooks uninstalled."
```

- [ ] **Step 1: Create the file** with the contents above.
- [ ] **Step 2: Make it executable + verify the prune is tag-matched and atomic.** Run a throwaway check against a temp settings file (NOT real `~/.claude`):
  - `chmod +x /Users/jalen/Documents/code/claudegotchi/scripts/uninstall.sh`
  - Create `/tmp/cg-settings.json` with one `_claudegotchi`-tagged leaf in a shared `PreToolUse` group plus one foreign leaf, then run the embedded python against it: `python3 /Users/jalen/Documents/code/claudegotchi/scripts/uninstall.sh` after temporarily setting `SETTINGS=/tmp/cg-settings.json` (or copy the inline `python3 - "$SETTINGS"` block and run it against the temp path). **Acceptance:** tagged leaf removed; foreign leaf and an untagged same-path leaf preserved; now-empty group/event keys dropped; file remains valid JSON (written via temp + `os.replace`).
- [ ] **Step 3: Commit.**
  - `cd /Users/jalen/Documents/code/claudegotchi && git add scripts/uninstall.sh && git commit -m "Add scripts/uninstall.sh: tag-matched hook prune + support-dir removal + cask zap note"`

### Task 4: Q3 end-to-end with a real headless Claude session (documented)

Files:
- create `/Users/jalen/Documents/code/claudegotchi/docs/specs/notes/q3-hooks-e2e-verification.md`

**Responsibilities.** A live, manual end-to-end that proves the whole ingestion path with a **real** Claude Code session and a real exec of the copied helper, then records results. Not `swift test`-able (needs the GUI app, `claude` CLI, Gatekeeper). The artifact is the notes file capturing each command + observed output.

> Schema note (load-bearing — verified against `Database.swift` v1/v2/v3, `DailyRollup.swift`, `Pet.swift`): the `daily_rollup` table has columns `date, sessions, messages, tokens_in, tokens_out, tools_used` — there is **no** `tokens` column; the "today token" figure is the **sum** `tokens_in + tokens_out`. The `pet` table has `fullness, stamina, intimacy, xp` — there is **no** `satiety`/`energy` column (the 饱食/体力 UI labels map to `fullness`/`stamina`); `last_event_at` is added by the §B6 v3 migration this chunk depends on. The spool line is written by `Event.encodeJSON()`, whose key is `sessionId` (camelCase), not `session_id`. Use the real column/field names below verbatim.

**Procedure to execute and transcribe into the notes file:**

- [ ] **Step 1: Build + launch the signed app.**
  - `cd /Users/jalen/Documents/code/claudegotchi/App && xcodegen generate && xcodebuild -project claudegotchi.xcodeproj -scheme claudegotchi -configuration Debug -derivedDataPath build build`
  - `open "$(find /Users/jalen/Documents/code/claudegotchi/App/build -name claudegotchi.app -print -quit)"`
  - Record: app launches, menu-bar item renders the pixel pet (no `🐤` fallback), dropdown shows the pet panel.

- [ ] **Step 2: Install hooks from the UI.** Open the 钩子设置 sheet → click 安装钩子. Record:
  - status label flips to 已安装;
  - `cat ~/.claude/settings.json` shows 5 `_claudegotchi`-tagged leaves (`session_start`/`stop`/`pre_tool_use`/`post_tool_use`/`notification`), each command a single-quoted absolute path to `~/Library/Application Support/claudegotchi/bin/claudegotchi-hook`;
  - `ls -l ~/Library/Application\ Support/claudegotchi/bin/claudegotchi-hook` is mode `0755`;
  - `xattr ~/Library/Application\ Support/claudegotchi/bin/claudegotchi-hook` does NOT list `com.apple.quarantine`;
  - `codesign -dv …/bin/claudegotchi-hook 2>&1` shows `flags=…(runtime)`.

- [ ] **Step 3: Confirm a *different* process can exec the copied helper AND that the stdin payload is parsed (Gatekeeper + §B1 stdin bridge).** Simulate Claude Code's exec out-of-band, piping the payload to **stdin** (Claude Code delivers hook JSON on stdin, not via `--json`; this exercises the Q0 §B1 stdin bridge):
  - `BIN="$HOME/Library/Application Support/claudegotchi/bin/claudegotchi-hook"`
  - `BEFORE=$(wc -l < "$HOME/Library/Application Support/claudegotchi/spool.jsonl" 2>/dev/null || echo 0)`
  - `echo '{"session_id":"q3","cwd":"/tmp"}' | "$BIN" session_start; echo "exit=$?"`
  - `tail -1 "$HOME/Library/Application Support/claudegotchi/spool.jsonl"`
  - **Acceptance (all required):**
    1. `exit=0`.
    2. The spool line count grew by exactly 1 (`wc -l` after > `$BEFORE`).
    3. **The piped payload was actually parsed (not silently dropped):** `tail -1 "$HOME/Library/Application Support/claudegotchi/spool.jsonl" | grep '"sessionId":"q3"'` matches, AND the same line contains `"cwd":"/tmp"`. If these grep checks fail while `exit=0`, the §B1 stdin bridge regressed (the shipped helper reads only `--json` and drops stdin) — Q0 must be fixed before this acceptance can pass; do not record a pass on exit-0 alone.
    4. (Gatekeeper) no "cannot be opened because the developer cannot be verified" dialog appeared; if it did, quarantine/signing failed — re-check Task 1 Step 2 and Task 2 install flow.

- [ ] **Step 4: Run a REAL headless Claude session in a scratch dir.**
  - `mkdir -p /tmp/cg-e2e && cd /tmp/cg-e2e && claude -p "Create a file hello.txt containing the word hi, then stop." --permission-mode acceptEdits`
  - Record the exit and that the spool grows: `wc -l ~/Library/Application\ Support/claudegotchi/spool.jsonl` before vs after; confirm lines for `session_start`, `pre_tool_use`/`post_tool_use`, `stop` (each line carries a `"sessionId"` matching the live session).

- [ ] **Step 5: Confirm DB aggregates populated.** Query the live SQLite (read-only) and transcribe results. **Use the real column names** (no `tokens`, no `satiety`/`energy`):
  - `sqlite3 "$HOME/Library/Application Support/claudegotchi/pet.sqlite" "SELECT date, tokens_in, tokens_out, sessions, tools_used FROM daily_rollup ORDER BY date DESC LIMIT 3;"`
  - `sqlite3 "$HOME/Library/Application Support/claudegotchi/pet.sqlite" "SELECT model, tokens_in, tokens_out, calls FROM model_usage ORDER BY (tokens_in+tokens_out) DESC;"`
  - `sqlite3 "$HOME/Library/Application Support/claudegotchi/pet.sqlite" "SELECT fullness, stamina, intimacy, xp, last_event_at FROM pet WHERE death_at IS NULL;"`
  - **Acceptance:** for today's `daily_rollup` row, `(tokens_in + tokens_out) > 0` AND `sessions > 0` AND `tools_used > 0` (DailyRollup writes `tokens_in`/`tokens_out` separately; the "today token" total is their sum); `model_usage` has ≥1 row if the payload carried `model` (else documented empty); `pet.last_event_at` > 0 and pet stats (`fullness`/`stamina`/`intimacy`/`xp`) moved from their hatch values (`fullness=100, stamina=100, intimacy=50, xp=0`).

- [ ] **Step 6: Confirm the UI reflects it.** Open the dropdown: 今日 token/会话/工具 row shows nonzero compact values (the 今日token figure equals the summed `tokens_in + tokens_out` from Step 5, NOT a single `tokens` column); activity line shows the last tool or 空闲. Open 打开统计 → Overview cards (总token/今日token/…) nonzero, where 今日token matches `tokens_in + tokens_out`; Models tab lists the model (or empty state if no `model`). Record screenshots or a textual description.

- [ ] **Step 7: Write the notes file.** Create `docs/specs/notes/q3-hooks-e2e-verification.md` with: environment (macOS version, `claude --version`, app build commit), the exact commands run, their captured outputs (spool deltas, the `tail -1 … | grep '"sessionId":"q3"'` result from Step 3, the three `sqlite3` result sets, signing/quarantine checks), pass/fail per acceptance bullet, and any deviations. This file IS the deliverable for the e2e.

- [ ] **Step 8: Uninstall cleanly to prove reversibility.** Click 卸载 in the UI (and separately run `scripts/uninstall.sh` against a *copy* of settings to validate parity). Record: `~/.claude/settings.json` has zero `_claudegotchi` leaves, foreign hooks (if any pre-existed) untouched, and the stable bin removed. Append the result to the notes file.

- [ ] **Step 9: Commit.**
  - `cd /Users/jalen/Documents/code/claudegotchi && git add docs/specs/notes/q3-hooks-e2e-verification.md && git commit -m "Record Q3 hooks install + headless Claude e2e verification results"`
