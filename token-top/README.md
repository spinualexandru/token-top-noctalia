# Token Top

Track Codex, Claude Code, and OpenCode Go quota consumption and local session token activity from the bar.

## Plugin

| Field | Value |
| --- | --- |
| ID | `spinualexandru/token-top` |
| Entries | Bar widget: `usage`; panel: `details`; service: `poller` |

## Features

- A compact bar view showing every enabled provider.
- An Overview tab with quota and activity summaries for every enabled agent.
- Dedicated Codex, Claude, and OpenCode tabs with provider-native quota and local-session detail.
- Independent provider state: an error or stale response from one agent never replaces the other agent's data.
- Automatic refresh at startup and every five minutes, plus a manual refresh for every agent.
- Last-good quota retention with visible stale and sign-in guidance.

Codex detail includes input, output, cached input, reasoning, requests, turns, and thread distribution. Claude detail
includes input, output, cache creation, cache reads, requests, sessions, and model mix.
Claude quota detail also shows model- and surface-scoped weekly limits (such as Fable or Cowork) and how the current
week's usage splits across surfaces like Claude Code, chats, and Cowork.
OpenCode Go detail shows the rolling 5-hour, weekly, and monthly limits, plus input, output, cache, reasoning,
requests, sessions, model mix, and OpenCode's estimated cost.

## Usage

Sign in to one or both supported coding agents:

```sh
codex login
claude login
opencode auth   # choose OpenCode Go
```

Enable `spinualexandru/token-top`, add the **Token Top** widget to a bar, and open its plugin settings. Enable Codex,
Claude, and/or OpenCode Go under their corresponding settings. Click the widget to open Overview. The agent tabs remain
available when an agent is not connected and show the action needed to connect it.

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
- **OpenCode Go token traffic** is input + output + reasoning + cache-read + cache-write tokens from assistant messages
  whose provider is `opencode-go`. The estimated cost is OpenCode's own per-message figure; it does not match Go's
  limit accounting, which is only available as the quota percentages.
- The activity chart divides the active seven-day window into seven 24-hour slices.

## Authentication and supported accounts

Codex credentials and sessions are read from `$CODEX_HOME`, or `~/.codex` when the variable is unset.

Claude Code credentials and sessions are read from `$CLAUDE_CONFIG_DIR`, or `~/.claude` when the variable is unset.
Claude subscription quota requires Claude Code OAuth credentials with usage access. API-key, Amazon Bedrock, and Google
Vertex configurations can still show local Claude activity when compatible session logs exist, but they do not expose
Claude subscription quota through this plugin.

OpenCode data is read from `$XDG_DATA_HOME/opencode`, or `~/.local/share/opencode` when the variable is unset. The Go
API key comes from the active `opencode-go` credential in `opencode.db` (OpenCode v2), falling back to `auth.json`
(OpenCode v1). Local activity comes from the same database's `session_message` table, or `message` on v1.

The plugin reads one active account per provider. It does not import browser cookies, automate the Claude `/usage`
screen, switch accounts, or refresh/rewrite either provider's credentials. If a credential expires, sign in again with
the corresponding CLI.

## Requirements

- Noctalia v5.4.0 or newer (`plugin_api = 43`).
- `rg` (ripgrep), used to extract structural token metadata from Codex and Claude session JSONL.
- `sqlite3`, used for OpenCode Go only, to read the API key and token metadata from OpenCode's database (read-only).

`curl`, `jq`, CodexBar, and the Claude CLI are not invoked by the plugin.

## Settings

- **Codex · Enable:** show or hide Codex quota in the compact bar widget and panel; enabled by default.
- **Claude · Enable:** show or hide Claude quota in the compact bar widget and panel; disabled by default.
- **Codex settings · Show 5-hour limit in bar/panel:** independent Codex controls, both disabled by default.
- **Claude settings · Show 5-hour limit in bar/panel:** independent Claude controls, both enabled by default.
- **OpenCode Go · Enable:** show or hide OpenCode Go quota; disabled by default.
- **OpenCode Go settings · Show 5-hour limit in bar/panel:** OpenCode Go's rolling 5-hour window, both enabled by
  default. The monthly limit appears in the tooltip and panel.

The bar's standard **Color** presentation setting tints the usage text, while **Icon Color** tints the Codex and OpenCode glyphs. The
Claude logo keeps its brand color. When unset, usage-based semantic theme colors are used. Disabling both providers
hides the widget.

A disabled provider is fully idle: the service neither requests its quota nor scans its session logs.

## Side effects and privacy

- **Filesystem reads:** credentials and local JSONL session metadata under the active Codex and Claude configuration
  roots, and OpenCode's database (opened read-only), for enabled providers only.
- **Network:** for enabled providers, authenticated quota requests to `https://chatgpt.com/backend-api/wham/usage` and
  `https://api.anthropic.com/api/oauth/usage`, and `https://opencode.ai/zen/go/v1/usage`. Requests honor Noctalia's offline mode.
- **Filesystem writes:** none.
- **Spawned processes:** ripgrep scans relevant JSONL files. Claude extraction emits only timestamp, message/request
  IDs, session ID, model, token counters, and sidechain status; prompts, responses, and tool payloads are never sent to
  the Luau parser. `sqlite3` reads the OpenCode Go key and, for messages, only IDs, timestamps, model, token counters,
  and cost.

Access tokens stay inside the polling service only while a request is created. Credentials, transcript content,
filenames, and project paths are never copied into shared state, logs, tooltips, notifications, or screenshots.

## Troubleshooting

- **Codex quota is unavailable:** run `codex login`, then refresh from the panel.
- **Claude quota is unavailable:** run `claude login`, then refresh from the panel.
- **OpenCode Go quota is unavailable:** reconnect OpenCode Go with `opencode auth`. Go API keys expire; create a new
  one in OpenCode Console if the key was rejected.
- **Only local activity appears:** the session store was readable but subscription quota credentials were not.
- **A provider is stale:** the previous successful quota remains visible; check Noctalia offline mode and the network.
- **Local activity is unavailable:** install `rg` (`sqlite3` for OpenCode Go) and confirm the corresponding agent has
  local session data.
