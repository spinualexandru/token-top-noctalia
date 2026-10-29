#!/usr/bin/env python3
"""Run the real polling service with a fake clock and HTTP host (no network/auth reads)."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]

HOST = r'''
local now = 1900000000
local config = {
  enable_codex = false,
  enable_claude = true,
  enable_opencode = false,
  show_claude_five_hour_panel = true,
}
local os = { time = function() return now end, date = os.date }
local values, watchers, requests, pending = {}, {}, {}, {}
local scans = 0
local credentialsAvailable = true
local startHttp = true
local noctalia = {
  getConfig = function(key) return config[key] end,
  getenv = function() return nil end,
  expandPath = function(path) return path end,
  tr = function(key) return key end,
  setUpdateInterval = function() end,
  listDir = function()
    scans += 1
    return nil
  end,
  readFile = function(path)
    if path:sub(-17) == ".credentials.json" then
      return credentialsAvailable and "claude-auth" or nil
    end
    return "codex-auth"
  end,
  json = { decode = function(body)
    if body == "claude-auth" then
      return { claudeAiOauth = { accessToken = "fake", scopes = { "user:profile" } } }
    elseif body == "codex-auth" then
      return { tokens = { access_token = "fake" } }
    elseif body == "usage" then
      return {
        five_hour = { utilization = 12, resets_at = "2030-04-01T00:00:00Z" },
        seven_day = { utilization = 42, resets_at = "2030-04-07T00:00:00Z" },
      }
    end
    return nil
  end },
  state = {
    get = function(key) return values[key] end,
    set = function(key, value) values[key] = value end,
    watch = function(key, callback) watchers[key] = callback end,
  },
  http = function(request, callback)
    local name = request.url:find("anthropic", 1, true) and "claude" or "codex"
    requests[name] = (requests[name] or 0) + 1
    if not startHttp then return false end
    assert(pending[name] == nil, "overlapping HTTP requests")
    pending[name] = callback
    return true
  end,
}
local function refresh()
  watchers.refresh_request(1)
end
local function respond(name, status, ok)
  local callback = pending[name]
  assert(callback ~= nil, "no pending request for " .. name)
  pending[name] = nil
  callback({ ok = ok ~= false, status = status, body = "usage" })
end
local function claudeSnapshot()
  return values.usage_snapshot.providers.claude
end
local function expectCount(expected)
  assert(requests.claude == expected, "expected " .. expected .. " Claude requests, got " .. tostring(requests.claude))
end
'''

CHECKS = r'''
-- Startup, rapid update ticks, and manual refresh cannot overlap requests.
expectCount(1)
for _ = 1, 100 do update(); refresh() end
expectCount(1)
respond("claude", 200)
assert(claudeSnapshot().weekly.usedPercent == 42)
for _ = 1, 100 do refresh(); update() end
expectCount(1)
now += 299
refresh(); update()
expectCount(1)
now += 1
update()
expectCount(2)

-- A delayed 429 starts the cooldown at response time and retains good quota.
now += 120
respond("claude", 429)
assert(claudeSnapshot().status == "stale")
assert(claudeSnapshot().weekly.usedPercent == 42)
local scansBefore = scans
refresh()
assert(scans > scansBefore, "local scans must still run during cooldown")
expectCount(2)

-- Toggling Claude off/on or its 5-hour display cannot bypass the cooldown.
config.enable_claude = false
onConfigChanged()
config.enable_claude = true
onConfigChanged()
config.show_claude_five_hour_panel = false
onConfigChanged()
config.show_claude_five_hour_panel = true
onConfigChanged()
expectCount(2)

now += 15 * 60 - 1
refresh(); update()
expectCount(2)

-- Other providers' configuration must not refresh Claude, even when due.
now += 1
config.enable_codex = true
onConfigChanged()
assert(requests.codex == 1)
expectCount(2)
respond("codex", 500)
config.show_five_hour_panel = true
onConfigChanged()
assert(requests.codex == 2)
expectCount(2)
respond("codex", 500)
config.enable_codex = false
onConfigChanged()

-- Repeated 429s double the delay to a one-hour cap. Check both sides of each boundary.
update()
expectCount(3)
for index, delay in ipairs({ 30 * 60, 60 * 60, 60 * 60 }) do
  respond("claude", 429)
  now += delay - 1
  for _ = 1, 20 do refresh(); update() end
  expectCount(2 + index)
  now += 1
  update()
  expectCount(3 + index)
end

-- Success clears the backoff; a later 429 starts again at 15 minutes.
respond("claude", 200)
assert(claudeSnapshot().status == "ready")
now += 299
refresh(); update()
expectCount(6)
now += 1
update()
expectCount(7)
respond("claude", 429)
now += 15 * 60 - 1
refresh(); update()
expectCount(7)
now += 1
update()
expectCount(8)

-- Network, rejected-start, and malformed-response paths also throttle manual refreshes.
respond("claude", 0, false)
refresh(); update()
expectCount(8)
now += 5 * 60
startHttp = false
update()
expectCount(9)
for _ = 1, 20 do refresh(); update() end
expectCount(9)
now += 5 * 60
startHttp = true
update()
expectCount(10)
local callback = pending.claude
pending.claude = nil
callback({ ok = true, status = 200, body = "invalid" })
refresh(); update()
expectCount(10)

-- Disabled Claude is idle. Fixing missing credentials can retry immediately,
-- because a credential read failure did not send an HTTP request.
config.enable_claude = false
onConfigChanged()
now += 5 * 60
refresh(); update()
expectCount(10)
credentialsAvailable = false
config.enable_claude = true
onConfigChanged()
expectCount(10)
assert(claudeSnapshot().error == "errors.claude_auth_missing")
credentialsAvailable = true
refresh()
expectCount(11)
respond("claude", 200)
print("Claude polling: ok (throttling, backoff, config isolation, retained quota, local scans, failure recovery)")
'''

RATE_LIMITED_STARTUP = r'''
respond("claude", 429)
assert(claudeSnapshot().status == "error")
assert(claudeSnapshot().weekly == nil)
now += 15 * 60 - 1
for _ = 1, 20 do refresh(); update() end
expectCount(1)
now += 1
update()
expectCount(2)
respond("claude", 200)
assert(claudeSnapshot().status == "ready")
print("Claude rate-limited startup: ok")
'''


def main() -> None:
    source = (ROOT / "token-top/service.luau").read_text()
    with tempfile.TemporaryDirectory(prefix="token-top-polling-test-") as temp:
        script = Path(temp) / "polling.luau"
        for checks in (CHECKS, RATE_LIMITED_STARTUP):
            script.write_text(HOST + "\n" + source + "\n" + checks)
            subprocess.run(["luau", str(script)], check=True)


if __name__ == "__main__":
    main()
