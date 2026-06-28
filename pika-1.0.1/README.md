# `_sdk_<version>/` — Pika SDK trên SD (OTA-update được)

> **Spec gốc:** [Lua/SD-Resources.md](../../../Lua/SD-Resources.md) — kiến trúc đầy đủ. **API:** [docs/sdk/pika-sdk-api-map.md](../../../docs/sdk/pika-sdk-api-map.md).
> **Trạng thái skeleton:** asset nhị phân (`.png/.gif/.mp3/.wav/.bin`) là placeholder 0-byte — drop file thật vào thay. Text file (`.lua/.json/.md/.complete`) là content thật.

## Hai loại entry duy nhất ở `/sd/games/`

```
/sd/games/
├── _sdk_1.0.1/                  # ← SDK umbrella (hạ tầng) — VERSION nằm trong TÊN folder
├── _sdk_1.0.2/                  # ← version mới song song (multi-version coexist)
└── <publisher>/<game>/          # ← game thật (vd: pika/hello-pika/)
```

Browser scan ([statemachine_menu.cpp](../../../back_esp32/main/src/application/statemachine/statemachine_menu.cpp)) **lọc prefix `_*`** → `_sdk_*/` không xuất hiện trong game list. Quy ước: top-level dưới `/sd/games/` bắt đầu `_` = hạ tầng; còn lại = `<pub>/<game>/`.

## Bên trong `_sdk_<version>/`

| Folder | Loại | Atomic | Truy cập từ Lua |
|---|---|---|---|
| `libs/` | subsys | **cluster** (`libs/.complete`) | `require("@sdk/libs/<mod>")` (nested OK) |
| `boot/` | subsys | flat per-file | bootloader đọc trực tiếp (KHÔNG qua Lua) |
| `images/` | subsys | flat per-file | `Sprite.image("@sdk/images/<...>")` |
| `images/emoji/` | trong images | flat per-file | `Emoji.lookup(...)` → `@sdk/images/emoji/png/<hex>.png` |
| `audio/` | subsys | flat per-file | alias khai trong `manifest.audio.sounds` (path `@sdk:audio/<...>`) |
| `fonts/` | subsys | flat per-file | `HUD.set_font("@sdk/fonts/<...>")` (stub phase 1) |
| `examples/` | companion | ship-once | copy folder sang `<pub>/<game>/` để chạy |
| `packs/` | companion | OTA 3rd-party | game khai `requires` trong manifest |

## 3 surface API (xem api-map cho chi tiết)

```lua
-- A. require Lua module (libs/ của SDK game đang pin)
local fsm  = require("@sdk/libs/fsm")
local vec2 = require("@sdk/libs/math/vec2")     -- nested namespace OK

-- B. asset file (images/fonts) — file path resolver, dấu slash
local heart = Sprite.image("@sdk/images/ui/icons/heart.png")
HUD.set_font("@sdk/fonts/vi/regular.ttf", 16)  -- size px, render runtime (tiny_ttf)

-- C. audio — alias khai trong manifest.audio.sounds (path dùng @sdk:audio/ dấu colon)
Speaker.play("click")   -- "click" = alias; manifest: { "click": { "path": "@sdk:audio/ui/click" } }
```

## Folder=truth — KHÔNG có manifest

KHÔNG có `_sdk_<version>/manifest.json`, KHÔNG có `s.json`. Engine sniff folder lúc boot:
- `sdk_index_init()` scan `_sdk_*/`, verify `libs/.complete` → build map `version → root_path`. KHÔNG pick latest, KHÔNG so semver.
- **Per-game pin:** lúc launch đọc `<game>/manifest.json.sdk` (thiếu field = legacy fallback `"1.0.1"`) → resolve `_sdk_<that>/`. Không có trên SD = abort launch với lỗi rõ ràng (KHÔNG fallback latest).

Trust: HTTPS transport + Pika CI (single owner). Xem [SD-Resources.md §7](../../../Lua/SD-Resources.md).

## Cây con đầy đủ

Mỗi subsys có `README.md` riêng giải thích layout + lifecycle. `examples/` chứa game mẫu chạy được ngay sau khi copy.
