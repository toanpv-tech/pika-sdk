-- test_text: the Text API and runtime TTF fonts (Text:set_font).
--
-- Fonts: Nunito Regular and Nunito Black (Google Fonts, OFL, see
-- fonts/OFL.txt), subset to Latin + Vietnamese. Black is the weight the
-- robot's own settings screen uses, so Black 24 should look like it.
--
-- Groups:
--   api    : return values and errors of every Text call (automatic)
--   pool   : Text slots (text_slots = 8) and font-face reuse (automatic)
--   look   : glyphs, sizes, weight, anchors, colours, show/hide. The operator
--            answers each card: ENTER = looks right, RIGHT = looks wrong.
--
-- The HUD itself holds one Text and one face (Regular 14), so tests that
-- count slots expect text_slots - 1 free labels. Every test destroys the
-- labels it made, also on failure.

local REGULAR = "fonts/nunito-regular.ttf"
local BLACK   = "fonts/nunito-black.ttf"
-- text_slots, font_px_min / font_px_max in contract/constraints.json.
local TEXT_SLOTS = 8
local PX_MIN, PX_MAX = 8, 96
local HUD_SLOTS = 1

local fmt = string.format
local W, H = 480, 320

-- Labels made by the running test; free_all() destroys them.
local made = {}

local function new_label(str, x, y, path, px, rgb)
    local t, err = Text.new(str, x, y)
    if not t then error("Text.new: " .. tostring(err)) end
    made[#made + 1] = t
    if path then
        local _, ferr = t:set_font(path, px)
        if ferr then error("set_font(" .. path .. ", " .. tostring(px) .. "): " .. ferr) end
    end
    if rgb then t:set_color(rgb) end
    return t
end

local function free_all()
    for i = #made, 1, -1 do
        made[i]:destroy()
        made[i] = nil
    end
end

-- Runs fn with the labels it makes always destroyed afterwards.
local function with_labels(fn)
    return function()
        local ok, pass, msg = pcall(fn)
        free_all()
        if not ok then error(pass, 0) end
        return pass, msg
    end
end

-- ── Suite ────────────────────────────────────────────────────────────
local tk = require("libs/testkit")

local S = tk.suite({
    tag = "text", title = "TEXT TEST",
    font = REGULAR, font_px = 14,
    groups = {
        api  = { label = "TEXT API",   what = "returns and errors of each call" },
        pool = { label = "POOL",       what = "8 Text slots, font-face reuse" },
        look = { label = "LOOK",       what = "operator checks the screen" },
    },
    on_abort = free_all,
})

-- ── Group: api (sync) ────────────────────────────────────────────────
-- "Non-string" probes pass a table: Lua converts a number to a string where a
-- string is expected, so 42 is a valid label text.
S:sync("api", "Text.new(table) raises", function()
    local ok, t = pcall(Text.new, {}, 0, 0)
    if ok and t then t:destroy() end
    return not ok, ok and "returned instead of raising" or "raised"
end)

S:sync("api", "Text.new(str, 1.5, 0) raises", function()
    local ok = pcall(Text.new, "x", 1.5, 0)
    return not ok, ok and "returned instead of raising" or "raised"
end)

S:sync("api", "set_font: missing file -> nil, msg", with_labels(function()
    local t = new_label("x", 10, 200)
    local r, err = t:set_font("fonts/missing.ttf", 20)
    return r == nil and type(err) == "string", fmt("-> %s, %s", tostring(r), tostring(err))
end))

S:sync("api", "set_font: path with .. -> nil, msg", with_labels(function()
    local t = new_label("x", 10, 200)
    local r, err = t:set_font("../secret.ttf", 20)
    return r == nil and type(err) == "string", fmt("-> %s, %s", tostring(r), tostring(err))
end))

S:sync("api", "set_font(table) raises", with_labels(function()
    local t = new_label("x", 10, 200)
    local ok = pcall(t.set_font, t, {}, 20)
    return not ok, ok and "returned instead of raising" or "raised"
end))

S:sync("api", "set_font px 4 / 200 clamp, no error", with_labels(function()
    local t = new_label("x", 10, 200)
    local _, e1 = t:set_font(REGULAR, PX_MIN - 4)
    local _, e2 = t:set_font(REGULAR, PX_MAX + 104)
    return e1 == nil and e2 == nil,
           fmt("px 4 -> %s, px 200 -> %s", tostring(e1 or "ok"), tostring(e2 or "ok"))
end))

S:sync("api", "align: 9 anchors ok, bad -> nil, msg", with_labels(function()
    local t = new_label("x", 10, 200)
    for _, where in ipairs({ "center", "top", "bottom", "left", "right",
                             "top_left", "top_right", "bottom_left", "bottom_right" }) do
        local _, err = t:align(where, 0, 0)
        if err then return false, where .. " -> " .. err end
    end
    local r, err = t:align("nowhere")
    return r == nil and type(err) == "string", "bad anchor -> " .. tostring(err)
end))

S:sync("api", "align(table) raises", with_labels(function()
    local t = new_label("x", 10, 200)
    local ok = pcall(t.align, t, {})
    return not ok, ok and "returned instead of raising" or "raised"
end))

S:sync("api", "set_color(table) raises", with_labels(function()
    local t = new_label("x", 10, 200)
    local ok = pcall(t.set_color, t, {})
    return not ok, ok and "returned instead of raising" or "raised"
end))

S:sync("api", "set(non-string) raises", with_labels(function()
    local t = new_label("x", 10, 200)
    local ok = pcall(t.set, t, {})
    return not ok, ok and "returned instead of raising" or "raised"
end))

S:sync("api", "destroy twice + set after destroy: no raise", function()
    local t, err = Text.new("x", 10, 200)
    if not t then return false, "Text.new: " .. tostring(err) end
    t:destroy()
    local ok1 = pcall(t.destroy, t)
    local ok2 = pcall(t.set, t, "after")
    return ok1 and ok2, fmt("second destroy=%s set=%s", ok1 and "ok" or "raised",
                            ok2 and "ok" or "raised")
end)

-- ── Group: pool (sync) ───────────────────────────────────────────────
-- Manual: it overflows the pool on purpose, which smoke.py reports as an
-- error, so RUN SUITE (and the smoke gate) leave it out.
S:sync("pool", "7 free slots, 8th -> nil, pool_full", with_labels(function()
    local free = TEXT_SLOTS - HUD_SLOTS
    for i = 1, free do
        local t, err = Text.new("slot " .. i, 10, 20 + i * 20)
        if not t then return false, fmt("label %d/%d failed: %s", i, free, tostring(err)) end
        made[#made + 1] = t
    end
    local extra, err = Text.new("one too many", 10, 300)
    if extra then
        made[#made + 1] = extra
        return false, "label past the pool was created"
    end
    return err == "pool_full", fmt("%d created, then -> nil, %s", free, tostring(err))
end), { manual = true })

S:sync("pool", "destroy frees the slot for a new label", with_labels(function()
    local free = TEXT_SLOTS - HUD_SLOTS
    for i = 1, free do new_label("slot " .. i, 10, 20 + i * 20) end
    made[#made]:destroy()
    made[#made] = nil
    local t, err = Text.new("reused", 10, 300)
    if t then made[#made + 1] = t end
    return t ~= nil, t and "slot reused" or ("-> nil, " .. tostring(err))
end))

-- A face nobody uses can be evicted, so one label can walk many sizes while
-- other labels keep theirs.
S:sync("pool", "one label walks 10 sizes, others keep theirs", with_labels(function()
    new_label("a", 10, 60, BLACK, 24)
    new_label("b", 10, 100, REGULAR, 18)
    local t = new_label("sweep", 10, 140)
    for _, px in ipairs({ 8, 12, 16, 20, 28, 36, 44, 56, 72, 96 }) do
        local _, err = t:set_font(BLACK, px)
        if err then return false, fmt("px %d -> %s", px, err) end
    end
    return true, "10 sizes loaded without font cache full"
end))

-- ── Group: look (operator) ───────────────────────────────────────────
local TOP = 48   -- below the two fullscreen HUD lines

local GLYPH_CARDS = {
    { name = "ASCII",
      text = "ABCDEFG abcdefg\n0123456789\n!?.,:;'\"()[]{}\n@#&%*+-=/<>" },
    { name = "Vietnamese",
      text = "ăâđêôơư ĂÂĐÊÔƠƯ\nạảãàá ẹẻẽèé ịỉĩìí\nọỏõ ụủũ ỳỵỷỹ" },
    -- Two stacked marks (hat + tone) break first when a subset loses its
    -- mark-positioning tables: the font still loads, the marks sit wrong.
    { name = "stacked marks",
      text = "ế ề ể ễ ệ  ố ồ ổ ỗ ộ\nớ ờ ở ỡ ợ  ứ ừ ử ữ ự\nẤ Ầ Ẩ Ẫ Ậ  Ắ Ằ Ẳ Ẵ Ặ" },
    { name = "mixed + currency",
      text = "Xin chào PIKA! 123\nGiá: 50.000₫  Café €5\nĂn cơm chưa?" },
    { name = "capitals with marks",
      text = "ĐƯỜNG LÊN ĐỈNH\nỐC ĐẢO XANH MƯỢT\nGIỮ VỮNG NIỀM TIN" },
}

for _, card in ipairs(GLYPH_CARDS) do
    S:look("look", "glyphs: " .. card.name, function()
        new_label(card.text, 16, TOP + 16, BLACK, 24)
        return free_all
    end, "Every glyph drawn, marks in place?")
end

S:look("look", "sizes 12 / 18 / 24 / 36 / 48", function()
    local y = TOP
    for _, px in ipairs({ 12, 18, 24, 36, 48 }) do
        new_label(fmt("Pika %dpx", px), 16, y, BLACK, px)
        y = y + px + 10
    end
    return free_all
end, "Five lines, each larger than the one above?")

S:look("look", "weight: Black vs Regular", function()
    new_label("Black:   Đường nét đậm 123", 16, TOP + 30, BLACK, 24)
    new_label("Regular: Đường nét mảnh 123", 16, TOP + 80, REGULAR, 24)
    return free_all
end, "Top line clearly bolder, same size?")

S:look("look", "anchors: left / center / right / bottom x3", function()
    for _, where in ipairs({ "left", "center", "right",
                             "bottom_left", "bottom", "bottom_right" }) do
        local t = new_label("[" .. where .. "]", 0, 0, REGULAR, 18, 0xFFC107)
        local _, err = t:align(where, 0, 0)
        if err then error("align " .. where .. ": " .. err) end
    end
    return free_all
end, "Six labels at the edges and centre, none clipped?")

S:look("look", "colours + 24-bit mask", function()
    local colours = {
        { "white  0xFFFFFF", 0xFFFFFF }, { "amber  0xFFC107", 0xFFC107 },
        { "green  0x4CAF50", 0x4CAF50 }, { "red    0xE53935", 0xE53935 },
        { "blue   0x2196F3", 0x2196F3 },
        -- the engine keeps the low 24 bits: shows as 0x123456 (dark blue)
        { "0xFF123456 -> 0x123456", 0xFF123456 },
    }
    for i, c in ipairs(colours) do
        new_label(c[1], 16, TOP + (i - 1) * 34, BLACK, 24, c[2])
    end
    return free_all
end, "Each line in the colour it names?")

S:look("look", "show(false) hides, move() moves", function()
    new_label("1  visible", 16, TOP + 20, BLACK, 24)
    local hidden = new_label("2  YOU SHOULD NOT SEE THIS", 16, TOP + 70, BLACK, 24, 0xE53935)
    hidden:show(false)
    local moved = new_label("3  moved to the bottom", 16, TOP + 120, BLACK, 24)
    moved:move(16, H - 50)
    return free_all
end, "Lines 1 and 3 only, line 3 at the bottom?")

-- ── Lua engine hooks ─────────────────────────────────────────────────
function game_start()
    print(fmt("text: screen %dx%d, %d Text slots", W, H, TEXT_SLOTS))
    S:start()
end

function on_input(action, phase, hold_ms)
    S:input(action, phase, hold_ms)
end

function on_tick(_dt)
    S:tick()
end

function game_end()
    free_all()
    S:summary()
end
