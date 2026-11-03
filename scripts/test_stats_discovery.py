#!/usr/bin/env python3
"""Exercise session discovery with a bounded fake filesystem host (no user data)."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]

HOST = r'''
local now = 1793692800 -- 2026-11-03T08:00:00Z
local os = { time = function(parts) return parts and os.time(parts) or now end, date = os.date }
local config = { enable_codex = true, enable_claude = true, enable_opencode = false }
local values, watchers, directories, files, extracted = {}, {}, {}, {}, {}
local pendingCommand, interval = nil, nil
local fsCalls, maxFsCalls = 0, 0
local brokenDirectory, rgAvailable = nil, true
local function filesystemCall()
  fsCalls += 1
  assert(fsCalls <= 32, "callback walked too much history without yielding")
end
local function callback(fn)
  fsCalls = 0
  fn()
  maxFsCalls = math.max(maxFsCalls, fsCalls)
end
local function directory(path)
  directories[path] = {}
  files[path] = { isDir = true }
end
local function add(parent, name, isDir, mtime)
  table.insert(directories[parent], name)
  local path = parent .. "/" .. name
  if isDir then
    directory(path)
  else
    files[path] = { size = 100, mtime = mtime or now }
  end
  return path
end
directory("~/.codex/sessions")
directory("~/.claude/projects")
local codexFile = add("~/.codex/sessions", "a.jsonl")
add("~/.codex/sessions", "old.jsonl", false, now - 30 * 86400)
add("~/.codex/sessions", ".hidden", true)
add("~/.codex/sessions/.hidden", "hidden.jsonl")
add("~/.codex/sessions", "notes.txt")
local deep = "~/.codex/sessions"
for index = 1, 180 do deep = add(deep, "d" .. index, true) end
local deepFile = add(deep, "b.jsonl")
for index = 1, 1200 do
  local project = add("~/.claude/projects", "project-" .. index, true)
  add(project, "notes.txt")
end
local claudeFile = add("~/.claude/projects/project-1", "c.jsonl")
local subagents = add("~/.claude/projects/project-1200", "subagents", true)
local subagentFile = add(subagents, "d.jsonl")
add("~/.claude/projects/project-1", ".hidden.jsonl")
add("~/.claude/projects/project-1", "gone.jsonl")
files["~/.claude/projects/project-1/gone.jsonl"] = nil

local noctalia = {
  getConfig = function(key) return config[key] end,
  getenv = function() return nil end,
  expandPath = function(path) return path end,
  tr = function(key) return key end,
  setUpdateInterval = function(ms) interval = ms end,
  listDir = function(path)
    filesystemCall()
    return path ~= brokenDirectory and directories[path] or nil
  end,
  fileInfo = function(path) filesystemCall(); return files[path] end,
  commandExists = function() return rgAvailable end,
  readFile = function() return nil end,
  state = {
    get = function(key) return values[key] end,
    set = function(key, value) values[key] = value end,
    watch = function(key, fn) watchers[key] = fn end,
  },
  runAsync = function(command, fn)
    assert(pendingCommand == nil, "overlapping extraction commands")
    local seen = {}
    for path in command:gmatch("'([^']+%.jsonl)'") do
      if not seen[path] then
        extracted[path] = (extracted[path] or 0) + 1
        seen[path] = true
      end
    end
    local output = {}
    for index in command:gmatch("printf.-'(%d+)' \"%$record\"") do
      local record = command:find("~/.codex", 1, true)
        and "C|2026-11-03T07:00:00Z|100|60|40|10|5"
        or ("2026-11-03T07:00:00Z|msg-" .. index .. "|req|session|test-model|60|0|10|30|false")
      table.insert(output, index .. ":" .. record)
    end
    assert(#output > 0, "fake host could not identify extraction command indices")
    pendingCommand = function()
      fn({ exitCode = 0, stdout = table.concat(output, "\n") .. "\n" })
    end
    return true
  end,
}
'''

CHECKS = r'''
local function stats(name) return values.usage_snapshot.providers[name].tokenStats end
local function drain()
  for _ = 1, 10000 do
    if pendingCommand ~= nil then
      local fn = pendingCommand
      pendingCommand = nil
      callback(fn)
    else
      callback(update)
    end
    if interval == 60000 then return end
  end
  error("stats scheduler did not become idle")
end
local function refresh() callback(function() watchers.refresh_request(1) end); drain() end

assert(fsCalls == 0, "startup must defer filesystem discovery")
drain()
assert(stats("codex").status == "ready" and stats("claude").status == "ready")
assert(stats("codex").sinceReset == 200, "lost nested Codex records")
assert(stats("claude").sinceReset == 200, "lost nested Claude/subagent records")
assert(extracted[codexFile] == 1 and extracted[deepFile] == 1)
assert(extracted[claudeFile] == 1 and extracted[subagentFile] == 1)
local count = 0
for _ in pairs(extracted) do count += 1 end
assert(count == 4, "hidden, old, missing or non-session files were extracted")

-- Unchanged histories reuse their extraction cache; changed and removed files
-- update the totals only after a complete discovery pass.
refresh()
assert(extracted[codexFile] == 1 and extracted[claudeFile] == 1)
files[codexFile].size += 1
files[deepFile] = nil
refresh()
assert(extracted[codexFile] == 2 and extracted[deepFile] == 1)
assert(stats("codex").sinceReset == 100, "deleted session remained in totals")

-- Listing errors must release the scheduler so the other provider can finish.
brokenDirectory = "~/.codex/sessions/d1"
refresh()
assert(stats("codex").status == "unavailable")
assert(stats("claude").status == "ready")
brokenDirectory = nil
refresh()
assert(stats("codex").sinceReset == 100)

-- Missing extraction tools, absent roots, and empty histories also settle.
rgAvailable = false
files[codexFile].size += 1
refresh()
assert(stats("codex").status == "unavailable")
assert(stats("claude").status == "ready")
rgAvailable = true
refresh()
assert(stats("codex").status == "ready")
brokenDirectory = "~/.claude/projects"
refresh()
assert(stats("claude").status == "unavailable")
brokenDirectory = nil
directories["~/.claude/projects"] = {}
refresh()
assert(stats("claude").status == "ready" and stats("claude").sinceReset == 0)
assert(maxFsCalls <= 32)
print("Stats discovery: ok (bounded callbacks, wide/deep histories, filtering, caching, deletion, failure recovery)")
'''


def main() -> None:
    source = (ROOT / "token-top/service.luau").read_text()
    with tempfile.TemporaryDirectory(prefix="token-top-discovery-test-") as temp:
        script = Path(temp) / "discovery.luau"
        script.write_text(HOST + "\n" + source + "\n" + CHECKS)
        subprocess.run(["luau", str(script)], check=True)


if __name__ == "__main__":
    main()
