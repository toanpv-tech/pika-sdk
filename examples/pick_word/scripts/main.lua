-- pick_word: hear a word, move the ring to the matching card, confirm.
--
-- A line-by-line port of kit/template/index.html (see docs/guides/port-a-demo.md).
-- The sprites are the demo's <template id="pika-art"> elements captured at
-- their declared size; the sounds are placeholder recordings of each `say`.
--
-- Budget (worst frame): 6 sprites ~446 KiB PSRAM, 2/8 Text, 2/4 font faces,
-- 3/64 sound aliases. on_tick allocates nothing.

local ROUNDS = {
  { ask = "ask", answer = 2, cards = { "assets/card_dog.png", "assets/card_cat.png", "assets/card_sun.png" } },
}
local CARD_X, CARD_Y = { 16, 174, 332 }, 120
local FONT = "fonts/regular.ttf"
local HERO = "assets/hero.rgb565"
local SAD_MS = 1500   -- back to the idle face even if on_sound_end never arrives
local CARD_COUNT = 3

local bg, hero, ring, hud, hint
local cards = {}
local cursor, state, tween, last_ring_x, sad_until = 1, "ask", nil, -1, 0

-- Every factory can fail; game_start is the only place that may raise.
local function need(what, obj, err)
  if not obj then error(what .. ": " .. tostring(err)) end
  return obj
end

local function mk_text(str, x, y, size)
  local t = need("Text.new", Text.new(str, x, y))
  local _, err = t:set_font(FONT, size)
  if err then error("set_font: " .. err) end
  return t
end

local function calm_hero() hero:set_frame(HERO, 0); sad_until = 0 end

local function tween_to(spr, x, y, ms)
  local x0, y0 = spr:get_pos()
  tween = { spr = spr, x0 = x0, y0 = y0, x = x, y = y, t0 = Timer.millis(), ms = ms }
end

function game_start(params)
  bg = need("bg", Sprite.new("assets/bg.rgb565", 480, 320))
  bg:set_pos(0, 0)   -- sprites stay hidden until first placed
  local r = ROUNDS[1]
  for i = 1, CARD_COUNT do
    local c = need("card", Sprite.image(r.cards[i]))
    c:set_pos(CARD_X[i], CARD_Y)
    cards[i] = c
  end
  ring = need("ring", Sprite.image("assets/ring.png"))
  hero = need("hero", Sprite.new(HERO, 64, 64))
  hero:set_pos(208, 236)
  hud = mk_text("Round 1/1", 16, 12, 18)
  hint = mk_text("Left/Right: choose  -  Middle: confirm", 0, 0, 16)
  hint:align("bottom", 0, -10)
  Speaker.play(r.ask)
end

function on_tick(dt_ms)
  local rx = CARD_X[cursor] - 6
  if rx ~= last_ring_x then ring:set_pos(rx, CARD_Y - 6); last_ring_x = rx end
  if tween then
    local k = math.min(1, (Timer.millis() - tween.t0) / tween.ms)
    local e = 1 - (1 - k) * (1 - k)
    tween.spr:set_pos(math.floor(tween.x0 + (tween.x - tween.x0) * e + 0.5),
                      math.floor(tween.y0 + (tween.y - tween.y0) * e + 0.5))
    if k >= 1 then tween = nil end
  end
  if sad_until ~= 0 and Timer.millis() >= sad_until then calm_hero() end   -- every wait has a timeout
end

function on_input(action, phase)
  if phase ~= Input.PRESS or state ~= "ask" then return end
  if action == "left" then cursor = (cursor + CARD_COUNT - 2) % CARD_COUNT + 1 end
  if action == "right" then cursor = cursor % CARD_COUNT + 1 end
  if action == "confirm" then
    local ok = cursor == ROUNDS[1].answer
    hero:set_frame(HERO, ok and 1 or 2)
    Speaker.play(ok and "right" or "wrong")
    if ok then
      state = "done"
      tween_to(hero, CARD_X[cursor] + 34, 60, 400)
      hud:set("Well done!")
    else
      sad_until = Timer.millis() + SAD_MS
    end
  end
end

function on_sound_end(alias, reason)
  if alias == "wrong" and reason == Speaker.REASON_COMPLETED then calm_hero() end
end

function game_end()
  Speaker.stop_all()
  for i = 1, #cards do cards[i]:destroy() end
  for _, o in ipairs({ bg, ring, hero, hud, hint }) do o:destroy() end
end
