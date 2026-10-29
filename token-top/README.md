# Token Top

Track Codex, Claude Code, and OpenCode Go usage from your Noctalia bar.

- See quota usage and reset times at a glance.
- Click the widget for token activity, session counts, and model breakdowns.
- Choose which providers and 5-hour limits appear in the bar and panel.

## Get started

Requires **Noctalia 5.4+** and **ripgrep**. OpenCode Go also needs **sqlite3**.

1. Sign in with `codex login`, `claude login`, or `opencode auth` (choose OpenCode Go).
2. Enable **Token Top** and add its widget to your bar.
3. Enable your providers in plugin settings.

Claude quota requires a Claude Code subscription sign-in. API-key, Bedrock, and Vertex accounts can show local activity only.

Usage refreshes automatically every five minutes. Claude waits longer when rate limited and keeps the last successful update visible.

If quota is unavailable, check the panel message. For expired or rejected credentials, sign in again with the corresponding CLI.
