-- examples/emoji-demo — Emoji helpers (engine_level 5)
--
-- ASSET REQUIRED to draw the PNG (currently 0-byte placeholders):
--   <sdk>/images/emoji/png/<hex>.png   (drop real Noto Emoji PNGs)
-- The alias tables <sdk>/images/emoji/aliases/{en,vi}.json ARE real, so
-- Emoji.path / Emoji.lookup return correct paths; only Sprite.image(path)
-- fails to decode until the PNGs are dropped.

local faces = { "😀", "👋", "❤", "🔥", "⭐" }
local idx = 1
local sprite

local function show()
  local ch = faces[idx]
  local hex = Emoji.path(ch) or "?"   -- UTF-8 char -> codepoint hex; no asset needed
  HUD.set_label(string.format("%s  hex=%s  (%d/%d) ENTER=draw", ch, tostring(hex), idx, #faces))
end

function game_start(level_json)
  Emoji.set_lang("en")   -- keyword language for Emoji.lookup (default already en)
  show()
end

function on_input(action, phase, hold_ms)
  if phase ~= Input.PRESS then return end
  if action == "next" then idx = (idx % #faces) + 1; show()
  elseif action == "prev" then idx = ((idx - 2) % #faces) + 1; show()
  elseif action == "fire" then
    local path, err = Emoji.lookup("happy")   -- resolves via aliases/en.json -> 1f600
    if not path then HUD.set_label("lookup fail: " .. tostring(err)); return end
    if sprite then sprite:destroy(); sprite = nil end
    local s, serr = Sprite.image(path)
    if not s then HUD.set_label("draw fail (drop PNG): " .. tostring(serr)); return end
    sprite = s
    sprite:set_pos(216, 120)
  end
end

function on_tick(dt_ms) end

function game_end() if sprite then sprite:destroy() end end
