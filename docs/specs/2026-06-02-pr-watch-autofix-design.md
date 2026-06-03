# claudegotchi — PR Watch & Auto-Fix Design

- Status: Draft (revision 2, post multi-lens review)
- Brainstorming date: 2026-06-02
- Author: jalen
- Extends: `docs/specs/2026-04-30-claudegotchi-design.md` (read that first)

## 1. Summary

Add a **work** dimension to claudegotchi: monitor pull-request status for
user-configured repos + authors, surface a clear view of "what needs my
attention", let the user trigger a one-click **auto-fix** that runs local
Claude Code (headless) against a PR's review feedback **in an isolated git
worktree**, and show which local Claude Code sessions are currently running.

PR outcomes feed the existing pet game loop as a *work-pressure* mood
(cosmetic) plus **monotonically positive** stat nudges — approve/merge make
the pet happy. **By construction, no work event can move the pet toward
death** (see §7).

### Surfaces

- **Menu-bar icon** — pet mood reflects work pressure; dot badge when *my* PRs
  need attention.
- **Dropdown panel (260px)** — compact "工作" section: attention count, top PRs,
  "Claude is running in N repos".
- **Stats window (680px)** — new "工作台 / PR" tab: grouped PR list with fix
  buttons, fix-job panel (live progress + history + logs), local-session panel.
- **Settings GUI** — manage watched repos (slug + local path + enable) and
  per-repo authors (default = self).

### Core additions to the loop

```
gh poll (~90s) → GHCLIClient (classify) → PRSync (pure diff) → PRStore (SQLite)
                      │
                      ├─ derived mood (live, not persisted): calm / busy / stressed
                      └─ POSITIVE-only synthetic events → ApplyTransaction.process(event:)
                            pr_approved → intimacy +   (happy)   [death-safe: raises a stat]
                            pr_merged   → xp +          (accomplished) [xp ∉ death inputs]

user clicks 修复 → FixCoordinator (per-repo lock) → worktree add →
                   claude -p headless (confined) → FixJob state machine → UI

hook events (+session_id,+cwd typed columns) → SessionTracker → "running sessions"
```

## 2. Goals / Non-Goals

### Goals (v1)

1. Watch PR status for configured `(repo, author)` pairs via `gh` CLI.
2. A clear, bounded UI of my PRs needing attention (review requested, changes
   requested, unresolved threads).
3. One-click auto-fix: run local Claude Code headless against a PR's
   unresolved review comments **in an isolated worktree on a dedicated local
   branch** (`claudegotchi/fix/<number>`), show live progress, capture a
   redacted log, commit the fix to that branch locally (no push).
4. Show which local Claude Code sessions are running and in which repo.
5. Integrate PR outcomes into the pet's mood + positive-only stat nudges.

### Non-Goals (v1)

- GitHub token / OAuth (gh CLI only; source abstracted for a later token impl).
- Auto-push of fixes (local commit only; integration to remote is the user's).
- Seamless "the fix updates the PR automatically" — v1 commits locally onto
  `claudegotchi/fix/<number>` (tracking the PR head); pushing it to the PR
  branch (`git push origin claudegotchi/fix/<number>:<head_branch>`) is manual.
- Fixing arbitrary authors' PRs by auto-checking-out their branches. Fix is
  offered only for PRs authored by the configured self user. Non-self authors
  are **read-only status**.
- Resolving/replying to review threads on GitHub from the app.
- A new persisted decaying pet stat (work pressure is derived + positive
  nudges only).
- Webhooks / push (polling only).
- Event-log/fix-log/worktree long-term retention policy beyond the simple
  caps stated here (full retention strategy deferred with base §3).

## 3. Architecture & Data Flow

Extends the existing "external source → event → SQLite → engine/UI" shape with
two new parallel inflows alongside the hook spool.

```
                       ┌─────────────── existing ───────────────┐
 Claude Code hooks ──▶ spool.jsonl ──▶ SpoolWatcher ─▶ ApplyTransaction ─▶ Pet (SQLite)
        │  (extend: emit session_id + cwd)                  │ (EventApplier)
        └──────────────────────────────────────────┐       │
                                                    ▼       ▼
                                             SessionTracker ─▶ "running sessions"
                       ┌─────────────── new ───────────────┐
   gh CLI  ◀─ poll ── PRWatcher ─▶ GHCLIClient ─▶ PRSync(pure) ─▶ PRStore (SQLite)
                                       │                          │
                                       └─ synthetic Event ─▶ ApplyTransaction.process(event:) ─▶ Pet
   claude -p  ◀─ spawn ── FixCoordinator/FixRunner ─▶ FixJob (SQLite) ─▶ UI
```

### Layering (PetCore = pure logic / App = UI + process)

**PetCore** (`swift test`-able; all I/O behind protocols, fakes in tests):

| Unit | Purpose | Depends on |
|---|---|---|
| `GitHubClient` (protocol) + `GHCLIClient` | Run `gh ... --json` via argv `Process`; decode + **classify** (merge vs close); parse RFC3339 → epoch ms | `Foundation.Process` |
| `PRStore` | DAO + `v2_pr_watch` migration: watched config, PR cache | GRDB |
| `PRSync` | **Pure**: (old PRs, classified gh outcomes) → upserts + positive synthetic events | — |
| `WorkPressure` | **Pure**: PR rows → mood tier | — |
| `FixPromptBuilder` | **Pure**: unresolved review threads → fenced, injection-safe prompt | — |
| `RefValidator` | **Pure**: validate branch/slug strings before they reach git/gh argv | — |
| `LogRedactor` | **Pure**: strip secret patterns from captured output | — |
| `FixJob` | Model + DAO + **pure** state-machine/guard predicates over injected (state, clock, exit) | GRDB |
| `ClaudeRunner` (protocol) + `CLIClaudeRunner` | Spawn confined `claude -p` in its own process group; stream stdout | `Foundation.Process` |
| `GitRunner` (protocol) + `CLIGitRunner` | argv `git` (fetch / worktree add / status / commit / remove) | `Foundation.Process` |
| `SessionTracker` | **Pure**: decoded events (typed columns) → active sessions | GRDB (read) |
| `Event` (+ `session_id`, `cwd`; + 2 synthetic `EventType`s) | Carry session metadata + PR events | — |

**App** (lifecycle, timers, real subprocesses, SwiftUI):
`PRWatcher` (Timer; per-tick poll), `FixCoordinator` (single-job FIFO queue,
per-repo lock, startup reconciliation, child cleanup on quit), `WorkPanelView`,
`PRTabView`, `WatchSettingsView`.

### Shared-instance invariant

`PRWatcher` and `FixCoordinator` **reuse the App's single `EventApplier` and
single `DatabaseQueue`** (which serializes writes against `SpoolWatcher`). They
must not construct fresh instances, or the in-memory pending/sessionStarts
tracker forks and `tickPendingTimeouts` accounting diverges.

## 4. Data Model

New tables via a new GRDB migration `v2_pr_watch` appended to the existing
migrator (v1 untouched). The `pet` table is **unchanged** (no work-pressure
column; pressure is derived live).

```sql
CREATE TABLE watched_repo (
  id INTEGER PRIMARY KEY,
  slug TEXT NOT NULL UNIQUE,          -- 'owner/name', validated ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$
  local_path TEXT,                    -- absolute path to local clone; NULL = fix disabled
  enabled INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE watched_author (
  id INTEGER PRIMARY KEY,
  repo_id INTEGER NOT NULL REFERENCES watched_repo(id) ON DELETE CASCADE,
  login TEXT NOT NULL,
  UNIQUE (repo_id, login)
);

CREATE TABLE pr (
  id INTEGER PRIMARY KEY,
  repo_slug TEXT NOT NULL,
  number INTEGER NOT NULL,
  title TEXT NOT NULL,
  author TEXT NOT NULL,
  state TEXT NOT NULL,                 -- OPEN / CLOSED / MERGED  (classified by GHCLIClient)
  is_draft INTEGER NOT NULL DEFAULT 0,
  review_decision TEXT,               -- APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED / NULL
  unresolved_count INTEGER NOT NULL DEFAULT 0,
  last_approved_review_at INTEGER NOT NULL DEFAULT 0,  -- ms; drives pr_approved id + re-approval
  head_branch TEXT NOT NULL,
  url TEXT NOT NULL,
  updated_at INTEGER NOT NULL,        -- epoch ms (parsed from gh RFC3339, UTC)
  is_mine INTEGER NOT NULL DEFAULT 0, -- author == gh self login
  fetched_at INTEGER NOT NULL,        -- local clock of last successful sync (also marks "loaded")
  UNIQUE (repo_slug, number)
);
CREATE INDEX idx_pr_repo ON pr(repo_slug);

CREATE TABLE fix_job (
  id INTEGER PRIMARY KEY,
  pr_rowid INTEGER NOT NULL REFERENCES pr(id),
  repo_slug TEXT NOT NULL,
  pr_number INTEGER NOT NULL,
  state TEXT NOT NULL,                 -- queued / checkout / running / succeeded / failed / canceled
  prompt TEXT,
  worktree_path TEXT,                  -- the isolated worktree dir for this job
  started_at INTEGER,
  ended_at INTEGER,
  exit_code INTEGER,
  error TEXT,                          -- human-readable failure reason (redacted)
  log_path TEXT,                       -- redacted claude stdout file, 0600
  commit_sha TEXT,                     -- local commit on claudegotchi/fix/<n> (no push)
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_fix_job_pr ON fix_job(pr_rowid);
CREATE INDEX idx_fix_job_state ON fix_job(state);
```

### Event table: typed columns (avoid JSON scans)

The `v2_pr_watch` migration adds two nullable typed columns to `event`:

```sql
ALTER TABLE event ADD COLUMN session_id TEXT;
ALTER TABLE event ADD COLUMN cwd TEXT;
CREATE INDEX idx_event_session ON event(session_id);
```

**Both** apply paths must populate them: the existing `process(jsonLine:)`
INSERT (today writes only `helper_event_id, ts, type, pet_id, payload` —
`ApplyTransaction.swift`) is amended to also write
`session_id = event.sessionId, cwd = event.cwd`; the synthetic
`process(event:)` overload (§5) writes both as NULL. An `ApplyTransactionTests`
case asserts a decoded hook line lands its `session_id`/`cwd` in the typed
columns — without this, `SessionTracker` (the §9 session feature, a P1
deliverable) gets zero data. `SessionTracker` queries these columns directly
(no payload JSON parsing). Pre-v2 rows are NULL → those sessions render repo
"(unknown)".

## 5. Event Schema & Synthetic Events

### `Event` struct edits (three coordinated edits + call sites)

Add `public let cwd: String?` with a **default `nil`** in the memberwise init
(so existing call sites — `ClaudegotchiHook.main`, `EventApplierTests.evt()` —
don't all churn) and CodingKey `cwd`. `session_id` already exists. Backward
compatible: old spool lines without `cwd` decode to `nil`. Add an encode→decode
round-trip test: old line (no cwd) → nil; new line preserves cwd.

`claudegotchi-hook` reads `cwd` (and `session_id`) from Claude Code's hook
payload JSON and includes them. **P0 verifies** that Claude Code's
`SessionStart` **and** `Stop` hook payloads actually carry `session_id` and
`cwd`; if `Stop` lacks `session_id`, SessionTracker falls back to the activity
window alone (see §9).

### New synthetic event types (POSITIVE only)

Add to `Event.EventType` exactly two cases:

| Case | raw value | Pet effect | Death-safe? |
|---|---|---|---|
| `prApproved` | `pr_approved` | intimacy += `work.pr_approved_intimacy` (clamped ≤100) | yes — *raises* a death-input stat |
| `prMerged` | `pr_merged` | xp += `work.pr_merged_xp` | yes — xp ∉ death inputs |

There is **no negative work event.** "Stress" of changes-requested is purely
the derived mood (§7), never a stat change. This makes death-isolation true by
construction (§7).

`EventApplier.apply` gains two switch arms reading `config.work.*` (it already
owns the full `ConfigYAML`). These arms are idempotent under replay (clamped
add / monotonic xp via dedup). `DailyRollup.upsert`'s `default: break` is never
reached because synthetic events **skip the rollup path** (below).

`ClaudegotchiHook` maps unknown `EventType(rawValue:) ?? .notification`; guard
the CLI to **reject** `pr_*` raw values so PR types stay app-internal and a
hook can never forge one.

### Injection path (concrete)

Synthetic events are produced in-memory by `PRSync`; they are **not** written
to the spool. `ApplyTransaction` gains an explicit overload:

```
ApplyTransaction.process(event: Event)   // sibling of process(jsonLine:)
  1. INSERT INTO event (helper_event_id = event.eventId, ts, type, pet_id =
     <current alive pet>, payload, session_id=NULL, cwd=NULL)
     — reuse the EXISTING dedup idiom (plain INSERT, catch SQLITE_CONSTRAINT
     and return; or check changes()==0). A literal `ON CONFLICT DO NOTHING`
     does NOT throw, so it would fall through to steps 2-4 and double-count —
     on a duplicate, short-circuit and return before steps 2-4.
  2. SKIP DailyRollup.upsert  (PR events are not Claude activity; avoids
     materializing all-zero heatmap rows).
  3. If NOT paused: EventApplier.apply(event:) → update pet.
  4. UPDATE pet.last_applied_event_id = <the just-inserted event rowid>
     (via `SELECT MAX(id) FROM event`, as process(jsonLine:) does — `Event`
     has no `.id`, only the `eventId` ULID string).
```

Synthetic events thus interleave into the same monotonic `event.id` sequence
and participate in startup replay (`SELECT * FROM event WHERE id > watermark`);
their applier arms are idempotent, asserted by a re-apply test. The "free
idempotent replay" claim is scoped to **dedup-by-event_id + clamped applier
arms** (both real and tested), not to unbuilt infrastructure. Synthetic event
payloads omit `cwd`/`session_id` (NULL) so encode→store→decode is byte-stable
on replay. All `event`-table consumers filter by type: `SessionTracker` ignores
`pr_*`; the heatmap reads only `daily_rollup` (which PR events never touch).

### Deterministic, replay-safe event ids

```
pr_approved: "pr:" + slug + "#" + number + ":approved:" + lastApprovedReviewAtMs
pr_merged:   "pr:" + slug + "#" + number + ":merged:"   + mergedAtMs
```

Carrying the triggering timestamp makes **re-approval distinct**
(approve → re-request → re-approve emits a new id, applies again). `slug` is
charset-validated (§12) so `:`/`#` can't be smuggled to forge another PR's id.
A `PRSyncTests` case asserts distinct `(repo, number, transition, ts)` never
collide and that re-approval is a separately-applicable event.

## 6. PR Monitoring Flow

### gh commands (all via argv `Process`, never `/bin/sh`)

Self login (for `is_mine` + default author seed), cached **per app launch**,
refreshed on "测试连接" and on gh-auth-error recovery; if unknown (logged out),
`is_mine = 0` and fix stays disabled:
```
gh api user --jq .login
```

List, per `(enabled repo, login)`:
```
gh pr list --repo <slug> --author <login> --state open \
  --json number,title,author,isDraft,reviewDecision,headRefName,url,updatedAt --limit 50
```

Detail (only for PRs whose `updatedAt` advanced, or new): unresolved threads +
latest approving review timestamp:
```
gh pr view <number> --repo <slug> \
  --json number,reviewDecision,latestReviews,reviewThreads,state,mergedAt,url
```
(`reviewThreads`/`latestReviews` availability on gh 2.91 is verified in P0; if
absent, `GHCLIClient` falls back to `gh api graphql`. All RFC3339 timestamps
are parsed to epoch ms in **UTC**; all comparisons are UTC.)

### Loop (per ~90s tick, `PRWatcher`)

1. For each `(enabled repo × its authors)`: `gh pr list`. **Union and
   de-duplicate results by `(repo_slug, number)`** before diffing (the same PR
   can return under two watched authors).
2. For changed/new PRs: `gh pr view` for detail; compute `unresolved_count`,
   `review_decision`, latest approving review ts.
3. **Disappearance classification (in `GHCLIClient`, not `PRSync`):** a PR in
   the cache no longer returned by `gh pr list` is **confirmed** via
   `gh pr view --json state,mergedAt`. Only `MERGED` emits `pr_merged`; `CLOSED`
   updates state with no event; an `--limit`-window dropout (still open) is left
   as-is. `PRSync` receives already-classified outcomes so it stays pure and
   never fires false merge/close events.
4. `PRSync.diff(old:[PR], outcomes:[Classified]) -> {upserts, events}`:
   - `pr_approved` only when `review_decision` transitions to `APPROVED` (old ≠
     APPROVED → new = APPROVED), id carries that approval's ts.
   - `pr_merged` only on a confirmed `MERGED` outcome, id carries `mergedAt`.
   - Pure; no I/O; testable on fixtures.
5. Persist `upserts` via `PRStore`; feed `events` into
   `ApplyTransaction.process(event:)` (§5).

### Failure handling

Per-repo try/catch (one repo failing doesn't block others). gh missing/not
authed → one-time PR-tab banner, keep cache, no pet effect. Network/non-zero
exit → keep stale cache, show "上次更新于 HH:mm", retry next tick.

## 7. Pet Emotion Coupling

### Derived mood (live, never persisted)

```
pendingCount = count(pr where is_mine=1 AND state='OPEN' AND is_draft=0
               AND (review_decision='CHANGES_REQUESTED' OR unresolved_count>0))
tier = pendingCount >= work.pressure_stressed_threshold ? .stressed
     : pendingCount >= work.pressure_busy_threshold    ? .busy : .calm
```

`WorkPressure.tier(prs:config:)` is pure. Mood is presentation only (sprite
overlay: calm/focused/sweating), computed each render; nothing stored.

### Positive-only nudges (via §5 synthetic events)

- `pr_approved` → intimacy + (clamped). - `pr_merged` → xp +.
- **No event ever decreases a stat.**

### Death-isolation — true by construction

`DeathWindow.isLowDay` reads exactly `fullness/stamina/intimacy`. The
**invariant**: *no work event decreases any of these.* `pr_approved` only
*raises* intimacy; `pr_merged` touches only xp (not a death input). Therefore a
PR storm cannot push the pet toward death — stated as an explicit, provable
bound, replacing the earlier hand-wavy "cannot kill the pet".

**Test (`DeathIsolationTests`):** apply a worst-case sequence (hundreds of
`pr_approved`/`pr_merged`) and drive the **real** midnight path
(`DeathWindow.isLowDay` + `appendDay` over N days via an injected `FixedClock`
— the existing `Clock` protocol in `DecayClock.swift`), asserting `shouldDie`
stays false and intimacy never decreases from work. NOTE: the
midnight-checkpoint *driver* (the caller of `appendDay`) is a **pre-existing
base-game gap** — no caller exists yet, so shipping P3's positive nudges does
not by itself make the pet die-able. This test drives the pure functions
directly with a pinned clock, so it is independent of that driver and not
vacuous; building the driver is tracked as a P3 item.

### Pause semantics

Pause freezes pet stats. Synthetic PR events are subject to the **same pause
gate** as hook events (`ApplyTransaction` step 3): during pause the event row is
written and the watermark advances, but `EventApplier.apply` is skipped, so the
nudge is dropped (no later replay). PR **polling and UI continue during pause**
(the PR tab stays fresh); only the *pet coupling* pauses. Documented so an
approval during a paused week is understood to be intentionally not banked.

## 8. One-Click Auto-Fix

### Eligibility (button enabled only when all true)

`pr.is_mine = 1`; the repo's `local_path` is set, is a git repo, **and its
remote resolves to `repo_slug`** (§12); no `fix_job` in `running`/`checkout`.

### Isolation model — dedicated worktree (key decision)

The fix **never mutates the user's primary checkout or current branch.** The
runner fetches the PR head and operates in an **isolated git worktree on a
dedicated local branch** (NOT a detached HEAD — a detached commit lands on no
branch and is GC-eligible once the worktree is pruned, silently destroying the
fix):

```
git -C <local_path> -c core.hooksPath=/dev/null fetch origin -- <head_branch>
# reconcile any stale worktree at this path first (see below), then:
git -C <local_path> -c core.hooksPath=/dev/null \
    worktree add -B claudegotchi/fix/<number> <job_dir> origin/<head_branch>
```

- `-B claudegotchi/fix/<number>` creates (or resets) a **named local branch**
  tracking the PR head; commits land on a real branch. This succeeds even when
  the PR's own `head_branch` is checked out elsewhere (the fix branch has a
  distinct name). `--force` is not used.
- `<job_dir>` lives under `…/claudegotchi/worktrees/<slug>/<number>/`.
- **Reconcile-before-add (crash safety):** a deterministic job-dir means a
  crash leaves a registered worktree; re-running `worktree add` then fails
  `'<dir>' already exists` (permanently stuck) or mixes leftover edits into the
  next fix. Before adding, run `git worktree list --porcelain`; if a worktree
  exists at `<job_dir>` (or the fix branch is registered), `git worktree remove
  --force <job_dir>` + `git worktree prune` to start clean. This cleanup is
  wired into the **startup reconciliation** (below), not only the
  dismiss/merge/age-cap prune path.
- **Checked-out-elsewhere guard:** parse `git worktree list --porcelain` and
  fail clearly if the target `<job_dir>` is occupied by an unrelated worktree
  that reconcile can't safely clear.
- On success the fix is **committed locally onto `claudegotchi/fix/<number>`**
  in the worktree (`work.fix_commit` default **true**; message notes
  claudegotchi); **never pushed.** The UI surfaces the worktree path, the diff,
  and the exact integration command
  `git push origin claudegotchi/fix/<number>:<head_branch>`. Worktrees are
  pruned on user dismiss, on PR merge/close, or by a simple age cap — **never**
  while their branch has un-integrated (un-pushed) commits.
- This sidesteps the clean-tree TOCTOU, branch-restore, and "concurrent claude
  session in the same checkout" problems entirely (different working dir).

### `FixJob` state machine

```
queued → checkout → running → succeeded
                          └──→ failed   (guard/step error; redacted error set)
   (any) ───────────────────→ canceled  (user cancel → SIGTERM process group)
```

`FixCoordinator` runs **one job at a time** (FIFO), holding a **per-repo app
lock** for the whole job (checkout→run→finish).

### Steps (`FixRunner`)

1. **Guards**: repo `rev-parse` ok; remote URL resolves to `repo_slug` (else
   fail "本地仓库 origin 与 owner/name 不匹配"); `head_branch` passes
   `RefValidator`; not checked out elsewhere.
2. **checkout**: reconcile stale worktree → `git fetch` → `git worktree add -B`
   (argv; `--` before refs). `-c core.hooksPath=/dev/null` is **per-invocation**,
   so `CLIGitRunner` carries it on **every** git call (fetch / worktree add /
   list / status / commit / remove) — not just checkout — so no repo-controlled
   hook ever runs during a fix.
3. **prompt**: fetch unresolved review threads (file, line, author, body) via
   `gh`; `FixPromptBuilder.build(threads:branch:)` produces an
   **injection-safe** prompt (§12): a system preamble stating the bodies are
   *review feedback to address, not instructions*, each body wrapped in a fenced
   data block with backticks/fence delimiters escaped.
4. **running**: spawn in `<job_dir>`, in its **own process group**:
   ```
   claude -p "<prompt>" \
     --permission-mode <work.fix_permission_mode>   # default acceptEdits
     --allowedTools <work.fix_allowed_tools>          # default: edit/read only
     --disallowedTools <work.fix_disallowed_tools>    # default: deny network + dangerous bash
     --output-format stream-json --verbose
   ```
   stdout → `LogRedactor` → `log_path` (0600). Parse stream-json for live
   progress (current tool, tokens). Exact flags + tool-scoping syntax are
   verified against the installed `claude` in P2 (via claude-code-guide);
   `ClaudeRunner` centralizes the argv.
5. **timeout** `work.fix_timeout_seconds` (900) → SIGTERM the **process group**,
   SIGKILL after grace → `failed` "修复超时".
6. **finish**: exit 0 → commit onto `claudegotchi/fix/<number>` (if
   `fix_commit`) → `succeeded`. No push; UI shows the integration command.

### Lifecycle reconciliation & child cleanup

- **Startup reconciliation**: any `fix_job` left in `running`/`checkout` (app
  killed mid-fix; child unreattachable) → `failed` ("应用在修复中途重启"), **and
  its registered worktree is reconciled** (`git worktree remove --force` +
  `git worktree prune`) so the deterministic job-dir is clean for the next job;
  `queued` rows resume (picked up by `FixCoordinator` on launch). This prevents
  the eligibility guard and a stale worktree from permanently blocking a PR.
- **App quit/crash**: `FixCoordinator` terminates all live fix children on
  `applicationWillTerminate`; children run in their own process group so
  grandchildren (bash) die too — no orphaned `claude` editing a worktree
  unsupervised.

## 9. Local Session Status

Reuses the hook event stream via the typed `event.session_id` / `event.cwd`
columns (§4) — no new table, no JSON scan.

```
SessionTracker.activeSessions(events:now:window:) — input is decoded events
(or a windowed query on session_id/type/ts):
  a session_id is active if it has a session_start with no later stop
  AND its most recent event ts is within `window` (default 15 min).
  → [{ session_id, cwd, repo, started_at, last_activity, last_tool }]
```

- Repo label is **pure string manipulation** on `cwd`: longest matching
  `watched_repo.local_path` prefix, else basename. **No** `git -C <cwd>`
  subprocess per session on a timer.
- Fallback: if `Stop` hooks lack `session_id` (verified P0), the "no later
  stop" clause can't fire; sessions then rely on the activity window only
  (documented degradation). Pre-v2 events (no cwd) → repo "(unknown)".

## 10. UI

Every view handles empty / **loading** / error states, long-string truncation,
count caps (`99+`), scrollable lists with explicit **max-height**, and small
viewports. A distinct **first-poll loading** state ("正在加载…" until `fetched_at`
is set) is separate from the genuine all-clear empty state.

### Badge vs list populations (explicit)

- The **attention badge** (menu-bar dot, dropdown 🔔, "N 个待处理") counts
  **`is_mine` attention PRs only** (= `pendingCount`, §7). Capped `99+`.
- The **dropdown ≤3 rows** and the **工作台 list** render watched PRs of **any**
  author (non-self are read-only status), **ordered attention-first**
  (`CHANGES_REQUESTED` → unresolved>0 → most-recently-updated), so `is_mine`
  attention PRs surface above the 3-row cap.
- Dropdown empty-state `✅ 全部清空` fires on `pendingCount == 0` (even if
  non-mine rows still exist).

### Dropdown panel (260px) — pinned-height "工作" section

```
┌──────────────────────────────┐
│  🍞 ▓▓▓▓▓░  💪 ▓▓▓░░  …       │  (existing stats — never clipped)
├──────────────────────────────┤
│ 工作                          │  ← fixed max-height, internal scroll
│ 🔔 3 个 PR 待处理        99+   │     (or hard 3-row cap)
│ • fix: login race…   ⚠ CR    │
│ • feat: heatmap…     👁 待审   │
│ 🟢 Claude 在 2 个仓库运行 99+  │     (capped; hidden when none)
│            [ 打开工作台 ]      │  ← pinned at bottom, always reachable
└──────────────────────────────┘
```

### Stats window (680px) — "工作台 / PR" tab

Three lists (PR / 修复任务 / 本地会话). **Each** gets its own max-height +
overflow (or the tab is one scroll container); vertical space split is defined
so no list pushes another off-screen. The PR list **windows/paginates for 100+
rows**. fix-job history renders **last 20 (ordered `created_at DESC`) inline**;
"查看全部" opens a windowed/paginated view (same 100+ windowing as the PR list).
`fix_job` rows have a retention/age cap (alongside the worktree age cap, §8/§12);
`本地会话` is capped.

```
┌─ Overview │ Models │ 成长史 │ 工作台 ──────────────────────────┐
│ owner/repo-a                          (slug header truncates)  │
│  #128 fix: login race…  ⚠ CR   💬3   [修复]  ↻ 上次:失败       │
│  #131 feat: heatmap…    👁 待审 💬0   [ – ]                    │
│ ───── PR list: max-height, scroll, paginate 100+ ────────────│
│ 修复任务  (last 20 + 查看全部; error/log tail truncated)       │
│  ▶ #128 running  Edit src/auth.ts  ··· 12.3k tok [取消][log]  │
│ 本地会话  (capped; repo label = cwd basename, truncated)       │
│  🟢 repo-a abc123 运行8m 最近:Bash                            │
└──────────────────────────────────────────────────────────────┘
```

Status chips: `📝 草稿 / 👁 待审 / ⚠ CR / ✅ 已批准 / 🔀 已合并`. 修复 button
disabled (tooltip reason) when not `is_mine`, no/invalid local path, or a job
runs. Unresolved badge, attention count, and "Claude 在 N 个仓库" all capped
`99+`. Titles, slug headers, fix `error`/log-tail, and session repo labels all
truncate/wrap with stated max-lines.

### Settings GUI (`WatchSettingsView`)

Add/remove watched repos: validated `owner/name` + local-path picker (validated
git repo, remote-matches-slug check) + enable toggle. Per-repo authors: chips,
default seeded with self login. "测试连接" runs `gh pr list --limit 1` with a
pending/spinner state and reports ok/error inline.

## 11. Config additions (`config.yaml`)

New **non-optional** `work` section in `ConfigYAML` (with matching
`ConfigYAML.defaults`, snake_case CodingKeys like existing sections), so
`EventApplier` need not handle a missing section:

```yaml
work:
  poll_interval_seconds: 90
  pressure_busy_threshold: 1
  pressure_stressed_threshold: 3
  pr_approved_intimacy: 2.0
  pr_merged_xp: 50
  fix_timeout_seconds: 900
  fix_permission_mode: acceptEdits
  fix_allowed_tools: "Edit,Read,Write,Grep,Glob"
  fix_disallowed_tools: "WebFetch,WebSearch"
  fix_commit: true
```

## 12. Security

This feature introduces the repo's **first subprocess code and first ingestion
of attacker-influenceable data** (branch names, PR/review bodies). No safe
pattern exists to copy, so these are explicit requirements, not impl details.

1. **Subprocess discipline** — all `git`/`gh`/`claude` calls use argv-array
   `Foundation.Process` (no `/bin/sh`, no string interpolation). Positional ref
   args are preceded by `--` (`git fetch origin -- <branch>`); `gh` option-like
   args use `--flag value` argv pairs, never interpolated strings.
2. **Ref / slug / login validation (`RefValidator`, at config-entry AND at use)**
   — reject branch names starting with `-`, or containing whitespace/control
   chars/`..`/refspec metacharacters. `slug` must match
   `^[A-Za-z0-9._][A-Za-z0-9._-]*/[A-Za-z0-9._][A-Za-z0-9._-]*$` — **each
   segment** must not start with `-` (a plain `[A-Za-z0-9._-]+` segment would
   accept `-h/repo` / `a/-rf`). `login` (fed to `gh pr list --author <login>`)
   must match the GitHub handle charset and not start with `-`. Prevents
   option-smuggling (`--upload-pack=`, `-c …`, `--state`) and id-forgery.
   `RefValidatorTests` covers leading-dash branch/slug/login.
3. **Prompt-injection containment (`FixPromptBuilder`)** — review-thread bodies
   (writable by anyone who can comment, not just trusted parties) are treated as
   **untrusted data, never instructions**: a system preamble says so, each body
   is wrapped in a fenced data block with backticks/fence delimiters escaped so
   it cannot break out. Residual risk documented.
4. **Execution confinement** — `claude -p` runs with scoped `--allowedTools` /
   `--disallowedTools` (network denied by default), in an **isolated worktree**,
   in its own process group, with repo git hooks disabled for **all fix-time git
   operations** (`-c core.hooksPath=/dev/null` on every `CLIGitRunner` call,
   since the flag is per-invocation). Residual: `core.hooksPath` does **not**
   disable gitattributes clean/smudge filters or `core.fsmonitor`, which can run
   repo-controlled commands; this is bounded because `local_path` is
   user-asserted trust (§12.5), and `CLIGitRunner` additionally passes
   `-c core.fsmonitor=false`. `acceptEdits` grants worktree-wide edit + bash;
   this is documented and the feature is opt-in.
5. **local_path ↔ slug binding** — at fix time the clone's remote URL must
   resolve to `repo_slug`, else refuse. local_path is user-asserted trust;
   mismatched origin is rejected.
6. **Log hygiene (`LogRedactor`)** — captured stdout and surfaced `error`/log
   tails are redacted for tokens, `Authorization` headers, AWS keys, and
   `user:pass@` URL userinfo before write/display; `log_path` is `0600` under
   Application Support; logs are **never uploaded**; a retention/cleanup policy
   bounds them.

## 13. Error-Handling Matrix

| Condition | Behavior |
|---|---|
| gh missing / not authed | PR-tab banner; keep cache; no pet effect; fix disabled |
| gh self-login unknown (logged out) | `is_mine=0`; fix disabled |
| gh network/exit error | keep stale cache; "上次更新于…"; retry next tick |
| one repo fails, others ok | per-repo isolation; failed repo flagged |
| same PR under 2 authors | unioned/de-duped by (repo,number) before diff |
| PR disappears from list | confirm via `gh pr view`; MERGED→event, CLOSED→state only, window-dropout→keep |
| invalid branch/slug | `RefValidator` rejects; fix fails with reason; never reaches git |
| local_path unset/not a repo/origin≠slug | 修复 disabled or job fails with reason |
| stale worktree at job-dir (prior crash) | reconciled (`worktree remove --force` + `prune`) before add |
| job-dir occupied by unrelated worktree | job fails "工作目录被占用" |
| claude not on PATH / non-zero exit | job → failed (redacted reason / log tail) |
| fix timeout | SIGTERM→SIGKILL process group; job → failed |
| user cancel | SIGTERM process group; job → canceled |
| app killed mid-fix | startup: running/checkout→failed; queued→resume |
| app quit with live fix | children terminated via process group |
| paused + synthetic event | event row written, applier skipped, watermark advances (dropped) |
| duplicate synthetic event (replay) | UNIQUE(helper_event_id) skips; applier arms idempotent |
| corrupt/missing cwd or session_id | session repo "(unknown)" / activity-window fallback |

## 14. Testing Strategy

**PetCore pure-logic unit tests (fixtures, no I/O):**

- `PRSyncTests` — diff → upserts + positive events; unchanged poll → no events;
  re-approval emits a *new* applicable event; replay twice → identical state;
  distinct `(repo,number,transition,ts)` ids never collide.
- `GHCLIClient` classification test — merged-vs-closed-vs-window-dropout on
  fixture `gh` bytes; RFC3339→epoch-ms parsing.
- `WorkPressureTests` — thresholds → tiers; drafts/non-mine excluded.
- `RefValidatorTests` — option-smuggling/metachar/`-`-prefix rejected; valid
  refs/slugs pass.
- `FixPromptBuilderTests` — fence escaping; bodies can't break out; empty
  threads handled.
- `LogRedactorTests` — token/header/key/userinfo patterns redacted.
- `SessionTrackerTests` — typed-column events → active sessions; stop closes;
  stale window excludes; missing cwd/session_id → unknown/fallback.
- `FixJobTests` — **pure surface = transition graph + guard predicates** over
  injected `(state, clock, exit_code)` (clock injected via the existing `Clock`
  protocol, e.g. `FixedClock` — `DecayClock.swift`). Timing/IO (`started_at`,
  cancel, timeout) live in `FixRunner`/`FixCoordinator` tests with a **fake
  `ClaudeRunner`/`GitRunner`**.
- `DeathIsolationTests` — §7: worst-case work sequence + real midnight path over
  N pinned `FixedClock` days → `shouldDie` false, intimacy never decreased by
  work.
- `Event` round-trip — old line (no cwd) → nil; new line preserves cwd; synthetic
  payload byte-stable.

**App (lighter):** targeted XCUITest for PR-tab states (empty / loading / error
/ long titles / 99+ badges / 100+ rows), fix-button enablement, cancel.

## 15. Phasing (each phase independently testable & shippable)

- **P0 — groundwork**: `Event.cwd` + hook passthrough; **verify Claude Code
  SessionStart/Stop payloads carry session_id+cwd**; `v2_pr_watch` migration
  (tables + typed event columns); `GitHubClient`/`GitRunner`/`ClaudeRunner`
  protocols + impls + fixtures + fakes; `RefValidator`, `LogRedactor`. Verify:
  migration applies, gh fixtures decode + classify, `swift test` green.
- **P1 — read-only monitoring + sessions**: `PRStore`, `PRSync`, `PRWatcher`,
  `SessionTracker`; PR tab (read-only) + sessions panel + Settings GUI. No fix,
  no pet coupling. Verify: configured repos' PRs render with correct chips;
  running sessions show; per-author dedup; loading/empty/error states.
- **P2 — one-click fix**: `FixPromptBuilder`, `FixJob`, `FixRunner`,
  `FixCoordinator` (worktree, per-repo lock, reconciliation, process-group
  cleanup); fix button + live progress + history + redacted log viewer. Verify:
  fix a real PR end-to-end on a scratch repo; origin-mismatch refusal; invalid
  ref refusal; cancel; timeout; app-restart reconciliation.
- **P3 — pet emotion coupling**: two synthetic `EventType`s + applier arms;
  `ApplyTransaction.process(event:)`; `PRSync` emits them; `WorkPressure` mood
  overlay; dropdown 工作 section; **midnight-checkpoint driver** (the
  `DeathWindow` caller). Verify: approve/merge move stats once; replay
  idempotent; mood tracks tier; `DeathIsolationTests` green.

## 16. Open Questions / Risks

1. **Exact `claude` headless flags** (`--permission-mode`, `--allowedTools`/
   `--disallowedTools` syntax, `--output-format stream-json`) verified against
   the installed version in P2 via claude-code-guide; `ClaudeRunner` centralizes
   argv.
2. **`gh pr view` review-thread/`latestReviews` fields** on gh 2.91 — graphql
   fallback if absent. Resolved in P0.
3. **Worktree integration ergonomics** — v1 commits locally onto
   `claudegotchi/fix/<number>` (tracking the PR head) in an isolated worktree
   and surfaces `git push origin claudegotchi/fix/<number>:<head_branch>` for
   the user; a smoother one-click integration flow is deferred.
4. **acceptEdits + bash for formatters** — confined by tool-scoping + worktree +
   process group, surfaced via timeout rather than silently hung; permission
   mode is a documented, opt-in trade-off.
