# `examples/` — game mẫu ship-with-firmware

**KHÔNG OTA** (khác subsys + packs). Examples khớp Lua API của firmware đang chạy → ship cùng bundle.

## Lifecycle

1. Examples ship trong firmware bundle (hoặc copy lần đầu vào SD lúc setup).
2. User copy folder từ `_sdk_<version>/examples/<name>/` sang `<pub>/<game>/` (vd `pika/<name>/`) để game xuất hiện trong browser.
3. Browser scan ([statemachine_menu.cpp](../../../../back_esp32/main/src/application/statemachine/statemachine_menu.cpp)) lọc prefix `_*` → examples vô hình tới khi copy.

## Examples hiện có

| Folder | engine_level | Mô tả | API touched |
|---|---|---|---|
| `hello/` | 1 | Hello world + menu chọn | HUD, Input, `@sdk/libs/ui` (selector) |
| `sprite-demo/` | 1 | Ô màu di chuyển (asset-free) | Sprite.solid, Input, on_tick |
| `led-blink/` | 7 | Bật/tắt LED + đổi màu | Led, `@sdk/libs/fsm` (cần back board) |
| `pose-demo/` | 7 | Cycle pose servo | Servo.pose/move (cần back board) |
| `image-demo/` | 1 | Sprite PNG di chuyển | Sprite.image (cần asset PNG) |
| `anim-demo/` | 1 | Phát GIF/MJPEG | Anim.new/play/pause (cần asset GIF) |
| `emoji-demo/` | 5 | Emoji hex + lookup | Emoji.path/lookup/set_lang (cần PNG emoji) |
| `voice-demo/` | 7 | Speech recognition | Voice.start/stop + on_voice_event (cần back board) |

> Example dùng asset (`image/anim/emoji`) tham chiếu file thật trên SD nhưng asset đang là placeholder 0-byte — xem block `ASSET REQUIRED` đầu mỗi `main.lua`. Code API đã đúng; drop asset thật để chạy trọn vẹn.

## Mô hình callback (KHÔNG có `Game`)

Engine gọi các **global function** game định nghĩa; thoát bằng `Engine.exit()`:

```lua
local ui = require("@sdk/libs/ui")
local menu
function game_start(level_json) menu = ui.selector({ "Play", "Quit" }); menu:render() end
function on_input(action, phase, hold_ms)
  if phase ~= Input.PRESS then return end
  if action == "next" then menu:next():render()
  elseif action == "fire" and menu:current() == "Quit" then Engine.exit() end
end
function on_tick(dt_ms) end
function game_end() end
```

Hook khác: `on_sound_end(alias, reason)` (L6+), `on_voice_event(event)` (L7+). Xem [api-map §6](../../../../docs/sdk/pika-sdk-api-map.md).

## Khi tạo example mới

- Folder: `<name>/manifest.json` + `<name>/scripts/main.lua`. Game ID = folder name.
- Manifest: `"sdk":"1.0.1"`, `engine_level` đúng mức binding dùng, `input.actions` khai mọi action script đọc. Audio: khai alias trong `audio.sounds` (path `@sdk:audio/...`). Servo L7: khai `servos`/`poses`.
- Reference resource qua `@sdk/...` / `require("@sdk/libs/...")` — KHÔNG hardcode absolute path. Mọi lời gọi phải có trong [api-map](../../../../docs/sdk/pika-sdk-api-map.md).
