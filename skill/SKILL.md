# Skill — Vibe-code một game Pika

> **Đối tượng: AI viết code** (Claude Code, Cursor, Copilot…), không phải người.
> Bạn đang sinh code Lua chạy trên **Pika Engine** (ESP32-S3, LVGL, FreeRTOS).
> Mục tiêu: game **chạy được ngay** trên engine thật — **không bịa API**.

Đọc theo thứ tự: file này → [api-contract.md](api-contract.md) khi cần signature → [constraints.md](constraints.md) cho giới hạn cứng → [pitfalls.md](pitfalls.md) khi có lỗi.

---

## 1. Luật vàng (vi phạm = game hỏng)

1. **Chỉ gọi API có trong [api-contract.md](api-contract.md).** Không có trong danh sách = **không tồn tại**. Đừng suy ra từ tên (`Engine.now_ms`, `Sprite.rotate`, `require("json")`… đều KHÔNG có). Cần thời gian? Dùng `Timer.millis()`.
2. **Game là một tập hàm global.** Engine gọi vào các **hook** bạn định nghĩa (`game_start`, `on_tick`, …). Không có vòng `while true` — engine giữ vòng lặp; `on_tick` là frame của bạn (~30 FPS, dt ≈ 33ms).
3. **Sandbox chặt.** Không `io`, `os`, `require` module tuỳ ý, không mạng, không file ngoài thư mục game. `require` chỉ nạp được `libs/…` trong chính game. Chi tiết: [constraints.md](constraints.md).
4. **Không block.** Mỗi hook có watchdog **1.5s**. Không `while` chờ, không sleep, không thao tác nặng mỗi frame. Việc dài → chia nhỏ qua `on_tick` + `Timer.millis()`.
5. **Đường dẫn tương đối với gốc game.** `Sprite.image("images/a.png")`, `Speaker.play("hit")`. Không đường dẫn tuyệt đối, không `..`.

---

## 2. Vòng đời & các hook

Engine gọi các hàm global này nếu bạn định nghĩa (đều tuỳ chọn trừ khuyến nghị mạnh):

| Hook | Khi nào gọi | Tham số |
|---|---|---|
| `game_start(level_json)` | 1 lần, khi vào game. Nơi tạo sprite/text/keyword. | `level_json` = string JSON (thường `nil`/rỗng) |
| `on_tick(dt_ms)` | Mỗi frame (~33ms). Frame logic của bạn. | `dt_ms` = số ms từ frame trước |
| `on_input(action, phase, hold_ms)` | Khi có sự kiện nút | `action` string, `phase` = `Input.PRESS/RELEASE/REPEAT`, `hold_ms` int |
| `on_voice_event(e)` | Khi backend trả lệnh giọng | `e` = table (hoặc raw JSON string nếu vượt cap) |
| `on_sound_end(alias, reason)` | Khi 1 âm thanh kết thúc | `reason` = `Speaker.REASON_*` |
| `on_home()` | Nút HOME (lùi 1 cấp). Trả về gì tuỳ game. | — |
| `game_end()` | Trước khi game thoát (dọn dẹp) | — |

> **Không có** `on_draw` / `update` / `love.*`. Vẽ = tạo `Sprite`/`Text` (retained, engine tự render mỗi frame). Bạn chỉ đổi trạng thái của chúng.

> ⚠️ **Quirk `game_start`:** tạo sprite/anim bằng **đường dẫn game-relative** ngay trong `game_start` có thể raise `unsafe path` (id game chưa set kịp). An toàn: tạo ở **frame `on_tick` đầu tiên**. Xem [pitfalls.md](pitfalls.md).

---

## 3. Cấu trúc một game pack

```
<game_id>/
├── manifest.json      # BẮT BUỘC — khai báo game, input, assets
├── icon.png           # icon lưới menu (khuyến nghị)
├── scripts/
│   └── main.lua       # entry_script (theo manifest)
├── images/            # .png / .rgb565 (tuỳ)
├── audio/             # nếu game có tiếng
└── libs/              # module Lua require("libs/x") (copy từ SDK libraries/)
```

### manifest.json tối thiểu

```json
{
  "version": "0.1.0",
  "display_name": "Tên hiển thị",
  "entry_script": "scripts/main.lua",
  "input": {
    "actions": {
      "enter": ["button:enter"],
      "left":  ["button:left"],
      "right": ["button:right"]
    }
  },
  "assets": { "sprites": [], "audio": [] }
}
```

- `input.actions`: ánh xạ **tên action bạn tự đặt** → nguồn phần cứng. Phần cứng chỉ có 3 nút: `button:enter`, `button:left`, `button:right`. `Input.is_down("enter")` dùng chính tên bạn đặt.
- Âm thanh: khai alias trong `manifest.audio.sounds` rồi `Speaker.play("<alias>")`.
- Servo/pose: khai trong `manifest.servos` / `poses`.

---

## 4. Khuôn game tối thiểu (copy được ngay)

Xem [templates/minimal-game/](templates/minimal-game/) cho bản đầy đủ có comment. Rút gọn:

```lua
-- scripts/main.lua
local player          -- sprite, tạo trễ (xem quirk game_start)
local score = 0
local hud

function game_start()
  hud = Text.new("Score: 0", 4, 4)   -- Text OK trong game_start
end

function on_tick(dt_ms)
  if not player then                       -- tạo sprite ở frame đầu (tránh unsafe path)
    player = Sprite.solid(24, 24, 0x07E0)  -- khối xanh 24x24 (RGB565)
    if player then player:set_pos(100, 100) end
    return
  end
  if Input.is_down("left")  then local x,y = player:get_pos(); player:set_pos(x-2, y) end
  if Input.is_down("right") then local x,y = player:get_pos(); player:set_pos(x+2, y) end
end

function on_input(action, phase)
  if action == "enter" and phase == Input.PRESS then
    score = score + 1
    hud:set("Score: " .. score)
  end
end

function on_home()
  Engine.exit("home")   -- thoát game
end
```

Điểm mấu chốt trong khuôn này:
- **Sprite tạo trễ** trong `on_tick` (không phải `game_start`).
- **Text tạo được trong `game_start`.**
- **Đọc nút bằng poll** (`Input.is_down`) cho chuyển động mượt; **sự kiện rời rạc** (bắn, chọn) qua `on_input` + `Input.PRESS`.
- **Không vòng lặp riêng.** Engine gọi `on_tick`.

---

## 5. Dùng thư viện có sẵn (khuyến nghị hơn tự viết)

SDK có sẵn module Lua trong `libraries/` (tween/easing, animator, math…). Trong game: `require("libs/easing")`. Người dùng copy chúng vào `<game>/libs/` khi tạo game (extension: nút **Add to a game…** kéo cả dependency). Đừng tự viết lại tween/collision nếu SDK đã có — xem `libraries/libs.index.json`.

Menu cài đặt trước game (Start / Độ khó / Âm lượng): dùng thẳng recipe [recipes/settings-menu.md](recipes/settings-menu.md).

---

## 6. Trước khi giao game — checklist

- [ ] Chỉ gọi API có trong [api-contract.md](api-contract.md); không có `Engine.now_ms`/`os`/`io`.
- [ ] Sprite/Anim tạo trong `on_tick` đầu, không trong `game_start`.
- [ ] Không hook nào block > 1.5s; không `while` chờ.
- [ ] Text ≤ 8 handle, sprite trong ngân sách, 1 anim tại một thời điểm.
- [ ] `manifest.json` khai đủ actions/audio/servo mà code dùng.
- [ ] Đường dẫn tương đối, không `..`, không tuyệt đối.
- [ ] Nhắc người dùng **regen `s.json`** sau khi sửa file (nếu chạy trên board thật).

---

## 7. Bản đồ tài liệu

| Cần gì | Đọc |
|---|---|
| Bạn là người, muốn quy trình ý tưởng → game | [workflow.md](workflow.md) |
| Signature/ràng buộc từng hàm | [api-contract.md](api-contract.md) |
| Giới hạn cứng (pool, size, timing) | [constraints.md](constraints.md) |
| Lỗi thường gặp + cách sửa | [pitfalls.md](pitfalls.md) |
| Ví dụ theo tác vụ | [recipes/](recipes/) |
| Game rỗng để bắt đầu | [templates/minimal-game/](templates/minimal-game/) |
| Nền tảng engine (dành cho người) | [../docs/api.md](../docs/api.md), [../docs/guide.md](../docs/guide.md) |
| Game mẫu hoàn chỉnh | [../examples/](../examples/) |

_Khớp binding thật của engine (`bind_*.c`) tại thời điểm SDK 1.0.0. Nếu tool báo lệch version → API có thể đã đổi, đối chiếu lại._
