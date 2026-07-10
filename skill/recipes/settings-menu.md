# Recipe — Menu cài đặt trước khi vào game

**Mục tiêu:** màn hình đầu game cho chọn Độ khó / Âm lượng rồi bấm Start — **không tự viết**, dùng lib `libs/settings` có sẵn trong SDK.

**API dùng:** `require("libs/settings")` → `settings.new(spec)`, forward nút qua `menu:input`.

### 1. Copy lib vào game

Cần `libs/settings.lua` (extension nút **Add to a game…** sẽ kéo cả dependency của nó). Sau đó:

```lua
local settings = require("libs/settings")
```

### 2. Định nghĩa menu + chuyển sang game khi Start

```lua
local settings = require("libs/settings")
local menu           -- màn settings (nil sau khi vào game)
local cfg            -- cấu hình đã chọn
local player

-- Gọi khi người chơi bấm Start
local function start_game(chosen)
  cfg  = chosen        -- { difficulty=<index>, volume=<number>, ... }
  menu = nil           -- rời menu → vào game
  Speaker.set_volume(cfg.volume or 60)
end

function on_tick()
  if menu then return end          -- đang ở màn settings, chờ nút

  if not player then               -- vừa Start → dựng game (tạo trễ, pitfalls #1)
    player = Sprite.solid(24, 24, 0x07E0)
    if player then player:set_pos(140, 180) end
    return
  end
  -- ... vòng game bình thường, đọc cfg.difficulty ...
end

function on_input(action, phase)
  if menu then
    menu:input(action, phase)      -- lib tự xử lý nav + Start
    return
  end
  -- input trong game
end

function game_start()
  menu = settings.new({
    title       = "Cai dat",       -- nhãn ASCII (xem lưu ý font)
    start_label = "Bat dau",
    on_start    = start_game,      -- BẮT BUỘC
    rows = {
      { kind = "choice", key = "difficulty", label = "Do kho",
        options = { "De", "Vua", "Kho" } },              -- cfg.difficulty = 1/2/3
      { kind = "range",  key = "volume", label = "Am luong",
        lo = 0, hi = 100, step = 10, default = 60 },      -- cfg.volume = số
    },
  })
end
```

**Ghi chú:**
- `on_start(cfg)` **bắt buộc**. `cfg[key]`: `choice` → **index** (1-based), `range` → **số**.
- Phải **forward `on_input` → `menu:input(action, phase)`** khi menu còn sống; lib lo nav 3-nút và nút Start.
- Có save? `settings.new` hỗ trợ `has_save`/`on_resume` (Continue vs New) — xem `libs/settings.lua`.
- **Lưu ý font:** dùng nhãn **ASCII không dấu** ("Do kho" không "Độ khó") trừ khi đã `set_font` một TTF có glyph tiếng Việt; font mặc định thiếu dấu.

Chi tiết đầy đủ: đọc header của [../../libraries/settings.lua](../../libraries/settings.lua).
