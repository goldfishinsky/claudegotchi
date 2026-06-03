# P0 Live Verification — Claude Code SessionStart/Stop Hook Payloads

- Spec gate: `docs/specs/2026-06-02-pr-watch-autofix-design.md` §5, §9, §15 (P0)
- Verified: 2026-06-02
- Installed Claude Code version: `2.1.161 (Claude Code)` (`claude --version`)

## What this verifies

Whether the **real** installed Claude Code passes `session_id` and `cwd` on its
`SessionStart` and `Stop` hook payloads, so that `claudegotchi-hook` can forward
them and the `event.session_id` / `event.cwd` typed columns (`v2_pr_watch`
migration) get real data for `SessionTracker` (P1).

## Capture method (reproducible)

A throwaway capture hook was registered in an **isolated scratch project**
(`mktemp -d`), never in the user's global `~/.claude/settings.json`. The hook
reads the payload Claude Code writes to **stdin** and dumps it to a per-event
file:

```bash
# capture.sh
#!/bin/bash
evt="$1"
cat > "$CG_CAPTURE_DIR/${evt}.json"
exit 0
```

```jsonc
// <scratch>/.claude/settings.json
{
  "hooks": {
    "SessionStart": [ { "hooks": [ { "type": "command", "command": "<scratch>/capture.sh SessionStart" } ] } ],
    "Stop":         [ { "hooks": [ { "type": "command", "command": "<scratch>/capture.sh Stop" } ] } ]
  }
}
```

Then one real headless session was run in the scratch dir to fire both hooks:

```bash
CG_CAPTURE_DIR=<scratch> claude -p "Reply with the single word: ok" \
  --permission-mode acceptEdits --disallowedTools "WebFetch,WebSearch,Bash"
```

The scratch dir and the project transcript Claude created for it were removed
after capture.

Note: Claude Code delivers the hook payload as a **JSON object on stdin** (not
as an argv string). `claudegotchi-hook` currently reads its JSON from
`--json '<json>'` argv; the App's hook-registration wiring (P1) must bridge
stdin→`--json` (or the hook helper must additionally read stdin). This is a
wiring detail for the hook installer, not a payload-shape blocker — the keys we
need are present (below).

## Captured payloads (session_id redacted)

### SessionStart — `session_id` present: YES · `cwd` present: YES

```json
{
  "session_id": "[REDACTED-UUID]",
  "transcript_path": "/Users/<user>/.claude/projects/<proj>/<session>.jsonl",
  "cwd": "/private/tmp/<scratch>",
  "hook_event_name": "SessionStart",
  "source": "startup"
}
```

### Stop — `session_id` present: YES · `cwd` present: YES

```json
{
  "session_id": "[REDACTED-UUID]",
  "transcript_path": "/Users/<user>/.claude/projects/<proj>/<session>.jsonl",
  "cwd": "/private/tmp/<scratch>",
  "permission_mode": "acceptEdits",
  "effort": { "level": "high" },
  "hook_event_name": "Stop",
  "stop_hook_active": false,
  "last_assistant_message": "ok",
  "background_tasks": [],
  "session_crons": []
}
```

The `Stop` payload's `session_id` equals the `SessionStart` one (same UUID),
so the two can be correlated.

## Adopted behavior

- **`Stop` carries `session_id`** → SessionTracker's "a session is active when
  it has a `session_start` with **no later `stop`**" clause is usable **as
  designed** (spec §9). No activity-window-only fallback is required for the
  installed version.
- **`Stop` also carries `cwd`** (bonus; spec only required `session_id` on
  `Stop`). Both hooks give a usable repo label via longest-prefix match on
  `watched_repo.local_path`.
- Pre-v2 `event` rows (written before the `v2_pr_watch` migration) have NULL
  `cwd`/`session_id` and still render repo "(unknown)" per spec §9 — unchanged.

## Residual notes

- `cwd` here is the macOS firmlinked real path (`/private/tmp/...` for a
  `/tmp/...` scratch); the longest-prefix repo-label match (§9) should compare
  resolved/real paths, or accept that a `watched_repo.local_path` under `/tmp`
  would need the `/private` prefix. Not relevant for normal repo clones under
  `~`; flagged for the P1 SessionTracker repo-label implementation.
