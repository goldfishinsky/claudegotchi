# claudegotchi

A tiny macOS desktop pet for Claude Code and OpenAI Codex.

claudegotchi turns agent activity into a long-running pixel-pet experience. It
tracks sessions, tools, models, and token usage; the pet grows as you work and
reacts to active agents, completed tasks, and permission requests.

[Download Preview 5 for Apple Silicon](https://github.com/goldfishinsky/claudegotchi/releases/tag/v0.1.0-preview.5)

## Highlights

- Use Claude Code, Codex, or both. Activity and statistics are attributed to the
  correct platform while contributing to the same pet.
- Keep the pet in the menu-bar island or drag it out into an always-on-top
  desktop companion.
- Hover over the pet to see active agents and jump back to their terminal or
  Codex task.
- Review token, model, tool, and platform usage without mixing Claude and Codex
  together.
- Receive useful permission and completion notifications, including the task
  name when it is available.
- Sign in with GitHub in the browser to join the optional global leaderboard.

## Requirements

- Apple Silicon Mac
- macOS 13 or later
- Claude Code and/or the Codex CLI

The current preview is distributed for Apple Silicon only.

## Install

1. Download the DMG from [GitHub Releases](https://github.com/goldfishinsky/claudegotchi/releases).
2. Open it and drag **claudegotchi.app** into **Applications**.
3. Try to open the app once. If macOS shows “Apple could not verify…”, choose
   **Done** — do not move the app to Trash.
4. Open **System Settings → Privacy & Security**, scroll to **Security**, then
   choose **Open Anyway** for claudegotchi and confirm **Open**. This option is
   available for about an hour after the blocked launch attempt.

This one-time override is necessary because the preview is not yet signed and
notarized. Future builds should remove this extra installation step.

Installing a newer build over the existing app does not remove your pet or
statistics. Local data lives in:

```text
~/Library/Application Support/claudegotchi/
```

## Connect Claude Code and Codex

Open **设置 → 连接与同步 → 管理钩子**. Claude Code and Codex have
separate install controls, so either or both can be enabled.

Codex requires one additional trust step after installing its hook:

1. Start a new `codex` CLI session.
2. Run `/hooks`.
3. Select the claudegotchi hook and press `t` to trust it.

The app installs the hook helper under its Application Support directory and
registers it with Claude Code in `~/.claude/settings.json` or with Codex in
`~/.codex/hooks.json`.

> Codex desktop activity can be shown when the corresponding Codex CLI hooks
> are available and trusted. The desktop app itself does not currently expose a
> separate public hook interface.

## Privacy and data

Pet state and detailed activity statistics are stored locally. GitHub sign-in
and leaderboard participation are optional. Leaderboard sync uploads aggregate
usage statistics and pet information; it does not upload your source code or
full conversation content.

Use **设置 → 退出 claudegotchi** (or <kbd>⌘Q</kbd>) to quit. Replacing or
quitting the app does not delete local data.

## Build from source

Install the development dependencies:

```bash
brew bundle
```

Generate the Xcode project and build the app:

```bash
cd App
xcodegen generate
xcodebuild \
  -project claudegotchi.xcodeproj \
  -scheme claudegotchi \
  -configuration Debug \
  -derivedDataPath build \
  build
```

Run the core and server test suites:

```bash
swift test --package-path PetCore
cd server && npm ci && npm test
```

`App/project.yml` is the source of truth for the generated Xcode project.

## Leaderboard server

The optional leaderboard is a Cloudflare Worker backed by D1. The desktop app
uses GitHub's browser-based OAuth flow and returns through the
`claudegotchi://oauth/github` callback.

Configure the GitHub OAuth App callback URL as:

```text
https://<your-worker-domain>/v1/auth/github/web/callback
```

Set `GITHUB_CLIENT_ID` for the Worker, then add `GITHUB_CLIENT_SECRET` and a long
random `OAUTH_STATE_SECRET` with `wrangler secret put`. Apply the D1 migrations
before deploying. Migration `0003_oauth_grants.sql` stores five-minute,
single-use grants bound to the desktop app's PKCE verifier.

## Project status

claudegotchi is an early preview. The main experience is working, but releases
are not yet signed or notarized and some integrations depend on the hook APIs
provided by Claude Code and Codex.

See `docs/specs/` for product and implementation notes.

## License

MIT
