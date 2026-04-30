# claudegotchi — Design

- Status: Draft (pending review)
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
   → if 2 of 3 decaying stats ≤ 20 for 5 days → death
   → if no events for 72h → hibernation (decay frozen, pet sleeps)
Death → memorial → new egg → random species → repeat
```

### Stats (4-axis)

| Stat | Symbol | Decays? | Driven by |
|---|---|---|---|
| 饱食度 (fullness) | 🍞 | yes | Claude tokens consumed |
| 体力 (stamina) | 💪 | regenerates passively, drained by long Claude sessions | session duration / tool calls |
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
│  │  EventQueue    │ events → stat change mapping            │ │
│  │  Persistence   │ SQLite at Application Support           │ │
│  └─────────────────────────┬────────────────────────────────┘ │
│                            │                                  │
│  ┌────────────────── HookListener ─────────────────────────┐ │
│  │  Unix domain socket @ ~/Library/.../claudegotchi.sock   │ │
│  │  receives JSON events from claudegotchi-hook            │ │
│  └─────────────────────────┬────────────────────────────────┘ │
└────────────────────────────┼─────────────────────────────────┘
                             │ JSON over UDS
                             │
┌────────────────────────────┴────────────────────────────────┐
│  ~/.claude/settings.json hooks                                │
│  SessionStart / Stop / PreToolUse / PostToolUse / etc.        │
│  → exec: claudegotchi-hook <event-name>                       │
└─────────────────────────────────────────────────────────────┘
```

### Modules

- **`claudegotchi.app`** — main GUI app, menu bar resident, owns game engine
  and persistence
- **`claudegotchi-hook`** — small CLI binary (< 1 MB) invoked by Claude Code
  hooks; forwards events as JSON over UDS to the main app then exits in
  milliseconds
- **Species assets** — YAML definitions + sprite sheet PNGs bundled with the app
  (overridable from `~/Library/Application Support/claudegotchi/species/`)

### Why this split

- Claude Code hooks are fire-and-forget subprocess calls — they cannot hold
  state, so a tiny helper binary is necessary to forward events
- UDS is bound to the user's account → safer than a TCP port, lower latency
  than file-watching
- The main app is independent: if hooks aren't installed, the pet still runs
  (it'll just go hungry without events)

## 3. Data Model

### SQLite schema

Database at `~/Library/Application Support/claudegotchi/db.sqlite`.

```sql
-- The currently living pet (at most one row with death_at IS NULL)
CREATE TABLE pet (
  id INTEGER PRIMARY KEY,
  species TEXT NOT NULL,         -- 'frog' / 'slime' / 'dragon' / 'cat'
  name TEXT,                     -- user-given name, nullable
  birthday INTEGER NOT NULL,     -- unix epoch
  death_at INTEGER,              -- NULL = alive
  fullness REAL NOT NULL,        -- 0-100
  stamina REAL NOT NULL,         -- 0-100
  intimacy REAL NOT NULL,        -- 0-100
  xp INTEGER NOT NULL,           -- cumulative, never decreases
  last_tick_at INTEGER NOT NULL, -- unix epoch of last decay tick
  hibernation_since INTEGER      -- unix epoch when hibernation began; NULL when awake
);

-- Append-only event stream; powers stats window heatmap and recovery on restart
CREATE TABLE event (
  id INTEGER PRIMARY KEY,
  ts INTEGER NOT NULL,
  type TEXT NOT NULL,            -- 'session_start' / 'pre_tool_use' / 'post_tool_use' / 'stop' / 'pet_click'
  pet_id INTEGER REFERENCES pet(id),
  payload TEXT                   -- JSON blob: {tool, model, tokens_in, tokens_out, ...}
);

-- Past pets (moved here on death). Drives the Pet 成长史 tab.
CREATE TABLE memorial (
  id INTEGER PRIMARY KEY,
  species TEXT, name TEXT,
  birthday INTEGER, death_at INTEGER,
  max_xp INTEGER, peak_stage TEXT
);

CREATE INDEX idx_event_ts ON event(ts);
CREATE INDEX idx_event_pet ON event(pet_id);
```

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
recognizable silhouettes at 16px.

## 4. Event Flow

```
Claude user action
  ↓
~/.claude/settings.json hooks fire
  ↓
exec: ~/Applications/claudegotchi-hook <event-name> --json '{"session_id":"..."}'
  ↓ (UDS connect)
claudegotchi.app HookListener receives JSON
  ↓
EventQueue.enqueue(Event(type, ts, payload))
  ↓
GameEngine processes asynchronously:
  · session_start  → wake from hibernation if needed; persist event
  · pre_tool_use   → trigger 'thinking' animation; stamina -= 0.5
  · post_tool_use  → fullness += min(tokens_total/2000, 5); xp += tokens_total/200
  · stop (success) → 'happy' animation; intimacy += 0.5
  · pet_click      → intimacy += 2 (60s cooldown enforced in UI)
  ↓
StatsStore persists (debounced 1s)
  ↓
NotificationCenter post → UI redraws
```

### Time decay (background tick)

A timer at 1 Hz wall-clock (using `mach_continuous_time` so it does not double-count macOS sleep) runs the decay step. Hibernation freezes the tick.

| Stat | Rate | Full → 0 |
|---|---|---|
| 饱食度 | -0.0006/s | ~33 hours of total idle |
| 亲密度 | -0.0003/s | ~93 hours of total idle |
| 体力 | +0.0002/s natural regen, -1.0/s during sustained sessions > 30 min | regenerates by default |
| 智慧/XP | unchanged | — |

All numeric constants live in `~/Library/Application Support/claudegotchi/config.yaml` so they can be tuned post-launch without a release.

### Crash recovery

On startup the engine re-reads all events with `ts > last_tick_at` from the
`event` table and replays them in order. This makes the system tolerant to
crashes, force quits, and machine reboots — no state is lost as long as the
event log was written.

## 5. UI Behavior

### Menu-bar icon (16-22px)

Per-second redraw, animation frame derived from the current pet state:

| State | Visual | Trigger |
|---|---|---|
| idle | 4-frame loop, 800 ms cycle | default |
| thinking | eye-roll loop | PreToolUse fired without matching PostToolUse |
| hibernation | curled-up sprite, no animation | 72h with zero events |
| sick | dim color + jitter | any decaying stat < 20 for ≥ 1 day |
| celebration | 3-second particle overlay | level-up or evolution |

### Dropdown panel (left-click, 260 × ~330 px)

- Pet area (90 px tall) — large sprite. Click pet = pet (intimacy +2, 60 s
  cooldown; the pet animates regardless to give feedback)
- Live status line — "Claude is currently running ${tool}" fades to
  "在等你" 5 s after last activity
- Four stat bars (饱食 / 体力 / 亲密 with bars, 智慧 with Lv N + XP / next
  threshold)
- Today's metrics — sessions count, tokens (resets at local midnight)
- Click Lv N → opens StatsWindow
- Renders only while open (no background overhead)

### Stats window (680 × ~520 px)

Independent window, opened from the dropdown.

- Three tabs: **Overview** / **Models** / **Pet 成长史**
- Range selector: All / 30d / 7d
- Headline metrics (8): Sessions, Messages, Total tokens, Active days,
  Current streak, Longest streak, Peak hour, Favorite model
- Activity heatmap (contribution-graph style)
- Footer line: rotating witty comparison ("you've used ~12× more tokens than
  the Lord of the Rings — Mochi is stuffed")
- Pet 成长史 tab: evolution timeline; future stages locked behind ?

### Right-click menu

Pause tracking · Settings · About · Quit

## 6. Game Logic

### Time decay

See section 4 table.

### Event-driven changes

| Event | Effect |
|---|---|
| `PostToolUse` | 饱食 += min(tokens_total / 2000, 5); XP += tokens_total / 200 |
| `PreToolUse` | 体力 -= 0.5 |
| Sustained session > 30 min | 体力 decay rate doubles for the duration |
| `Stop` (success) | 亲密 += 0.5 |
| User clicks pet (60s cooldown) | 亲密 += 2 |

### Level

```
Lv = floor(sqrt(XP / 100))
```

- Lv 1 at 100 XP
- Lv 5 at 2,500 XP
- Lv 10 at 10,000 XP

Evolution is **independent** of level — driven by `min_xp` thresholds in the
species YAML, not by Lv.

### Hibernation

- Trigger: 72 h with zero events
- Effect: all decay frozen, sprite switches to sleeping pose,
  `pet.hibernation_since` set
- Wake: any inbound event clears `hibernation_since`, plays a 3-s yawn
  animation

This rule is what protects vacationers from coming home to a corpse.

### Death

- **Condition:** any **2 of {饱食, 体力, 亲密}** stay ≤ 20 across **5
  consecutive integer days** (checked daily at local midnight)
- **Action:** copy pet row → memorial; create new pet row with random species,
  fresh stats, fresh XP starting from 0; user notified via system notification
  with the deceased pet's name and final stage
- **No revival, no inheritance.** This is the user-chosen hardcore mode.

### Tunability

All numeric constants live in `~/Library/Application Support/claudegotchi/config.yaml`. Defaults ship aggressive (medium-strict) so feedback can drive tuning down rather than up.

## 7. Distribution & Install

### Channels

- **Homebrew Cask** via own tap `goldfishinsky/tap` (avoid having to land in
  homebrew-cask main repo on day 1):
  ```
  brew install --cask goldfishinsky/tap/claudegotchi
  ```
- **Direct .dmg** from GitHub Releases. Tag `vX.Y.Z` triggers a GitHub Actions
  build → uploads signed (eventually) `.dmg` artifact.

### Code signing

- v0.1 MVP: **unsigned**, README documents the right-click → Open Gatekeeper
  bypass with screenshots
- v0.2+: paid Apple Developer account, sign + notarize. Triggered when project
  has measurable adoption.

### Hooks installation flow

On first launch the app:

1. Reads (or creates) `~/.claude/settings.json`
2. Shows a one-time prompt: "Install Claude Code hooks? (~5 lines added to
   your settings.json)" with a **Preview diff** button
3. On consent, performs a **structured JSON merge** (not string concatenation)
   that preserves any existing user hooks
4. Settings page exposes idempotent **Reinstall hooks** and **Remove hooks**
   buttons

### Uninstall

Homebrew `brew uninstall` triggers `uninstall.sh` which:

1. Removes the claudegotchi hooks from `~/.claude/settings.json`
2. Deletes `~/Library/Application Support/claudegotchi/`
3. Removes the app bundle

### Auto-update

- v0.1: none — rely on `brew upgrade` or manual download
- v0.3+: Sparkle framework integration

## 8. Testing Strategy

### Unit tests (XCTest)

- `StatsStore` decay math with injected clock; verify exact stat values after simulated 5-day idle
- Death and hibernation state machines, including boundary cases:
  - stat at exactly 20 (does not count as ≤20? we say ≤20 = yes, counts)
  - hibernation entered at 71h59m vs 72h00m
  - event arriving while hibernating wakes correctly
- Event → stat change mapping table
- Evolution threshold checks vs `Lv = floor(sqrt(XP/100))`
- Species YAML parser + sprite sheet frame index bounds

### Integration tests

- UDS end-to-end: spawn a fake `claudegotchi-hook` → write socket → main
  process records to DB
- Persistence round-trip: kill process → restart → replay event log → final
  state matches expected
- Hooks install idempotence: install twice in a row produces same
  `settings.json`; install then uninstall leaves it byte-identical to before
  install

### UI tests (XCUITest, golden paths only)

- Menu-bar icon present and responds to click
- Dropdown panel renders four stat bars matching the underlying values
- Click on pet sprite increments intimacy by 2; second click within 60 s does
  not
- StatsWindow opens; all three tabs render

### Community-contribution guard

`.github/workflows/asset-check.yml` runs on every PR:

- Validates new species YAML against a JSON Schema
- Asserts each sprite PNG dimension ∈ [16×16, 256×256]
- Asserts every animation frame index falls within the sprite-sheet range

A broken species cannot land on `main`.

### Pre-release manual smoke

1. Install hooks via the app
2. Run a real Claude Code session, watch the icon update in real time
3. Use a debug `--time-skip 5d` flag to simulate 5 days of neglect → verify
   death + memorial + new egg of a different random species

## 9. Out of scope (v0.1)

- Outfit / accessory system (hats, glasses)
- Multi-pet households
- Linux / Windows ports
- iCloud sync of pet state across machines
- Auto-update
- Code signing & notarization
- Telemetry

## 10. Open questions

None at design close. Numeric constants are tunable via config.yaml after
launch and will likely need adjustment based on real player data.
