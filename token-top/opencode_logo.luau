--!nonstrict

-- OpenCode's mark (github.com/anomalyco/opencode, packages/identity/mark.svg, MIT):
-- a 4:5 frame one-fifth of its height thick, with a square block filling the
-- bottom of the opening. Drawn from boxes instead of an SVG so it follows the
-- theme like a glyph; ui.image cannot recolor an SVG.
return function(size, color, opacity)
  local stroke = math.max(2, size // 5)
  local width = stroke * 4
  local inner = stroke * 2
  local function bar(barWidth, barHeight)
    return ui.box({ width = barWidth, height = barHeight, fill = color })
  end
  return ui.column({ width = width, height = stroke * 5, gap = 0, opacity = opacity or 1 }, {
    bar(width, stroke),
    ui.row({ height = stroke * 3, gap = 0 }, {
      bar(stroke, stroke * 3),
      ui.column({ width = inner, height = stroke * 3, gap = 0, justify = "end" }, {
        ui.box({ width = inner, height = inner, fill = color, opacity = 0.35 }),
      }),
      bar(stroke, stroke * 3),
    }),
    bar(width, stroke),
  })
end
