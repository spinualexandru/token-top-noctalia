# token-top

Track Codex and Claude Code quota consumption and local session token activity from the bar.

## Plugin

| Field | Value |
| --- | --- |
| ID | `spinualexandru/token-top` |
| Entries | Bar widget: `usage`; panel: `details`; service: `poller` |

## Features

- A compact bar view for either Codex or Claude, selected in plugin settings.
- An Overview tab with quota and activity summaries for both agents.
- Dedicated Codex and Claude tabs with provider-native quota and local-session detail.
- Independent provider state: an error or stale response from one agent never replaces the other agent's data.
- Automatic refresh at startup and every five minutes, plus a manual refresh for both agents.
- Last-good quota retention with visible stale and sign-in guidance.

Codex detail includes input, output, cached input, reasoning, requests, turns, and thread distribution. Claude detail
includes input, output, cache creation, cache reads, requests, sessions, and model mix.

## Usage

Sign in to one or both supported coding agents:

```sh
codex login
claude login
```

Enable `spinualexandru/token-top`, add the **token-top** widget to a bar, and choose **Agent shown in bar** in plugin
settings. Click the widget to open Overview. The Codex and Claude tabs remain available when an agent is not connected
and show the action needed to connect it.

Toggle the details panel directly with:

```sh
noctalia msg panel-toggle spinualexandru/token-top:details
```

The quota bars show percentage consumed, not percentage remaining.

## Activity definitions

When weekly quota boundaries are available, local statistics use the provider's exact current and previous limit
windows. Otherwise they use a rolling seven-day window and omit reset projections.

- **Today** starts at local midnight.
- **Codex token activity** uses cumulative local rollout snapshots. Cached input is a subset of input, and reasoning is
  a subset of output.
- **Claude token traffic** is input + cache-created input + cache-read input + output. Repeated streaming chunks and
  parent/subagent copies are deduplicated before requests, sessions, and model mix are calculated.
- The activity chart divides the active seven-day window into seven 24-hour slices.

## Authentication and supported accounts

Codex credentials and sessions are read from `$CODEX_HOME`, or `~/.codex` when the variable is unset.

Claude Code credentials and sessions are read from `$CLAUDE_CONFIG_DIR`, or `~/.claude` when the variable is unset.
Claude subscription quota requires Claude Code OAuth credentials with usage access. API-key, Amazon Bedrock, and Google
Vertex configurations can still show local Claude activity when compatible session logs exist, but they do not expose
Claude subscription quota through this plugin.

The plugin reads one active account per provider. It does not import browser cookies, automate the Claude `/usage`
screen, switch accounts, or refresh/rewrite either provider's credentials. If a credential expires, sign in again with
the corresponding CLI.

## Dependencies

- `rg` (ripgrep), used to extract structural token metadata from Codex and Claude session JSONL.

`curl`, `jq`, CodexBar, and the Claude CLI are not invoked by the plugin.

## Settings

- **Agent shown in bar:** Codex by default; may be switched to Claude.
- **Codex settings · Show 5-hour limit in bar/panel:** independent Codex controls, both disabled by default.
- **Claude settings · Show 5-hour limit in bar/panel:** independent Claude controls, both enabled by default.

The bar's standard **Color** and **Icon Color** presentation settings tint the usage text and selected-provider glyph.
When unset, usage-based semantic theme colors are used. Selecting an unavailable provider never silently substitutes
the other provider; the bar shows an em dash and sign-in guidance.

## Side effects and privacy

- **Filesystem reads:** credentials and local JSONL session metadata under the active Codex and Claude configuration
  roots.
- **Network:** authenticated quota requests to `https://chatgpt.com/backend-api/wham/usage` and
  `https://api.anthropic.com/api/oauth/usage`. Requests honor Noctalia's offline mode.
- **Filesystem writes:** none.
- **Spawned processes:** ripgrep scans relevant JSONL files. Claude extraction emits only timestamp, message/request
  IDs, session ID, model, token counters, and sidechain status; prompts, responses, and tool payloads are never sent to
  the Luau parser.

Access tokens stay inside the polling service only while a request is created. Credentials, transcript content,
filenames, and project paths are never copied into shared state, logs, tooltips, notifications, or screenshots.

## Troubleshooting

- **Codex quota is unavailable:** run `codex login`, then refresh from the panel.
- **Claude quota is unavailable:** run `claude login`, then refresh from the panel.
- **Only local activity appears:** the session store was readable but subscription quota credentials were not.
- **A provider is stale:** the previous successful quota remains visible; check Noctalia offline mode and the network.
- **Local activity is unavailable:** install `rg` and confirm the corresponding agent has local session JSONL files.
