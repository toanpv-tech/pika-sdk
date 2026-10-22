-- test_sprite: the Sprite API (Sprite.new / image / solid and every sprite method).
--
-- Groups (suite order):
--   probe  : what the factories return, sizes from file / header, positions
--   guard  : bad arguments raise; runtime failures return nil, msg (factories)
--            or false (boolean methods), as contract/semantics.json says
--   geom   : get_pos, hit_test, intersects against known rectangles (async:
--            the position is read a few frames after set_pos, see below)
--   xform  : set_scale / set_rotation / set_pivot return values and clamps
--   flip   : set_flip return values
--   frame  : set_frame on raw, solid and opaque PNG sprites, past-the-end
--   life   : destroy is idempotent; every method after destroy is a no-op
--   mem    : same-path images share pixels, full-screen churn
--   look   : the operator judges the screen: colours, alpha, frame swap, flip,
--            rotation, scale, opacity, z-order, visibility, pivot.
--            ENTER = looks right, RIGHT = looks wrong.
--   manual : left out of RUN SUITE: rows smoke.py reports as errors on purpose
--            (transform refusal, set_frame on an alpha PNG) and a PSRAM
--            exhaustion run that can starve the rest of the head board.
--
-- Positions: the engine reads a sprite's position back from LVGL, which
-- applies set_pos at the next screen refresh. "set_pos -> get_pos same frame"
-- checks the contract as written; the geom group waits a few frames so a
-- failure there means wrong geometry, not a late refresh.
--
-- Every test destroys the objects it made (free_all), also on failure and on
-- abort. Assets (assets/, ~33 KB): arrow.png, ball.png (RGBA 64x64),
-- photo.png + photo.rgb565 (the same 96x64 picture), tile.png (RGB 48x48),
-- strip.rgb565 (4 frames 48x48, digits 0..3), wide.png (481x2).

-- img_max_w / img_max_h, transform_max_px in contract/constraints.json.
local IMG_MAX_W, IMG_MAX_H = 480, 320
local XFORM_MAX = 96
-- set_pivot range: -img_max_w..x2_max, -img_max_h..y2_max (derived).
local PIVOT_X_MAX, PIVOT_Y_MAX = 960, 640
local SETTLE_FRAMES = 5          -- frames between set_pos and the geometry read
local PSRAM_CAP = 48             -- full-screen solids tried by the exhaustion row (~14 MiB)

local ARROW, BALL = "assets/arrow.png", "assets/ball.png"
local PHOTO_PNG, PHOTO_RAW = "assets/photo.png", "assets/photo.rgb565"
local TILE, WIDE = "assets/tile.png", "assets/wide.png"
local STRIP, STRIP_FRAMES = "assets/strip.rgb565", 4
local REGULAR = "fonts/nunito-regular.ttf"

local fmt = string.format
local TOP = 48                   -- below the two fullscreen HUD lines

-- Objects made by the running test (sprites and caption Text); free_all()
-- destroys them. Keeping them here also stops the GC from collecting them.
local made = {}

local function keep(o) made[#made + 1] = o; return o end

local function free_all()
    for i = #made, 1, -1 do
        made[i]:destroy()
        made[i] = nil
    end
end

local function solid(w, h, rgb565, x, y)
    local s, err = Sprite.solid(w, h, rgb565)
    if not s then error("Sprite.solid: " .. tostring(err)) end
    keep(s)
    if x then s:set_pos(x, y) end
    return s
end

local function image(path, x, y)
    local s, err = Sprite.image(path)
    if not s then error("Sprite.image: " .. tostring(err)) end
    keep(s)
    if x then s:set_pos(x, y) end
    return s
end

local function raw(path, w, h, x, y)
    local s, err = Sprite.new(path, w, h)
    if not s then error("Sprite.new: " .. tostring(err)) end
    keep(s)
    if x then s:set_pos(x, y) end
    return s
end

local function caption(str)
    local t, err = Text.new(str, 8, 290)
    if not t then error("Text.new: " .. tostring(err)) end
    keep(t)
    t:set_font(REGULAR, 14)
    return t
end

-- Runs fn with every object it made destroyed afterwards.
local function with_objs(fn)
    return function()
        local ok, pass, msg = pcall(fn)
        free_all()
        if not ok then error(pass, 0) end
        return pass, msg
    end
end

-- true when f(...) raises; a value it returned instead is destroyed.
local function raises(f, ...)
    local ok, r = pcall(f, ...)
    if ok and type(r) ~= "nil" and type(r) ~= "boolean" then pcall(function() r:destroy() end) end
    return not ok, ok and "returned instead of raising" or "raised"
end

-- nil, msg factory failure; a handle it returned instead is destroyed.
local function fails(what, s, err)
    if s then
        keep(s)
        return false, what .. " returned a sprite"
    end
    return type(err) == "string", fmt("%s -> nil, %s", what, tostring(err))
end

-- ── Suite ────────────────────────────────────────────────────────────
local tk = require("libs/testkit")

local S = tk.suite({
    tag = "sprite", title = "SPRITE TEST",
    font = REGULAR, font_px = 14,
    groups = {
        probe  = { label = "PROBE",     what = "factory results, sizes, positions" },
        guard  = { label = "GUARDS",    what = "bad args raise, failures nil/false" },
        geom   = { label = "GEOMETRY",  what = "get_pos, hit_test, intersects" },
        xform  = { label = "TRANSFORM", what = "scale / rotation / pivot returns" },
        flip   = { label = "FLIP",      what = "set_flip returns" },
        frame  = { label = "FRAMES",    what = "set_frame on strip / solid / PNG" },
        life   = { label = "LIFETIME",  what = "destroy, calls after destroy" },
        mem    = { label = "MEMORY",    what = "shared PNG pixels, PSRAM churn" },
        look   = { label = "LOOK",      what = "operator checks the screen" },
        manual = { label = "MANUAL",    what = "smoke errors on purpose, PSRAM" },
    },
    status = function() return fmt("objects held by this test: %d", #made) end,
    on_abort = free_all,
})

-- ── Group: probe ─────────────────────────────────────────────────────
S:sync("probe", "Sprite.solid -> handle, get_size = w, h", with_objs(function()
    local s = solid(40, 30, 0xF800)
    local w, h = s:get_size()
    return w == 40 and h == 30, fmt("get_size -> %s, %s", tostring(w), tostring(h))
end))

S:sync("probe", "new sprite sits at (0, 0) before set_pos", with_objs(function()
    local s = solid(10, 10, 0x07E0)
    local x, y = s:get_pos()
    return x == 0 and y == 0, fmt("get_pos -> %s, %s", tostring(x), tostring(y))
end))

S:sync("probe", "Sprite.image alpha PNG -> 64x64 from header", with_objs(function()
    local w, h = image(ARROW):get_size()
    return w == 64 and h == 64, fmt("arrow.png -> %dx%d", w, h)
end))

S:sync("probe", "Sprite.image opaque PNG -> 96x64", with_objs(function()
    local w, h = image(PHOTO_PNG):get_size()
    return w == 96 and h == 64, fmt("photo.png -> %dx%d", w, h)
end))

S:sync("probe", "Sprite.new raw RGB565 -> 96x64", with_objs(function()
    local w, h = raw(PHOTO_RAW, 96, 64):get_size()
    return w == 96 and h == 64, fmt("photo.rgb565 -> %dx%d", w, h)
end))

S:sync("probe", "Sprite.new on a 4-frame strip uses frame 0", with_objs(function()
    local w, h = raw(STRIP, 48, 48):get_size()
    return w == 48 and h == 48, fmt("strip.rgb565 48x48 -> %dx%d", w, h)
end))

-- Contract as written: get_pos returns what set_pos set. On the robot the
-- value comes from LVGL coordinates refreshed at the next screen update.
S:sync("probe", "set_pos -> get_pos in the same frame", with_objs(function()
    local s = solid(20, 20, 0x001F)
    s:set_pos(123, 77)
    local x, y = s:get_pos()
    return x == 123 and y == 77, fmt("set (123, 77) -> get (%s, %s)", tostring(x), tostring(y))
end))

S:sync("probe", "get_size unchanged by set_scale(512)", with_objs(function()
    local s = solid(40, 30, 0xFFE0, 300, 200)
    local ok = s:set_scale(512)
    local w, h = s:get_size()
    return ok == true and w == 40 and h == 30,
           fmt("set_scale -> %s, get_size -> %dx%d", tostring(ok), w, h)
end))

-- ── Group: guard ─────────────────────────────────────────────────────
-- "Non-string" probes pass a table: Lua converts a number to a string where a
-- string is expected (luaL_checkstring), so 42 is a valid path.
S:sync("guard", "Sprite.image(table) raises", function()
    return raises(Sprite.image, {})
end)

S:sync("guard", "Sprite.image unsafe paths raise", function()
    for _, p in ipairs({ "../escape.png", "/sd/abs.png", "assets//arrow.png", "assets/./arrow.png" }) do
        local r = raises(Sprite.image, p)
        if not r then return false, p .. " did not raise" end
    end
    return true, "../, absolute, //, ./ all raised"
end)

S:sync("guard", "Sprite.image missing file -> nil, msg", with_objs(function()
    return fails("missing.png", Sprite.image("assets/missing.png"))
end))

S:sync("guard", "Sprite.image 481 px wide -> nil, msg", with_objs(function()
    return fails("wide.png 481x2", Sprite.image(WIDE))
end))

S:sync("guard", "Sprite.image of a non-PNG -> nil, msg", with_objs(function()
    return fails("strip.rgb565 as PNG", Sprite.image(STRIP))
end))

S:sync("guard", "Sprite.new(table, w, h) raises", function()
    return raises(Sprite.new, {}, 4, 4)
end)

S:sync("guard", "Sprite.new unsafe path raises", function()
    return raises(Sprite.new, "../strip.rgb565", 48, 48)
end)

S:sync("guard", "Sprite.new fractional w raises", function()
    return raises(Sprite.new, STRIP, 47.5, 48)
end)

S:sync("guard", "Sprite.new missing file -> nil, msg", with_objs(function()
    return fails("missing.rgb565", Sprite.new("assets/missing.rgb565", 8, 8))
end))

S:sync("guard", "Sprite.new file too small -> nil, msg", with_objs(function()
    -- photo.rgb565 holds 96*64*2 bytes; 96x65 needs 192 more
    return fails("96x65 from a 96x64 file", Sprite.new(PHOTO_RAW, 96, 65))
end))

S:sync("guard", "Sprite.new w 481 -> nil, msg", with_objs(function()
    return fails("481x2", Sprite.new(STRIP, IMG_MAX_W + 1, 2))
end))

-- The engine rejects a zero size before reading the file
-- (asset_loader.c asset_load_rgb565: w <= 0 -> ESP_ERR_INVALID_ARG).
S:sync("guard", "Sprite.new w 0 -> nil, msg", with_objs(function()
    return fails("0x48", Sprite.new(STRIP, 0, 48))
end))

S:sync("guard", "Sprite.solid size out of 1..480 x 1..320 raises", function()
    for _, wh in ipairs({ { 0, 10 }, { 10, 0 }, { IMG_MAX_W + 1, 10 }, { 10, IMG_MAX_H + 1 }, { -5, 10 } }) do
        if not raises(Sprite.solid, wh[1], wh[2], 0xFFFF) then
            return false, fmt("%dx%d did not raise", wh[1], wh[2])
        end
    end
    return true, "0x10, 10x0, 481x10, 10x321, -5x10 all raised"
end)

S:sync("guard", "Sprite.solid fractional w raises", function()
    return raises(Sprite.solid, 10.5, 10, 0xFFFF)
end)

S:sync("guard", "Sprite.solid 480x320 (full screen) -> sprite", with_objs(function()
    local s, err = Sprite.solid(IMG_MAX_W, IMG_MAX_H, 0x0000)
    if s then keep(s) end
    return s ~= nil, s and "created" or ("-> nil, " .. tostring(err))
end))

S:sync("guard", "set_pos fractional raises", with_objs(function()
    local s = solid(8, 8, 0xFFFF)
    return raises(s.set_pos, s, 1.5, 0)
end))

-- Methods are called through a real handle's metatable with a table as self.
local function non_sprite_self(methods)
    return with_objs(function()
        local s = solid(8, 8, 0xFFFF)
        for _, m in ipairs(methods) do
            if not raises(s[m], {}) then return false, m .. "({}) did not raise" end
        end
        return true, table.concat(methods, ", ") .. " raised"
    end)
end

S:sync("guard", "get_pos / get_size / set_flip / set_visible on a non-sprite raise",
    non_sprite_self({ "get_pos", "get_size", "set_flip", "set_visible" }))

S:sync("guard", "to_front / to_back on a non-sprite raise",
    non_sprite_self({ "to_front", "to_back" }))

S:sync("guard", "intersects(table) raises", with_objs(function()
    local s = solid(8, 8, 0xFFFF)
    return raises(s.intersects, s, {})
end))

S:sync("guard", "set_opacity(table) raises", with_objs(function()
    local s = solid(8, 8, 0xFFFF)
    return raises(s.set_opacity, s, {})
end))

S:sync("guard", "set_opacity 300 / -5 / 127.6 clamp, no raise", with_objs(function()
    local s = solid(8, 8, 0xFFFF, 400, 300)
    for _, a in ipairs({ 300, -5, 127.6 }) do
        local ok, err = pcall(s.set_opacity, s, a)
        if not ok then return false, fmt("%s raised: %s", tostring(a), tostring(err)) end
    end
    return true, "no raise"
end))

S:sync("guard", "set_z fractional raises", with_objs(function()
    local s = solid(8, 8, 0xFFFF)
    return raises(s.set_z, s, 1.5)
end))

S:sync("guard", "set_z -5 / 100000 clamp, no raise", with_objs(function()
    local s = solid(8, 8, 0xFFFF, 400, 300)
    local ok1 = pcall(s.set_z, s, -5)
    local ok2 = pcall(s.set_z, s, 100000)
    return ok1 and ok2, fmt("-5 %s, 100000 %s", ok1 and "ok" or "raised", ok2 and "ok" or "raised")
end))

S:sync("guard", "set_scale / set_rotation fractional raise", with_objs(function()
    local s = solid(8, 8, 0xFFFF)
    local r1 = raises(s.set_scale, s, 256.5)
    local r2 = raises(s.set_rotation, s, 900.5)
    return r1 and r2, fmt("set_scale %s, set_rotation %s", r1 and "raised" or "returned",
                          r2 and "raised" or "returned")
end))

S:sync("guard", "set_pivot fractional raises", with_objs(function()
    local s = solid(8, 8, 0xFFFF)
    return raises(s.set_pivot, s, 1.5, 0)
end))

S:sync("guard", "hit_test fractional raises", with_objs(function()
    local s = solid(8, 8, 0xFFFF)
    return raises(s.hit_test, s, 1.5, 0)
end))

S:sync("guard", "set_frame unsafe path raises", with_objs(function()
    local s = raw(STRIP, 48, 48)
    return raises(s.set_frame, s, "../strip.rgb565", 0)
end))

S:sync("guard", "set_frame fractional index raises", with_objs(function()
    local s = raw(STRIP, 48, 48)
    return raises(s.set_frame, s, STRIP, 1.5)
end))

-- ── Group: geom (async) ──────────────────────────────────────────────
-- place() creates and positions sprites; check() runs SETTLE_FRAMES frames
-- later. Handles live in G (and in made) until free_all.
local G = {}

local function placed(name, place, check)
    S:async("geom", name,
        function()
            local ok, err = pcall(place)
            if not ok then free_all(); error(err, 0) end
            return { frames = 0 }
        end,
        function(st)
            st.frames = st.frames + 1
            if st.frames < SETTLE_FRAMES then return false end
            local ok, pass, msg = pcall(check)
            free_all()
            for k in pairs(G) do G[k] = nil end
            if not ok then error(pass, 0) end
            return true, pass, msg
        end)
end

placed("get_pos after set_pos, off-screen allowed",
    function()
        G.a = solid(20, 20, 0x001F, 123, 77)
        G.b = solid(20, 20, 0x001F, -20, 400)
    end,
    function()
        local ax, ay = G.a:get_pos()
        local bx, by = G.b:get_pos()
        return ax == 123 and ay == 77 and bx == -20 and by == 400,
               fmt("a (%d, %d) want (123, 77); b (%d, %d) want (-20, 400)", ax, ay, bx, by)
    end)

-- 40x30 at (100, 150): inside is [100, 140) x [150, 180).
placed("hit_test: half-open box [x, x+w) x [y, y+h)",
    function() G.a = solid(40, 30, 0xF800, 100, 150) end,
    function()
        local cases = {
            { 100, 150, true }, { 139, 179, true }, { 120, 165, true },
            { 140, 150, false }, { 100, 180, false }, { 99, 150, false }, { 100, 149, false },
        }
        for _, c in ipairs(cases) do
            local r = G.a:hit_test(c[1], c[2])
            if r ~= c[3] then return false, fmt("(%d, %d) -> %s, want %s", c[1], c[2], tostring(r), tostring(c[3])) end
        end
        return true, "7 points on and around the box"
    end)

placed("hit_test ignores visibility and scale",
    function()
        G.a = solid(40, 30, 0xF800, 100, 150)
        G.a:set_visible(false)
        G.b = solid(40, 30, 0x07E0, 300, 150)
        G.b:set_scale(512)              -- drawn 80x60 around its centre
    end,
    function()
        local hidden = G.a:hit_test(110, 160)
        local scaled_in = G.b:hit_test(310, 160)
        local scaled_out = G.b:hit_test(345, 155)   -- inside the drawn 2x box only
        return hidden == true and scaled_in == true and scaled_out == false,
               fmt("hidden -> %s, scaled inside -> %s, scaled outside source -> %s",
                   tostring(hidden), tostring(scaled_in), tostring(scaled_out))
    end)

-- a: [100, 140) x [150, 180)
placed("intersects: overlap, touching edge, inside, symmetric",
    function()
        G.a = solid(40, 30, 0xF800, 100, 150)
        G.overlap = solid(10, 10, 0x07E0, 139, 179)   -- shares pixel (139, 179)
        G.edge_x = solid(10, 10, 0x07E0, 140, 150)    -- starts where a ends
        G.edge_y = solid(10, 10, 0x07E0, 100, 140)    -- ends where a starts
        G.inside = solid(10, 10, 0x07E0, 110, 160)
        G.big = solid(200, 100, 0x001F, 50, 120)       -- contains a
        G.far = solid(10, 10, 0x07E0, 400, 50)
    end,
    function()
        local cases = {
            { "overlap", true }, { "edge_x", false }, { "edge_y", false },
            { "inside", true }, { "big", true }, { "far", false },
        }
        for _, c in ipairs(cases) do
            local o = G[c[1]]
            local ab, ba = G.a:intersects(o), o:intersects(G.a)
            if ab ~= c[2] or ba ~= c[2] then
                return false, fmt("%s: a->o %s, o->a %s, want %s", c[1], tostring(ab), tostring(ba), tostring(c[2]))
            end
        end
        local self = G.a:intersects(G.a)
        return self == true, "6 pairs both ways; self -> " .. tostring(self)
    end)

-- ── Group: xform ─────────────────────────────────────────────────────
S:sync("xform", "set_scale 256 / 0 / 100000 -> true (clamped)", with_objs(function()
    local s = image(ARROW, 380, 200)
    local a, b, c = s:set_scale(256), s:set_scale(0), s:set_scale(100000)
    s:set_scale(256)
    return a == true and b == true and c == true,
           fmt("-> %s, %s, %s", tostring(a), tostring(b), tostring(c))
end))

S:sync("xform", "set_rotation 900 / -900 / 7200 -> true", with_objs(function()
    local s = image(ARROW, 380, 200)
    local a, b, c = s:set_rotation(900), s:set_rotation(-900), s:set_rotation(7200)
    return a == true and b == true and c == true,
           fmt("-> %s, %s, %s", tostring(a), tostring(b), tostring(c))
end))

S:sync("xform", "96x96 is transformable (limit inclusive)", with_objs(function()
    local s = solid(XFORM_MAX, XFORM_MAX, 0x07E0, 380, 200)
    local a, b = s:set_scale(384), s:set_rotation(450)
    return a == true and b == true, fmt("set_scale -> %s, set_rotation -> %s", tostring(a), tostring(b))
end))

S:sync("xform", "set_pivot inside -480..960 x -320..640 -> true", with_objs(function()
    local s = image(ARROW, 380, 200)
    for _, p in ipairs({ { 0, 0 }, { -IMG_MAX_W, -IMG_MAX_H }, { PIVOT_X_MAX, PIVOT_Y_MAX }, { 32, 32 } }) do
        local r = s:set_pivot(p[1], p[2])
        if r ~= true then return false, fmt("(%d, %d) -> %s", p[1], p[2], tostring(r)) end
    end
    return true, "4 pivots accepted"
end))

S:sync("xform", "set_pivot outside the range -> false", with_objs(function()
    local s = image(ARROW, 380, 200)
    for _, p in ipairs({ { PIVOT_X_MAX + 1, 0 }, { -IMG_MAX_W - 1, 0 }, { 0, PIVOT_Y_MAX + 1 }, { 0, -IMG_MAX_H - 1 } }) do
        local r = s:set_pivot(p[1], p[2])
        if r ~= false then return false, fmt("(%d, %d) -> %s, want false", p[1], p[2], tostring(r)) end
    end
    return true, "961, -481, 641, -321 refused"
end))

S:sync("xform", "set_pivot is not gated by the transform limit", with_objs(function()
    local s = solid(200, 200, 0x001F, 260, 100)
    local r = s:set_pivot(100, 100)
    return r == true, "200x200 set_pivot -> " .. tostring(r)
end))

-- ── Group: flip ──────────────────────────────────────────────────────
S:sync("flip", "set_flip h, again, off -> true each", with_objs(function()
    local s = raw(PHOTO_RAW, 96, 64, 360, 240)
    local a, b, c = s:set_flip(true, false), s:set_flip(true, false), s:set_flip(false, false)
    return a == true and b == true and c == true,
           fmt("-> %s, %s (same state), %s", tostring(a), tostring(b), tostring(c))
end))

S:sync("flip", "set_flip h+v on an alpha PNG -> true", with_objs(function()
    local s = image(ARROW, 380, 240)
    local r = s:set_flip(true, true)
    return r == true, "-> " .. tostring(r)
end))

S:sync("flip", "set_flip v on a solid -> true", with_objs(function()
    local s = solid(30, 20, 0xF81F, 380, 240)
    local r = s:set_flip(false, true)
    return r == true, "-> " .. tostring(r)
end))

-- ── Group: frame ─────────────────────────────────────────────────────
S:sync("frame", "set_frame 0..3 on the strip -> true", with_objs(function()
    local s = raw(STRIP, 48, 48, 400, 240)
    for i = 0, STRIP_FRAMES - 1 do
        local r = s:set_frame(STRIP, i)
        if r ~= true then return false, fmt("frame %d -> %s", i, tostring(r)) end
    end
    return true, fmt("%d frames", STRIP_FRAMES)
end))

S:sync("frame", "set_frame past the end / -1 -> false", with_objs(function()
    local s = raw(STRIP, 48, 48, 400, 240)
    local a, b = s:set_frame(STRIP, STRIP_FRAMES), s:set_frame(STRIP, -1)
    return a == false and b == false, fmt("frame %d -> %s, -1 -> %s", STRIP_FRAMES, tostring(a), tostring(b))
end))

S:sync("frame", "set_frame missing file -> false", with_objs(function()
    local s = raw(STRIP, 48, 48, 400, 240)
    local r = s:set_frame("assets/missing.rgb565", 0)
    return r == false, "-> " .. tostring(r)
end))

S:sync("frame", "set_frame on a 48x48 solid -> true", with_objs(function()
    local s = solid(48, 48, 0x0000, 400, 240)
    local r = s:set_frame(STRIP, 2)
    return r == true, "-> " .. tostring(r)
end))

S:sync("frame", "set_frame on an opaque PNG sprite -> true", with_objs(function()
    local s = image(TILE, 400, 240)
    local r = s:set_frame(STRIP, 3)
    return r == true, "tile.png (RGB) -> " .. tostring(r)
end))

-- ── Group: life ──────────────────────────────────────────────────────
S:sync("life", "destroy twice: no raise", function()
    local s, err = Sprite.solid(8, 8, 0xFFFF)
    if not s then return false, "Sprite.solid: " .. tostring(err) end
    s:destroy()
    local ok = pcall(s.destroy, s)
    return ok, ok and "second destroy ok" or "second destroy raised"
end)

S:sync("life", "after destroy: setters are silent no-ops", function()
    local s, err = Sprite.solid(8, 8, 0xFFFF)
    if not s then return false, "Sprite.solid: " .. tostring(err) end
    s:set_pos(10, 10)
    s:destroy()
    local calls = {
        { "set_pos", 1, 2 }, { "set_visible", true }, { "set_opacity", 100 },
        { "set_z", 0 }, { "to_front" }, { "to_back" },
    }
    for _, c in ipairs(calls) do
        local ok, e = pcall(s[c[1]], s, c[2], c[3])
        if not ok then return false, c[1] .. " raised: " .. tostring(e) end
    end
    return true, "6 setters, no raise"
end)

S:sync("life", "after destroy: get_pos / get_size -> 0, 0", function()
    local s, err = Sprite.solid(40, 30, 0xFFFF)
    if not s then return false, "Sprite.solid: " .. tostring(err) end
    s:set_pos(100, 100)
    s:destroy()
    local x, y = s:get_pos()
    local w, h = s:get_size()
    return x == 0 and y == 0 and w == 0 and h == 0,
           fmt("get_pos -> %s, %s; get_size -> %s, %s", tostring(x), tostring(y), tostring(w), tostring(h))
end)

S:sync("life", "after destroy: boolean methods -> false", function()
    local s, err = Sprite.new(STRIP, 48, 48)
    if not s then return false, "Sprite.new: " .. tostring(err) end
    s:set_pos(100, 100)
    s:destroy()
    local r = {
        set_frame = s:set_frame(STRIP, 1), set_flip = s:set_flip(true, false),
        set_scale = s:set_scale(512), set_rotation = s:set_rotation(900),
        set_pivot = s:set_pivot(0, 0), hit_test = s:hit_test(0, 0),
    }
    for _, k in ipairs({ "set_frame", "set_flip", "set_scale", "set_rotation", "set_pivot", "hit_test" }) do
        if r[k] ~= false then return false, k .. " -> " .. tostring(r[k]) end
    end
    return true, "set_frame, set_flip, set_scale, set_rotation, set_pivot, hit_test -> false"
end)

-- ── Group: mem ───────────────────────────────────────────────────────
-- Sprite.image of a path a live sprite uses shares its pixels; set_flip on one
-- takes a private copy first. Destroying the first owner must leave the others
-- intact.
S:sync("mem", "same PNG x3: destroy one, the others still work", with_objs(function()
    local a, b, c = image(ARROW, 300, 240), image(ARROW, 360, 240), image(ARROW, 420, 240)
    a:destroy()
    local flip = b:set_flip(true, false)
    local w, h = c:get_size()
    return flip == true and w == 64 and h == 64,
           fmt("b:set_flip -> %s, c:get_size -> %dx%d", tostring(flip), w, h)
end))

S:sync("mem", "full-screen solid x10 create + destroy", function()
    for i = 1, 10 do
        local s, err = Sprite.solid(IMG_MAX_W, IMG_MAX_H, 0x0000)
        if not s then return false, fmt("round %d -> nil, %s", i, tostring(err)) end
        s:destroy()
    end
    return true, "10 x 300 KB allocated and freed"
end)

-- ── Group: look (operator) ───────────────────────────────────────────
local function look(name, show, question)
    S:look("look", name, function()
        local ok, err = pcall(show)
        if not ok then free_all(); error(err, 0) end
        return free_all
    end, question)
end

look("RGB565 colours, low 16 bits only", function()
    local x = 40
    for _, c in ipairs({ 0xF800, 0x07E0, 0x001F, 0x1F800 }) do
        solid(80, 80, c, x, TOP + 60)
        x = x + 105
    end
    caption("red 0xF800, green 0x07E0, blue 0x001F, 0x1F800 -> red")
end, "Red, green, blue, red?")

look("PNG alpha over stripes", function()
    for i = 0, 7 do
        solid(480, 15, (i % 2 == 0) and 0xFFFF or 0x8410, 0, TOP + 40 + i * 15)
    end
    image(BALL, 120, TOP + 68)
    image(ARROW, 280, TOP + 68)
    caption("disc and arrow: stripes show through the corners")
end, "Corners see-through?")

look("opaque PNG vs raw RGB565", function()
    image(PHOTO_PNG, 100, TOP + 60)
    raw(PHOTO_RAW, 96, 64, 280, TOP + 60)
    caption("left photo.png, right photo.rgb565: same picture")
end, "Both pictures identical?")

look("set_frame: strip, solid, opaque PNG", function()
    for i = 0, STRIP_FRAMES - 1 do
        local s = raw(STRIP, 48, 48, 30 + i * 70, TOP + 70)
        if s:set_frame(STRIP, i) ~= true then error("set_frame " .. i) end
    end
    local so = solid(48, 48, 0x0000, 310, TOP + 70)
    if so:set_frame(STRIP, 2) ~= true then error("solid set_frame") end
    local t = image(TILE, 380, TOP + 70)
    if t:set_frame(STRIP, 3) ~= true then error("tile set_frame") end
    caption("boxes read 0 1 2 3, then 2 (solid) and 3 (PNG)")
end, "Reads 0 1 2 3 2 3?")

look("set_flip: none, h, v, h+v", function()
    local flips = { { false, false }, { true, false }, { false, true }, { true, true } }
    for i, f in ipairs(flips) do
        local s = image(ARROW, 40 + (i - 1) * 110, TOP + 70)
        if s:set_flip(f[1], f[2]) ~= true then error("set_flip " .. i) end
    end
    caption("1 right, 2 left, 3 right dot below, 4 left dot below")
end, "Mirrored as captioned?")

look("rotation and scale", function()
    for i, deg10 in ipairs({ 0, 450, 900, 1800 }) do
        local s = image(ARROW, 30 + (i - 1) * 110, TOP + 10)
        if s:set_rotation(deg10) ~= true then error("set_rotation " .. deg10) end
    end
    for i, sc in ipairs({ 128, 256, 384 }) do
        local s = image(ARROW, 60 + (i - 1) * 140, TOP + 140)
        if s:set_scale(sc) ~= true then error("set_scale " .. sc) end
    end
    caption("top 0/45/90/180 deg clockwise; bottom x0.5 x1 x1.5")
end, "Angles and sizes right?")

look("set_opacity 255 / 170 / 85 / 0", function()
    solid(480, 40, 0xF800, 0, TOP + 80)
    for i, a in ipairs({ 255, 170, 85, 0 }) do
        local s = solid(80, 80, 0xFFFF, 30 + (i - 1) * 115, TOP + 60)
        s:set_opacity(a)
    end
    caption("white squares fade left to right, the 4th invisible")
end, "Fades out, 4th gone?")

-- Created red, green, blue (blue on top), then reordered: red to_front, blue
-- to_back, green set_z(huge) -> bottom to top: blue, red, green.
look("z-order: to_front, to_back, set_z", function()
    local r = solid(110, 110, 0xF800, 120, TOP + 30)
    local g = solid(110, 110, 0x07E0, 170, TOP + 70)
    local b = solid(110, 110, 0x001F, 220, TOP + 110)
    r:to_front()
    b:to_back()
    g:set_z(100000)
    caption("green on top, red in the middle, blue at the bottom")
end, "Stacked as captioned?")

-- A sprite hidden by set_visible(false) stays hidden through set_pos; one
-- never placed is never drawn (it would sit at 0, 0 over the title).
look("visibility: hidden, never placed, re-shown", function()
    solid(70, 70, 0x07E0, 60, TOP + 70)
    local hidden = solid(70, 70, 0xF800, 160, TOP + 70)
    hidden:set_visible(false)
    keep(Sprite.solid(70, 70, 0xF800) or error("Sprite.solid"))     -- never placed
    local moved = solid(70, 70, 0xF800)
    moved:set_visible(false)
    moved:set_pos(260, TOP + 70)
    local back = solid(70, 70, 0x07E0, 360, TOP + 70)
    back:set_visible(false)
    back:set_visible(true)
    caption("two green squares, no red anywhere")
end, "Two green, no red?")

look("set_pivot: centre vs top-left", function()
    local a = image(ARROW, 100, TOP + 80)
    a:set_rotation(900)
    local b = image(ARROW, 300, TOP + 80)
    if b:set_pivot(0, 0) ~= true then error("set_pivot") end
    b:set_rotation(900)
    solid(6, 6, 0xFFFF, 297, TOP + 77)     -- marks b's top-left corner
    caption("left turns 90 in place; right swings round the white dot")
end, "Pivots as captioned?")

-- ── Group: manual ────────────────────────────────────────────────────
-- smoke.py reports a transform on a sprite over the limit as an ERROR (XFORM)
-- although the robot just returns false, so the row stays out of RUN SUITE.
S:sync("manual", "97x96 set_scale / set_rotation -> false", with_objs(function()
    local s = solid(XFORM_MAX + 1, XFORM_MAX, 0x07E0, 380, 200)
    local a, b = s:set_scale(512), s:set_rotation(900)
    return a == false and b == false,
           fmt("set_scale -> %s, set_rotation -> %s (log: sprite_xform refused)", tostring(a), tostring(b))
end), { manual = true })

-- smoke.py reports set_frame on an alpha PNG as an ERROR (FRAME-FMT).
S:sync("manual", "set_frame on an alpha PNG sprite -> false", with_objs(function()
    local s = image(ARROW, 380, 200)
    local r = s:set_frame(STRIP, 0)
    return r == false, "-> " .. tostring(r) .. " (log: set_frame refused reason=alpha_sprite)"
end), { manual = true })

-- Drives PSRAM to empty: while it runs, GIF decode, audio buffers and LVGL on
-- the head board can fail too, so it is never part of RUN SUITE. Everything is
-- freed before the row returns.
S:sync("manual", "PSRAM: full-screen solids until nil", with_objs(function()
    for i = 1, PSRAM_CAP do
        local s, err = Sprite.solid(IMG_MAX_W, IMG_MAX_H, 0x0000)
        if not s then
            free_all()
            return err == "oom" or err == "sprite create failed",
                   fmt("%d created (%d KB), then nil, %s", i - 1, (i - 1) * 300, tostring(err))
        end
        keep(s)
    end
    return false, fmt("all %d created (%d KB): no PSRAM limit reached", PSRAM_CAP, PSRAM_CAP * 300)
end), { manual = true })

-- ── Lua engine hooks ─────────────────────────────────────────────────
function game_start()
    print(fmt("sprite: screen %dx%d, transform limit %d px", IMG_MAX_W, IMG_MAX_H, XFORM_MAX))
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
