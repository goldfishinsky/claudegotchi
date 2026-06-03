# claudegotchi — Pet Status & Stats UI + Hook Ingestion Design

- Status: Draft (revision 3, post multi-lens review + verification round)
- Brainstorming date: 2026-06-03
- Author: jalen
- Extends: `docs/specs/2026-04-30-claudegotchi-design.md` (base game) and
  `docs/specs/2026-06-02-pr-watch-autofix-design.md` (PR feature, already built)

## 1. Summary

The app renders only the PR-watch/auto-fix UI today; the pet + token data layer
exists in PetCore but is never shown and never fed real data (no hooks wired, no
pet hatched, no decay tick). This project delivers the base-game experience in
two parts and folds the existing PR UI into one unified shell.

- **Part B — Ingestion (make data real):** bridge Claude Code hook payloads
  (stdin) into the spool, one-click install hooks into `~/.claude/settings.json`,
  hatch a pet on launch (and re-hatch on death), drive decay over time, and
  aggregate per-model usage.
- **Part A — Pet & Stats UI (show it):** a code-drawn pixel pet in the menu bar;
  a dropdown combining the pet status panel with the existing work section; and a
  680px stats window with tabs **Overview / Models / 成长史 / 工作台** (the
  existing PR view becomes the 工作台 tab).

No new third-party deps. Pixel art is generated in code (no PNG assets, no
species YAML/registry at runtime). Pet visuals are placeholders pending real art.

## 2. Goals / Non-Goals

### Goals
1. Real Claude Code usage feeds the pet: tokens → 饱食/智慧, tool calls → 体力,
   sessions tracked, `daily_rollup` + `model_usage` populated.
2. A pet is always alive (hatched on first launch; re-hatched after death).
3. Stats drift over time (decay tick); the pet sleeps after inactivity.
4. From the menu bar: see the pet, its 4 stats, level, today's token/session/tool
   totals, and what Claude is doing now.
5. A 680px dashboard: 8 headline metrics, a contribution heatmap, per-model
   usage, and pet 成长史 — plus the existing 工作台 as a tab.
6. One-click, merge-safe, atomic, reversible hook installation.

### Non-Goals (v1)
Real sprite-art sheets; sound/notifications/achievements; decay-tuning UI;
multi-pet/rename UI; retention/pruning beyond base §3; changing PR behavior
(only re-hosting its view); per-day model breakdown (model_usage is
lifetime-cumulative).

## 3. Architecture

Extends the existing `AppServices` composition root (`claudegotchiApp.swift`),
reusing the single shared `DatabaseQueue` + `EventApplier` (§3 shared-instance
invariant) and the existing `pausedProvider`. PR drivers untouched.

```
launch (AppServices.start, ORDERED §B7):
  coordinator.reconcileOnLaunch
  → HatchService.ensureAlive()         (hatch if no alive pet)
  → spool.pump → spool.startWatching
  → watcher.start
  → midnight.start  (onDeath = HatchService.ensureAlive)   ← death→rehatch
  → tick.start                          (TickDriver, NEW)

Claude Code hooks ─stdin payload─▶ claudegotchi-hook <snake_type> ─▶ spool.jsonl
  ─▶ SpoolWatcher ─▶ ApplyTransaction (pet stats, daily_rollup, model_usage,
     last_event_at, watermark) ─▶ Pet (SQLite) ─▶ post petDidChange

menu-bar (AppDelegate timer → PixelPet.renderToNSImage) ──click──▶ dropdown
        ├ PetPanelView (pixel pet + 4 bars + level + today + activity)
        └ WorkPanelView (existing) ; pinned footer: [打开统计] + pause toggle
   "打开统计" ─▶ StatsWindow (TabView: Overview │ Models │ 成长史 │ 工作台)
```

### Layering
- **PetCore (pure / testable):** `PixelSpeciesCatalog` (id→{nameZh, stage
  thresholds, frames}), `PixelSprite` frames, `PetMood` (pure), `TickCheckpoint`
  (pure, clock-injected), `StatsQueries` (DAO, now+tz injected), `HooksInstaller`
  (injected settings path + now), `HatchService` logic, `ModelUsage` record,
  `LocalDay.key`, `PetClick.allowed`, hook stdin parsing, v3 migration.
- **App (timers + SwiftUI):** `TickDriver`, `PixelPetView` (+menu-bar NSImage
  driver), `PetPanelView`/`PetPanelModel`, `StatsWindow` + tab views, hooks
  install button. Folds `WorkPanelView`/`PRTabView` into the unified shell.

## 4. Part B — Ingestion

### B1. Hook stdin bridge + event type (`ClaudegotchiHook`)
- **Type comes from argv** (unchanged): `claudegotchi-hook <snake_token>` where
  `<snake_token>` ∈ EventType raw values (`session_start`, `stop`,
  `pre_tool_use`, `post_tool_use`, `notification`). The installer (§B2) writes a
  distinct command per event using the PascalCase→snake_case map
  (`SessionStart→session_start`, `Stop→stop`, `PreToolUse→pre_tool_use`,
  `PostToolUse→post_tool_use`, `Notification→notification`). The helper keeps
  `EventType(rawValue: argv[1]) ?? .notification` — it does NOT read
  `hook_event_name` from stdin.
- **Payload comes from stdin:** if `--json` is absent, read all of stdin and
  parse it as the Claude Code payload object; extract `session_id`, `cwd`,
  `tool_name`→`tool`, `model`, token fields. The `--json` argv path is retained
  for tests/back-compat. The key mapping is centralized and unit-tested with the
  captured payload (`docs/specs/notes/p0-hook-payload-verification.md`).
- **Always exit 0** (even on empty/malformed stdin → emit a type-only event), so
  a stale registration can never block or error a Claude tool call.
- Extend `rejectsRawType` to reject BOTH `pr_` and `pet_` prefixes (a forged
  `pet_click` does not share the `pr_` prefix today and would otherwise be
  accepted as `.notification`).

### B2. `HooksInstaller` (one-click, merge-safe, atomic)
PetCore type over an **injectable settings path** (default
`~/.claude/settings.json`) and an **injected now** (for the backup suffix), so it
is unit-testable against a temp file with no real-home access.

**Exact JSON shape written** (Claude Code matcher-group form):
```jsonc
"hooks": {
  "PreToolUse":  [ { "matcher": "*", "hooks": [ { "type": "command", "command": "<quoted-cmd> pre_tool_use",  "_claudegotchi": true } ] } ],
  "PostToolUse": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "<quoted-cmd> post_tool_use", "_claudegotchi": true } ] } ],
  "SessionStart":[ { "hooks": [ { "type": "command", "command": "<quoted-cmd> session_start", "_claudegotchi": true } ] } ],
  "Stop":        [ { "hooks": [ { "type": "command", "command": "<quoted-cmd> stop", "_claudegotchi": true } ] } ],
  "Notification":[ { "hooks": [ { "type": "command", "command": "<quoted-cmd> notification", "_claudegotchi": true } ] } ]
}
```
- `_claudegotchi: true` lives on the **leaf** (`{type,command}`) object — install,
  idempotency, and uninstall all key off this tag (NOT the command path, so a
  user's own command at the same path is never touched). Claude Code ignores
  unknown keys.
- `<quoted-cmd>` = the **shell-quoted absolute path** of the installed helper
  (see §B3 stable location). Single-quote the path (escape embedded quotes) so a
  path with spaces re-parses to the intended argv. PreToolUse/PostToolUse carry
  `"matcher": "*"`; SessionStart/Stop/Notification omit matcher.
- **Idempotent:** if a leaf tagged `_claudegotchi` already exists for an event,
  update its command (path may change across versions) rather than appending a
  duplicate; never duplicate. The JSON block above is **illustration of a
  fresh file only** — on an existing `settings.json` the installer **appends**
  our tagged group to the existing `hooks.<Event>` array (and merges into the
  top-level object), **never replacing** the user's foreign groups/keys.
- **Atomic write:** serialize to a temp file in the same directory, fsync, then
  `rename(2)`/`FileManager.replaceItemAt` over `settings.json`. Take a backup
  (`settings.json.bak-<injected-ISO>`) BEFORE the rename. Corrupt/unparseable
  existing JSON → refuse to write, return a clear error, leave the file intact.
- **`uninstall()` — 3-level prune, tag-matched:** remove our tagged leaf from a
  possibly-shared `hooks[]`; remove the matcher group only if its `hooks[]`
  became empty; remove the event key only if its array became empty. Foreign
  groups/leaves/untagged-same-path entries are left intact.
- **`status()`:** `notInstalled / installed / partiallyInstalled` (by counting
  tagged leaves vs the 5 expected).

### B3. Helper ship + install location (stable, bundle-decoupled)
**Ship:** the app target today depends only on `PetCore` and embeds no helper, so
there is nothing to install. Fix in `App/project.yml` (xcodegen): add the
`claudegotchi-hook` executable as an app-target dependency with a **Copy-Files
build phase into `Contents/Helpers/`** (or stage `swift build -c release
--product claudegotchi-hook` as a bundled resource). The app uses
`ENABLE_HARDENED_RUNTIME=true`, so the copied helper must carry a **valid code
signature** (signed standalone, or strip + re-sign on copy).
**Install:** on first install, copy the helper from `Bundle.main` (`Contents/Helpers/`)
to the stable path `~/Library/Application Support/claudegotchi/bin/claudegotchi-hook`
(decoupled from the `.app`, so deleting the app can't strand the hook command),
set the executable bit `0755`, and **clear `com.apple.quarantine`** on the copied
file (else a *different* process — Claude Code — exec'ing it is Gatekeeper-blocked,
which "always exit 0" does NOT cover). The command string is byte-stable across
reinstalls. Combined with "always exit 0" (§B1) a missing/stale registration is
harmless. Ship `scripts/uninstall.sh` (remove tagged hooks + support dir) + a
Homebrew cask `zap` note. **Q3 e2e must verify Claude Code can actually exec the
copied helper on a clean machine** (signature + quarantine + permission bit).

### B4. `HatchService`
On launch and on death, if `Pet.fetchAlive == nil`, hatch from
`PixelSpeciesCatalog.ids` (code constants — NO registry/YAML) →
`Pet.fresh(species:at:)` → insert (sets `lastTickAt`, `last_event_at` = now).
The existing `SpeciesRoulette.pick(from registry:using:)` requires a
`SpeciesRegistry` (the abandoned runtime-YAML path); **add a new pure overload
`pick(fromIds:using:) -> String`** (id-only) and use it here. Under v1 the
registry-based `pick(from:)` + `SpeciesRegistry.load` are **dead** — do NOT
re-wire `HatchService` to `SpeciesRegistry.load` (that would reintroduce the
killed runtime-source blocker). Idempotent (no-op if an alive pet exists).
PetCore holds the pure pick+construct; App calls it from `AppServices.start` and
`MidnightDriver.onDeath` (§B8). After a rehatch the menu-bar icon + open panels
refresh via `petDidChange` (§B6).

### B5. Drivers: `TickCheckpoint` (pure) + `TickDriver` (App)
**Time-unit contract (single base = unix milliseconds).** `Pet.lastTickAt`,
`last_event_at`, and `hibernationSince` are all unix **ms** (e.g. `Pet.fresh`
sets `lastTickAt = ts` in ms; `EventApplier` sets `hibernationSince = event.ts`
in ms; `ApplyTransaction`/`MidnightCheckpoint` divide stored time by 1000 to make
a `Date`). So the pure checkpoint takes **`nowMs`** (NOT `nowSeconds`):
`TickCheckpoint.run(pet:nowMs:lastEventMs:config:) -> TickResult` where
`TickResult = { pet, emit: TickEmit? }`, `TickEmit ∈ {.hibernateStart,
.hibernateEnd}`.
Rules (pure, `FixedClock`/fixed-ms tested):
- `elapsedSeconds = max(0, nowMs - pet.lastTickAt) / 1000.0` (clamp skew; ms→s
  only for `Decay.apply`/`Hibernation`, which take seconds).
- If `hibernationSince == nil` and `Hibernation.shouldEnter(nowSeconds: nowMs/1000,
  lastEventSeconds: lastEventMs/1000, config:)` → set `hibernationSince = nowMs`,
  emit `.hibernateStart`, do NOT decay.
- If `hibernationSince != nil` and `lastEventMs > hibernationSince` (a genuinely
  newer event) → clear `hibernationSince`, re-anchor `lastTickAt = nowMs`, emit
  `.hibernateEnd`.
- Else if awake → `Decay.apply(pet:, elapsedSeconds:, config:)`.
- Always set `pet.lastTickAt = nowMs` on the returned pet.

**Wake re-anchor also lives in `EventApplier.sessionStart`:** a real
`session_start` clears `hibernationSince` *before* the next tick, so
`TickCheckpoint` would otherwise see an awake pet with a stale `lastTickAt` and
bill the whole sleep span as one decay burst. The `sessionStart` arm therefore
**also sets `lastTickAt = event.ts`** when it clears `hibernationSince`.
`TickCheckpoint`'s own wake branch is a backstop for non-sessionStart wakes.
A normal session_start wake thus does NOT log a `hibernate_end` event — decay is
**live** via `lastTickAt`, never replayed from hibernate spans, so the missing
event is informational only.

`TickDriver` (App, ~60s `Timer`, high tolerance):
- Uses a **unix-epoch-ms `nowMs` provider** (default `Int64(Date().timeIntervalSince1970*1000)`,
  injected for tests) — **NOT `MachClock`** (whose `nowSeconds()` is uptime, not
  epoch, and would corrupt `lastTickAt` for every reader).
- **Reads `pausedProvider()`; while paused, no-op decay AND re-anchor
  `lastTickAt = nowMs`** so the paused span produces no spike (ApplyTransaction's
  paused gate does not cover direct tick writes).
- Reads `lastEventMs` from `pet.last_event_at` (§B6).
- Persists the returned pet via the shared `DatabaseQueue`; if `emit`, routes a
  synthetic `hibernate_start`/`hibernate_end` via `ApplyTransaction.process(event:)`
  with id `tick:<petId>:<emit>:<nowMs>` (the ms component prevents same-day
  UNIQUE-collision drops). Posts `petDidChange` (§B6) **after** the write returns.

### B6. `last_event_at`, `model_usage`, `petDidChange` (v3 migration)
Migration `v3_pet_stats`, registered AFTER `v2_pr_watch` (v1/v2 unchanged):
```sql
ALTER TABLE pet ADD COLUMN last_event_at INTEGER NOT NULL DEFAULT 0;
CREATE TABLE model_usage (
  model TEXT PRIMARY KEY,
  tokens_in INTEGER NOT NULL DEFAULT 0,
  tokens_out INTEGER NOT NULL DEFAULT 0,
  calls INTEGER NOT NULL DEFAULT 0
);
```
`ApplyTransaction.process(jsonLine:)`, **after** the event-INSERT
duplicate-short-circuit (same position as `daily_rollup`, so a duplicate spool
line / startup replay banks once):
- updates `pet.last_event_at = max(last_event_at, event.ts)`;
- on `post_tool_use` with `event.model != nil`, upserts `model_usage` (counters
  `tokens_in/tokens_out/calls += …`). Synthetic PR/tick events skip both, like
  `daily_rollup`. `model_usage` is **lifetime-cumulative** (no day dimension).

**`petDidChange` notification:** define `Notification.Name("claudegotchi.petDidChange")`
posted by `ApplyTransaction`, `TickDriver`, and the `MidnightDriver`. **Hard rule
for all three: post AFTER `db.write(...)` RETURNS — never from inside the
`db.write {}` closure.** GRDB's `DatabaseQueue` is strictly non-reentrant, and
`NotificationCenter.post` is synchronous same-thread, so a synchronous observer
re-querying the DB from inside the write closure would fatal-error/deadlock the
single shared queue. On the spool path the returning thread is already main
(`SpoolWatcher` dispatches FSEvents to `.main`); `TickDriver`/`MidnightDriver`
post on their own thread. **Observers must hop to the main actor for UI and must
never synchronously re-query the DB on the notification thread.** `PetPanelModel`
and the stats models observe it; the AppDelegate 5s timer remains a fallback.
(No NotificationCenter usage exists today — this introduces exactly one name.)

### B7. `pet_click` interaction
`config.eventCosts.petClickIntimacy` (2.0) and
`config.thresholds.petClickCooldownSeconds` (60) **already exist** — do not
re-add. Additions:
- `EventType.petClick = "pet_click"` (the `EventApplier.apply` switch has no
  `default`, so this is a **forced** edit — without the arm the build fails);
  arm: `intimacy += config.eventCosts.petClickIntimacy` (clamped). `DailyRollup`'s
  `default: break` absorbs it (no rollup); synthetic so it skips model_usage.
- Cooldown source of truth is the **DB** (`MAX(event.ts) WHERE type='pet_click'`
  for the alive pet), so it survives relaunch. Pure predicate
  `PetClick.allowed(lastClickMs:nowMs:cooldownSeconds:) -> Bool`; the UI calls it
  with an observed now and emits `pet_click` via `process(event:)` when allowed.
- intimacy add is non-idempotent under replay (like `stop`/`pr_approved`) —
  accepted and documented.

### B8. `AppServices.start()` ordering (pinned)
`reconcileOnLaunch → HatchService.ensureAlive → spool.pump → spool.startWatching
→ watcher.start → midnight.start → tick.start`. `midnight` is constructed with
`onDeath = { HatchService.ensureAlive(...) }`; since `midnight.start()` runs
`runIfDue()` immediately (can kill at launch), `onDeath` rehatches synchronously
so no window leaves zero alive pets. `ApplyTransaction.aliveOrThrow` stays the
guard (unreachable post-hatch).

## 5. Part A — Pixel Pet Rendering

### A1. `PixelSpeciesCatalog` + `PixelSprite` (PetCore, code constants)
Replaces runtime species YAML/registry. For each launch species (`frog`,
`slime`, `cat`, `dragon`): `{ id, nameZh, stages:[{id, minXp}], frames:[String:
[PixelFrame]] }` where a `PixelFrame` is a small grid (16×16 of `UInt8` palette
indices, 0 = transparent) over a shared palette. Animations: `idle`, `happy`,
`sick`, `sleeping`. Pure; snapshot-tested (grid dims, frame counts, palette
indices in range). `catalog[id]` resolves name/stages/frames; unknown id →
generic block + raw id (stated fallback). The existing `Species`/`SpeciesRegistry`
model, `SpeciesRoulette.pick(from:)`, their tests, and the `Fixtures/species`
YAML resource are **retained as unused-but-tested legacy** in v1 (not deleted —
out of scope); only the new `pick(fromIds:using:)` overload (§B4) is live.

### A2. `PetMood` (PetCore, pure)
`PetMood.derive(pet:pressure:) -> PetVisual { stage, animation, overlay }`:
`hibernationSince != nil` → `sleeping`; `DeathWindow.isLowDay`-style 2-of-3 low →
`sick`; else `idle`. Stage from xp via `catalog[species].stages.minXp`. `overlay`
from `WorkPressure.tier` (calm/busy/stressed → none/focus/sweat). **`happy` is
App-side transient animation** (triggered by `petDidChange` on a positive
event), NOT part of the pure table — keeping `derive` a pure function of
`{pet, pressure}` only. Table-tested.

### A3. `PixelPetView` + menu-bar icon driver (App)
`PixelPetView` (SwiftUI `Canvas`) draws the current frame as filled rects,
advances frames on a display timer (~800ms idle cadence), draws the overlay, and
exposes `renderToNSImage(size:) -> NSImage` (color, ~18px). Tap → `pet_click`
(cooldown-gated via `PetClick.allowed`). **The menu-bar status item is redrawn by
an AppDelegate-owned timer** (independent of the popover being open): periodically
(or on `petDidChange`) it calls `renderToNSImage` and assigns
`statusItem.button.image`, replacing the `🐤` title. At 16–22px the mood overlay
is reduced to a single corner dot (like the PR attention badge), not the full
focus/sweat art.

## 6. Part A — Dropdown Panel

The popover `contentSize` grows to **276 × 460** with a pinned footer. Layout
budget (sums to ≤460):
- **Pet panel** (`PetPanelView`, ~200px): pixel pet (`PixelPetView`, ~96) +
  4 stat bars (~80) + level/species line (~24). Tappable pet (intimacy).
- **Today + activity** (~44): 今日 tokens(compact `12.3k`) / 会话(`99+`) /
  工具(`99+`) on one row; an activity line below — `lineLimit(1)` +
  `.truncationMode(.middle)` for long/MCP tool names.
- Divider.
- **Work section** (~140): `WorkPanelView` **wrapped in an outer
  `frame(maxHeight: 140)` + internal `ScrollView`**, since the view's intrinsic
  height is ~218px (header + content maxHeight 120 + running line + its own
  button + spacing/padding) and `NSPopover` hard-clips to `contentSize`.
  **Remove `WorkPanelView`'s internal `打开工作台` button** — it duplicates the
  footer entry; the footer is the single open affordance.
- **Pinned footer** (~40, OUTSIDE any scroll, always reachable): `[打开统计]` +
  pause toggle. The §10 App check asserts the footer is hit-testable at 460px
  with a fully-populated work section.

Stats: 饱食 🍞 / 体力 💪 / 亲密 💖 (0–100 bars, low→red) and 智慧 🌟 as
`Lv N` + xp-to-next from `Level`. **Current activity** is sourced from
`SessionTracker.activeSessions(...).lastTool` (persisted, thread-safe) plus the
hibernation flag — NOT `EventApplier.pending` (private, in-memory, cross-thread).
Precedence: `💤 休眠中` (hibernating) > `Claude 正在 <tool>…` (active session) >
`空闲`. Today's totals render `0/0/0` when no `daily_rollup` row exists
(`今日会话` = `sessions`, `今日工具` = `tools_used`). Empty/loading states per
project rules.

## 7. Part A — Stats Window (680px)

`StatsWindow` = an AppDelegate-owned `NSWindow` (single `window` ivar reused;
`isReleasedWhenClosed = false`; **opened on "打开统计"**, not auto-opened)
hosting `StatsWindowView(deps)` with a `TabView`. The root view receives all deps
and distributes: **工作台** gets `watcher`/`coordinator`/`db`/`config`; the other
tabs get `StatsQueries`/`db`. Each tab **eagerly subscribes** to its data on
window-create (not lazily on first selection) so loading/error/empty states are
correct while unselected.

### Overview
- **8 headline metric cards:** 总token(lifetime) · 今日token · 今日会话 ·
  今日工具 · 当前等级 · 活跃天数(streak) · 单日峰值token · 宠物年龄(天). Tokens
  compact (`k`/`M`, reuse `PRTabFormat.tokenLabel`); small ints `99+`. Zero on
  fresh install.
- **Contribution heatmap** (`HeatmapView`): ~53 weeks × 7 days. Budget against
  the **usable tab content width** (≈ 680 − window/TabView insets ~16/side −
  weekday gutter ~28 ≈ **~620**), NOT the raw 680. **Cell 9×9, gap 2** → 53
  columns = 53×9 + 52×2 = 581 + gutter 28 ≈ 609 ≤ ~620 (fits; last column has no
  trailing gap). If a measured layout still overflows, fall back to a constrained
  horizontal `ScrollView`. 4 token-intensity buckets (quantized) + an empty (dim)
  bucket; all-dim on fresh install; per-cell tooltip (date + tokens). Day cells
  keyed by `LocalDay.key` (§8). The §10 App check asserts total grid width ≤ the
  measured tab content width.

### Models
Per-model lifetime usage from `model_usage`, sorted by tokens desc: model name
(`lineLimit(1)` + `.truncationMode(.middle)` — ids like
`claude-opus-4-8-20260101` are long), compact tokens/calls, share %. List
`maxHeight` + scroll; inline cap 20 rows + "查看全部" (version proliferation).
Labeled **累计(lifetime)**. Empty state when no model data.

### 成长史
Current pet stage progress (xp → next-stage `minXp`) + a memorial list of past
pets from `StatsQueries.growthHistory()` (`Pet.fetchAllDead` capped with SQL
`LIMIT`). Pin exactly as 工作台 does: inline cap 20, `maxHeight 160`, scroll,
"查看全部". Compact xp; species label = `catalog[species].nameZh` else raw id.
Newest first.

### `StatsQueries` (PetCore, deterministic)
Every function needing "now"/a local day takes **`nowMs` + `timeZone`** (tests
pin `TimeZone(identifier:"UTC")` + fixed `nowMs` over a seeded DB):
`lifetimeTokens`, `todayTotals(nowMs:tz:)`, `activeStreakDays(nowMs:tz:)`
(consecutive `LocalDay.key` day-indices ending at today's key, integer day math —
seeded-gap + DST test asserts an exact value), `peakDayTokens`,
`heatmapSeries(weeks:nowMs:tz:)`, `modelUsage()`, `petAgeDays(nowMs:)`,
`growthHistory(limit:)`. Day keys come from the **shared `LocalDay.key`** (§8).

## 8. Shared local-day key

Extract `LocalDay.key(unixMs:timeZone:) -> String` (the `yyyy-MM-dd`
`DateFormatter`, `en_US_POSIX`, logic currently inlined in
`ApplyTransaction.localDate`). `ApplyTransaction` is refactored to call it (with
`TimeZone.current`); `StatsQueries` and `HeatmapView` call it with the injected
tz. This guarantees a read's "today" key byte-matches the `daily_rollup` key a
same-day event wrote. A test asserts `StatsQueries` today-key == the rollup key
produced by a same-day event.

A companion **`LocalDay.dayIndex(unixMs:timeZone:) -> Int`** gives a contiguous
integer day number for adjacency math, so `activeStreakDays` works in a single
representation: convert each present `daily_rollup` `yyyy-MM-dd` back to a
`dayIndex` (parse via the same `en_US_POSIX` formatter + injected tz) and count
the run of consecutive indices ending at today's index. The DST test pins the tz
so the parse↔index round-trip is exercised. (`MidnightCheckpoint.localDayKey`
integer math is for death-window counting and is left as-is; rollup/stats
consistency uses `LocalDay`.)

## 9. Error Handling
| Condition | Behavior |
|---|---|
| settings.json missing | create on install (atomic) |
| settings.json corrupt JSON | refuse to write; clear error; file intact; backup kept |
| concurrent settings.json edit | read-modify-rename is last-writer-wins (backup holds pre-rename content); v1 accepts this, optionally flock a `settings.lock` sibling |
| helper binary missing | install button disabled w/ reason |
| stale hook after app delete | helper at stable path + always exit 0 → harmless; uninstall.sh / cask zap |
| hook stdin empty/malformed | emit type-only event, exit 0 |
| no alive pet at launch/death | HatchService.ensureAlive hatches/rehatches |
| model field absent | model_usage not updated (no-op) |
| clock skew (elapsed<0) | TickCheckpoint clamps elapsed ≥0 |
| paused | TickDriver no-ops decay + re-anchors lastTickAt; activity hidden |
| asleep | decay frozen; panel 💤; wake re-anchors lastTickAt |
| empty data (fresh) | every view explicit zero/empty state |
| duplicate spool line / replay | event-INSERT dedup; model_usage/rollup/last_event_at after short-circuit bank once |

## 10. Testing
**PetCore (swift test):** `HooksInstallerTests` (fresh/existing/corrupt/idempotent/
re-install-path-change/uninstall-3-level: shared-group, sibling foreign group,
untagged-same-path-must-not-remove; injected temp path + injected now; emitted
command re-parses with a space-containing path), `StatsQueriesTests` (seeded DB,
UTC, fixed now: lifetime/today/streak-with-gap+DST/peak/heatmap/modelUsage/age/
history), `LocalDayTests` (today-key == rollup key), `ModelUsageTests` (upsert;
double-process banks once; PR/tick events skip), `TickCheckpointTests`
(FixedClock: elapsed<0 clamp, decay, hibernate-enter/exit boundary, paused
re-anchor), `HatchServiceTests`, `PetMoodTests` (sleeping/sick/idle + overlay
table), `PixelSpriteTests` (grid/frame/palette invariants; catalog ids),
`PetClickTests` (cooldown predicate), hook stdin-parse + argv-type + always-exit-0
+ pet_/pr_ reject, v3 migration test.
**App (file-level + manual):** Canvas render + NSImage menu-bar driver, dropdown
height/pinned-footer, click cooldown, StatsWindow tab hosting + eager subscribe,
heatmap fit.

## 11. Phasing
- **Q0 — backend:** §B1 stdin/type; v3 migration (`last_event_at`+`model_usage`);
  `LocalDay.key` extraction; `model_usage` rollup; `EventType.petClick`+arm+
  `PetClick.allowed`; `HatchService`; `TickCheckpoint`; `StatsQueries`;
  `HooksInstaller`; `PixelSpeciesCatalog`+`PixelSprite`; `PetMood`. All
  PetCore/HookHelper; swift test green.
- **Q1 — pet dropdown + drivers:** `PixelPetView` (+menu-bar NSImage driver,
  replace 🐤); `PetPanelView`/`PetPanelModel`; click-intimacy; fold `WorkPanelView`
  + pinned footer; wire `HatchService`/`TickDriver`/`onDeath`/`petDidChange` into
  `AppServices` per §B8.
- **Q2 — stats window:** `StatsWindow` TabView; Overview (8 cards + `HeatmapView`);
  Models; 成长史; re-host `PRTabView` as 工作台 tab (eager subscribe); "打开统计".
- **Q3 — hooks install + e2e:** install/uninstall button + status; copy helper to
  stable path; `uninstall.sh`; real-data end-to-end (install hooks, run a real
  Claude session, confirm tokens/stats move + model_usage populates).

## 12. Open Questions / Risks
1. **Pixel art is placeholder** — code-drawn; real sprite sheets later.
2. **Claude Code hook payload keys / settings schema** — centralized in §B1/§B2;
   a fixture test asserts the written JSON parses under Claude Code's documented
   matcher-group schema; re-checked in Q3 e2e.
3. **Menu-bar icon visibility** — notch/overflow may hide the status item (OS-level);
   a narrow color NSImage cannot defeat overflow.
4. **Models tab depends on `event.model`** in payloads; absent → empty, not error.
