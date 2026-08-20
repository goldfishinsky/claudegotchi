# claudegotchi

A menu-bar Tamagotchi for Claude Code and OpenAI Codex.

It lives in your macOS menu bar as an 8-bit pixel pet that watches your coding
agents — feed it tokens, keep it company during long sessions, level it up over
time. Neglect it and it gets sad, sick, then leaves.

## Connect an agent

Open **设置 → 连接与同步 → 管理钩子**. Claude Code and Codex
have separate install buttons, and you can enable either or both.

Codex requires one additional trust step after installation:

1. Start a new `codex` CLI session.
2. Run `/hooks`.
3. Select the claudegotchi hook and press `t` to trust it.

Claude and Codex usage share the same pet, but model usage and leaderboard
statistics are recorded separately by platform.

## GitHub OAuth for the leaderboard

The desktop app uses GitHub's browser-based web OAuth flow and returns through
the `claudegotchi://oauth/github` callback. Configure the GitHub OAuth App's
authorization callback URL as:

```text
https://<your-worker-domain>/v1/auth/github/web/callback
```

Set `GITHUB_CLIENT_ID` for the Worker, then add `GITHUB_CLIENT_SECRET` and a long
random `OAUTH_STATE_SECRET` with `wrangler secret put`. Apply D1 migrations before
deploying; migration `0003_oauth_grants.sql` stores five-minute, one-use grants
bound to the desktop app's PKCE verifier.

## Status

Design phase. See `docs/specs/` for in-progress design.

## License

MIT
