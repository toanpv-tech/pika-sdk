# Pika Engine — Hướng dẫn viết Game Pack (Lua)

> **Đối tượng:** Người viết game cho robot PIKA bằng Lua, đặt trên thẻ SD.
> **Phạm vi:** `manifest.json`, vòng đời, sandbox & best practices. Toàn bộ API Lua tách riêng ở [API Reference](api.md).
> **Tài liệu kèm:** [Pika Engine — Module Firmware](module.md) (kiến trúc nội bộ cho kỹ sư firmware).

Một **game pack** là một thư mục trên thẻ SD chứa `manifest.json` + script Lua + asset. Engine nạp pack, dựng một Lua VM sandbox, và gọi các **hook** trong script của bạn theo từng frame (~30 FPS). Bạn điều khiển robot qua các bảng global: `Sprite`, `Anim`, `Text`, `Speaker`, `Servo`, `Led`, `Voice`, `Input`, `State`, `Timer`, `Engine` — chi tiết từng hàm xem [API Reference](api.md).

- Gốc game trên SD: `/sd/games` (`CONFIG_GAME_ENGINE_GAMES_ROOT`)
- Phiên bản Lua: **5.5.0** (sandbox — xem [§6 Sandbox & giới hạn](#6-sandbox--giới-hạn))

---

## 1. Quickstart — game pack đầu tiên

### 1.1. Cấu trúc tối thiểu

```
/sd/games/hello_pika/
├── manifest.json
└── scripts/
    └── main.lua
```

### 1.2. `manifest.json`

```json
{
  "display_name": "Hello Pika",
  "entry_script": "scripts/main.lua",
  "input": {
    "actions": {
      "confirm": ["button:enter"],
      "left":    ["button:left"],
      "right":   ["button:right"]
    }
  }
}
```

### 1.3. `scripts/main.lua`

```lua
local label   -- Text handle, tạo lazy (Text.new cần game screen)

-- Chạy 1 lần khi game bắt đầu
function game_start(level_json)
  label = Text.new("Hello Pika!", 4, 4)
  Servo.pose("say_hi")          -- nếu pose "say_hi" được khai báo trong manifest.servos.poses
end

-- Chạy mỗi frame (~33ms @30FPS)
function on_tick(dt_ms)
  -- cập nhật trạng thái game ở đây
end

-- Chạy mỗi sự kiện nút bấm
function on_input(action, phase, hold_ms)
  if action == "confirm" and phase == Input.PRESS then
    if label then label:set("Pressed ENTER") end
  end
end

-- HOME ngắn: trả true để giữ game chạy, false/nil để thoát
function on_home()
  return false   -- để HOME thoát game như mặc định
end
```

> Mỗi game pack **self-contained**: mọi asset (libs/ images/ audio/ fonts/) nằm dưới `/sd/games/<game_id>/` của chính nó. Không còn SDK bundle dùng chung, không còn versioning.

---

## 2. Cấu trúc thư mục trên thẻ SD

Mỗi game pack **self-contained** — tự mang mọi asset của riêng nó, không có bundle dùng chung:

```
/sd/games/
└── <game_id>/                  # game pack của bạn (game_id = tên thư mục)
    ├── manifest.json           # bắt buộc
    ├── scripts/main.lua        # entry_script mặc định
    ├── libs/                   # .lua dùng qua require("libs/<module>")
    │   └── <module>.lua
    ├── sprites/ images/        # ảnh RGB565 thô / PNG
    ├── audio/                  # file âm thanh (alias trong manifest)
    ├── animations/             # .gif / .mjpeg
    ├── fonts/                  # .ttf (Text:set_font)
    └── save.sav                # do State.save tạo (không sửa thủ công)
```

### Quy tắc path (sandbox)

- **Game-relative:** mọi đường dẫn resolve dưới `/sd/games/<game_id>/`. Ví dụ `"sprites/hero.png"` → `/sd/games/<game_id>/sprites/hero.png`, `"libs/util"` (require) → `/sd/games/<game_id>/libs/util.lua`.
- **Cấm:** đường dẫn tuyệt đối, `..`, `\`, `:`, ký tự control, segment rỗng. Vi phạm → binding STRICT **raise**, binding factory trả `(nil, msg)`. Path tối đa 200 byte.

---

## 3. `manifest.json` — schema đầy đủ

Tham chiếu: [game_pack.c](../../head_esp32/components/game_engine/src/core/game_pack.c) (giới hạn 64KB, parse cJSON), [input.c](../../head_esp32/components/game_engine/src/subsystems/input/input.c), [sound.c](../../head_esp32/components/game_engine/src/subsystems/sound/sound.c), [servo.c](../../head_esp32/components/game_engine/src/subsystems/servo/servo.c).

### 3.1. Field gốc

| Field | Kiểu | Bắt buộc | Default | Giới hạn |
|---|---|---|---|---|
| `display_name` | string | không | `""` | ≤ 63 ký tự (buffer 64 gồm NUL; dài hơn bị cắt) |
| `entry_script` | string | không | `"scripts/main.lua"` | ≤ 63 ký tự (dài hơn bị cắt) |
| `input` | object | không | xem 3.2 | ≤ 16 action, tên ≤ 23 ký tự |
| `audio` | object | không | rỗng | ≤ 64 sound |
| `servos` / `poses` | object | không | rỗng | ≤ 8 servo / ≤ 16 pose, alias ≤ 23 ký tự |

> **Hành vi khi vượt giới hạn — KHÔNG đồng nhất, cần nhớ:**
> - `audio.sounds` vượt **64** → engine **âm thầm bỏ bớt** (giữ 64 cái đầu, không báo lỗi).
> - `input.actions` vượt **16**, `servos` vượt **8**, `poses` vượt **16** → **reject cả pack** với `GAME_ENGINE_ERR_PACK_MANIFEST`.
> - `display_name`/`entry_script` dài hơn 63 ký tự → **cắt cụt** (không reject).
>
> Sai kiểu bất kỳ bảng con nào (input/audio/servo) cũng làm cả manifest bị từ chối.

### 3.2. `input.actions`

Map **tên action** (bạn tự đặt) → mảng nguồn nút. Action name là thứ bạn nhận trong `on_input` và truyền vào `Input.*`.

```json
"input": {
  "actions": {
    "jump":  ["button:enter"],
    "move":  ["button:left", "button:right"]
  }
}
```

- Nguồn hợp lệ: `"button:enter"`, `"button:left"`, `"button:right"` (nhiều nguồn/action được — bitmask).
- Action name: 1–24 ký tự, duy nhất. Tối đa **16 action**.
- **Bỏ block `input`** → engine dùng mặc định: `confirm → [button:enter]`, `left → [button:left]`, `right → [button:right]`.

### 3.3. `audio.sounds`

Khai báo alias âm thanh để gọi `Speaker.play("alias")`.

```json
"audio": {
  "sounds": {
    "shoot":  { "path": "audio/shoot.wav", "loop": false },
    "bgm":    { "path": "audio/loop.wav", "loop": true }
  },
  "volume": 75
}
```

- `path`: ≤ 64 ký tự, safe relative (game-relative, resolve dưới `/sd/games/<game_id>/`).
- `loop`: bool, default false. `volume`: 0–100, override volume phiên (khôi phục khi thoát game).
- Tối đa **64 alias**, tên 1–24 ký tự. File được `stat()` ngay lúc nạp manifest → sai đường dẫn sẽ làm pack nạp thất bại.

### 3.4. `servos` & `poses`

```json
"servos": { "neck": "head", "torso": "body" },
"poses":  { "hello": "say_hi", "win": "cheer_jump" }
```

- `servos`: map alias → hardware target. Target hợp lệ (phân biệt hoa thường): `"head"`, `"base"` (hoặc `"body"`), `"left"`, `"right"`. Tối đa **8 alias**.
- `poses`: map alias → tên gesture có sẵn của robot. Tối đa **16 alias**. Tên gesture hợp lệ (wire-stable, append-only):

  `default`, `poke`, `talk_random_v1`, `talk_random_v2`, `say_hi`, `raise_both`, `idle_talk_1`, `idle_talk_2`, `greeting`, `noaction`, `left_arm_rotate`, `open_menu`, `admiring`, `cheer_jump`, `left_wave`, `system_error`

---

## 4. Vòng đời & hook

Tất cả hook đều **optional** (thiếu thì engine bỏ qua, không báo lỗi) và chạy dưới `pcall` + watchdog (1.5s/lần) + budget PSRAM. Lỗi/timeout trong `game_start`/`on_tick`/`on_input`/`on_sound_end`/`on_voice_event` sẽ **kết thúc game** kèm `EVT_ERROR`.

| Hook | Chữ ký | Khi nào gọi | Trả về |
|---|---|---|---|
| `game_start(level_json)` | `(string)` | 1 lần khi bắt đầu (sau khi script nạp xong) | bỏ qua |
| `on_tick(dt_ms)` | `(integer)` | mỗi frame (~33ms @30FPS) | bỏ qua |
| `on_input(action, phase, hold_ms)` | `(string, int, int)` | mỗi input event, **trước** `on_tick` cùng frame | bỏ qua |
| `on_input_lost(count)` | `(integer)` | khi input ring (32 slot) tràn | bỏ qua |
| `on_sound_end(alias, reason)` | `(string, int)` | khi audio kết thúc | bỏ qua |
| `on_sound_lost(count)` | `(integer)` | khi finish-ring (8 slot) tràn | bỏ qua |
| `on_voice_event(event)` | `(table\|string)` | mỗi frame voice_session | bỏ qua |
| `on_home()` | `()` | HOME ngắn khi đang chơi | **bool**: true=giữ game, false/nil=thoát |
| `game_end()` | `()` | khi teardown (stop/home-thoát/kết thúc) | bỏ qua (lỗi non-fatal) |

`phase` của `on_input`: `Input.PRESS` (0) / `Input.RELEASE` (1) / `Input.REPEAT` (2). `hold_ms` = 0 khi PRESS.

> **Thứ tự trong 1 frame:** sound drain (`on_sound_end`) → input drain (`on_input`/`on_input_lost`) → `on_tick` → reset edge → servo/led/sound-stop drain → anim pump. Vì vậy `Input.just_pressed()` đúng trong cả `on_input` lẫn `on_tick` của cùng frame.

> 📖 Chữ ký, hằng số và hành vi của từng hàm `Sprite`/`Anim`/`Speaker`/`Servo`/`Led`/`Voice`/… nằm trong [API Reference](api.md#tham-chiếu-api-lua).

---

## 5. `require` & thư viện dùng chung

Chỉ một dạng được phép:

```lua
local util = require("libs/util")   -- → /sd/games/<game_id>/libs/util.lua
```

Module được cache 1 phiên. Dạng khác (`require("util")` không có prefix `libs/`, có `..`) đều bị từ chối.

---

## 6. Sandbox & giới hạn

Lua VM bị giới hạn để bảo vệ firmware:

- **Thư viện mở:** `base`, `table`, `string`, `math`, `utf8`. **Không có:** `io`, `os`, `package`, `debug`, `coroutine`; `load`/`loadfile`/`dofile` bị vô hiệu hóa (gán `nil`).
- **Bộ nhớ:** toàn bộ alloc của Lua nằm trong budget PSRAM **512KB** (`CONFIG_GAME_ENGINE_LUA_HEAP_KB`). Vượt → script nhận lỗi memory (pcall bắt). Engine phát `EVT_MEM_FALLBACK` khi chạm 90%.
- **Watchdog:** mỗi lần engine gọi hook của bạn có trần **1.5s**; vòng lặp vô tận trong `on_tick` sẽ bị cắt và kết thúc game.
- **Frame budget:** `on_tick` nên xong trong ~33ms; nếu engine_task treo >5s (ví dụ deadlock binding) stall detector kết thúc game.

---

## 7. Best practices

- So sánh `reason`/`phase` bằng hằng (`Speaker.REASON_*`, `Input.*`), không dùng số literal.
- `State.save()` chỉ ở checkpoint (chạm FATFS chậm) — **không** gọi trong `on_tick`.
- Bọc factory trả `(nil,msg)`: `local s = Sprite.image(p); if not s then print("load fail", p) end`.
- Không tạo sprite/anim mới mỗi frame — tái sử dụng + `:destroy()` khi xong (trần 32 sprite).
- `Servo.is_busy`/`Speaker.is_playing` là **dự đoán**, không phải trạng thái thật của phần cứng — không xây logic phụ thuộc tuyệt đối vào chúng.
- Giữ danh sách `Voice.set_keywords` gọn (≤64 keyword; JSON encode ≤2048B, sâu ≤4, ≤32 key).
- `Led.blink` period phải ∈ [333,5000]ms — ngoài range bị **từ chối** (không tự clamp), kiểm `if not Led.blink(...)`.

> Bảng tra giá trị nhanh (FPS, max sprite, watchdog, trần file…): xem [API Reference](api.md#bảng-tra-giá-trị-nhanh).

---

_Khớp code tại nhánh `feat/game_engine`. Chính sách version & quy tắc bump: xem [README](README.md). Chi tiết hiện thực: [Module Firmware](module.md)._
