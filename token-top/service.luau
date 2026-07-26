--!nonstrict

-- The service is the only entry that handles credentials, network access, or
-- local transcript scanning. UI entries receive token-free provider snapshots.

local STATE_KEY = "usage_snapshot"
local REFRESH_REQUEST_KEY = "refresh_request"
local CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
local CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
local POLL_SECONDS = 5 * 60
local STATS_REFRESH_SECONDS = 5 * 60
local IDLE_UPDATE_MS = 60000
local WORK_UPDATE_MS = 32
local SCAN_FILES_PER_COMMAND = 4
local SCAN_RECORDS_PER_TICK = 24
local WEEK_SECONDS = 7 * 24 * 60 * 60
local FIVE_HOUR_SECONDS = 5 * 60 * 60
local CODEX_RECORDS_PER_TICK = 100
local CLAUDE_RECORDS_PER_TICK = 100

local providers = {
  codex = {
    name = "codex",
    inFlight = false,
    nextPollAt = 0,
    nextStatsScanAt = 0,
    lastGood = nil,
    status = "loading",
    error = nil,
    attemptedAt = nil,
    tokenStats = { status = "loading" },
    statsCache = {},
    statsCacheReady = false,
    pendingScan = false,
  },
  claude = {
    name = "claude",
    inFlight = false,
    nextPollAt = 0,
    nextStatsScanAt = 0,
    lastGood = nil,
    status = "loading",
    error = nil,
    attemptedAt = nil,
    tokenStats = { status = "loading" },
    statsCache = {},
    statsCacheReady = false,
    pendingScan = false,
  },
}

local providerOrder = { "codex", "claude" }
local activeScan = nil
local activeAggregation = nil
local scanGeneration = 0

local function tr(key, substitutions)
  return noctalia.tr(key, substitutions)
end

local function configEnabled(key)
  local value = noctalia.getConfig(key)
  return value == true or value == "true"
end

local function shouldTrackFiveHour(providerName)
  if providerName == "claude" then
    return configEnabled("show_claude_five_hour_bar") or configEnabled("show_claude_five_hour_panel")
  end
  return configEnabled("show_five_hour_bar") or configEnabled("show_five_hour_panel")
end

local trackingFiveHour = {
  codex = shouldTrackFiveHour("codex"),
  claude = shouldTrackFiveHour("claude"),
}

local function codexHome()
  local configured = noctalia.getenv("CODEX_HOME")
  if type(configured) == "string" and noctalia.string.trim(configured) ~= "" then
    return noctalia.expandPath(configured):gsub("/+$", "")
  end
  return noctalia.expandPath("~/.codex")
end

local function claudeHome()
  local configured = noctalia.getenv("CLAUDE_CONFIG_DIR")
  if type(configured) == "string" and noctalia.string.trim(configured) ~= "" then
    -- Claude Code documents one configuration root. If a future version accepts
    -- a list, the first root remains the active credential owner.
    local first = configured:match("^%s*([^,]+)")
    return noctalia.expandPath(noctalia.string.trim(first or configured)):gsub("/+$", "")
  end
  return noctalia.expandPath("~/.claude")
end

local function providerSnapshot(provider)
  local quota = provider.lastGood
  local hasQuota = type(quota) == "table"
  local hasLocal = type(provider.tokenStats) == "table" and provider.tokenStats.status == "ready"
  local availability = if hasQuota then "connected" elseif hasLocal then "local_only" else "unavailable"
  local status = provider.status
  if status == "error" and hasQuota then
    status = "stale"
  end

  local snapshot = {
    availability = availability,
    status = status,
    error = provider.error,
    attemptedAt = provider.attemptedAt,
    stale = status == "stale",
    tokenStats = provider.tokenStats,
  }

  if hasQuota then
    snapshot.planType = quota.planType
    snapshot.fiveHour = quota.fiveHour
    snapshot.weekly = quota.weekly
    snapshot.scopedWindows = quota.scopedWindows
    snapshot.extraUsage = quota.extraUsage
    snapshot.updatedAt = quota.updatedAt
  end

  return snapshot
end

local function publishAll()
  local codex = providerSnapshot(providers.codex)
  local claude = providerSnapshot(providers.claude)
  local refreshedAt = math.max(
    tonumber(codex.updatedAt) or 0,
    tonumber(claude.updatedAt) or 0,
    type(codex.tokenStats) == "table" and (tonumber(codex.tokenStats.updatedAt) or 0) or 0,
    type(claude.tokenStats) == "table" and (tonumber(claude.tokenStats.updatedAt) or 0) or 0
  )
  noctalia.state.set(STATE_KEY, {
    providers = {
      codex = codex,
      claude = claude,
    },
    refreshedAt = refreshedAt > 0 and refreshedAt or nil,
  })
end

local function publishProvider(provider, status, errorMessage, attemptedAt)
  provider.status = status
  provider.error = errorMessage
  provider.attemptedAt = attemptedAt
  publishAll()
end

local function failProvider(provider, message, attemptedAt)
  provider.inFlight = false
  publishProvider(provider, "error", message, attemptedAt)
end

-- Convert UTC timestamps without depending on the machine's local timezone.
local function daysFromCivil(year, month, day)
  year -= month <= 2 and 1 or 0
  local era = (year >= 0 and year or year - 399) // 400
  local yearOfEra = year - era * 400
  local shiftedMonth = month + (month > 2 and -3 or 9)
  local dayOfYear = (153 * shiftedMonth + 2) // 5 + day - 1
  local dayOfEra = yearOfEra * 365 + yearOfEra // 4 - yearOfEra // 100 + dayOfYear
  return era * 146097 + dayOfEra - 719468
end

local function parseIsoTimestamp(value)
  if type(value) ~= "string" then
    return nil
  end

  local year, month, day, hour, minute, second =
    value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  year = tonumber(year)
  month = tonumber(month)
  day = tonumber(day)
  hour = tonumber(hour)
  minute = tonumber(minute)
  second = tonumber(second)
  if year == nil or month == nil or day == nil or hour == nil or minute == nil or second == nil then
    return nil
  end

  local timestamp = daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
  local sign, offsetHour, offsetMinute = value:match("([%+%-])(%d%d):(%d%d)$")
  if sign ~= nil then
    local offset = (tonumber(offsetHour) or 0) * 3600 + (tonumber(offsetMinute) or 0) * 60
    timestamp += sign == "+" and -offset or offset
  end
  return timestamp
end

local function localMidnight(timestamp)
  local parts = os.date("*t", timestamp)
  parts.hour = 0
  parts.min = 0
  parts.sec = 0
  parts.isdst = nil
  return os.time(parts)
end

local function collectSessionFiles(directory, files)
  local entries, listError = noctalia.listDir(directory)
  if entries == nil then
    return false, listError
  end

  table.sort(entries)
  for _, name in ipairs(entries) do
    if name:sub(1, 1) ~= "." then
      local path = directory .. "/" .. name
      local info = noctalia.fileInfo(path)
      if info ~= nil and info.isDir then
        local ok, childError = collectSessionFiles(path, files)
        if not ok then
          return false, childError
        end
      elseif info ~= nil and name:sub(-6) == ".jsonl" then
        table.insert(files, { path = path, size = info.size, mtime = info.mtime })
      end
    end
  end
  return true, nil
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function positiveDelta(current, previous)
  local delta = current - previous
  if delta < 0 then
    return math.max(0, current)
  end
  return math.max(0, delta)
end

-- Codex session parsing -------------------------------------------------------

local function splitDelimited(value, expectedFields)
  local fields = {}
  local start = 1
  while #fields < expectedFields - 1 do
    local separator = value:find("|", start, true)
    if separator == nil then
      return nil
    end
    table.insert(fields, value:sub(start, separator - 1))
    start = separator + 1
  end
  table.insert(fields, value:sub(start))
  return #fields == expectedFields and fields or nil
end

local function parseCodexStatsRecord(recordText, cached)
  local kind = recordText:sub(1, 1)
  if kind == "T" then
    local fields = splitDelimited(recordText, 3)
    local occurredAt = fields ~= nil and parseIsoTimestamp(fields[2]) or nil
    if occurredAt ~= nil then
      table.insert(cached.turns, { occurredAt = occurredAt, id = fields[3] })
    end
    return
  end
  if kind ~= "C" then
    return
  end

  local fields = splitDelimited(recordText, 7)
  local occurredAt = fields ~= nil and parseIsoTimestamp(fields[2]) or nil
  local total = fields ~= nil and tonumber(fields[3]) or nil
  if occurredAt == nil or total == nil then
    return
  end
  table.insert(cached.samples, {
    occurredAt = occurredAt,
    total = math.max(0, total),
    input = math.max(0, tonumber(fields[4]) or 0),
    output = math.max(0, tonumber(fields[5]) or 0),
    cached = math.max(0, tonumber(fields[6]) or 0),
    reasoning = math.max(0, tonumber(fields[7]) or 0),
  })
end

local function emptyCodexSummary()
  return { total = 0, input = 0, output = 0, cached = 0, reasoning = 0, requests = 0, turns = 0 }
end

local function addCodexDeltas(summary, deltas)
  summary.total += deltas.total
  summary.input += deltas.input
  summary.output += deltas.output
  summary.cached += deltas.cached
  summary.reasoning += deltas.reasoning
  if deltas.total > 0 then
    summary.requests += 1
  end
end

local function selectCodexThread(selected, threadId, summary)
  if summary.total <= 0 and summary.turns <= 0 then
    return
  end
  local previous = selected[threadId]
  if previous == nil
    or summary.total > previous.total
    or (summary.total == previous.total and summary.turns > previous.turns)
  then
    selected[threadId] = summary
  end
end

local function aggregateCodexThreads(selected)
  local aggregate = { total = 0, input = 0, output = 0, cached = 0, reasoning = 0, requests = 0, turns = 0 }
  for _, summary in pairs(selected) do
    for key, _ in pairs(aggregate) do
      aggregate[key] += summary[key] or 0
    end
  end
  return aggregate
end

local function buildCodexTokenStats(context)
  local current = aggregateCodexThreads(context.current)
  local today = aggregateCodexThreads(context.today)
  local previous = aggregateCodexThreads(context.previous)
  local perThread = {}
  local largestThread = 0
  for _, summary in pairs(context.current) do
    if summary.total > 0 then
      table.insert(perThread, summary.total)
      largestThread = math.max(largestThread, summary.total)
    end
  end
  table.sort(perThread)

  local threadCount = #perThread
  local medianPerThread = 0
  if threadCount > 0 then
    local middle = (threadCount + 1) // 2
    medianPerThread = if threadCount % 2 == 0
      then math.floor((perThread[middle] + perThread[middle + 1]) / 2 + 0.5)
      else perThread[middle]
  end

  local dailyActivity = {}
  for index = 1, 7 do
    local bucket = aggregateCodexThreads(context.daily[index])
    table.insert(dailyActivity, {
      startedAt = math.floor(context.windowStartedAt + (index - 1) * context.bucketSeconds),
      tokens = math.floor(bucket.total + 0.5),
    })
  end

  local elapsedSeconds = math.max(1, context.now - context.windowStartedAt)
  local projectedByReset = nil
  local previousChangePercent = nil
  if context.windowMode == "exact" then
    projectedByReset = math.floor(current.total * context.windowSeconds / elapsedSeconds + 0.5)
    if previous.total > 0 then
      previousChangePercent = math.floor(((projectedByReset - previous.total) / previous.total) * 100 + 0.5)
    end
  end

  return {
    status = "ready",
    windowMode = context.windowMode,
    sinceReset = math.floor(current.total + 0.5),
    today = math.floor(today.total + 0.5),
    averagePerDay = math.floor(current.total * 86400 / elapsedSeconds + 0.5),
    averagePerThread = threadCount > 0 and math.floor(current.total / threadCount + 0.5) or 0,
    medianPerThread = medianPerThread,
    largestThread = math.floor(largestThread + 0.5),
    largestThreadPercent = current.total > 0 and math.floor(largestThread / current.total * 100 + 0.5) or 0,
    threadCount = threadCount,
    requestCount = current.requests,
    turnCount = current.turns,
    inputTokens = math.floor(current.input + 0.5),
    outputTokens = math.floor(current.output + 0.5),
    cachedInputTokens = math.floor(current.cached + 0.5),
    cachedInputPercent = current.input > 0 and math.floor(current.cached / current.input * 100 + 0.5) or 0,
    reasoningTokens = math.floor(current.reasoning + 0.5),
    reasoningPercent = current.output > 0 and math.floor(current.reasoning / current.output * 100 + 0.5) or 0,
    dailyActivity = dailyActivity,
    projectedByReset = projectedByReset,
    previousWindow = math.floor(previous.total + 0.5),
    previousChangePercent = previousChangePercent,
    resetStartedAt = context.windowStartedAt,
    updatedAt = os.time(),
  }
end

-- Claude session parsing ------------------------------------------------------

local function parseClaudeStatsLine(line, cached)
  local _, recordText = line:match("^(.-):(%d%d%d%d%-.*)$")
  if recordText == nil then
    return
  end
  local fields = splitDelimited(recordText, 10)
  if fields == nil or #fields ~= 10 then
    return
  end

  local occurredAt = parseIsoTimestamp(fields[1])
  local messageId = fields[2]
  local requestId = fields[3]
  local sessionId = fields[4]
  if occurredAt == nil or messageId == "" or sessionId == "" then
    return
  end

  local record = {
    occurredAt = occurredAt,
    messageId = messageId,
    requestId = requestId,
    sessionId = sessionId,
    model = fields[5] ~= "" and fields[5] or "Unknown",
    input = math.max(0, tonumber(fields[6]) or 0),
    cacheCreate = math.max(0, tonumber(fields[7]) or 0),
    cacheRead = math.max(0, tonumber(fields[8]) or 0),
    output = math.max(0, tonumber(fields[9]) or 0),
    sidechain = fields[10] == "true",
  }
  record.total = record.input + record.cacheCreate + record.cacheRead + record.output
  record.key = requestId ~= "" and (messageId .. "|" .. requestId) or messageId
  -- The later line is the latest cumulative streaming chunk.
  cached.records[record.key] = record
end

local function preferClaudeRecord(current, candidate)
  if current == nil then
    return candidate
  end
  if current.sidechain ~= candidate.sidechain then
    return candidate.sidechain and current or candidate
  end
  if candidate.total > current.total then
    return candidate
  end
  if candidate.total == current.total and candidate.occurredAt >= current.occurredAt then
    return candidate
  end
  return current
end

local function addClaudeUsage(summary, record)
  summary.total += record.total
  summary.input += record.input
  summary.cacheCreate += record.cacheCreate
  summary.cacheRead += record.cacheRead
  summary.output += record.output
  summary.requests += 1
end

local function emptyClaudeUsage()
  return { total = 0, input = 0, cacheCreate = 0, cacheRead = 0, output = 0, requests = 0 }
end

local function summarizeClaudeRecord(context, record)
  local timestamp = record.occurredAt
  if timestamp >= context.windowStartedAt and timestamp < context.windowEndedAt then
    addClaudeUsage(context.currentUsage, record)
    context.sessionTotals[record.sessionId] = (context.sessionTotals[record.sessionId] or 0) + record.total
    local model = context.modelTotals[record.model]
    if model == nil then
      model = { name = record.model, tokens = 0, requests = 0 }
      context.modelTotals[record.model] = model
    end
    model.tokens += record.total
    model.requests += 1

    local bucket = math.floor((timestamp - context.windowStartedAt) / context.bucketSeconds) + 1
    bucket = math.max(1, math.min(7, bucket))
    context.daily[bucket] += record.total
  elseif timestamp >= context.previousStartedAt and timestamp < context.windowStartedAt then
    addClaudeUsage(context.previousUsage, record)
  end

  if timestamp >= context.todayStartedAt and timestamp < context.now + 1 then
    addClaudeUsage(context.todayUsage, record)
  end
end

local function buildClaudeModelMix(modelTotals)
  local models = {}
  for _, model in pairs(modelTotals) do
    table.insert(models, model)
  end
  table.sort(models, function(a, b)
    if a.tokens == b.tokens then
      return a.name < b.name
    end
    return a.tokens > b.tokens
  end)

  if #models <= 3 then
    return models
  end
  local result = { models[1], models[2], models[3] }
  local other = { name = "Other", tokens = 0, requests = 0 }
  for index = 4, #models do
    other.tokens += models[index].tokens
    other.requests += models[index].requests
  end
  table.insert(result, other)
  return result
end

local function buildClaudeTokenStats(context)
  local perSession = {}
  local largestSession = 0
  for _, total in pairs(context.sessionTotals) do
    if total > 0 then
      table.insert(perSession, total)
      largestSession = math.max(largestSession, total)
    end
  end
  table.sort(perSession)

  local sessionCount = #perSession
  local medianPerSession = 0
  if sessionCount > 0 then
    local middle = (sessionCount + 1) // 2
    medianPerSession = if sessionCount % 2 == 0
      then math.floor((perSession[middle] + perSession[middle + 1]) / 2 + 0.5)
      else perSession[middle]
  end

  local dailyActivity = {}
  for index = 1, 7 do
    table.insert(dailyActivity, {
      startedAt = math.floor(context.windowStartedAt + (index - 1) * context.bucketSeconds),
      tokens = math.floor(context.daily[index] + 0.5),
    })
  end

  local current = context.currentUsage
  local previous = context.previousUsage
  local elapsedSeconds = math.max(1, context.now - context.windowStartedAt)
  local projectedByReset = nil
  local previousChangePercent = nil
  if context.windowMode == "exact" then
    projectedByReset = math.floor(current.total * context.windowSeconds / elapsedSeconds + 0.5)
    if previous.total > 0 then
      previousChangePercent = math.floor(((projectedByReset - previous.total) / previous.total) * 100 + 0.5)
    end
  end

  return {
    status = "ready",
    windowMode = context.windowMode,
    sinceReset = math.floor(current.total + 0.5),
    today = math.floor(context.todayUsage.total + 0.5),
    averagePerDay = math.floor(current.total * 86400 / elapsedSeconds + 0.5),
    averagePerSession = sessionCount > 0 and math.floor(current.total / sessionCount + 0.5) or 0,
    medianPerSession = medianPerSession,
    largestSession = math.floor(largestSession + 0.5),
    largestSessionPercent = current.total > 0 and math.floor(largestSession / current.total * 100 + 0.5) or 0,
    sessionCount = sessionCount,
    requestCount = current.requests,
    inputTokens = math.floor(current.input + 0.5),
    outputTokens = math.floor(current.output + 0.5),
    cacheCreationInputTokens = math.floor(current.cacheCreate + 0.5),
    cacheReadInputTokens = math.floor(current.cacheRead + 0.5),
    dailyActivity = dailyActivity,
    modelMix = buildClaudeModelMix(context.modelTotals),
    projectedByReset = projectedByReset,
    previousWindow = math.floor(previous.total + 0.5),
    previousChangePercent = previousChangePercent,
    resetStartedAt = context.windowStartedAt,
    updatedAt = os.time(),
  }
end

-- Cooperative scan and aggregation scheduler --------------------------------

local function statsWindow(provider)
  local weekly = type(provider.lastGood) == "table" and provider.lastGood.weekly or nil
  local resetAt = type(weekly) == "table" and tonumber(weekly.resetAt) or nil
  local windowSeconds = type(weekly) == "table" and tonumber(weekly.windowSeconds) or nil
  if resetAt ~= nil and windowSeconds ~= nil and windowSeconds > 0 and resetAt > os.time() then
    local now = math.min(os.time(), resetAt)
    return {
      mode = "exact",
      now = now,
      endedAt = resetAt,
      startedAt = resetAt - windowSeconds,
      seconds = windowSeconds,
    }
  end

  local now = os.time()
  return {
    mode = "rolling",
    now = now,
    endedAt = now + 1,
    startedAt = now - WEEK_SECONDS,
    seconds = WEEK_SECONDS,
  }
end

local function beginStatsAggregation(providerName)
  local provider = providers[providerName]
  if not provider.statsCacheReady or activeScan ~= nil or activeAggregation ~= nil then
    provider.pendingScan = true
    return false
  end

  local window = statsWindow(provider)
  local queue = {}
  for _, cached in pairs(provider.statsCache) do
    table.insert(queue, cached)
  end
  local daily = {}
  for index = 1, 7 do
    daily[index] = providerName == "codex" and {} or 0
  end

  local context = {
    providerName = providerName,
    phase = providerName == "codex" and "codex" or "merge",
    queue = queue,
    queueIndex = 1,
    iteratorKey = nil,
    records = {},
    windowMode = window.mode,
    now = window.now,
    windowStartedAt = window.startedAt,
    windowEndedAt = window.endedAt,
    windowSeconds = window.seconds,
    previousStartedAt = window.startedAt - window.seconds,
    todayStartedAt = localMidnight(window.now),
    bucketSeconds = window.seconds / 7,
    daily = daily,
  }

  if providerName == "codex" then
    context.current = {}
    context.today = {}
    context.previous = {}
  else
    context.currentUsage = emptyClaudeUsage()
    context.todayUsage = emptyClaudeUsage()
    context.previousUsage = emptyClaudeUsage()
    context.sessionTotals = {}
    context.modelTotals = {}
  end

  activeAggregation = context
  if provider.tokenStats.status ~= "ready" then
    provider.tokenStats = { status = "loading", calculating = true }
  end
  noctalia.setUpdateInterval(WORK_UPDATE_MS)
  publishAll()
  return true
end

local beginProviderStatsScan

local function startNextStatsWork()
  if activeScan ~= nil or activeAggregation ~= nil then
    return
  end
  for _, name in ipairs(providerOrder) do
    local provider = providers[name]
    if provider.pendingScan then
      provider.pendingScan = false
      -- Forward declaration is resolved when the scheduler runs.
      beginProviderStatsScan(name)
      return
    end
  end
  noctalia.setUpdateInterval(IDLE_UPDATE_MS)
end

local function finishStatsAggregation()
  local context = activeAggregation
  if context == nil then
    return
  end
  local provider = providers[context.providerName]
  provider.tokenStats = context.providerName == "codex"
    and buildCodexTokenStats(context)
    or buildClaudeTokenStats(context)
  activeAggregation = nil
  publishAll()
  startNextStatsWork()
end

local function processCodexAggregation(context)
  local processed = 0
  while processed < CODEX_RECORDS_PER_TICK do
    local work = context.fileWork
    if work == nil then
      local cached = context.queue[context.queueIndex]
      if cached == nil then
        finishStatsAggregation()
        return
      end
      local daily = {}
      for index = 1, 7 do
        daily[index] = emptyCodexSummary()
      end
      work = {
        cached = cached,
        sampleIndex = 1,
        turnIndex = 1,
        previousTotals = { total = 0, input = 0, output = 0, cached = 0, reasoning = 0 },
        current = emptyCodexSummary(),
        today = emptyCodexSummary(),
        previous = emptyCodexSummary(),
        daily = daily,
      }
      context.fileWork = work
    end

    local sample = work.cached.samples[work.sampleIndex]
    if sample ~= nil then
      local deltas = {
        total = positiveDelta(sample.total or 0, work.previousTotals.total),
        input = positiveDelta(sample.input or 0, work.previousTotals.input),
        output = positiveDelta(sample.output or 0, work.previousTotals.output),
        cached = positiveDelta(sample.cached or 0, work.previousTotals.cached),
        reasoning = positiveDelta(sample.reasoning or 0, work.previousTotals.reasoning),
      }
      local occurredAt = sample.occurredAt
      if occurredAt >= context.windowStartedAt and occurredAt < context.windowEndedAt then
        addCodexDeltas(work.current, deltas)
        local bucket = math.floor((occurredAt - context.windowStartedAt) / context.bucketSeconds) + 1
        if bucket >= 1 and bucket <= 7 then
          addCodexDeltas(work.daily[bucket], deltas)
        end
      end
      if occurredAt >= context.todayStartedAt and occurredAt <= context.now then
        addCodexDeltas(work.today, deltas)
      end
      if occurredAt >= context.previousStartedAt and occurredAt < context.windowStartedAt then
        addCodexDeltas(work.previous, deltas)
      end
      work.previousTotals.total = sample.total or 0
      work.previousTotals.input = sample.input or 0
      work.previousTotals.output = sample.output or 0
      work.previousTotals.cached = sample.cached or 0
      work.previousTotals.reasoning = sample.reasoning or 0
      work.sampleIndex += 1
      processed += 1
    else
      local turn = work.cached.turns[work.turnIndex]
      if turn ~= nil then
        local occurredAt = turn.occurredAt
        if occurredAt >= context.windowStartedAt and occurredAt < context.windowEndedAt then
          work.current.turns += 1
          local bucket = math.floor((occurredAt - context.windowStartedAt) / context.bucketSeconds) + 1
          if bucket >= 1 and bucket <= 7 then
            work.daily[bucket].turns += 1
          end
        end
        if occurredAt >= context.todayStartedAt and occurredAt <= context.now then
          work.today.turns += 1
        end
        if occurredAt >= context.previousStartedAt and occurredAt < context.windowStartedAt then
          work.previous.turns += 1
        end
        work.turnIndex += 1
        processed += 1
      else
        local threadId = work.cached.threadId
        selectCodexThread(context.current, threadId, work.current)
        selectCodexThread(context.today, threadId, work.today)
        selectCodexThread(context.previous, threadId, work.previous)
        for index = 1, 7 do
          selectCodexThread(context.daily[index], threadId, work.daily[index])
        end
        context.queueIndex += 1
        context.fileWork = nil
      end
    end
  end
end

local function processClaudeMerge(context)
  local processed = 0
  while processed < CLAUDE_RECORDS_PER_TICK do
    local cached = context.queue[context.queueIndex]
    if cached == nil then
      context.phase = "summarize"
      context.iteratorKey = nil
      return
    end

    local key, record = next(cached.records, context.iteratorKey)
    if key == nil then
      context.queueIndex += 1
      context.iteratorKey = nil
    else
      context.iteratorKey = key
      context.records[key] = preferClaudeRecord(context.records[key], record)
      processed += 1
    end
  end
end

local function processClaudeSummaries(context)
  local processed = 0
  while processed < CLAUDE_RECORDS_PER_TICK do
    local key, record = next(context.records, context.iteratorKey)
    if key == nil then
      finishStatsAggregation()
      return
    end
    context.iteratorKey = key
    summarizeClaudeRecord(context, record)
    processed += 1
  end
end

local function processStatsAggregation()
  local context = activeAggregation
  if context == nil then
    return
  end
  if context.phase == "codex" then
    processCodexAggregation(context)
  elseif context.phase == "merge" then
    processClaudeMerge(context)
  else
    processClaudeSummaries(context)
  end
end

local function codexFileCommand(path)
  local tokenPattern = [[^\{"timestamp":"(?<timestamp>[^"]+)","type":"event_msg","payload":\{"type":"token_count","info":\{"total_token_usage":\{(?=[^\r\n]*?"input_tokens":(?<input>\d+))(?=[^\r\n]*?"cached_input_tokens":(?<cached>\d+))(?=[^\r\n]*?"output_tokens":(?<output>\d+))(?=[^\r\n]*?"reasoning_output_tokens":(?<reasoning>\d+))(?=[^\r\n]*?"total_tokens":(?<total>\d+))]]
  local turnPattern = [[^\{"timestamp":"(?<timestamp>[^"]+)","type":"turn_context","payload":\{"turn_id":"(?<turn>[^"]+)"]]
  local tokenReplacement = "C|$timestamp|$total|$input|$output|$cached|$reasoning"
  local turnReplacement = "T|$timestamp|$turn"
  return "{ rg --no-messages --no-filename --no-line-number --color never -P -o --replace "
    .. shellQuote(tokenReplacement)
    .. " "
    .. shellQuote(tokenPattern)
    .. " "
    .. shellQuote(path)
    .. "; rg --no-messages --no-filename --no-line-number --color never -P -o --replace "
    .. shellQuote(turnReplacement)
    .. " "
    .. shellQuote(turnPattern)
    .. " "
    .. shellQuote(path)
    .. "; }"
end

local function claudeFileCommand(path)
  local pattern = [[^(?=\{"parentUuid":)(?=.*"type":"assistant","uuid":"[^"]+","timestamp":"(?<timestamp>[^"]+)")(?=.*"isSidechain":(?<side>true|false))(?=.*"message":\{"model":"(?<model>[^"]+)","id":"(?<message>[^"]+)")(?=.*,"usage":\{(?=[^\r\n]*?"input_tokens":(?<input>\d+))(?=[^\r\n]*?"cache_creation_input_tokens":(?<create>\d+))(?=[^\r\n]*?"cache_read_input_tokens":(?<read>\d+))(?=[^\r\n]*?"output_tokens":(?<output>\d+)))(?=.*,"cwd":"(?:\\.|[^"])*","sessionId":"(?<session>[^"]+)")(?:(?=.*\},"requestId":"(?<request>[^"]+)".*"type":"assistant"))?]]
  local replacement = "$timestamp|$message|$request|$session|$model|$input|$create|$read|$output|$side"
  return "rg --no-messages --no-filename --no-line-number --color never -P -o --replace "
    .. shellQuote(replacement)
    .. " "
    .. shellQuote(pattern)
    .. " "
    .. shellQuote(path)
end

local function statsBatchCommand(scan, startedAt, endedAt)
  local commands = {}
  for index = startedAt, endedAt do
    local fileCommand = scan.providerName == "codex"
      and codexFileCommand(scan.queue[index].file.path)
      or claudeFileCommand(scan.queue[index].file.path)
    table.insert(commands, "{ " .. fileCommand .. "; } | while IFS= read -r record; do printf '%s:%s\\n' "
      .. shellQuote(tostring(index))
      .. " \"$record\"; done")
  end
  return table.concat(commands, "; ")
end

local function finishStatsScan(providerName)
  local scan = activeScan
  if scan == nil or scan.providerName ~= providerName then
    return
  end
  local provider = providers[providerName]
  for path, _ in pairs(provider.statsCache) do
    if not scan.seenPaths[path] then
      provider.statsCache[path] = nil
    end
  end
  activeScan = nil
  provider.statsCacheReady = true
  provider.nextStatsScanAt = os.time() + STATS_REFRESH_SECONDS
  publishAll()
  if not beginStatsAggregation(providerName) then
    startNextStatsWork()
  end
end

local function handleStatsRecord(record)
  local scan = activeScan
  if scan == nil then
    return
  end
  local indexText, recordText = record:match("^(%d+):(.+)$")
  local entry = indexText ~= nil and scan.queue[tonumber(indexText)] or nil
  if type(entry) ~= "table" or type(entry.cache) ~= "table" or recordText == nil then
    return
  end
  if scan.providerName == "codex" then
    parseCodexStatsRecord(recordText, entry.cache)
  else
    parseClaudeStatsLine(indexText .. ":" .. recordText, entry.cache)
  end
end

local function onStatsBatchResult(providerName, generation, result)
  local scan = activeScan
  if scan == nil or scan.providerName ~= providerName or scan.generation ~= generation then
    return
  end
  scan.commandInFlight = false
  scan.batchFailed = result.timedOut == true
    or result.stdoutTruncated == true
    or tonumber(result.exitCode) == nil
    or tonumber(result.exitCode) > 1
  scan.pendingOutput = scan.batchFailed and "" or (result.stdout or "")
  scan.outputOffset = 1
  noctalia.setUpdateInterval(WORK_UPDATE_MS)
end

local function launchStatsBatch(scan)
  if scan.commandInFlight or scan.pendingOutput ~= nil then
    return
  end
  if scan.nextCommandIndex > #scan.queue then
    finishStatsScan(scan.providerName)
    return
  end

  scan.batchStartedAt = scan.nextCommandIndex
  scan.batchEndedAt = math.min(#scan.queue, scan.batchStartedAt + SCAN_FILES_PER_COMMAND - 1)
  scan.batchFailed = false
  scan.commandInFlight = true
  local generation = scan.generation
  local command = statsBatchCommand(scan, scan.batchStartedAt, scan.batchEndedAt)
  local started = noctalia.runAsync(command, function(result)
    onStatsBatchResult(scan.providerName, generation, result)
  end, 30000)
  if not started then
    scan.commandInFlight = false
    scan.batchFailed = true
    scan.pendingOutput = ""
    scan.outputOffset = 1
  end
end

local function completeStatsBatch(scan)
  local provider = providers[scan.providerName]
  if not scan.batchFailed then
    for index = scan.batchStartedAt, scan.batchEndedAt do
      local entry = scan.queue[index]
      provider.statsCache[entry.file.path] = entry.cache
    end
  end
  scan.nextCommandIndex = scan.batchEndedAt + 1
  scan.pendingOutput = nil
  scan.outputOffset = 1
  launchStatsBatch(scan)
end

local function processStatsScan()
  local scan = activeScan
  if scan == nil then
    return
  end

  if scan.pendingOutput == nil then
    launchStatsBatch(scan)
    return
  end

  local processed = 0
  while processed < SCAN_RECORDS_PER_TICK do
    local newline = scan.pendingOutput:find("\n", scan.outputOffset, true)
    if newline == nil then
      if scan.outputOffset <= #scan.pendingOutput then
        handleStatsRecord(scan.pendingOutput:sub(scan.outputOffset))
        processed += 1
      end
      completeStatsBatch(scan)
      return
    else
      handleStatsRecord(scan.pendingOutput:sub(scan.outputOffset, newline - 1))
      scan.outputOffset = newline + 1
      processed += 1
    end
  end
end

beginProviderStatsScan = function(providerName)
  if activeScan ~= nil or activeAggregation ~= nil then
    providers[providerName].pendingScan = true
    return
  end

  local provider = providers[providerName]
  local root = providerName == "codex" and (codexHome() .. "/sessions") or (claudeHome() .. "/projects")
  local files = {}
  local ok = collectSessionFiles(root, files)
  if not ok then
    provider.tokenStats = { status = "unavailable" }
    provider.statsCacheReady = false
    provider.nextStatsScanAt = os.time() + STATS_REFRESH_SECONDS
    publishAll()
    startNextStatsWork()
    return
  end

  local window = statsWindow(provider)
  local scanStartedAt = window.startedAt - window.seconds - 86400
  local queue = {}
  local seenPaths = {}
  for _, file in ipairs(files) do
    if file.mtime >= scanStartedAt then
      seenPaths[file.path] = true
      local cached = provider.statsCache[file.path]
      if cached == nil or cached.size ~= file.size or cached.mtime ~= file.mtime then
        cached = {
          size = file.size,
          mtime = file.mtime,
        }
        if providerName == "codex" then
          cached.threadId = file.path:match("([0-9a-f%-]+)%.jsonl$") or file.path
          cached.samples = {}
          cached.turns = {}
        else
          cached.records = {}
        end
        table.insert(queue, { file = file, cache = cached })
      end
    end
  end

  scanGeneration += 1
  activeScan = {
    providerName = providerName,
    seenPaths = seenPaths,
    queue = queue,
    nextCommandIndex = 1,
    commandInFlight = false,
    pendingOutput = nil,
    outputOffset = 1,
    batchStartedAt = 0,
    batchEndedAt = 0,
    batchFailed = false,
    generation = scanGeneration,
  }
  if #queue == 0 then
    finishStatsScan(providerName)
    return
  end

  if not provider.statsCacheReady then
    provider.tokenStats = { status = "loading", processedFiles = 0, totalFiles = #queue }
    publishAll()
  end
  noctalia.setUpdateInterval(WORK_UPDATE_MS)
  if not noctalia.commandExists("rg") then
    activeScan = nil
    provider.tokenStats = { status = "unavailable" }
    provider.nextStatsScanAt = os.time() + STATS_REFRESH_SECONDS
    publishAll()
    startNextStatsWork()
    return
  end
  launchStatsBatch(activeScan)
end

local function scheduleStatsScan(providerName)
  providers[providerName].pendingScan = true
  noctalia.setUpdateInterval(WORK_UPDATE_MS)
  startNextStatsWork()
end

-- Quota providers ------------------------------------------------------------

local function decodeCodexWindow(value)
  if type(value) ~= "table" then
    return nil
  end
  local usedPercent = tonumber(value.used_percent)
  local resetAt = tonumber(value.reset_at)
  local windowSeconds = tonumber(value.limit_window_seconds)
  if usedPercent == nil or resetAt == nil or windowSeconds == nil or windowSeconds <= 0 then
    return nil
  end
  return {
    usedPercent = math.max(0, math.min(100, usedPercent)),
    resetAt = math.floor(resetAt),
    windowSeconds = math.floor(windowSeconds),
  }
end

local function codexWindowRole(window)
  if window == nil then
    return "missing"
  elseif window.windowSeconds == FIVE_HOUR_SECONDS then
    return "five_hour"
  elseif window.windowSeconds == WEEK_SECONDS then
    return "weekly"
  end
  return "unknown"
end

local function normalizeCodexWindows(rateLimit, includeFiveHour)
  local primary = decodeCodexWindow(rateLimit.primary_window)
  local secondary = decodeCodexWindow(rateLimit.secondary_window)
  local primaryRole = codexWindowRole(primary)
  local secondaryRole = codexWindowRole(secondary)
  local fiveHour = nil
  local weekly = nil

  if includeFiveHour and primaryRole == "five_hour" then fiveHour = primary end
  if primaryRole == "weekly" then weekly = primary end
  if includeFiveHour and secondaryRole == "five_hour" then fiveHour = secondary end
  if secondaryRole == "weekly" then weekly = secondary end

  if includeFiveHour and fiveHour == nil then
    if primary ~= nil and primaryRole ~= "weekly" then
      fiveHour = primary
    elseif secondary ~= nil and secondaryRole ~= "weekly" then
      fiveHour = secondary
    end
  end
  if weekly == nil then
    if secondary ~= nil and secondaryRole ~= "five_hour" and secondary ~= fiveHour then
      weekly = secondary
    elseif primary ~= nil and primaryRole ~= "five_hour" and primary ~= fiveHour then
      weekly = primary
    end
  end
  return fiveHour, weekly
end

local function parseCodexUsage(body, includeFiveHour)
  local decoded = noctalia.json.decode(body)
  if type(decoded) ~= "table" then
    return nil, tr("errors.codex_response_invalid")
  end
  local rateLimit = decoded.rate_limit
  if type(rateLimit) ~= "table" then
    return nil, tr("errors.codex_no_windows")
  end
  local fiveHour, weekly = normalizeCodexWindows(rateLimit, includeFiveHour)
  if fiveHour == nil and weekly == nil then
    return nil, tr("errors.codex_no_windows")
  end
  local planType = type(decoded.plan_type) == "string" and decoded.plan_type ~= "" and decoded.plan_type or nil
  return {
    planType = planType,
    fiveHour = fiveHour,
    weekly = weekly,
    updatedAt = os.time(),
  }, nil
end

local function loadCodexCredentials()
  local contents = noctalia.readFile(codexHome() .. "/auth.json")
  if type(contents) ~= "string" or contents == "" then
    return nil, nil, tr("errors.codex_auth_missing")
  end
  local decoded = noctalia.json.decode(contents)
  if type(decoded) ~= "table" then
    return nil, nil, tr("errors.codex_auth_invalid")
  end
  local tokens = decoded.tokens
  if type(tokens) ~= "table" then
    return nil, nil, tr("errors.codex_oauth_required")
  end
  local accessToken = tokens.access_token or tokens.accessToken
  local accountId = tokens.account_id or tokens.accountId
  if type(accessToken) ~= "string" or accessToken == "" then
    return nil, nil, tr("errors.codex_oauth_required")
  end
  if type(accountId) ~= "string" or accountId == "" then
    accountId = nil
  end
  return accessToken, accountId, nil
end

local function refreshCodexUsage()
  local provider = providers.codex
  if provider.inFlight then
    return
  end
  local attemptedAt = os.time()
  local accessToken, accountId, credentialError = loadCodexCredentials()
  provider.nextPollAt = attemptedAt + POLL_SECONDS
  if credentialError ~= nil then
    failProvider(provider, credentialError, attemptedAt)
    return
  end

  provider.inFlight = true
  publishProvider(provider, "loading", nil, attemptedAt)
  local headers = {
    "Authorization: Bearer " .. accessToken,
    "Accept: application/json",
    "User-Agent: Noctalia-token-top/0.7.0",
  }
  if accountId ~= nil then
    table.insert(headers, "ChatGPT-Account-Id: " .. accountId)
  end

  local started = noctalia.http({
    url = CODEX_USAGE_URL,
    method = "GET",
    headers = headers,
  }, function(response)
    if not response.ok then
      failProvider(provider, tr("errors.codex_network"), attemptedAt)
      return
    end
    if response.status == 401 or response.status == 403 then
      failProvider(provider, tr("errors.codex_unauthorized"), attemptedAt)
      return
    end
    if response.status < 200 or response.status >= 300 then
      failProvider(provider, tr("errors.codex_http_status", { status = response.status }), attemptedAt)
      return
    end
    local parsed, parseError = parseCodexUsage(response.body, shouldTrackFiveHour("codex"))
    if parsed == nil then
      failProvider(provider, parseError, attemptedAt)
      return
    end
    provider.lastGood = parsed
    provider.inFlight = false
    publishProvider(provider, "ready", nil, attemptedAt)
    scheduleStatsScan("codex")
  end)
  if not started then
    failProvider(provider, tr("errors.codex_request_not_started"), attemptedAt)
  end
end

local function claudePlan(subscriptionType, rateLimitTier)
  local source = ""
  if type(subscriptionType) == "string" then
    source = subscriptionType:lower()
  end
  if source == "" and type(rateLimitTier) == "string" then
    source = rateLimitTier:lower()
  end

  local label = nil
  if source:find("max", 1, true) then
    label = "Claude Max"
  elseif source:find("pro", 1, true) then
    label = "Claude Pro"
  elseif source:find("team", 1, true) then
    label = "Claude Team"
  elseif source:find("enterprise", 1, true) then
    label = "Claude Enterprise"
  elseif source:find("ultra", 1, true) then
    label = "Claude Ultra"
  end

  if label == "Claude Max" and type(rateLimitTier) == "string" then
    local multiplier = rateLimitTier:lower():match("max[_%-](%d+x)")
    if multiplier ~= nil then
      label ..= " " .. multiplier
    end
  end
  return label
end

local function loadClaudeCredentials()
  local contents = noctalia.readFile(claudeHome() .. "/.credentials.json")
  if type(contents) ~= "string" or contents == "" then
    return nil, tr("errors.claude_auth_missing")
  end
  local decoded = noctalia.json.decode(contents)
  if type(decoded) ~= "table" then
    return nil, tr("errors.claude_auth_invalid")
  end
  local oauth = decoded.claudeAiOauth
  if type(oauth) ~= "table" then
    return nil, tr("errors.claude_oauth_required")
  end
  local accessToken = oauth.accessToken
  if type(accessToken) ~= "string" or accessToken == "" then
    return nil, tr("errors.claude_oauth_required")
  end
  local expiresAt = tonumber(oauth.expiresAt)
  if expiresAt ~= nil and expiresAt <= os.time() * 1000 then
    return nil, tr("errors.claude_expired")
  end

  local scopes = oauth.scopes
  if type(scopes) == "table" then
    local hasProfile = false
    for _, scope in ipairs(scopes) do
      if scope == "user:profile" then
        hasProfile = true
        break
      end
    end
    if not hasProfile then
      return nil, tr("errors.claude_scope")
    end
  end

  return {
    accessToken = accessToken,
    planType = claudePlan(oauth.subscriptionType, oauth.rateLimitTier),
  }, nil
end

local function decodeClaudeWindow(value, windowSeconds, label)
  if type(value) ~= "table" then
    return nil
  end
  local usedPercent = tonumber(value.utilization)
  local resetAt = parseIsoTimestamp(value.resets_at)
  if usedPercent == nil then
    return nil
  end
  return {
    label = label,
    usedPercent = math.max(0, math.min(100, usedPercent)),
    resetAt = resetAt,
    windowSeconds = windowSeconds,
  }
end

local function addClaudeScopedWindow(windows, seen, label, value)
  local window = decodeClaudeWindow(value, WEEK_SECONDS, label)
  if window == nil then
    return
  end
  local key = label:lower()
  if seen[key] then
    return
  end
  seen[key] = true
  table.insert(windows, window)
end

local function parseClaudeExtraUsage(value)
  if type(value) ~= "table" or value.is_enabled ~= true then
    return nil
  end
  local monthlyLimit = tonumber(value.monthly_limit)
  local usedCredits = tonumber(value.used_credits)
  local utilization = tonumber(value.utilization)
  if monthlyLimit == nil and usedCredits == nil and utilization == nil then
    return nil
  end
  return {
    enabled = true,
    monthlyLimit = monthlyLimit ~= nil and monthlyLimit / 100 or nil,
    usedCredits = usedCredits ~= nil and usedCredits / 100 or nil,
    usedPercent = utilization ~= nil and math.max(0, utilization) or nil,
    currency = type(value.currency) == "string" and value.currency or "USD",
  }
end

local function parseClaudeUsage(body, includeFiveHour, planType)
  local decoded = noctalia.json.decode(body)
  if type(decoded) ~= "table" then
    return nil, tr("errors.claude_response_invalid")
  end
  local fiveHour = includeFiveHour and decodeClaudeWindow(decoded.five_hour, FIVE_HOUR_SECONDS) or nil
  local weekly = decodeClaudeWindow(decoded.seven_day, WEEK_SECONDS)
  local scopedWindows = {}
  local seen = {}

  addClaudeScopedWindow(scopedWindows, seen, "Sonnet only", decoded.seven_day_sonnet)
  addClaudeScopedWindow(scopedWindows, seen, "Opus only", decoded.seven_day_opus)
  addClaudeScopedWindow(scopedWindows, seen, "OAuth apps only", decoded.seven_day_oauth_apps)

  if type(decoded.limits) == "table" then
    for _, limit in ipairs(decoded.limits) do
      if type(limit) == "table" and limit.kind == "weekly_scoped" and limit.group == "weekly" then
        local model = type(limit.scope) == "table" and limit.scope.model or nil
        local displayName = type(model) == "table" and model.display_name or nil
        local modelId = type(model) == "table" and model.id or nil
        local normalized = type(displayName) == "string" and displayName:lower():gsub("[^%w]+", "-") or ""
        local normalizedId = type(modelId) == "string" and modelId:lower():gsub("[^%w]+", "-") or ""
        if type(displayName) == "string"
          and noctalia.string.trim(displayName) ~= ""
          and normalized ~= "all-models"
          and normalizedId ~= "all-models"
          and normalizedId:sub(-11) ~= "-all-models"
        then
          addClaudeScopedWindow(scopedWindows, seen, displayName .. " only", {
            utilization = limit.percent,
            resets_at = limit.resets_at,
          })
        end
      end
    end
  end

  local extraUsage = parseClaudeExtraUsage(decoded.extra_usage)
  if fiveHour == nil and weekly == nil and #scopedWindows == 0 and extraUsage == nil then
    return nil, tr("errors.claude_no_windows")
  end
  return {
    planType = planType,
    fiveHour = fiveHour,
    weekly = weekly,
    scopedWindows = scopedWindows,
    extraUsage = extraUsage,
    updatedAt = os.time(),
  }, nil
end

local function refreshClaudeUsage()
  local provider = providers.claude
  if provider.inFlight then
    return
  end
  local attemptedAt = os.time()
  local credentials, credentialError = loadClaudeCredentials()
  provider.nextPollAt = attemptedAt + POLL_SECONDS
  if credentialError ~= nil then
    failProvider(provider, credentialError, attemptedAt)
    return
  end

  provider.inFlight = true
  publishProvider(provider, "loading", nil, attemptedAt)
  local started = noctalia.http({
    url = CLAUDE_USAGE_URL,
    method = "GET",
    headers = {
      "Authorization: Bearer " .. credentials.accessToken,
      "Accept: application/json",
      "anthropic-beta: oauth-2025-04-20",
      "User-Agent: claude-code/2.1.0",
    },
  }, function(response)
    if not response.ok then
      failProvider(provider, tr("errors.claude_network"), attemptedAt)
      return
    end
    if response.status == 401 or response.status == 403 then
      failProvider(provider, tr("errors.claude_unauthorized"), attemptedAt)
      return
    end
    if response.status == 429 then
      failProvider(provider, tr("errors.claude_rate_limited"), attemptedAt)
      return
    end
    if response.status < 200 or response.status >= 300 then
      failProvider(provider, tr("errors.claude_http_status", { status = response.status }), attemptedAt)
      return
    end
    local parsed, parseError = parseClaudeUsage(response.body, shouldTrackFiveHour("claude"), credentials.planType)
    if parsed == nil then
      failProvider(provider, parseError, attemptedAt)
      return
    end
    provider.lastGood = parsed
    provider.inFlight = false
    publishProvider(provider, "ready", nil, attemptedAt)
    scheduleStatsScan("claude")
  end)
  if not started then
    failProvider(provider, tr("errors.claude_request_not_started"), attemptedAt)
  end
end

local function refreshAll()
  refreshCodexUsage()
  refreshClaudeUsage()
end

noctalia.setUpdateInterval(WORK_UPDATE_MS)
publishAll()

noctalia.state.watch(REFRESH_REQUEST_KEY, function(_value)
  scheduleStatsScan("codex")
  scheduleStatsScan("claude")
  refreshAll()
end)

-- Local logs are useful even before quota credentials are available.
scheduleStatsScan("codex")
scheduleStatsScan("claude")
refreshAll()

function update()
  if activeAggregation ~= nil then
    processStatsAggregation()
    return
  end
  if activeScan ~= nil then
    processStatsScan()
    return
  end
  local now = os.time()
  for _, name in ipairs(providerOrder) do
    local provider = providers[name]
    if now >= provider.nextStatsScanAt then
      provider.pendingScan = true
    end
  end
  startNextStatsWork()

  if now >= providers.codex.nextPollAt then
    refreshCodexUsage()
  end
  if now >= providers.claude.nextPollAt then
    refreshClaudeUsage()
  end
end

function onConfigChanged()
  local changed = false
  for _, name in ipairs(providerOrder) do
    local includeFiveHour = shouldTrackFiveHour(name)
    if includeFiveHour ~= trackingFiveHour[name] then
      changed = true
      trackingFiveHour[name] = includeFiveHour
      local provider = providers[name]
      if not includeFiveHour then
        if provider.lastGood ~= nil then
          provider.lastGood.fiveHour = nil
        end
      else
        provider.nextPollAt = 0
      end
    end
  end

  if not changed then
    return
  end
  publishAll()
  if trackingFiveHour.codex then
    refreshCodexUsage()
  end
  if trackingFiveHour.claude then
    refreshClaudeUsage()
  end
end
