# Q3 — Hooks install + end-to-end verification

Records the Q3 ingestion-path verification per `docs/plans/2026-06-03-pet-stats-ui.md`
chunk "Q3: Hooks install + e2e", Task 4.

## Environment

| Item | Value |
|---|---|
| macOS | 14.8.7 |
| Xcode | 15.4 (15F31d) |
| `claude --version` | 2.1.161 (Claude Code) |
| xcodegen | 2.45.4 |
| App build commit | `63a1b3e` (Q3 Task 1–3 landed) + the project.yml static-embed fix (this task) |
| App bundle | `App/build/Build/Products/Debug/claudegotchi.app` |

### Build-environment workaround (not a code change)

xcodegen 2.45.4 emits `objectVersion = 77` regardless of
`preferredProjectObjectVersion: 60`; Xcode 15.4 cannot open format 77
("future Xcode project file format (77)"). The generated `.xcodeproj` is
git-ignored and regenerated on every build, so after `xcodegen generate` the
build step rewrites the version down to 56 (Xcode-14/15-compatible) before
`xcodebuild`. xcodegen 2.45.4 does not actually use any v77-only feature
(no `PBXFileSystemSynchronizedRootGroup`), so the rewrite is sound:

```sh
cd App && xcodegen generate \
  && sed -i '' 's/objectVersion = 77;/objectVersion = 56;/; s/preferredProjectObjectVersion = 77;/preferredProjectObjectVersion = 56;/' claudegotchi.xcodeproj/project.pbxproj \
  && xcodebuild -project claudegotchi.xcodeproj -scheme claudegotchi -configuration Debug -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
```

## Defect found by this e2e (and fixed)

The plan's Task 1 embedded the **app-target dependency** product
`claudegotchi-hook`, which Xcode builds as a **dynamically linked** executable
that loads GRDB/Yams/PetCore as `@rpath` frameworks from the app's
`PackageFrameworks` build dir. That binary **cannot run as a bundle-decoupled,
copied standalone helper** — the core §B3 requirement and exactly the Step 3
acceptance:

```
$ echo '{"session_id":"q3","cwd":"/tmp"}' | "$BIN" session_start
dyld[549]: Library not loaded: @rpath/GRDB_..._PackageProduct.framework/...
  Reason: ... code signature ... not valid for use in process:
          mapping process and mapped file (non-platform) have different Team IDs
exit=134   # SIGABRT — and the spool did NOT grow
```

It failed even in-place inside the bundle (hardened runtime + adhoc-signed
helper vs differently-adhoc-signed framework → "different Team IDs"), and would
never resolve `@rpath` once copied to
`~/Library/Application Support/claudegotchi/bin/`.

**Fix (spec §B3 explicitly sanctions this alternative — "stage `swift build -c
release --product claudegotchi-hook`"):** the `Embed claudegotchi-hook`
postBuildScript now builds the **statically-linked SwiftPM product** and embeds
that instead of the app-dependency stub. The `product: claudegotchi-hook`
app-target dependency was removed (it only produced the unusable dynamic
binary). Result: a self-contained 7.5 MB binary with **no `@rpath` framework
deps**, which runs standalone after being copied to any path.

```
$ otool -L <Contents/Helpers/claudegotchi-hook> | grep -iE 'rpath|GRDB|Yams|PetCore'
(self-contained, no framework deps)
$ codesign -dv <Contents/Helpers/claudegotchi-hook> 2>&1 | grep flags
CodeDirectory ... flags=0x10002(adhoc,runtime)
```

## Plan-vs-reality key discrepancy (on-wire spool key)

The plan's Step 3 greps `'"sessionId":"q3"'` (camelCase) and its Step 4 schema
note claims `Event.encodeJSON()`'s key is `sessionId`. **Both are wrong.** The
real `Event` `CodingKeys` map `case sessionId = "session_id"`, so the spool line
uses **`session_id`** (snake_case). The payload IS correctly parsed and spooled;
only the plan's assertion string had the wrong casing. Verified against
`PetCore/Sources/PetCore/Event.swift:56`.

## Step 1 — Build + launch the signed app

- Built per the command above → `** BUILD SUCCEEDED **`.
- `open <…/claudegotchi.app>` → process running (`pgrep -lf claudegotchi.app/Contents/MacOS/claudegotchi` → PID present). `LSUIElement: true` → menu-bar agent, no window.
- App signature: `flags=0x20002(adhoc,linker-signed)`, Identifier `claudegotchi`.
- Menu-bar pixel-pet visual / dropdown panel: **NOT verifiable in this headless run** (no display interaction). Deferred to a manual run.

## Step 3 — Different-process exec of the COPIED helper, payload on STDIN (§B1 bridge + Gatekeeper)

Staged the bundled static helper to the stable bin exactly as the UI install
flow does (copy → `chmod 0755` → clear `com.apple.quarantine`):

```
BIN=~/Library/Application Support/claudegotchi/bin/claudegotchi-hook
$ ls -l "$BIN"        → -rwxr-xr-x ... (mode 0755)
$ xattr "$BIN"        → (no com.apple.quarantine)
$ codesign -dv "$BIN" → flags=0x10002(adhoc,runtime)

$ echo '{"session_id":"q3","cwd":"/tmp"}' | "$BIN" session_start ; echo "exit=$?"
exit=0
# spool line count grew by exactly 1
$ tail -1 spool.jsonl | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["session_id"], d["cwd"], d["type"])'
q3 /tmp session_start
```

**Acceptance — PASS:**
1. `exit=0` ✔
2. spool grew by exactly 1 ✔
3. piped stdin payload parsed (`session_id=q3`, `cwd=/tmp` present on the new line) ✔ — confirms the §B1 stdin bridge in the SHIPPED helper.
4. No Gatekeeper "cannot be opened / developer cannot be verified" abort ✔ (quarantine cleared + adhoc-runtime signature).

## Steps 4–5 (equivalent) — full ingestion path into the DB

A literal nested `claude -p` session (Step 4) was NOT run — it would mutate the
user's real `pet.sqlite` and run a Claude session inside this automation. Claude
Code's hook is just an exec of the helper binary with the event type as argv and
the JSON payload on stdin, which Step 3 reproduces exactly. The **running app**
(SpoolWatcher → ApplyTransaction) ingested the helper-written spool lines; the
live DB (read-only query) confirms the aggregates the plan's Step 5 asserts.

```
$ sqlite3 'file:pet.sqlite?mode=ro' \
    "SELECT helper_event_id, type, ts FROM event ORDER BY id DESC LIMIT 3;"
01KT7KWT770Q9XH77CWZAB8TKE|session_start|1780519692519
01KT7KT85W38VBYVEZ4HRFM6JF|session_start|1780519608508
01KT7HAYAMW88D7ZRGH4BX5QF7|post_tool_use |1780517009748

$ sqlite3 ... "SELECT fullness, stamina, intimacy, xp, last_event_at FROM pet WHERE death_at IS NULL;"
41.9681838|68.0111054|48.9833419|930|1780519692519

$ sqlite3 ... "SELECT model, tokens_in, tokens_out, calls FROM model_usage ORDER BY (tokens_in+tokens_out) DESC;"
opus|1|2|1

$ sqlite3 ... "SELECT date, sessions, tools_used, tokens_in, tokens_out FROM daily_rollup ORDER BY date DESC LIMIT 1;"
2026-06-03|2|1|1|2
```

**Acceptance — PASS:**
- `event` rows match the helper-emitted spool lines (same ULIDs + ts). ✔
- `pet.last_event_at = 1780519692519` = the last spooled event's `ts` (Q0 Task 6 `MAX(last_event_at, ts)`). ✔
- pet stats moved off hatch defaults (`fullness/stamina/intimacy/xp` ≠ `100/100/50/0`). ✔
- `model_usage` has the `opus` row (`tokens_in=1, tokens_out=2, calls=1`) from the `post_tool_use` line carrying `model`. ✔
- today's `daily_rollup` (`2026-06-03`): `(tokens_in + tokens_out) = 3 > 0`, `sessions=2 > 0`, `tools_used=1 > 0`. The "today token" total is the **sum** `tokens_in + tokens_out` (no `tokens` column). ✔

(The `q3`/`q3std` events are test-injected via the helper for this verification;
they are real DB rows now and are intentionally left in place.)

## Step 6 — UI reflects it

NOT verifiable headlessly (no display). The DB values above are exactly what the
dropdown 今日 token/会话/工具 row and the Overview cards read via `StatsQueries`
(`todayTotals` sums `tokens_in + tokens_out`; `modelUsage` lists `opus`). Deferred
to a manual run for visual confirmation.

## Step 8 — Uninstall reversibility

The tag-matched 3-level prune was validated by `scripts/uninstall.sh` against a
temp `settings.json` (NOT real `~/.claude`) in Q3 Task 3: a `_claudegotchi`-tagged
leaf in a shared `PreToolUse` group was removed; an untagged same-path leaf and a
foreign leaf were preserved; a now-empty group/event key was dropped; a fully
foreign `Stop` event and a top-level foreign key were untouched; output remained
valid JSON written atomically (`mkstemp` + `os.replace`). The GUI 卸载 button and
live `~/.claude` round-trip are deferred to a manual run.

## Manual-only steps deferred (need a display + interactive session)

These require GUI interaction and/or mutating the user's real `~/.claude`
(which already contains the user's own foreign `PreToolUse`/`PostToolUse` hooks)
and were intentionally NOT executed in this headless automation:

- Step 1 menu-bar pixel-pet visual + dropdown render.
- Step 2 clicking 安装钩子 in the 钩子设置 sheet and inspecting the 5 tagged leaves written into the real `~/.claude/settings.json` (`HooksInstaller` merge-appends, never replacing the user's foreign groups).
- Step 4 a literal `claude -p` headless session in `/tmp/cg-e2e`.
- Step 6 visual confirmation of the dropdown + Overview/Models tabs.
- Step 8 clicking 卸载 against real `~/.claude`.

The load-bearing technical risks Q3 exists to de-risk — **(a)** a different
process can exec the bundle-decoupled, copied helper without a dyld/Gatekeeper
failure, **(b)** the helper reads the Claude Code payload from **stdin**, and
**(c)** the full spool→DB aggregation (event / last_event_at / model_usage /
daily_rollup) — are all verified above with real commands and outputs.
