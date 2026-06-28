-- examples/font-demo — runtime TTF font test card (tiny_ttf via HUD.set_font)
--
-- Requires the tiny_ttf firmware (HUD.set_font(path, size) + HUD.set_align).
--
-- Controls (3 buttons):
--   LEFT / RIGHT : previous / next TEST case (the matrix below).
--   ENTER (fire) : cycle the text SAMPLE (glyph range) on the focused face.
--
-- The TEST matrix covers every facet of the new font path:
--   * size      : same latin/regular.ttf at 16/24/32/48px — the engine resizes
--                 the cached face in place (set_size), so one .ttf = any size.
--   * weight    : latin regular vs latin bold.
--   * language  : vi/* render the Vietnamese block + ₫; latin/* do NOT (the VN
--                 samples then show tofu on a latin face — flagged, expected).
--   * family    : Arimo (Apache-2.0, Arial-compatible) next to Noto Sans vi/* —
--                 same VN coverage, compare the letterforms on a VN card.
--   * clamp     : ask 200px -> engine clamps to 96; ask 4px -> clamps to 8.
--   * degrade   : a missing .ttf returns (nil,msg); the label keeps the previous
--                 face instead of crashing (MUTATOR contract).
--   * alignment : HUD.set_align moves the label (top_left / bottom_right).
-- NOTE: the 96px clamp + 48px cases intentionally overflow 480x320 — the point
--       is to SEE the pixel height, not to fit the whole card.

local LATIN   = "@sdk/fonts/latin/regular.ttf"
local LATIN_B = "@sdk/fonts/latin/bold.ttf"
local VI      = "@sdk/fonts/vi/regular.ttf"
local VI_B    = "@sdk/fonts/vi/bold.ttf"
local ARIMO   = "@sdk/fonts/arimo/regular.ttf"   -- Apache-2.0, Arial-compatible, Latin+VN
local ARIMO_B = "@sdk/fonts/arimo/bold.ttf"

-- Each entry drives one HUD.set_font(path, px) call. `vi=true` marks a face that
-- carries the Vietnamese block. `align` (default "center") exercises set_align.
-- `expect_fail=true` is the degrade case: set_font must return (nil,msg).
local TESTS = {
  { desc = "size 16px (base)",       path = LATIN,   px = 16 },
  { desc = "size 24px (resize)",     path = LATIN,   px = 24 },
  { desc = "size 32px (resize)",     path = LATIN,   px = 32 },
  { desc = "size 48px (large)",      path = LATIN,   px = 48 },
  { desc = "bold 20px (weight)",     path = LATIN_B, px = 20 },
  { desc = "vi regular 18px",        path = VI,      px = 18, vi = true },
  { desc = "vi bold 24px",           path = VI_B,    px = 24, vi = true },
  { desc = "arimo regular 18px",     path = ARIMO,   px = 18, vi = true },
  { desc = "arimo bold 24px",        path = ARIMO_B, px = 24, vi = true },
  { desc = "clamp hi: ask 200 ->96", path = VI,      px = 200, vi = true },
  { desc = "clamp lo: ask 4 ->8",    path = LATIN,   px = 4 },
  { desc = "missing .ttf (degrade)", path = "@sdk/fonts/latin/none.ttf", px = 16,
    expect_fail = true },
  { desc = "align top_left",         path = VI,      px = 18, vi = true,
    align = "top_left" },
  { desc = "align bottom_right",     path = VI,      px = 18, vi = true,
    align = "bottom_right" },
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
    text = "The quick brown fox jumps\nover the lazy dog\nPIKA 0123456789" },
  { name = "Mixed", vi = true,
    text = "Xin chào PIKA! 123\nGiá: 50.000₫  Café €5\nĂn cơm chưa?" },
}

local tidx = 1   -- current test case
local sidx = 1   -- current sample card

-- Position the label per test (guarded: older firmware may lack set_align).
local function apply_align(where)
  if HUD.set_align then HUD.set_align(where or "center") end
end

local function show()
  local t = TESTS[tidx]
  apply_align(t.align)
  local _, err = HUD.set_font(t.path, t.px)   -- MUTATOR: ok -> nothing, fail -> nil,msg
  local s = SAMPLES[sidx]

  if t.expect_fail then
    -- Degrade case: set_font failed on purpose. The face is unchanged, so the
    -- sample below still renders in whatever font was active before this test.
    HUD.set_label(string.format(
      "[%d/%d] %s\nset_font -> %s\n(keeps previous font)\n%s",
      tidx, #TESTS, t.desc, tostring(err), s.text))
    return
  end
  if err then  -- a REAL font went missing (not expected) — surface it
    HUD.set_label("unexpected font fail:\n" .. t.path .. "\n" .. tostring(err))
    return
  end

  -- Flag the expected miss when a Vietnamese card is shown on a latin-only face.
  local note = (s.vi and not t.vi)
    and "\n(latin face: VN glyphs missing - expected)" or ""
  HUD.set_label(string.format(
    "[%d/%d] %s   card: %s\n%s%s",
    tidx, #TESTS, t.desc, s.name, s.text, note))
end

function game_start(_level_json)
  show()
end

function on_input(action, phase, _hold_ms)
  if phase ~= Input.PRESS then return end
  if action == "right" then
    tidx = (tidx % #TESTS) + 1
    show()
  elseif action == "left" then
    tidx = ((tidx - 2) % #TESTS) + 1
    show()
  elseif action == "fire" then
    sidx = (sidx % #SAMPLES) + 1
    show()
  end
end

function on_tick(_dt_ms) end

function game_end() end
