--!nonstrict

local STATE_KEY = "usage_snapshot"
local REFRESH_REQUEST_KEY = "refresh_request"
local snapshot = noctalia.state.get(STATE_KEY) or { providers = {} }
local opened = false
local activeTab = "overview"

local CODEX_PLAN_NAMES = {
  free = "ChatGPT Free",
  free_workspace = "ChatGPT Free",
  guest = "ChatGPT Free",
  go = "ChatGPT Go Subscription",
  plus = "ChatGPT Plus Subscription",
  prolite = "ChatGPT Pro 5x Subscription",
  pro_lite = "ChatGPT Pro 5x Subscription",
  pro = "ChatGPT Pro 20x Subscription",
  team = "ChatGPT Business",
  self_serve_business_usage_based = "ChatGPT Business",
  business = "ChatGPT Enterprise",
  enterprise_cbp_usage_based = "ChatGPT Enterprise",
  enterprise = "ChatGPT Enterprise",
  hc = "ChatGPT Enterprise",
  education = "ChatGPT Edu",
  edu = "ChatGPT Edu",
  k12 = "ChatGPT Edu",
  quorum = "ChatGPT Enterprise",
}

local PROVIDERS = {
  codex = {
    labelKey = "providers.codex",
    glyph = "brand-openai",
    detailsCallback = "viewCodexDetails",
  },
  claude = {
    labelKey = "providers.claude",
    glyph = "asterisk-simple",
    detailsCallback = "viewClaudeDetails",
  },
}

local function tr(key, substitutions)
  return noctalia.tr(key, substitutions)
end

local function providerSnapshot(name)
  local all = type(snapshot.providers) == "table" and snapshot.providers or {}
  return type(all[name]) == "table" and all[name] or {
    availability = "unavailable",
    status = "loading",
    tokenStats = { status = "loading" },
  }
end

local function showFiveHour(providerName)
  local key = providerName == "claude" and "show_claude_five_hour_panel" or "show_five_hour_panel"
  local value = noctalia.getConfig(key)
  return value == true or value == "true"
end

local function roundedPercent(window)
  if type(window) ~= "table" or tonumber(window.usedPercent) == nil then
    return nil
  end
  return math.floor(math.max(0, math.min(100, window.usedPercent)) + 0.5)
end

local function accent(percent)
  if percent == nil then
    return "on_surface_variant"
  elseif percent >= 90 then
    return "error"
  elseif percent >= 75 then
    return "secondary"
  end
  return "primary"
end

local function relativeReset(resetAt)
  if tonumber(resetAt) == nil then
    return tr("labels.reset_unknown")
  end
  local remaining = math.max(0, math.floor(resetAt - os.time()))
  if remaining == 0 then
    return tr("labels.reset_now")
  end
  local days = remaining // 86400
  local hours = (remaining % 86400) // 3600
  local minutes = math.max(1, (remaining % 3600) // 60)
  if days > 0 then
    return `{days}d {hours}h`
  elseif hours > 0 then
    return `{hours}h {minutes}m`
  end
  return `{minutes}m`
end

local function providerPlanLabel(providerName, value)
  if type(value) ~= "string" or value == "" then
    return tr("labels.unknown_plan")
  end
  if providerName == "codex" then
    local normalized = value:lower():gsub("[%s%-]+", "_")
    return CODEX_PLAN_NAMES[normalized] or value
  end
  return value
end

local function compactNumber(value)
  local amount = math.max(0, tonumber(value) or 0)
  local divisor = 1
  local suffix = ""
  if amount >= 1000000000 then
    divisor = 1000000000
    suffix = "B"
  elseif amount >= 1000000 then
    divisor = 1000000
    suffix = "M"
  elseif amount >= 1000 then
    divisor = 1000
    suffix = "K"
  end
  if divisor == 1 then
    return tostring(math.floor(amount + 0.5))
  end
  return string.format("%.1f", amount / divisor):gsub("%.0$", "") .. suffix
end

local function providerGuidance(providerName)
  return providerName == "claude" and tr("guidance.claude") or tr("guidance.codex")
end

local function windowCard(title, window)
  local percent = roundedPercent(window)
  if percent == nil then
    return nil
  end
  local color = accent(percent)
  local footer = tr("labels.reset_unknown")
  if tonumber(window.resetAt) ~= nil then
    footer = tr("labels.resets_in", { time = relativeReset(window.resetAt) })
  end
  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = title, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.label({
        text = tr("labels.percent_used", { percent = percent }),
        fontWeight = "bold",
        color = color,
      }),
    }),
    ui.progress({ progress = percent / 100, fill = color, height = 7, radius = 4 }),
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = footer, color = "on_surface_variant", fontSize = 12, flexGrow = 1 }),
      ui.label({
        text = tonumber(window.resetAt) ~= nil and noctalia.formatTime("%a %H:%M", window.resetAt) or "—",
        color = "on_surface_variant",
        fontSize = 12,
      }),
    }),
  }
  return ui.column({
    fill = "surface_variant",
    radius = 12,
    paddingH = 14,
    paddingV = 12,
    gap = 8,
  }, children)
end

local function statusContent(providerName, provider)
  if (provider.status == "error" or provider.status == "stale") and provider.error ~= nil then
    return ui.row({
      fill = provider.status == "stale" and "secondary/0.12" or "error/0.15",
      radius = 10,
      paddingH = 10,
      paddingV = 8,
      gap = 8,
      align = "center",
    }, {
      ui.glyph({
        name = provider.status == "stale" and "clock-exclamation" or "alert-triangle",
        size = 16,
        color = provider.status == "stale" and "secondary" or "error",
      }),
      ui.label({
        text = provider.error,
        color = provider.status == "stale" and "on_surface" or "error",
        fontSize = 12,
        flexGrow = 1,
      }),
    })
  elseif provider.status == "loading" then
    return ui.label({
      text = tr("status.loading", { provider = tr(PROVIDERS[providerName].labelKey) }),
      color = "on_surface_variant",
      fontSize = 12,
    })
  end

  local updatedAt = tonumber(provider.updatedAt)
  if updatedAt ~= nil then
    return ui.label({
      text = tr("labels.updated_at", { time = noctalia.formatTime("%Y-%m-%d %H:%M", updatedAt) }),
      color = "on_surface_variant",
      fontSize = 12,
    })
  end
  return ui.label({ text = tr("labels.not_updated"), color = "on_surface_variant", fontSize = 12 })
end

local function guidanceCard(providerName, provider)
  local message = provider.error or providerGuidance(providerName)
  return ui.row({
    fill = "surface_variant",
    radius = 12,
    paddingH = 14,
    paddingV = 12,
    gap = 10,
    align = "center",
  }, {
    ui.glyph({ name = "login", size = 18, color = "primary" }),
    ui.column({ gap = 3, flexGrow = 1 }, {
      ui.label({ text = tr("labels.quota_unavailable"), fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = message, fontSize = 11, color = "on_surface_variant" }),
    }),
  })
end

local function tokenMetric(label, value, accentValue)
  return ui.column({
    fill = "surface_variant",
    radius = 12,
    paddingH = 14,
    paddingV = 12,
    gap = 3,
    flexGrow = 1,
  }, {
    ui.label({
      text = tr("stats.tokens", { value = compactNumber(value) }),
      fontSize = 21,
      fontWeight = "bold",
      color = accentValue and "primary" or "on_surface",
    }),
    ui.label({ text = label, color = "on_surface_variant", fontSize = 11 }),
  })
end

local function dataCell(label, value, color)
  return ui.column({ gap = 2, flexGrow = 1 }, {
    ui.label({ text = value, fontSize = 15, fontWeight = "bold", color = color or "on_surface" }),
    ui.label({ text = label, color = "on_surface_variant", fontSize = 10 }),
  })
end

local function activityChart(stats)
  local activity = type(stats.dailyActivity) == "table" and stats.dailyActivity or {}
  local maximum = 0
  for _, day in ipairs(activity) do
    maximum = math.max(maximum, tonumber(day.tokens) or 0)
  end

  local bars = {}
  local now = os.time()
  for index = 1, 7 do
    local day = activity[index] or {}
    local tokens = math.max(0, tonumber(day.tokens) or 0)
    local startedAt = tonumber(day.startedAt)
    local height = tokens > 0 and math.max(4, math.floor(tokens / math.max(1, maximum) * 48 + 0.5)) or 3
    local nextStartedAt = activity[index + 1] ~= nil and tonumber(activity[index + 1].startedAt) or nil
    local isCurrent = startedAt ~= nil and now >= startedAt and (nextStartedAt == nil or now < nextStartedAt)
    local fill = tokens == 0 and "on_surface_variant/0.2" or (isCurrent and "primary" or "primary/0.45")
    table.insert(bars, ui.column({ flexGrow = 1, gap = 5, align = "center" }, {
      ui.column({ height = 50, justify = "end", align = "center" }, {
        ui.box({ width = 22, height = height, radius = 4, fill = fill }),
      }),
      ui.label({
        text = startedAt ~= nil and noctalia.formatTime("%a", startedAt):sub(1, 1) or "—",
        fontSize = 10,
        fontWeight = isCurrent and "bold" or "normal",
        color = isCurrent and "primary" or "on_surface_variant",
      }),
    }))
  end

  return ui.column({
    fill = "surface_variant",
    radius = 12,
    paddingH = 14,
    paddingV = 12,
    gap = 8,
  }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = tr("stats.daily_activity"), fontWeight = "bold", color = "on_surface" }),
      ui.label({
        text = stats.windowMode == "rolling" and tr("stats.last_seven_days") or tr("stats.current_window"),
        fontSize = 10,
        color = "on_surface_variant",
      }),
    }),
    ui.row({ gap = 6, align = "end" }, bars),
  })
end

local function codexBreakdown(stats)
  local cachedPercent = math.max(0, math.floor(tonumber(stats.cachedInputPercent) or 0))
  local reasoningPercent = math.max(0, math.floor(tonumber(stats.reasoningPercent) or 0))
  return ui.column({
    fill = "surface_variant",
    radius = 12,
    paddingH = 14,
    paddingV = 12,
    gap = 10,
  }, {
    ui.label({ text = tr("stats.codex_breakdown"), fontWeight = "bold", color = "on_surface" }),
    ui.row({ gap = 12, align = "start" }, {
      dataCell(tr("stats.input"), compactNumber(stats.inputTokens)),
      dataCell(tr("stats.output"), compactNumber(stats.outputTokens)),
      dataCell(tr("stats.cached"), compactNumber(stats.cachedInputTokens), "primary"),
    }),
    ui.separator(),
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({
        text = tr("stats.cached_share", { percent = cachedPercent }),
        fontSize = 11,
        color = "on_surface_variant",
      }),
      ui.label({
        text = tr("stats.reasoning_share", {
          value = compactNumber(stats.reasoningTokens),
          percent = reasoningPercent,
        }),
        fontSize = 11,
        color = "on_surface_variant",
      }),
    }),
  })
end

local function claudeBreakdown(stats)
  return ui.column({
    fill = "surface_variant",
    radius = 12,
    paddingH = 14,
    paddingV = 12,
    gap = 10,
  }, {
    ui.label({ text = tr("stats.claude_breakdown"), fontWeight = "bold", color = "on_surface" }),
    ui.row({ gap = 12, align = "start" }, {
      dataCell(tr("stats.input"), compactNumber(stats.inputTokens)),
      dataCell(tr("stats.output"), compactNumber(stats.outputTokens)),
    }),
    ui.separator(),
    ui.row({ gap = 12, align = "start" }, {
      dataCell(tr("stats.cache_write"), compactNumber(stats.cacheCreationInputTokens), "primary"),
      dataCell(tr("stats.cache_read"), compactNumber(stats.cacheReadInputTokens), "primary"),
    }),
  })
end

local function insightRow(label, value)
  return ui.row({ align = "center", justify = "space_between", gap = 10 }, {
    ui.label({ text = label, fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
    ui.label({ text = value, fontSize = 12, fontWeight = "bold", color = "on_surface" }),
  })
end

local function supportingStats(providerName, stats)
  local rows = {}
  if providerName == "codex" then
    table.insert(rows, insightRow(
      tr("stats.requests_turns"),
      tr("stats.requests_turns_value", {
        requests = math.max(0, math.floor(tonumber(stats.requestCount) or 0)),
        turns = math.max(0, math.floor(tonumber(stats.turnCount) or 0)),
      })
    ))
    table.insert(rows, ui.separator())
    table.insert(rows, insightRow(
      tr("stats.average_median_thread"),
      tr("stats.average_median_value", {
        average = compactNumber(stats.averagePerThread),
        median = compactNumber(stats.medianPerThread),
      })
    ))
    table.insert(rows, ui.separator())
    table.insert(rows, insightRow(
      tr("stats.largest_thread"),
      tr("stats.largest_value", {
        value = compactNumber(stats.largestThread),
        percent = math.max(0, math.floor(tonumber(stats.largestThreadPercent) or 0)),
      })
    ))
  else
    table.insert(rows, insightRow(
      tr("stats.requests_sessions"),
      tr("stats.requests_sessions_value", {
        requests = math.max(0, math.floor(tonumber(stats.requestCount) or 0)),
        sessions = math.max(0, math.floor(tonumber(stats.sessionCount) or 0)),
      })
    ))
    table.insert(rows, ui.separator())
    table.insert(rows, insightRow(
      tr("stats.average_median_session"),
      tr("stats.average_median_value", {
        average = compactNumber(stats.averagePerSession),
        median = compactNumber(stats.medianPerSession),
      })
    ))
    table.insert(rows, ui.separator())
    table.insert(rows, insightRow(
      tr("stats.largest_session"),
      tr("stats.largest_value", {
        value = compactNumber(stats.largestSession),
        percent = math.max(0, math.floor(tonumber(stats.largestSessionPercent) or 0)),
      })
    ))
  end
  return ui.column({
    fill = "surface_variant",
    radius = 12,
    paddingH = 14,
    paddingV = 11,
    gap = 8,
  }, rows)
end

local function modelMixCard(stats)
  local models = type(stats.modelMix) == "table" and stats.modelMix or {}
  if #models == 0 then
    return nil
  end
  local rows = {
    ui.label({ text = tr("stats.model_mix"), fontWeight = "bold", color = "on_surface" }),
  }
  for index, model in ipairs(models) do
    if index > 1 then
      table.insert(rows, ui.separator())
    end
    table.insert(rows, insightRow(
      model.name or tr("labels.unknown_model"),
      tr("stats.model_mix_value", {
        tokens = compactNumber(model.tokens),
        requests = math.max(0, math.floor(tonumber(model.requests) or 0)),
      })
    ))
  end
  return ui.column({
    fill = "surface_variant",
    radius = 12,
    paddingH = 14,
    paddingV = 11,
    gap = 8,
  }, rows)
end

local function projectionFooter(stats)
  if stats.windowMode ~= "exact" or tonumber(stats.projectedByReset) == nil then
    return nil
  end
  local change = tonumber(stats.previousChangePercent)
  local comparison = tr("stats.comparison_unavailable")
  if change ~= nil then
    local magnitude = math.abs(math.floor(change))
    if change > 0 then
      comparison = tr("stats.higher_than_previous", { percent = magnitude })
    elseif change < 0 then
      comparison = tr("stats.lower_than_previous", { percent = magnitude })
    else
      comparison = tr("stats.same_as_previous")
    end
  end
  return ui.column({ gap = 4, paddingH = 2 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = tr("stats.projected_by_reset"), fontSize = 11, color = "on_surface_variant" }),
      ui.label({
        text = tr("stats.tokens", { value = compactNumber(stats.projectedByReset) }),
        fontSize = 11,
        fontWeight = "bold",
        color = "on_surface",
      }),
    }),
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({
        text = tr("stats.daily_pace", { value = compactNumber(stats.averagePerDay) }),
        fontSize = 10,
        color = "on_surface_variant",
      }),
      ui.label({ text = comparison, fontSize = 10, color = "on_surface_variant" }),
    }),
  })
end

local function statsSummary(providerName, stats)
  local count
  local unit
  if providerName == "codex" then
    count = math.max(0, math.floor(tonumber(stats.threadCount) or 0))
    unit = count == 1 and tr("stats.one_thread") or tr("stats.threads", { count = count })
  else
    count = math.max(0, math.floor(tonumber(stats.sessionCount) or 0))
    unit = count == 1 and tr("stats.one_session") or tr("stats.sessions", { count = count })
  end
  if stats.windowMode == "rolling" then
    return tr("stats.rolling_summary", { units = unit })
  end
  local startedAt = tonumber(stats.resetStartedAt)
  local resetLabel = startedAt ~= nil and noctalia.formatTime("%a %d %b", startedAt) or "—"
  return tr("stats.exact_summary", { units = unit, date = resetLabel })
end

local function tokenStatsContent(providerName, provider)
  local stats = provider.tokenStats
  if type(stats) ~= "table" or stats.status == "loading" then
    local text = tr("stats.loading", { provider = tr(PROVIDERS[providerName].labelKey) })
    if type(stats) == "table" and stats.calculating then
      text = tr("stats.calculating")
    end
    return ui.row({
      fill = "surface_variant",
      radius = 12,
      paddingH = 14,
      paddingV = 12,
      gap = 8,
      align = "center",
    }, {
      ui.label({ text = text, color = "on_surface_variant", fontSize = 12 }),
    })
  elseif stats.status ~= "ready" then
    return ui.label({
      text = tr("stats.unavailable", { provider = tr(PROVIDERS[providerName].labelKey) }),
      color = "on_surface_variant",
      fontSize = 12,
    })
  end

  local children = {
    ui.row({ gap = 8, align = "stretch" }, {
      tokenMetric(
        stats.windowMode == "rolling" and tr("stats.last_seven_days") or tr("stats.since_reset"),
        stats.sinceReset,
        true
      ),
      tokenMetric(tr("stats.today"), stats.today, false),
    }),
    activityChart(stats),
    providerName == "codex" and codexBreakdown(stats) or claudeBreakdown(stats),
    supportingStats(providerName, stats),
  }
  if providerName == "claude" then
    local modelMix = modelMixCard(stats)
    if modelMix ~= nil then table.insert(children, modelMix) end
  end
  local projection = projectionFooter(stats)
  if projection ~= nil then table.insert(children, projection) end
  table.insert(children, ui.label({
    text = statsSummary(providerName, stats),
    color = "on_surface_variant",
    fontSize = 11,
  }))
  return ui.column({ gap = 8 }, children)
end

local function extraUsageCard(extra)
  if type(extra) ~= "table" or extra.enabled ~= true then
    return nil
  end
  local used = tonumber(extra.usedCredits)
  local limit = tonumber(extra.monthlyLimit)
  local percent = tonumber(extra.usedPercent)
  if percent == nil and used ~= nil and limit ~= nil and limit > 0 then
    percent = used / limit * 100
  end
  percent = percent ~= nil and math.max(0, math.min(100, percent)) or nil
  local currency = type(extra.currency) == "string" and extra.currency or "USD"
  local value = used ~= nil and limit ~= nil
    and tr("labels.extra_usage_value", {
      used = string.format("%.2f", used),
      limit = string.format("%.2f", limit),
      currency = currency,
    })
    or tr("labels.unavailable")
  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = tr("labels.extra_usage"), fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = value, color = "on_surface_variant", fontSize = 11 }),
    }),
  }
  if percent ~= nil then
    table.insert(children, ui.progress({
      progress = percent / 100,
      fill = accent(math.floor(percent + 0.5)),
      height = 7,
      radius = 4,
    }))
  end
  return ui.column({
    fill = "surface_variant",
    radius = 12,
    paddingH = 14,
    paddingV = 12,
    gap = 8,
  }, children)
end

local function detailContent(providerName)
  local provider = providerSnapshot(providerName)
  local children = {}
  if showFiveHour(providerName) then
    local card = windowCard(tr("labels.five_hour"), provider.fiveHour)
    if card ~= nil then table.insert(children, card) end
  end
  local weekly = windowCard(tr("labels.weekly"), provider.weekly)
  if weekly ~= nil then table.insert(children, weekly) end

  if providerName == "claude" and type(provider.scopedWindows) == "table" then
    for _, window in ipairs(provider.scopedWindows) do
      local card = windowCard(window.label or tr("labels.weekly_scoped"), window)
      if card ~= nil then table.insert(children, card) end
    end
    local extra = extraUsageCard(provider.extraUsage)
    if extra ~= nil then table.insert(children, extra) end
  end

  if weekly == nil and (not showFiveHour(providerName) or roundedPercent(provider.fiveHour) == nil) then
    table.insert(children, guidanceCard(providerName, provider))
  end
  table.insert(children, statusContent(providerName, provider))
  table.insert(children, ui.separator())
  table.insert(children, ui.label({
    text = tr("stats.title"),
    fontSize = 16,
    fontWeight = "bold",
    color = "on_surface",
  }))
  table.insert(children, tokenStatsContent(providerName, provider))
  return children
end

local function miniWindow(label, window)
  local percent = roundedPercent(window)
  if percent == nil then
    return ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
      ui.label({ text = "—", fontSize = 11, color = "on_surface_variant" }),
    })
  end
  return ui.column({ gap = 4 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }),
      ui.label({
        text = tr("labels.mini_usage", { percent = percent, time = relativeReset(window.resetAt) }),
        fontSize = 11,
        fontWeight = "bold",
        color = accent(percent),
      }),
    }),
    ui.progress({ progress = percent / 100, fill = accent(percent), height = 5, radius = 3 }),
  })
end

local function overviewProviderCard(providerName)
  local meta = PROVIDERS[providerName]
  local provider = providerSnapshot(providerName)
  local stats = provider.tokenStats
  local hasStats = type(stats) == "table" and stats.status == "ready"
  local subtitle
  if provider.availability == "connected" then
    subtitle = providerPlanLabel(providerName, provider.planType)
  elseif provider.availability == "local_only" then
    subtitle = tr("labels.local_activity_only")
  elseif provider.status == "loading" then
    subtitle = tr("labels.connecting")
  else
    subtitle = tr("labels.not_connected")
  end

  local children = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ align = "center", gap = 9, flexGrow = 1 }, {
        ui.column({
          width = 30,
          height = 30,
          radius = 9,
          fill = provider.availability == "unavailable" and "on_surface_variant/0.1" or "primary/0.12",
          align = "center",
          justify = "center",
        }, {
          ui.glyph({
            name = meta.glyph,
            size = 17,
            color = provider.availability == "unavailable" and "on_surface_variant" or "primary",
          }),
        }),
        ui.column({ gap = 1, flexGrow = 1 }, {
          ui.label({ text = tr(meta.labelKey), fontWeight = "bold", color = "on_surface" }),
          ui.label({ text = subtitle, fontSize = 10, color = "on_surface_variant" }),
        }),
      }),
      ui.button({
        key = "details_" .. providerName,
        text = tr("tabs.details"),
        variant = "ghost",
        onClick = meta.detailsCallback,
      }),
    }),
  }

  if showFiveHour(providerName) then
    table.insert(children, miniWindow(tr("labels.five_hour"), provider.fiveHour))
  end
  table.insert(children, miniWindow(tr("labels.weekly"), provider.weekly))
  table.insert(children, ui.separator())
  if hasStats then
    table.insert(children, ui.row({ gap = 12, align = "start" }, {
      dataCell(tr("stats.today"), tr("stats.tokens", { value = compactNumber(stats.today) })),
      dataCell(
        stats.windowMode == "rolling" and tr("stats.last_seven_days") or tr("stats.since_reset"),
        tr("stats.tokens", { value = compactNumber(stats.sinceReset) }),
        "primary"
      ),
    }))
  else
    local activityMessage
    local activityColor = "on_surface_variant"
    if type(stats) == "table" and stats.status == "loading" then
      activityMessage = tr("stats.loading", { provider = tr(meta.labelKey) })
    elseif provider.error ~= nil then
      activityMessage = provider.error
      activityColor = "error"
    elseif provider.availability == "connected" then
      activityMessage = tr("stats.unavailable", { provider = tr(meta.labelKey) })
    else
      activityMessage = providerGuidance(providerName)
    end
    table.insert(children, ui.label({
      text = activityMessage,
      color = activityColor,
      fontSize = 11,
    }))
  end

  return ui.column({
    fill = "surface_variant",
    radius = 14,
    paddingH = 14,
    paddingV = 13,
    gap = 10,
  }, children)
end

local function overviewContent()
  return {
    ui.label({
      text = tr("overview.subtitle"),
      color = "on_surface_variant",
      fontSize = 12,
    }),
    overviewProviderCard("codex"),
    overviewProviderCard("claude"),
  }
end

local function tabButton(key, label, callback)
  return ui.button({
    key = "tab_" .. key,
    text = label,
    variant = activeTab == key and "primary" or "ghost",
    onClick = callback,
    flexGrow = 1,
  })
end

local function tabRail()
  return ui.row({
    fill = "surface_variant",
    radius = 12,
    paddingH = 4,
    paddingV = 4,
    gap = 3,
    align = "center",
  }, {
    tabButton("overview", tr("tabs.overview"), "selectOverview"),
    tabButton("codex", tr("tabs.codex"), "selectCodex"),
    tabButton("claude", tr("tabs.claude"), "selectClaude"),
  })
end

local function connectedCount()
  local count = 0
  for name, _ in pairs(PROVIDERS) do
    if providerSnapshot(name).availability ~= "unavailable" then
      count += 1
    end
  end
  return count
end

local function headerSubtitle()
  if activeTab == "overview" then
    local count = connectedCount()
    return count == 1
      and tr("overview.one_available")
      or tr("overview.available", { count = count })
  end
  local provider = providerSnapshot(activeTab)
  return tr("labels.plan", { plan = providerPlanLabel(activeTab, provider.planType) })
end

local function render()
  if not opened then
    return
  end
  local codex = providerSnapshot("codex")
  local claude = providerSnapshot("claude")
  local bothLoading = codex.status == "loading" and claude.status == "loading"
  local header = ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = headerSubtitle(), color = "on_surface_variant", fontSize = 12 }),
    }),
    ui.button({
      key = "refresh_all",
      glyph = "refresh",
      variant = "ghost",
      enabled = not bothLoading,
      onClick = "refreshUsage",
    }),
    ui.button({ key = "close", glyph = "close", onClick = "closePanel" }),
  })

  local children = activeTab == "overview" and overviewContent() or detailContent(activeTab)
  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    header,
    tabRail(),
    ui.scroll({ key = "scroll_" .. activeTab, flexGrow = 1, gap = 12, align = "stretch" }, children),
  }))
end

function onOpen(_context)
  opened = true
  panel.setWantsSecondTicks(true)
  render()
end

function onClose()
  opened = false
  panel.setWantsSecondTicks(false)
end

function update()
  render()
end

function onConfigChanged()
  render()
end

function selectOverview()
  activeTab = "overview"
  render()
end

function selectCodex()
  activeTab = "codex"
  render()
end

function selectClaude()
  activeTab = "claude"
  render()
end

function viewCodexDetails()
  selectCodex()
end

function viewClaudeDetails()
  selectClaude()
end

function refreshUsage()
  local current = tonumber(noctalia.state.get(REFRESH_REQUEST_KEY)) or 0
  noctalia.state.set(REFRESH_REQUEST_KEY, current + 1)
end

function closePanel()
  panel.close()
end

noctalia.state.watch(STATE_KEY, function(value)
  snapshot = type(value) == "table" and value or { providers = {} }
  render()
end)
