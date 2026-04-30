# claudegotchi — Design

- Status: Draft (post-review revision 1)
- Brainstorming date: 2026-04-28 ~ 2026-04-30
- Author: jalen

## 1. Product Summary

**claudegotchi** is a macOS menu-bar 8-bit pixel Tamagotchi that mirrors and
reacts to your Claude Code activity. The pet eats tokens to grow, gets tired
during long sessions, and bonds with you when you click it. Neglect it and it
will actually die — at which point a new egg of a randomly-chosen species
hatches and you start over.

### Surfaces

- **Menu-bar icon** (16-22px) — always present, animates to reflect state
- **Dropdown panel** (260px wide) — pet sprite, four stat bars, current Claude
  activity, today's totals, level
- **Stats window** (680px wide) — full usage dashboard: 8 headline metrics +
  contribution heatmap + pet evolution timeline + tabs for Overview / Models /
  Pet 成长史

### Core loop

```
Use Claude → pet gains 饱食 / XP / 体力 strain
Pet idle → all decaying stats drift down
User click pet → 亲密 +2 (60s cooldown)
Time passes → tick decay
   → if 2 of 3 decaying stats ≤ 20 at 5 consecutive midnights → death
   → if no events for 72h → hibernation (decay frozen, pet sleeps)
Death → memorial → new egg → random species → repeat
```

### Stats (4-axis)

| Stat | Symbol | Decays? | Driven by |
|---|---|---|---|
| 饱食度 (fullness) | 🍞 | yes | Claude tokens consumed |
| 体力 (stamina) | 💪 | regenerates passively, drained by tool calls | session duration / tool calls |
| 亲密度 (intimacy) | 💖 | yes | user clicking the pet |
| 智慧/XP (wisdom) | 🌟 | **never decays** | total tokens (~tokens/200) |

## 2. System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  macOS App (Swift / AppKit / SwiftUI)                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │ MenuBarItem  │  │ DropdownView │  │ StatsWindow  │       │
│  │ (16px sprite)│  │ (260px panel)│  │ (680px sheet)│       │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘       │
│         └──────────────────┴──────────────────┘              │
│                            │                                  │
│  ┌────────────────────── PetCore ──────────────────────────┐ │
│  │  GameEngine    │ tick(): decay/death/evolution checks   │ │
│  │  StatsStore    │ {饱食, 体力, 亲密, 智慧/lvl/xp, age}    │ │
│  │  SpeciesRegistry │ YAML-loaded species + sprite assets   │ │
│  │  EventApplier  │ applies events idempotently by id       │ │
│  │  Persistence   │ SQLite at Application Support           │ │
│  └─────────────────────────┬────────────────────────────────┘ │
│                            │                                  │
│  ┌────────────────── SpoolWatcher ─────────────────────────┐ │
│  │  Watches ~/Library/.../spool.jsonl via FSEvents         │ │
│  │  Drains new lines → EventApplier (dedup by event_id)    │ │
│  └─────────────────────────┬────────────────────────────────┘ │
└────────────────────────────┼─────────────────────────────────┘
                             │ append-only JSONL
                             │
┌────────────────────────────┴────────────────────────────────┐
│  ~/.claude/settings.json hooks                                │
│  SessionStart / Stop / PreToolUse / PostToolUse / etc.        │
│  → exec: claudegotchi-hook <event-name>                       │
│         (writes one JSON line to spool.jsonl, exits)          │
└─────────────────────────────────────────────────────────────┘
```

### Modules

- **`claudegotchi.app`** — main GUI app, menu bar resident, owns game engine
  and persistence
- **`claudegotchi-hook`** — small CLI binary (< 1 MB) invoked by Claude Code
  hooks; appends one JSON line to a spool file with `O_APPEND` (atomic on
  POSIX) and exits in milliseconds. Never blocks on app being running.
- **Species assets** — YAML definitions + sprite sheet PNGs bundled with the app
  (overridable from `~/Library/Application Support/claudegotchi/species/`)

### Why spool-file + FSEvents instead of UDS

- The hook helper has zero dependency on the app being running. If the app is
  closed, events accumulate in the spool and get drained on next launch.
- FSEvents on macOS gives sub-100ms latency notifications on file changes — fast
  enough for animation responsiveness without the failure modes of UDS
  (refused connections, partial writes, race conditions).
- Single source of truth eliminates the dedup-across-channels problem.
- Crash recovery is the same code path as normal operation: read from spool,
  apply, persist.

### Why this split

- Claude Code hooks are fire-and-forget subprocess calls — they cannot hold
  state, so a tiny helper binary is necessary to capture events
- The main app is independent: if hooks aren't installed, the pet still runs
  (it'll just go hungry without events)

### File system layout

```
~/Library/Application Support/claudegotchi/
├── db.sqlite              # primary persistence (see §3)
├── config.yaml            # tunable constants (decay rates, thresholds)
├── spool.jsonl            # append-only event spool, drained by SpoolWatcher
├── log/
│   └── claudegotchi.log   # rotating diagnostic log (10 MB, 3 files)
└── species/               # user-installed species (overrides bundled)
    └── <id>/
        ├── species.yaml
        └── sprite.png
```

## 3. Data Model

### SQLite schema

Database at `~/Library/Application Support/claudegotchi/db.sqlite`.

```sql
-- All pets ever, alive and dead. Alive: death_at IS NULL. Dead: NOT NULL.
-- Keeping dead pets in this table preserves event FK integrity (no dangling).
CREATE TABLE pet (
  id INTEGER PRIMARY KEY,
  species TEXT NOT NULL,                 -- 'frog' / 'slime' / 'dragon' / 'cat'
  name TEXT,                              -- user-given name, nullable
  birthday INTEGER NOT NULL,              -- unix epoch (seconds)
  death_at INTEGER,                       -- NULL = alive
  fullness REAL NOT NULL,                 -- 0..100
  stamina REAL NOT NULL,                  -- 0..100
  intimacy REAL NOT NULL,                 -- 0..100
  xp INTEGER NOT NULL,                    -- cumulative, never decreases
  last_tick_at INTEGER NOT NULL,          -- unix epoch of last decay tick
  last_applied_event_id INTEGER NOT NULL DEFAULT 0,  -- replay watermark
  hibernation_since INTEGER,              -- NULL when awake
  death_window_state TEXT NOT NULL DEFAULT '[]'  -- JSON array of last 5 midnight booleans
);

-- Hard invariant: at most one alive pet at any time.
CREATE UNIQUE INDEX idx_one_alive ON pet(death_at) WHERE death_at IS NULL;

-- Append-only event stream.
-- helper_event_id is assigned by claudegotchi-hook (ULID) and is the
-- dedup key when the spool is drained more than once for the same line.
CREATE TABLE event (
  id INTEGER PRIMARY KEY,                 -- monotonic local ordering
  helper_event_id TEXT NOT NULL UNIQUE,   -- ULID set by helper, dedup
  ts INTEGER NOT NULL,                    -- unix epoch ms
  type TEXT NOT NULL,                     -- see §4 event JSON schema
  pet_id INTEGER NOT NULL REFERENCES pet(id),
  payload TEXT                            -- JSON; see §4 schema
);

CREATE INDEX idx_event_ts ON event(ts);
CREATE INDEX idx_event_pet ON event(pet_id);

-- Daily rollups for the heatmap. Backfilled lazily; falls back to event scan.
CREATE TABLE daily_rollup (
  date TEXT PRIMARY KEY,                  -- 'YYYY-MM-DD' local time
  sessions INTEGER NOT NULL,
  messages INTEGER NOT NULL,
  tokens_total INTEGER NOT NULL,
  tools_used INTEGER NOT NULL
);
```

### Event log retention

v0.1 ships with **no retention cap**. The event table will grow at roughly
one row per Claude tool call. Expected ceiling for a heavy user is well under
1 GB over a year.

The `daily_rollup` table is the cheap path for the heatmap and stats window —
it is updated incrementally on each event apply and is the sole source of
truth for All-time queries. Raw events are scanned only for the 7d/30d
ranges.

A retention strategy will land in v0.2: keep raw events for 90 days, retain
daily_rollup forever. This is **not** required for v0.1 correctness.

### Pet 成长史 query

```sql
SELECT id, species, name, birthday, death_at, xp
FROM pet
WHERE death_at IS NOT NULL
ORDER BY death_at DESC;
```

No separate memorial table; deceased pets simply have `death_at` set.

### Species YAML

Bundled definitions live in the app bundle. Users (and PR contributors) can
add new species by dropping a folder into
`~/Library/Application Support/claudegotchi/species/`.

```yaml
id: frog
name_zh: 青蛙
name_en: Frog
stages:
  - {id: egg,      sprite: frog/egg.png,      min_xp: 0}
  - {id: tadpole,  sprite: frog/tadpole.png,  min_xp: 50}
  - {id: juvenile, sprite: frog/juvenile.png, min_xp: 200}
  - {id: adult,    sprite: frog/adult.png,    min_xp: 800}
animations:
  idle:     [0, 1, 0, 2]   # sprite frame indices
  thinking: [3, 4]
  sleeping: [5]
  happy:    [6, 7, 6]
  sick:     [8]
```

Community contributions = a new species folder + sprite sheet + YAML. No
Swift code changes required.

### Launch species (4)

`frog`, `slime`, `dragon`, `cat` — chosen for visual diversity and
recognizable silhouettes at 16px. Random species selection on hatch is
**uniform** across the 4; the deceased pet's species is eligible for the
new pet (no anti-repeat logic in v0.1).

A new pet always starts with `xp = 0`, `fullness = 100`, `stamina = 100`,
`intimacy = 50`, current stage = `egg`.

## 4. Event Flow

### Event JSON schema (helper ↔ app contract)

```json
{
  "schema_version": 1,
  "event_id": "01HK6Y...ULID",
  "ts": 1714500000123,
  "type": "session_start",
  "session_id": "abc123",
  "tool": "Bash",
  "model": "claude-opus-4-7",
  "tokens_in": 1234,
  "tokens_out": 567,
  "extra": { ... }
}
```

| Field | Required | Notes |
|---|---|---|
| `schema_version` | yes | Integer. App rejects mismatched versions with a log warning. |
| `event_id` | yes | ULID assigned by helper at write time. Used as dedup key. |
| `ts` | yes | Unix epoch milliseconds, helper-side wall clock. |
| `type` | yes | One of: `session_start`, `pre_tool_use`, `post_tool_use`, `stop`, `notification`. |
| `session_id` | when applicable | Claude Code's session identifier. |
| `tool` | for tool events | Tool name (Bash / Read / Edit / etc). |
| `model` | when known | Model id; sourced from Claude Code's hook payload when available. |
| `tokens_in`, `tokens_out` | for `post_tool_use` | Integers; missing means "unknown" (treated as 0). |
| `extra` | optional | Free-form passthrough; stored verbatim in `event.payload`. |

### Pipeline

```
Claude user action
  ↓
~/.claude/settings.json hooks fire
  ↓
exec: claudegotchi-hook <type> --json '<json>'
  ↓
helper:
  1. Generate ULID for event_id
  2. Open spool.jsonl with O_APPEND | O_CREAT, mode 0600
  3. Write one JSON line + '\n', fsync, close, exit 0
  ↓ (FSEvents fires on file size change)
SpoolWatcher (in app):
  1. Read new lines since last position (track byte offset in memory)
  2. For each line, parse JSON
  3. Insert into event table; if helper_event_id is duplicate, ignore (UNIQUE constraint)
  4. Hand off to EventApplier
  ↓
EventApplier:
  · session_start  → wake from hibernation if active; persist event
  · pre_tool_use   → record pending(event_id, tool, ts); animation = thinking
  · post_tool_use  → resolve matching pending; fullness += min(tokens_total/2000, 5);
                     xp += tokens_total/200; animation = idle
  · stop (success) → 'happy' animation 1.5s; intimacy += 0.5
  · pet_click      → intimacy += 2 (60s cooldown enforced in UI)
  ↓
StatsStore.persist(); daily_rollup.upsert(date(ts), ...)
  ↓
Update pet.last_applied_event_id = event.id
  ↓
NotificationCenter post → UI redraws
```

### Spool drain semantics

- The app tracks the in-memory **byte offset** of how far it has read into
  spool.jsonl. On launch, the byte offset is recovered by querying
  `MAX(event.id)` and finding the corresponding helper_event_id, then scanning
  the spool for that ULID. If not found (e.g., spool was truncated), the app
  reads from byte 0.
- Lines older than the most recent applied helper_event_id are inserted into
  the event table; the UNIQUE constraint on `helper_event_id` causes duplicates
  to be silently ignored, achieving exactly-once apply.
- Once the spool exceeds 10 MB OR is older than 7 days (whichever first),
  the app rotates: rename → `spool.jsonl.<timestamp>.bak` → start fresh
  spool.jsonl. Backups older than 30 days are deleted.

### Pending tool-use timeout

If a `pre_tool_use` event has not been resolved by a matching `post_tool_use`
(same `session_id` + tool) within **5 minutes**, the EventApplier:

1. Drops the pending state for that pre_tool_use
2. Reverts animation from `thinking` to `idle`
3. Logs a warning (Claude likely crashed or was force-quit)

The 体力 -0.5 already applied is **not** rolled back — Claude did the work,
the tax stands.

### Crash recovery & idempotent replay

- All pet stat changes are derived from events in the `event` table.
- `pet.last_applied_event_id` is the watermark of the highest event id
  whose effects have been persisted to pet stats.
- On startup, after draining the spool into the event table, the engine runs:
  ```sql
  SELECT * FROM event
  WHERE id > pet.last_applied_event_id AND pet_id = <alive pet id>
  ORDER BY id ASC;
  ```
  and applies each event, then updates the watermark.
- Replay is **silent**: no animations, no notifications, no system sound. The
  app marks itself as "catching up" and only restores normal UI behavior once
  the queue is empty.
- Replaying the same event twice (e.g., the helper retried due to a partial
  write) is impossible because of the `helper_event_id` UNIQUE constraint at
  insert time AND the watermark at apply time.

### Hibernation + replay interaction

- Hibernation is captured in the event log: when entering hibernation, the
  engine inserts a synthetic `hibernate_start` event; on first inbound event
  that ends hibernation, a `hibernate_end` event is also inserted.
- Decay computation skips the interval `[hibernate_start.ts, hibernate_end.ts]`
  during replay. The watermark approach guarantees this is applied exactly
  once.
- On replay, the `hibernate_end` does **not** trigger the yawn animation —
  animations are suppressed during catch-up.

### Time decay (background tick)

A timer at 1 Hz wall-clock (using `mach_continuous_time` so it does not
double-count macOS sleep) runs the decay step. Hibernation freezes the tick.

| Stat | Rate | Full → 0 |
|---|---|---|
| 饱食度 | -0.0006/s | ~46 hours of total non-hibernating idle |
| 亲密度 | -0.0003/s | ~93 hours of total non-hibernating idle |
| 体力 | +0.0002/s natural regen | regenerates by default |
| 智慧/XP | unchanged | — |

(Above rates apply only when the pet is awake. Hibernation freezes all
decay/regen.) Stamina drops only via event-driven costs (see §6).

All numeric constants live in `~/Library/Application Support/claudegotchi/config.yaml`
so they can be tuned post-launch without a release. Tests pin the values
they assert against to a **fixture config** (in test bundle) — never to the
user's on-disk config.

## 5. UI Behavior

### Menu-bar icon (16-22px)

Per-second redraw, animation frame derived from the current pet state:

| State | Visual | Trigger |
|---|---|---|
| idle | 4-frame loop, 800 ms cycle | default |
| thinking | eye-roll loop | unresolved `pre_tool_use` (cleared after 5min timeout) |
| hibernation | curled-up sprite, no animation | 72h with zero events |
| sick | dim color + jitter | any decaying stat ≤ 20 for ≥ 1 day |
| celebration | 3-second particle overlay | level-up or evolution |
| paused | grey overlay, no animation | user toggled Pause tracking |

### Dropdown panel (left-click, 260 × ~330 px)

- Pet area (90 px tall) — large sprite. Click pet = pet (intimacy +2, 60 s
  cooldown; the pet animates regardless to give feedback)
- Live status line — "Claude is currently running ${tool}" fades to
  "在等你" 5 s after last activity
- Four stat bars (饱食 / 体力 / 亲密 with bars, 智慧 with Lv N + XP / next
  threshold)
- Today's metrics — sessions count, tokens (resets at local midnight; sourced
  from `daily_rollup` for today's date)
- Click Lv N → opens StatsWindow
- Renders only while open (no background overhead)

### Stats window (680 × ~520 px)

Independent window, opened from the dropdown.

- Three tabs: **Overview** / **Models** / **Pet 成长史**
- Range selector: All / 30d / 7d
- Headline metrics (8): Sessions, Messages, Total tokens, Active days,
  Current streak, Longest streak, Peak hour, Favorite model
- Activity heatmap (contribution-graph style). All / 30d → driven by
  `daily_rollup`. 7d → live query against `event` table for hourly granularity.
- Footer line: rotating witty comparison ("you've used ~12× more tokens than
  the Lord of the Rings — Mochi is stuffed")
- Pet 成长史 tab: evolution timeline + previous pets (queried from `pet`
  WHERE death_at IS NOT NULL); future stages locked behind ?

### Right-click menu

**Pause tracking** · Settings · About · Quit

**Pause tracking semantics:**

- All decay tick computation is suspended.
- Incoming events from the spool are still ingested into the `event` table
  AND into `daily_rollup` (so stats history stays accurate), but they are
  **not** applied to the pet's live stats. `pet.last_applied_event_id` is
  advanced as if applied (events are silently consumed, not retroactively
  applied on resume).
- Animation freezes on a static "paused" sprite frame.
- Click-on-pet does not increment intimacy while paused.
- Resume re-engages decay tick and event application starting from the
  current watermark and current wall clock — no replay, no spike.

## 6. Game Logic

### Time decay

See §4 table.

### Event-driven changes

| Event | Effect |
|---|---|
| `post_tool_use` | 饱食 += min(tokens_total / 2000, 5); XP += tokens_total / 200 |
| `pre_tool_use` | 体力 -= 0.5 (or -1.0 if the parent session has been active > 30 min) |
| `stop` (success) | 亲密 += 0.5 |
| User clicks pet (60s cooldown) | 亲密 += 2 |

A "sustained session" is defined as the time between a `session_start` and
the most recent event in the same `session_id`. Once that span exceeds 30
minutes, the per-`pre_tool_use` 体力 cost doubles for the remainder of the
session.

### Level

```
Lv = floor(sqrt(XP / 100))
```

- Lv 1 at 100 XP
- Lv 5 at 2,500 XP
- Lv 10 at 10,000 XP

Evolution is **independent** of level — driven by `min_xp` thresholds in the
species YAML.

### Hibernation

- **Trigger:** 72 h with zero applied events.
- **Effect:** decay frozen, sprite switches to sleeping pose,
  `pet.hibernation_since` set.
- **Wake:** any inbound applied event clears `hibernation_since`, plays a
  3-s yawn animation.
- The hibernation transition is recorded as a synthetic event so replay is
  deterministic (see §4).

### Death

#### Daily midnight checkpoint

Each local midnight (computed via `NSCalendar` with the user's current
timezone), the engine runs:

1. Snapshot current `fullness`, `stamina`, `intimacy`.
2. Compute boolean `low_today = (count of stats ≤ 20) ≥ 2`.
3. Append `low_today` to `pet.death_window_state` (sliding window of last 5
   days, JSON array of booleans).
4. If hibernation is active for **all 24h** of the day, treat the day as
   "skipped": neither `true` nor `false` is appended (window shrinks
   transiently).
5. If `death_window_state` has 5 entries and all 5 are `true` → death.

**Definition pinned:** "stat ≤ 20" is checked **at the midnight sample only**,
not as a min-over-day or never-rose-above. A stat that dipped to 19 at 11am
but recovered to 50 by midnight does **not** count as low for that day.

**Clock semantics:**

- Decay rate uses `mach_continuous_time` (sleep-aware monotonic).
- Day boundaries use NSCalendar local-time midnight. DST and timezone changes
  may produce a 23h or 25h day; the midnight checkpoint still fires once per
  local day, and decay continues at constant per-second rate. A 25h day will
  show slightly more cumulative decay before the snapshot — accepted as
  cosmetic noise.
- Manual clock changes that move time backward are detected (next checkpoint
  fires at a wall-clock time earlier than the previous checkpoint) and
  ignored (no double-count).

#### Action on death

1. Set `death_at = now()` on the pet row (do not delete).
2. Insert a new pet row with random species, fresh stats, `xp = 0`,
   `last_applied_event_id` set to the same watermark as the previous pet
   (events that arrive after the death stay attributable to the new pet via
   their `pet_id` foreign key).
3. Post a system notification with the deceased pet's name, species, peak
   stage, and final XP.
4. Force-open the dropdown showing the egg.

**No revival, no inheritance.** Hardcore mode by user choice.

### Tunability

All numeric constants live in `~/Library/Application Support/claudegotchi/config.yaml`.
Defaults ship aggressive (medium-strict) so feedback can drive tuning down
rather than up.

## 7. Distribution & Install

### Channels

- **Homebrew Cask** via own tap `goldfishinsky/tap`:
  ```
  brew install --cask goldfishinsky/tap/claudegotchi
  ```
- **Direct .dmg** from GitHub Releases. Tag `vX.Y.Z` triggers a GitHub Actions
  build → uploads `.dmg` artifact (signed in v0.2+).

### Code signing

- v0.1 MVP: **unsigned**, README documents the right-click → Open Gatekeeper
  bypass with screenshots.
- v0.2+: paid Apple Developer account, sign + notarize. Triggered when
  project has measurable adoption.

### Hooks installation flow

On first launch the app:

1. Locate `~/.claude/settings.json`. If absent, offer to create it (with just
   the claudegotchi block).
2. **Permission preflight:** stat the file. If not writable by the current
   user OR file ownership is unexpected, abort installation and present a
   dialog:

   > "Couldn't install Claude Code hooks: `~/.claude/settings.json` is not
   > writable. Open in Finder to fix permissions, then retry. Skipping for
   > now means claudegotchi will run, but won't react to Claude Code activity
   > until hooks are installed."
   >
   > Buttons: **Open Finder** · **Retry** · **Skip**

3. On consent, perform a **structured JSON merge** that:
   - Reads existing JSON
   - Inserts/updates a top-level metadata key `_claudegotchi`:
     ```json
     "_claudegotchi": {
       "version": 1,
       "managed_hook_ids": ["claudegotchi-session-start",
                            "claudegotchi-pre-tool",
                            "claudegotchi-post-tool",
                            "claudegotchi-stop"]
     }
     ```
   - Inserts hook entries into the appropriate `hooks.<event>` arrays. Each
     entry carries an `"id"` field matching the list above so Remove can
     target only its own.
   - Writes atomically: write to `settings.json.tmp` → rename. Backup of the
     original is kept at `settings.json.bak.<timestamp>` for one revision.
4. Settings page exposes idempotent **Reinstall hooks** and **Remove hooks**
   buttons. Both operate on entries with matching `id` only — never touch
   user-added hooks.

### Uninstall

Two paths, both calling the same logic:

- **Homebrew:** `brew uninstall` runs the cask's `uninstall_postflight` block,
  which invokes `/Applications/claudegotchi.app/Contents/Resources/uninstall.sh`.
- **Manual / .dmg:** Settings → Advanced → **Uninstall claudegotchi…** runs
  the same script, then quits.

`uninstall.sh`:

1. Removes hook entries from `~/.claude/settings.json` whose `id` matches the
   `_claudegotchi.managed_hook_ids` list.
2. Removes the `_claudegotchi` metadata key.
3. Writes back atomically.
4. Deletes `~/Library/Application Support/claudegotchi/`.
5. (Manual path only) Triggers `osascript -e 'tell application "Finder" to delete POSIX file ".../claudegotchi.app"'`.

### Auto-update

- v0.1: none — rely on `brew upgrade` or manual download.
- v0.3+: Sparkle framework integration.

## 8. Testing Strategy

### Unit tests (XCTest)

All tests use a **fixture config** loaded from the test bundle, never the
user's `config.yaml`.

- `StatsStore` decay math with injected clock; verify exact stat values
  after simulated 5-day idle (using fixture rates).
- Death and hibernation state machines, including boundary cases:
  - Stat at exactly 20 (≤ 20 evaluates `true` — counts as low).
  - Hibernation entered at 71h59m vs 72h00m.
  - Event arriving while hibernating wakes correctly.
  - Day-window with 4 trues then a hibernated day then 1 true → must NOT
    trigger death (window paused).
- Event → stat change mapping table.
- Sustained-session 体力 cost doubling at 30-min boundary.
- Evolution threshold checks vs `Lv = floor(sqrt(XP/100))`.
- Species YAML parser + sprite sheet frame index bounds.
- Unique-alive partial index: insert second pet with `death_at IS NULL`
  must fail.
- ULID parsing + dedup: same `helper_event_id` inserted twice → second
  insert raises constraint, no double-apply.
- Pre_tool_use timeout: simulate pre without post for 5min30s, verify
  pending state cleared and animation idle.
- DST / timezone test: simulate a 23h day and a 25h day, verify exactly
  one midnight checkpoint per day.

### Integration tests

- **Spool end-to-end:** spawn a fake `claudegotchi-hook`, write 3 events,
  verify SpoolWatcher ingests, EventApplier persists, `daily_rollup` updated.
- **Persistence round-trip:** kill process mid-tick → restart → replay event
  log → final state matches expected.
- **Replay idempotency:** N duplicate events in spool produce same final state
  as deduped sequence.
- **Hooks install idempotence:** install twice in a row produces same
  `settings.json`; install then uninstall leaves it byte-identical to before
  install (modulo the `.bak` file).
- **Pause/resume:** events arriving during pause appear in `event` table and
  `daily_rollup`, but not in pet stats; resume does not retroactively apply.
- **settings.json read-only:** simulate immutable file, install flow surfaces
  error dialog, no partial write.

### UI tests (XCUITest, golden paths only)

- Menu-bar icon present and responds to click.
- Dropdown panel renders four stat bars matching the underlying values.
- Click on pet sprite increments intimacy by 2; second click within 60 s does
  not.
- StatsWindow opens; all three tabs render.
- Pause tracking → animation grey, click-on-pet does not increment.

### Community-contribution guard

`.github/workflows/asset-check.yml` runs on every PR:

- Validates new species YAML against a JSON Schema.
- Asserts each sprite PNG dimension ∈ [16×16, 256×256].
- Asserts every animation frame index falls within the sprite-sheet range.

A broken species cannot land on `main`.

### Pre-release manual smoke

1. Install hooks via the app.
2. Run a real Claude Code session, watch the icon update in real time.
3. Use a debug `--time-skip 5d` flag to simulate 5 days of neglect → verify
   death + new egg of a (uniformly) random species.
4. Force-quit Claude Code mid-tool-use → verify pet returns to idle within
   5 minutes.
5. Toggle pause → run Claude session → verify dropdown shows session in
   today's count but stats unchanged.

## 9. Out of scope (v0.1)

- Outfit / accessory system (hats, glasses)
- Multi-pet households
- Linux / Windows ports
- iCloud sync of pet state across machines
- Auto-update
- Code signing & notarization
- Telemetry
- Anti-repeat species selection on hatch (uniform random for v0.1)
- Event log retention / pruning (revisit in v0.2)

## 10. Open questions

None at design close. Numeric constants are tunable via config.yaml after
launch and will likely need adjustment based on real player data.
