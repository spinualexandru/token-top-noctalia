--!nonstrict

local STATE_KEY = "usage_snapshot"
local PANEL_ID = "spinualexandru/token-top:details"
local snapshot = noctalia.state.get(STATE_KEY) or { providers = {} }

local PROVIDERS = {
  codex = {
    labelKey = "providers.codex",
    glyph = "brand-openai",
    enabledKey = "enable_codex",
    defaultEnabled = true,
  },
  claude = {
    labelKey = "providers.claude",
    enabledKey = "enable_claude",
    defaultEnabled = false,
  },
}

local PROVIDER_ORDER = { "codex", "claude" }

local function tr(key, substitutions)
  return noctalia.tr(key, substitutions)
end

local function showFiveHour(providerName)
  local key = providerName == "claude" and "show_claude_five_hour_bar" or "show_five_hour_bar"
  local value = noctalia.getConfig(key)
  return value == true or value == "true"
end

local function enabledProviderNames()
  local names = {}
  for _, name in ipairs(PROVIDER_ORDER) do
    local value = noctalia.getConfig(PROVIDERS[name].enabledKey)
    -- Missing settings can occur while upgrading from a version without the
    -- enable toggles. Preserve the previous Codex-only default.
    if value == nil then
      value = PROVIDERS[name].defaultEnabled
    end
    if value == true or value == "true" then
      table.insert(names, name)
    end
  end
  return names
end

local function providerSnapshot(name)
  local all = type(snapshot.providers) == "table" and snapshot.providers or {}
  return type(all[name]) == "table" and all[name] or {
    availability = "unavailable",
    status = "loading",
  }
end

-- The bar's standard presentation settings are seeded under these keys; the
-- hidden sentinel means the user left them unset.
local function configuredColor(key)
  local value = noctalia.getConfig(key)
  if type(value) == "string" and value ~= "" and value ~= "__unset__" then
    return value
  end
  return nil
end

local function roundedPercent(window)
  if type(window) ~= "table" or tonumber(window.usedPercent) == nil then
    return nil
  end
  return math.floor(math.max(0, math.min(100, window.usedPercent)) + 0.5)
end

local function percentText(window)
  local percent = roundedPercent(window)
  return percent ~= nil and (`{percent}%`) or "—"
end

local function accent(window)
  local percent = roundedPercent(window)
  if percent == nil then
    return "on_surface_variant"
  elseif percent >= 90 then
    return "error"
  elseif percent >= 75 then
    return "secondary"
  end
  return "primary"
end

local function resetText(window)
  if type(window) ~= "table" or tonumber(window.resetAt) == nil then
    return tr("labels.reset_unknown")
  end
  local remaining = math.max(0, math.floor(window.resetAt - os.time()))
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

local function percentage(window)
  return ui.label({
    text = percentText(window),
    color = configuredColor("color") or accent(window),
    fontWeight = "bold",
  })
end

local function providerGuidance(name)
  return name == "claude" and tr("guidance.claude") or tr("guidance.codex")
end

local function providerIcon(name)
  if name == "claude" then
    return ui.image({
      path = "claude.svg",
      width = 18,
      height = 18,
      fit = "contain",
    })
  end
  return ui.glyph({
    name = PROVIDERS[name].glyph,
    color = configuredColor("icon_color") or configuredColor("color"),
  })
end

local function appendTooltip(tooltip, name, provider)
  local meta = PROVIDERS[name]
  table.insert(tooltip, {
    key = tr("labels.provider"),
    value = tr(meta.labelKey),
  })
  if showFiveHour(name) then
    table.insert(tooltip, {
      key = tr("labels.five_hour"),
      value = tr("labels.usage_and_reset", {
        percent = percentText(provider.fiveHour),
        time = resetText(provider.fiveHour),
      }),
    })
  end
  table.insert(tooltip, {
    key = tr("labels.weekly"),
    value = tr("labels.usage_and_reset", {
      percent = percentText(provider.weekly),
      time = resetText(provider.weekly),
    }),
  })
  if provider.status == "loading" then
    table.insert(tooltip, {
      key = tr("labels.status"),
      value = tr("status.loading", { provider = tr(meta.labelKey) }),
    })
  elseif provider.error ~= nil then
    table.insert(tooltip, { key = tr("labels.status"), value = provider.error })
  elseif provider.availability == "local_only" then
    table.insert(tooltip, { key = tr("labels.status"), value = tr("labels.local_activity_only") })
  elseif provider.availability == "unavailable" then
    table.insert(tooltip, { key = tr("labels.status"), value = providerGuidance(name) })
  end
end

local function render()
  local names = enabledProviderNames()
  if #names == 0 then
    barWidget.setVisible(false)
    barWidget.clearTooltip()
    return
  end
  barWidget.setVisible(true)
  local container = barWidget.isVertical() and ui.column or ui.row
  local children = {}
  local tooltip = {}
  for _, name in ipairs(names) do
    local provider = providerSnapshot(name)
    local providerChildren = {
      providerIcon(name),
    }
    if showFiveHour(name) then
      table.insert(providerChildren, percentage(provider.fiveHour))
    end
    table.insert(providerChildren, percentage(provider.weekly))
    table.insert(children, container({ gap = 6, align = "center" }, providerChildren))
    appendTooltip(tooltip, name, provider)
  end
  barWidget.render(container({ gap = 8, align = "center" }, children))
  barWidget.setTooltip(tooltip)
end

noctalia.setUpdateInterval(60000)

noctalia.state.watch(STATE_KEY, function(value)
  snapshot = type(value) == "table" and value or { providers = {} }
  render()
end)

function update()
  render()
end

function onConfigChanged()
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

render()
