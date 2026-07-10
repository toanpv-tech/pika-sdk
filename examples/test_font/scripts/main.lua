-- examples/font-demo — runtime TTF font test card via Text:set_font (tiny_ttf)
--
-- LEFT/RIGHT : cycle the faces. Entries 1-3 are the SAME latin/regular.ttf at
--              16/24/32px — each (path,size) is a distinct cached face rendered
--              on demand by Tiny TTF. 4=bold (weight), 5/6=Vietnamese.
-- ENTER      : cycle the test cards (ASCII / Latin-1 / Tiếng Việt / Pangram /
--              Mixed) so every glyph range is exercised on the focused face.
--
-- What it verifies on device:
--   * size:   latin/regular.ttf at 16 vs 24 vs 32 — same text, scalable.
--   * weight: latin regular vs latin bold.
--   * range:  latin/* cover ASCII + Latin-1 + € only, so the Tiếng Việt / Mixed
--             cards show MISSING glyphs on them (flagged) — the vi/* faces must
--             render the diacritics + ₫. That contrast is the point.

-- Text:set_font(path, size): size is in px, rendered on demand by Tiny TTF.
local FONTS = {
  { label = "latin regular", px = 16, path = "fonts/latin/regular.ttf", vi = false },
  { label = "latin regular", px = 24, path = "fonts/latin/regular.ttf", vi = false },
  { label = "latin regular", px = 32, path = "fonts/latin/regular.ttf", vi = false },
  { label = "latin bold",    px = 20, path = "fonts/latin/bold.ttf",    vi = false },
  { label = "vi regular",    px = 18, path = "fonts/vi/regular.ttf",    vi = true  },
  { label = "vi bold",       px = 22, path = "fonts/vi/bold.ttf",       vi = true  },
}

-- Each card targets one glyph range. `vi=true` => needs the Vietnamese block
-- (renders only on vi/* faces; latin/* faces show tofu — demonstrated, not a bug).
local SAMPLES = {
  { name = "ASCII", vi = false,
    text = "ABCDEFG abcdefg\n0123456789\n!?.,:;'\"()[]{}\n@#&%*+-=/<>" },
  { name = "Latin-1", vi = false,
    text = "àáâãäå æç èéêë\nìíîï òóôõö ùúûü ñ ß\nmoney: $ ¢ £ ¥ €" },
  { name = "Tiếng Việt", vi = true,
    text = "ăâđêôơư ĂÂĐÊÔƠƯ\nạảãàá ẹẻẽèé ịỉĩìí\nọỏõ ụủũ ỳỵỷỹ\ndong: 1.000₫" },
  { name = "Pangram", vi = false,
    text = "The quick brown fox jumps\nover the lazy dog\nPIKA 0123 - size 16 vs 24" },
  { name = "Mixed", vi = true,
    text = "Xin chào PIKA! 123\nGiá: 50.000₫  Café €5\nĂn cơm chưa?" },
}

local idx  = 1   -- current font face
local sidx = 1   -- current test card

-- One Text label, created lazily (Text.new needs the game screen).
local lbl
local function set_line(s)
  if not Text then return end
  if lbl then lbl:set(s) else lbl = Text.new(s, 4, 4) end
end

local function show()
  set_line("")           -- ensure the label exists before set_font
  if not lbl then return end   -- no Text binding (headless test): nothing to show
  local f = FONTS[idx]
  local _, err = lbl:set_font(f.path, f.px)  -- MUTATOR: ok -> no value, fail -> nil,msg
  if err then
    set_line("font load fail:\n" .. f.path .. "\n" .. tostring(err))
    return
  end
  local s = SAMPLES[sidx]
  -- Flag the expected miss when a Vietnamese card is shown on a latin-only face.
  local note = (s.vi and not f.vi)
    and "\n(latin face: VN glyphs missing - expected)" or ""
  set_line(string.format(
    "[%d/%d] %s %dpx   card: %s\n%s%s",
    idx, #FONTS, f.label, f.px, s.name, s.text, note))
end

function game_start(_level_json)
  show()
end

function on_input(action, phase, _hold_ms)
  if phase ~= Input.PRESS then return end
  if action == "right" then
    idx = (idx % #FONTS) + 1
    show()
  elseif action == "left" then
    idx = ((idx - 2) % #FONTS) + 1
    show()
  elseif action == "fire" then
    sidx = (sidx % #SAMPLES) + 1
    show()
  end
end

function on_tick(_dt_ms) end

function game_end() end
